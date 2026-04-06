// apps/event-consumer/Program.cs
// Consumes enriched sensor events from Kafka 'sensor-events'.
// Reconstructs W3C trace context to continue the distributed trace.
// Writes results to Redis and logs with traceId for Kibana correlation.
//
// Secrets via Vault Agent:
//   /vault/secrets/kafka.env — KAFKA_BOOTSTRAP, KAFKA_USERNAME, KAFKA_PASSWORD,
//                              KAFKA_SASL_MECHANISM, KAFKA_SECURITY_PROTOCOL
//   /vault/secrets/redis.env — REDIS_HOST, REDIS_PORT, REDIS_PASSWORD

using System.Diagnostics;
using System.Text.Json;
using Confluent.Kafka;
using OpenTelemetry;
using OpenTelemetry.Context.Propagation;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Logs;
using StackExchange.Redis;

// ── Load Vault Agent secrets before host starts ────────────────────────────────
var vaultSecretsPath = "/vault/secrets";
if (Directory.Exists(vaultSecretsPath))
{
    foreach (var file in Directory.GetFiles(vaultSecretsPath, "*.env"))
    {
        foreach (var line in File.ReadAllLines(file))
        {
            var parts = line.Split('=', 2);
            if (parts.Length == 2)
                Environment.SetEnvironmentVariable(parts[0].Trim(), parts[1].Trim());
        }
    }
}

// ── Host — .NET 6 compatible (CreateDefaultBuilder, not CreateApplicationBuilder) ──
var host = Host.CreateDefaultBuilder(args)
    .ConfigureServices((ctx, services) =>
    {
        var config = ctx.Configuration;

        var kafkaBootstrap = config["KAFKA_BOOTSTRAP"]         ?? "localhost:9092";
        var kafkaUser      = config["KAFKA_USERNAME"]          ?? "sensor";
        var kafkaPassword  = config["KAFKA_PASSWORD"]          ?? throw new InvalidOperationException("KAFKA_PASSWORD not set");
        var kafkaSaslMech  = config["KAFKA_SASL_MECHANISM"]    ?? "PLAIN";
        var kafkaSecProto  = config["KAFKA_SECURITY_PROTOCOL"] ?? "SASL_PLAINTEXT";
        var redisHost      = config["REDIS_HOST"]              ?? "localhost";
        var redisPort      = int.Parse(config["REDIS_PORT"]    ?? "6379");
        var redisPass      = config["REDIS_PASSWORD"]          ?? throw new InvalidOperationException("REDIS_PASSWORD not set");
        var otlpEndpoint   = config["OTEL_EXPORTER_OTLP_ENDPOINT"]
                             ?? "http://otel-collector-gateway.observability.svc.cluster.local:4317";
        var kafkaTopic     = config["KAFKA_TOPIC"]             ?? "sensor-events";

        var activitySource = new ActivitySource("event-consumer");

        services.AddOpenTelemetry()
            .ConfigureResource(r => r
                .AddService("event-consumer", serviceVersion: "1.0.0")
                .AddAttributes(new Dictionary<string, object>
                {
                    ["deployment.environment"] = "poc",
                    ["service.namespace"]      = "sensor-demo"
                }))
            .WithTracing(t => t
                .AddSource("event-consumer")
                .AddOtlpExporter(o => o.Endpoint = new Uri(otlpEndpoint)))
            .WithLogging(l => l
                .AddOtlpExporter(o => o.Endpoint = new Uri(otlpEndpoint)));

        services.AddHostedService(sp =>
            new ConsumerWorker(
                sp.GetRequiredService<ILogger<ConsumerWorker>>(),
                activitySource,
                kafkaBootstrap, kafkaUser, kafkaPassword, kafkaSaslMech, kafkaSecProto,
                redisHost, redisPort, redisPass,
                kafkaTopic
            ));
    })
    .Build();

host.Run();

public class ConsumerWorker : BackgroundService
{
    private readonly ILogger<ConsumerWorker> _log;
    private readonly ActivitySource _tracer;
    private readonly string _kafkaBootstrap;
    private readonly string _kafkaUser;
    private readonly string _kafkaPassword;
    private readonly string _kafkaSaslMech;
    private readonly string _kafkaSecProto;
    private readonly string _redisHost;
    private readonly int _redisPort;
    private readonly string _redisPass;
    private readonly string _kafkaTopic;

    private static readonly TextMapPropagator Propagator = Propagators.DefaultTextMapPropagator;

    public ConsumerWorker(
        ILogger<ConsumerWorker> log, ActivitySource tracer,
        string kafkaBootstrap, string kafkaUser, string kafkaPassword,
        string kafkaSaslMech, string kafkaSecProto,
        string redisHost, int redisPort, string redisPass,
        string kafkaTopic)
    {
        _log = log; _tracer = tracer;
        _kafkaBootstrap = kafkaBootstrap; _kafkaUser = kafkaUser;
        _kafkaPassword = kafkaPassword; _kafkaSaslMech = kafkaSaslMech;
        _kafkaSecProto = kafkaSecProto;
        _redisHost = redisHost; _redisPort = redisPort; _redisPass = redisPass;
        _kafkaTopic = kafkaTopic;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        // ── Redis ──────────────────────────────────────────────────────────────
        _log.LogInformation("Connecting to Redis {Host}:{Port}", _redisHost, _redisPort);
        var redis = await ConnectionMultiplexer.ConnectAsync(new ConfigurationOptions
        {
            EndPoints = { { _redisHost, _redisPort } },
            Password  = _redisPass,
            AbortOnConnectFail = false
        });
        var db = redis.GetDatabase();

        // ── Kafka consumer ─────────────────────────────────────────────────────
        var kafkaConfig = new ConsumerConfig
        {
            BootstrapServers = _kafkaBootstrap,
            SecurityProtocol = _kafkaSecProto.ToUpper() switch {
                "SASL_PLAINTEXT" => SecurityProtocol.SaslPlaintext,
                "PLAINTEXT"      => SecurityProtocol.Plaintext,
                "SSL"            => SecurityProtocol.Ssl,
                "SASL_SSL"       => SecurityProtocol.SaslSsl,
                _ => throw new ArgumentException($"Unknown security protocol: {_kafkaSecProto}")
            },
            SaslMechanism    = SaslMechanism.Plain,
            SaslUsername     = _kafkaUser,
            SaslPassword     = _kafkaPassword,
            GroupId          = "event-consumer-group",
            AutoOffsetReset  = AutoOffsetReset.Earliest,
            // Commit offsets manually after successful processing
            EnableAutoCommit = false
        };

        using var consumer = new ConsumerBuilder<string, string>(kafkaConfig).Build();
        consumer.Subscribe(_kafkaTopic);
        _log.LogInformation("Subscribed to Kafka topic: {Topic}", _kafkaTopic);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                // Poll with a short timeout so we check cancellation regularly
                var result = consumer.Consume(TimeSpan.FromSeconds(1));
                if (result is null) continue;

                await ProcessEventAsync(result, db, ct);
                consumer.Commit(result);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (ConsumeException ex)
            {
                _log.LogError("Kafka consume error: {Reason}", ex.Error.Reason);
                await Task.Delay(5_000, ct);
            }
        }

        consumer.Close();
        redis.Dispose();
    }

    private async Task ProcessEventAsync(
        ConsumeResult<string, string> result,
        IDatabase db,
        CancellationToken ct)
    {
        EnrichedSensorEvent? evt;
        try
        {
            evt = JsonSerializer.Deserialize<EnrichedSensorEvent>(result.Message.Value);
            if (evt is null) return;
        }
        catch (Exception ex)
        {
            _log.LogWarning("Failed to deserialise Kafka message: {Error}", ex.Message);
            return;
        }

        // ── Restore trace context from the Kafka message envelope ──────────────
        // The mqtt-bridge embedded the current traceparent when it published.
        // We extract it here to create a child span — completing the three-service
        // trace chain: sensor-producer → mqtt-bridge → event-consumer.
        // All three spans share the same traceId, visible as one trace in Kibana.
        ActivityContext parentContext = default;
        if (!string.IsNullOrEmpty(evt.TraceParent))
        {
            var carrier = new Dictionary<string, string>
            {
                ["traceparent"] = evt.TraceParent,
                ["tracestate"]  = evt.TraceState ?? string.Empty
            };
            var propagationContext = Propagator.Extract(
                default,
                carrier,
                (c, key) => c.TryGetValue(key, out var val) ? new[] { val } : Array.Empty<string>());
            parentContext = propagationContext.ActivityContext;
        }

        using var activity = _tracer.StartActivity(
            "consume-sensor-event",
            ActivityKind.Consumer,
            parentContext);

        activity?.SetTag("sensor.id",       evt.SensorId);
        activity?.SetTag("sensor.value",    evt.Value);
        activity?.SetTag("sensor.trend",    evt.Trend);
        activity?.SetTag("sensor.delta",    evt.Delta?.ToString() ?? "n/a");
        activity?.SetTag("kafka.topic",     _kafkaTopic);
        activity?.SetTag("kafka.partition", result.Partition.Value);
        activity?.SetTag("kafka.offset",    result.Offset.Value);

        // ── Write result to Redis ──────────────────────────────────────────────
        using var redisSpan = _tracer.StartActivity("redis-result-write", ActivityKind.Client);
        redisSpan?.SetTag("db.system",    "redis");
        redisSpan?.SetTag("db.operation", "SET");
        redisSpan?.SetTag("sensor.id",    evt.SensorId);

        var resultKey = $"consumer:result:{evt.SensorId}";
        var resultValue = JsonSerializer.Serialize(new
        {
            sensorId    = evt.SensorId,
            value       = evt.Value,
            unit        = evt.Unit,
            trend       = evt.Trend,
            delta       = evt.Delta,
            processedAt = DateTimeOffset.UtcNow,
            traceId     = activity?.TraceId.ToString() ?? string.Empty
        });

        try
        {
            await db.StringSetAsync(resultKey, resultValue, TimeSpan.FromMinutes(10));
            redisSpan?.SetTag("db.result", "ok");
        }
        catch (Exception ex)
        {
            redisSpan?.SetStatus(ActivityStatusCode.Error, ex.Message);
            _log.LogWarning("Redis result write failed: {Message}", ex.Message);
        }

        // ── Structured log with traceId embedded ───────────────────────────────
        // With the OTel logging bridge active, the trace_id and span_id are
        // automatically attached to this log record as structured fields in
        // Elasticsearch — enabling direct log-to-trace correlation in Kibana
        // without relying on the [trace:xxxxxxxx] body text prefix.
        _log.LogInformation(
            "[trace:{TraceId}] Consumed event sensorId={SensorId} value={Value}{Unit} trend={Trend} delta={Delta}",
            activity?.TraceId.ToString()[..8] ?? "none",
            evt.SensorId,
            evt.Value,
            evt.Unit,
            evt.Trend,
            evt.Delta.HasValue ? evt.Delta.Value.ToString("+0.00;-0.00;0.00") : "n/a");
    }
}

// ── Message type ──────────────────────────────────────────────────────────────
public record EnrichedSensorEvent
{
    public string TraceParent  { get; init; } = string.Empty;
    public string TraceState   { get; init; } = string.Empty;
    public string SensorId     { get; init; } = string.Empty;
    public double Value        { get; init; }
    public string Unit         { get; init; } = string.Empty;
    public DateTimeOffset Timestamp   { get; init; }
    public double? PreviousValue      { get; init; }
    public double? Delta              { get; init; }
    public string Trend               { get; init; } = "unknown";
    public DateTimeOffset BridgedAt   { get; init; }
}
