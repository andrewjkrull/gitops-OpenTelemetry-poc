// apps/mqtt-bridge/Program.cs
// Bridges MQTT sensor readings to Kafka.
// Subscribes to 'sensors/reading', enriches with Redis delta, publishes to Kafka.
// Extracts W3C traceparent from each MQTT message to continue the distributed trace.
//
// Secrets via Vault Agent:
//   /vault/secrets/mqtt.env  — MQTT_HOST, MQTT_PORT, MQTT_USERNAME, MQTT_PASSWORD
//   /vault/secrets/redis.env — REDIS_HOST, REDIS_PORT, REDIS_PASSWORD
//   /vault/secrets/kafka.env — KAFKA_BOOTSTRAP, KAFKA_USERNAME, KAFKA_PASSWORD,
//                              KAFKA_SASL_MECHANISM, KAFKA_SECURITY_PROTOCOL

using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Confluent.Kafka;
using MQTTnet;
using MQTTnet.Client;
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

        var mqttHost       = config["MQTT_HOST"]               ?? "localhost";
        var mqttPort       = int.Parse(config["MQTT_PORT"]     ?? "1883");
        var mqttUser       = config["MQTT_USERNAME"]           ?? "sensor";
        var mqttPassword   = config["MQTT_PASSWORD"]           ?? throw new InvalidOperationException("MQTT_PASSWORD not set");
        var redisHost      = config["REDIS_HOST"]              ?? "localhost";
        var redisPort      = int.Parse(config["REDIS_PORT"]    ?? "6379");
        var redisPass      = config["REDIS_PASSWORD"]          ?? throw new InvalidOperationException("REDIS_PASSWORD not set");
        var kafkaBootstrap = config["KAFKA_BOOTSTRAP"]         ?? "localhost:9092";
        var kafkaUser      = config["KAFKA_USERNAME"]          ?? "sensor";
        var kafkaPassword  = config["KAFKA_PASSWORD"]          ?? throw new InvalidOperationException("KAFKA_PASSWORD not set");
        var kafkaSaslMech  = config["KAFKA_SASL_MECHANISM"]    ?? "PLAIN";
        var kafkaSecProto  = config["KAFKA_SECURITY_PROTOCOL"] ?? "SASL_PLAINTEXT";
        var otlpEndpoint   = config["OTEL_EXPORTER_OTLP_ENDPOINT"]
                             ?? "http://otel-collector-gateway.observability.svc.cluster.local:4317";
        var mqttTopic      = config["MQTT_TOPIC"]              ?? "sensors/reading";
        var kafkaTopic     = config["KAFKA_TOPIC"]             ?? "sensor-events";
        var bridgeDelayMs  = config["BRIDGE_DELAY_MS"] is string d
                             ? int.Parse(d) : 0;

        var activitySource = new ActivitySource("mqtt-bridge");

        services.AddOpenTelemetry()
            .ConfigureResource(r => r
                .AddService("mqtt-bridge", serviceVersion: "1.0.0")
                .AddAttributes(new Dictionary<string, object>
                {
                    ["deployment.environment"] = "poc",
                    ["service.namespace"]      = "sensor-demo"
                }))
            .WithTracing(t => t
                .AddSource("mqtt-bridge")
                .AddOtlpExporter(o => o.Endpoint = new Uri(otlpEndpoint)))
            .WithLogging(l => l
                .AddOtlpExporter(o => o.Endpoint = new Uri(otlpEndpoint)));

        services.AddHostedService(sp =>
            new BridgeWorker(
                sp.GetRequiredService<ILogger<BridgeWorker>>(),
                activitySource,
                mqttHost, mqttPort, mqttUser, mqttPassword,
                redisHost, redisPort, redisPass,
                kafkaBootstrap, kafkaUser, kafkaPassword, kafkaSaslMech, kafkaSecProto,
                mqttTopic, kafkaTopic, bridgeDelayMs
            ));
    })
    .Build();

host.Run();

public class BridgeWorker : BackgroundService
{
    private readonly ILogger<BridgeWorker> _log;
    private readonly ActivitySource _tracer;
    private readonly string _mqttHost;
    private readonly int _mqttPort;
    private readonly string _mqttUser;
    private readonly string _mqttPassword;
    private readonly string _redisHost;
    private readonly int _redisPort;
    private readonly string _redisPass;
    private readonly string _kafkaBootstrap;
    private readonly string _kafkaUser;
    private readonly string _kafkaPassword;
    private readonly string _kafkaSaslMech;
    private readonly string _kafkaSecProto;
    private readonly string _mqttTopic;
    private readonly string _kafkaTopic;
    private readonly int    _bridgeDelayMs;

    // W3C trace context propagator — used to extract context from message envelopes
    private static readonly TextMapPropagator Propagator = Propagators.DefaultTextMapPropagator;

    public BridgeWorker(
        ILogger<BridgeWorker> log, ActivitySource tracer,
        string mqttHost, int mqttPort, string mqttUser, string mqttPassword,
        string redisHost, int redisPort, string redisPass,
        string kafkaBootstrap, string kafkaUser, string kafkaPassword,
        string kafkaSaslMech, string kafkaSecProto,
        string mqttTopic, string kafkaTopic, int bridgeDelayMs)
    {
        _log = log; _tracer = tracer;
        _mqttHost = mqttHost; _mqttPort = mqttPort;
        _mqttUser = mqttUser; _mqttPassword = mqttPassword;
        _redisHost = redisHost; _redisPort = redisPort; _redisPass = redisPass;
        _kafkaBootstrap = kafkaBootstrap; _kafkaUser = kafkaUser;
        _kafkaPassword = kafkaPassword; _kafkaSaslMech = kafkaSaslMech;
        _kafkaSecProto = kafkaSecProto;
        _mqttTopic = mqttTopic; _kafkaTopic = kafkaTopic;
        _bridgeDelayMs = bridgeDelayMs;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        // ── Redis ──────────────────────────────────────────────────────────────
        _log.LogInformation("Connecting to Redis {Host}:{Port}", _redisHost, _redisPort);
        var redis = await ConnectionMultiplexer.ConnectAsync(new ConfigurationOptions
        {
            EndPoints = { { _redisHost, _redisPort } },
            Password = _redisPass,
            AbortOnConnectFail = false
        });
        var db = redis.GetDatabase();

        // ── Kafka producer ─────────────────────────────────────────────────────
        _log.LogInformation("Creating Kafka producer → {Bootstrap}", _kafkaBootstrap);
        var kafkaConfig = new ProducerConfig
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
            // Delivery guarantees — at least once
            Acks             = Acks.All,
            MessageSendMaxRetries = 3
        };
        using var producer = new ProducerBuilder<string, string>(kafkaConfig).Build();

        // ── MQTT client ────────────────────────────────────────────────────────
        _log.LogInformation("Connecting to MQTT {Host}:{Port}", _mqttHost, _mqttPort);
        var mqttFactory = new MqttFactory();
        using var mqttClient = mqttFactory.CreateMqttClient();

        // Wire up message handler BEFORE connecting
        mqttClient.ApplicationMessageReceivedAsync += async e =>
        {
            await HandleMessageAsync(e, db, producer, ct);
        };

        var mqttOptions = new MqttClientOptionsBuilder()
            .WithTcpServer(_mqttHost, _mqttPort)
            .WithCredentials(_mqttUser, _mqttPassword)
            .WithClientId($"mqtt-bridge-{Environment.MachineName}")
            .WithKeepAlivePeriod(TimeSpan.FromSeconds(30))
            .Build();

        // Connect with retry
        while (!mqttClient.IsConnected && !ct.IsCancellationRequested)
        {
            try
            {
                await mqttClient.ConnectAsync(mqttOptions, ct);
                _log.LogInformation("MQTT connected");
            }
            catch (Exception ex)
            {
                _log.LogWarning("MQTT connect failed: {Message} — retrying in 5s", ex.Message);
                await Task.Delay(5_000, ct);
            }
        }

        // Subscribe to sensor readings topic
        var subscribeOptions = new MqttClientSubscribeOptionsBuilder()
            .WithTopicFilter(_mqttTopic)
            .Build();
        await mqttClient.SubscribeAsync(subscribeOptions, ct);
        _log.LogInformation("Subscribed to MQTT topic: {Topic}", _mqttTopic);
        _log.LogInformation("Bridge delay: {DelayMs}ms", _bridgeDelayMs);

        // Keep alive until cancelled
        await Task.Delay(Timeout.Infinite, ct).ContinueWith(_ => { });

        await mqttClient.DisconnectAsync();
        redis.Dispose();
    }

    private async Task HandleMessageAsync(
        MqttApplicationMessageReceivedEventArgs e,
        IDatabase db,
        IProducer<string, string> producer,
        CancellationToken ct)
    {
        var payload = Encoding.UTF8.GetString(e.ApplicationMessage.PayloadSegment);
        SensorMessage? msg;
        try
        {
            msg = JsonSerializer.Deserialize<SensorMessage>(payload);
            if (msg is null) return;
        }
        catch (Exception ex)
        {
            _log.LogWarning("Failed to deserialise MQTT message: {Error}", ex.Message);
            return;
        }

        // ── Restore trace context from the message envelope ────────────────────
        // The sensor-producer embedded a W3C traceparent in the message.
        // We parse it here to create a child span that continues the same trace.
        // This is the key to end-to-end distributed tracing across MQTT.
        ActivityContext parentContext = default;
        if (!string.IsNullOrEmpty(msg.TraceParent))
        {
            // Use the propagator to extract context from a dictionary carrier
            var carrier = new Dictionary<string, string>
            {
                ["traceparent"] = msg.TraceParent,
                ["tracestate"]  = msg.TraceState ?? string.Empty
            };
            var propagationContext = Propagator.Extract(
                default,
                carrier,
                (c, key) => c.TryGetValue(key, out var val) ? new[] { val } : Array.Empty<string>());
            parentContext = propagationContext.ActivityContext;
        }

        // Start a child span linked to the producer's span
        using var activity = _tracer.StartActivity(
            "bridge-sensor-reading",
            ActivityKind.Consumer,
            parentContext);

        activity?.SetTag("sensor.id",       msg.SensorId);
        activity?.SetTag("sensor.value",    msg.Value);
        activity?.SetTag("mqtt.topic",      _mqttTopic);
        activity?.SetTag("kafka.topic",     _kafkaTopic);

        // ── Redis enrichment — read previous value ─────────────────────────────
        double? previousValue = null;
        double? delta = null;
        string trend = "unknown";

        using var redisSpan = _tracer.StartActivity("redis-enrich", ActivityKind.Client);
        redisSpan?.SetTag("db.system",    "redis");
        redisSpan?.SetTag("db.operation", "GET");
        redisSpan?.SetTag("sensor.id",    msg.SensorId);

        try
        {
            var prevRaw = await db.StringGetAsync($"bridge:previous:{msg.SensorId}");
            if (prevRaw.HasValue && double.TryParse(prevRaw.ToString(), out var prev))
            {
                previousValue = prev;
                delta = Math.Round(msg.Value - prev, 2);
                trend = delta > 0.5 ? "rising" : delta < -0.5 ? "falling" : "stable";
                redisSpan?.SetTag("db.result",    "hit");
                redisSpan?.SetTag("sensor.delta", delta);
                redisSpan?.SetTag("sensor.trend", trend);
            }
            else
            {
                redisSpan?.SetTag("db.result", "miss");
            }

            await db.StringSetAsync(
                $"bridge:previous:{msg.SensorId}",
                msg.Value.ToString(),
                TimeSpan.FromMinutes(10));
        }
        catch (Exception ex)
        {
            redisSpan?.SetStatus(ActivityStatusCode.Error, ex.Message);
            _log.LogWarning("Redis enrich failed: {Message}", ex.Message);
        }

        activity?.SetTag("sensor.trend", trend);
        activity?.SetTag("sensor.delta", delta?.ToString() ?? "n/a");

        // ── Injected delay (latency demo knob) ────────────────────────────────
        // BRIDGE_DELAY_MS > 0 adds artificial latency before the Kafka publish.
        // This is the Phase 5b demo mechanism: the delay is counted inside the
        // bridge-sensor-reading span, so it is immediately visible in the
        // Service Latency Over Time panel in Kibana without any code deployment.
        if (_bridgeDelayMs > 0)
        {
            activity?.SetTag("bridge.injected_delay_ms", _bridgeDelayMs);
            await Task.Delay(_bridgeDelayMs, ct);
        }

        // ── Build enriched Kafka event ─────────────────────────────────────────
        var enriched = new EnrichedSensorEvent
        {
            TraceParent    = activity != null
                ? $"00-{activity.TraceId}-{activity.SpanId}-{(activity.ActivityTraceFlags.HasFlag(ActivityTraceFlags.Recorded) ? "01" : "00")}"
                : msg.TraceParent,
            TraceState     = activity?.TraceStateString ?? msg.TraceState,
            SensorId       = msg.SensorId,
            Value          = msg.Value,
            Unit           = msg.Unit,
            Timestamp      = msg.Timestamp,
            PreviousValue  = previousValue,
            Delta          = delta,
            Trend          = trend,
            BridgedAt      = DateTimeOffset.UtcNow
        };

        var kafkaPayload = JsonSerializer.Serialize(enriched);

        // ── Kafka publish ──────────────────────────────────────────────────────
        using var kafkaSpan = _tracer.StartActivity("kafka-publish", ActivityKind.Producer);
        kafkaSpan?.SetTag("messaging.system",      "kafka");
        kafkaSpan?.SetTag("messaging.destination", _kafkaTopic);
        kafkaSpan?.SetTag("messaging.operation",   "publish");
        kafkaSpan?.SetTag("sensor.id",             msg.SensorId);

        try
        {
            await producer.ProduceAsync(
                _kafkaTopic,
                new Message<string, string>
                {
                    Key   = msg.SensorId,
                    Value = kafkaPayload
                },
                ct);

            kafkaSpan?.SetTag("messaging.result", "ok");

            _log.LogInformation(
                "[trace:{TraceId}] Bridged sensorId={SensorId} value={Value} trend={Trend}",
                activity?.TraceId.ToString()[..8] ?? "none",
                msg.SensorId, msg.Value, trend);
        }
        catch (Exception ex)
        {
            kafkaSpan?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            _log.LogError(ex, "Kafka publish failed");
        }
    }
}

// ── Message types ──────────────────────────────────────────────────────────────
public record SensorMessage
{
    public string TraceParent { get; init; } = string.Empty;
    public string TraceState  { get; init; } = string.Empty;
    public string SensorId    { get; init; } = string.Empty;
    public double Value       { get; init; }
    public string Unit        { get; init; } = string.Empty;
    public DateTimeOffset Timestamp { get; init; }
}

public record EnrichedSensorEvent
{
    public string TraceParent   { get; init; } = string.Empty;
    public string TraceState    { get; init; } = string.Empty;
    public string SensorId      { get; init; } = string.Empty;
    public double Value         { get; init; }
    public string Unit          { get; init; } = string.Empty;
    public DateTimeOffset Timestamp  { get; init; }
    public double? PreviousValue     { get; init; }
    public double? Delta             { get; init; }
    public string Trend              { get; init; } = "unknown";
    public DateTimeOffset BridgedAt  { get; init; }
}
