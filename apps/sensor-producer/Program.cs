// apps/sensor-producer/Program.cs
// Publishes fake sensor readings to MQTT topic defined by MQTT_TOPIC env var (default: sensors/reading).
// Each message carries a W3C traceparent so downstream services can continue the trace.
// Also caches the latest reading in Redis for the mqtt-bridge enrichment step.
//
// Secrets arrive via Vault Agent at:
//   /vault/secrets/mqtt.env  — MQTT_HOST, MQTT_PORT, MQTT_USERNAME, MQTT_PASSWORD
//   /vault/secrets/redis.env — REDIS_HOST, REDIS_PORT, REDIS_PASSWORD

using System.Diagnostics;
using System.Text;
using System.Text.Json;
using MQTTnet;
using MQTTnet.Client;
using OpenTelemetry;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Metrics;
using OpenTelemetry.Logs;
using StackExchange.Redis;

// ── Load Vault Agent secrets before building the host ─────────────────────────
// Vault Agent renders secrets as KEY=VALUE lines in /vault/secrets/*.env files.
// We load them into environment variables so IConfiguration picks them up
// via the environment variable provider — .NET 6 compatible pattern.
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

// ── Host builder — .NET 6 compatible ──────────────────────────────────────────
// Host.CreateDefaultBuilder is the .NET 6 pattern.
// Host.CreateApplicationBuilder was introduced in .NET 7 and will not compile here.
var host = Host.CreateDefaultBuilder(args)
    .ConfigureServices((ctx, services) =>
    {
        var config = ctx.Configuration;

        var mqttHost     = config["MQTT_HOST"]      ?? "localhost";
        var mqttPort     = int.Parse(config["MQTT_PORT"]      ?? "1883");
        var mqttUser     = config["MQTT_USERNAME"]  ?? "sensor";
        var mqttPassword = config["MQTT_PASSWORD"]  ?? throw new InvalidOperationException("MQTT_PASSWORD not set");
        var redisHost    = config["REDIS_HOST"]     ?? "localhost";
        var redisPort    = int.Parse(config["REDIS_PORT"]     ?? "6379");
        var redisPass    = config["REDIS_PASSWORD"] ?? throw new InvalidOperationException("REDIS_PASSWORD not set");
        var otlpEndpoint = config["OTEL_EXPORTER_OTLP_ENDPOINT"]
                           ?? "http://otel-collector-gateway.observability.svc.cluster.local:4317";

        // SENSOR_INTERVAL_MS is the demo knob in the ConfigMap.
        // Falls back to PUBLISH_INTERVAL_SECONDS * 1000 for backwards compatibility,
        // then to 1000ms (one reading per second) if neither is set.
        var intervalMs = config["SENSOR_INTERVAL_MS"] is string ms
            ? int.Parse(ms)
            : config["PUBLISH_INTERVAL_SECONDS"] is string sec
                ? int.Parse(sec) * 1000
                : 1000;

        var activitySource = new ActivitySource("sensor-producer");

        services.AddOpenTelemetry()
            .ConfigureResource(r => r
                .AddService("sensor-producer", serviceVersion: "1.0.0")
                .AddAttributes(new Dictionary<string, object>
                {
                    ["deployment.environment"] = "poc",
                    ["service.namespace"]      = "sensor-demo"
                }))
            .WithTracing(t => t
                .AddSource("sensor-producer")
                .AddOtlpExporter(o => o.Endpoint = new Uri(otlpEndpoint)))
            .WithMetrics(m => m
                .AddRuntimeInstrumentation()
                .AddOtlpExporter(o => o.Endpoint = new Uri(otlpEndpoint)))
            .WithLogging(l => l
                .AddOtlpExporter(o => o.Endpoint = new Uri(otlpEndpoint)));

        services.AddHostedService(sp =>
            new ProducerWorker(
                sp.GetRequiredService<ILogger<ProducerWorker>>(),
                activitySource,
                mqttHost, mqttPort, mqttUser, mqttPassword,
                redisHost, redisPort, redisPass,
                intervalMs
            ));
    })
    .Build();

host.Run();

// ── Worker ────────────────────────────────────────────────────────────────────
public class ProducerWorker : BackgroundService
{
    private readonly ILogger<ProducerWorker> _log;
    private readonly ActivitySource _tracer;
    private readonly string _mqttHost;
    private readonly int _mqttPort;
    private readonly string _mqttUser;
    private readonly string _mqttPassword;
    private readonly string _redisHost;
    private readonly int _redisPort;
    private readonly string _redisPass;
    private readonly int _intervalMs;

    private static readonly string[] SensorIds = new[] { "sensor-01", "sensor-02", "sensor-03" };
    private static readonly Random Rng = new();

    public ProducerWorker(
        ILogger<ProducerWorker> log,
        ActivitySource tracer,
        string mqttHost, int mqttPort, string mqttUser, string mqttPassword,
        string redisHost, int redisPort, string redisPass,
        int intervalMs)
    {
        _log = log; _tracer = tracer;
        _mqttHost = mqttHost; _mqttPort = mqttPort;
        _mqttUser = mqttUser; _mqttPassword = mqttPassword;
        _redisHost = redisHost; _redisPort = redisPort; _redisPass = redisPass;
        _intervalMs = intervalMs;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _log.LogInformation("Connecting to MQTT {Host}:{Port}", _mqttHost, _mqttPort);
        var mqttFactory = new MqttFactory();
        using var mqttClient = mqttFactory.CreateMqttClient();

        var mqttOptions = new MqttClientOptionsBuilder()
            .WithTcpServer(_mqttHost, _mqttPort)
            .WithCredentials(_mqttUser, _mqttPassword)
            .WithClientId($"sensor-producer-{Environment.MachineName}")
            .WithKeepAlivePeriod(TimeSpan.FromSeconds(30))
            .Build();

        _log.LogInformation("Connecting to Redis {Host}:{Port}", _redisHost, _redisPort);
        var redis = await ConnectionMultiplexer.ConnectAsync(
            new ConfigurationOptions
            {
                EndPoints = { { _redisHost, _redisPort } },
                Password = _redisPass,
                AbortOnConnectFail = false
            });
        var db = redis.GetDatabase();

        // Retry MQTT connect with backoff
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

        _log.LogInformation("Publishing every {IntervalMs}ms", _intervalMs);

        while (!ct.IsCancellationRequested)
        {
            await PublishReadingAsync(mqttClient, db, ct);
            await Task.Delay(TimeSpan.FromMilliseconds(_intervalMs), ct);
        }

        await mqttClient.DisconnectAsync();
        redis.Dispose();
    }

    private async Task PublishReadingAsync(IMqttClient mqttClient, IDatabase db, CancellationToken ct)
    {
        // Start a new root span for this publish cycle.
        // This span is the root — it has no parent.
        // Its traceId will flow through all downstream services.
        using var activity = _tracer.StartActivity("publish-sensor-reading", ActivityKind.Producer);

        var sensorId = SensorIds[Rng.Next(SensorIds.Length)];
        var value    = Math.Round(15.0 + Rng.NextDouble() * 20.0, 2);
        var ts       = DateTimeOffset.UtcNow;

        activity?.SetTag("sensor.id",    sensorId);
        activity?.SetTag("sensor.value", value);
        activity?.SetTag("mqtt.topic",   Environment.GetEnvironmentVariable("MQTT_TOPIC") ?? "sensors/reading");

        // ── W3C traceparent serialisation ──────────────────────────────────────
        // Extract the current span context into the W3C traceparent string.
        // This is injected into the message payload so downstream services can
        // reconstruct the parent context and attach their own child spans.
        var traceParent = activity != null
            ? $"00-{activity.TraceId}-{activity.SpanId}-{(activity.ActivityTraceFlags.HasFlag(ActivityTraceFlags.Recorded) ? "01" : "00")}"
            : string.Empty;

        var message = new SensorMessage
        {
            TraceParent = traceParent,
            TraceState  = activity?.TraceStateString ?? string.Empty,
            SensorId    = sensorId,
            Value       = value,
            Unit        = "celsius",
            Timestamp   = ts
        };

        var payload = JsonSerializer.Serialize(message);

        // ── Redis cache write ───────────────────────────────────────────────────
        using var cacheSpan = _tracer.StartActivity("redis-cache-write", ActivityKind.Client);
        cacheSpan?.SetTag("db.system",    "redis");
        cacheSpan?.SetTag("db.operation", "SET");
        cacheSpan?.SetTag("sensor.id",    sensorId);

        try
        {
            await db.StringSetAsync(
                $"sensor:latest:{sensorId}",
                payload,
                TimeSpan.FromMinutes(5));
            cacheSpan?.SetTag("db.result", "ok");
        }
        catch (Exception ex)
        {
            cacheSpan?.SetStatus(ActivityStatusCode.Error, ex.Message);
            _log.LogWarning("Redis write failed: {Message}", ex.Message);
        }

        // ── MQTT publish ────────────────────────────────────────────────────────
        using var publishSpan = _tracer.StartActivity("mqtt-publish", ActivityKind.Producer);
        publishSpan?.SetTag("messaging.system",      "mqtt");
        publishSpan?.SetTag("messaging.destination", Environment.GetEnvironmentVariable("MQTT_TOPIC") ?? "sensors/reading");
        publishSpan?.SetTag("messaging.operation",   "publish");

        try
        {
            var mqttMessage = new MqttApplicationMessageBuilder()
                .WithTopic(Environment.GetEnvironmentVariable("MQTT_TOPIC") ?? "sensors/reading")
                .WithPayload(Encoding.UTF8.GetBytes(payload))
                .WithQualityOfServiceLevel(MQTTnet.Protocol.MqttQualityOfServiceLevel.AtLeastOnce)
                .WithRetainFlag(false)
                .Build();

            await mqttClient.PublishAsync(mqttMessage, ct);
            publishSpan?.SetTag("messaging.result", "ok");

            _log.LogInformation(
                "[trace:{TraceId}] Published sensorId={SensorId} value={Value} interval={IntervalMs}ms",
                activity?.TraceId.ToString()[..8] ?? "none",
                sensorId, value, _intervalMs);
        }
        catch (Exception ex)
        {
            publishSpan?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            _log.LogError(ex, "MQTT publish failed");
        }
    }
}

// ── Message envelope ──────────────────────────────────────────────────────────
public record SensorMessage
{
    public string TraceParent { get; init; } = string.Empty;
    public string TraceState  { get; init; } = string.Empty;
    public string SensorId    { get; init; } = string.Empty;
    public double Value       { get; init; }
    public string Unit        { get; init; } = string.Empty;
    public DateTimeOffset Timestamp { get; init; }
}
