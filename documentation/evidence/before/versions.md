# Deployed versions at time of capture

**Captured:** 2026-04-22T17:24:21Z
**Cluster:** k3d-poc

## Helm releases (chart versions)

```
NAMESPACE        RELEASE                      CHART                                    APP_VERSION
--------------------------------------------------------------------------------------------------
argocd           argocd                       argo-cd-9.4.17                           v3.3.6
cert-manager     cert-manager                 cert-manager-v1.20.1                     v1.20.1
gitea            gitea                        gitea-12.5.0                             1.25.4
observability    kps                          kube-prometheus-stack-83.6.0             v0.90.1
observability    loki                         loki-6.55.0                              3.6.7
reloader         reloader                     reloader-2.2.9                           v1.4.14
observability    tempo                        tempo-1.24.4                             2.9.0
traefik          traefik                      traefik-39.0.7                           v3.6.12
vault            vault                        vault-0.32.0                             1.21.2
```

## Sensor pipeline container images (running pods)

```
sensor-producer      gitea.test/poc/sensor-producer:63d8ceb0
mqtt-bridge          gitea.test/poc/mqtt-bridge:ec46440b
event-consumer       gitea.test/poc/event-consumer:5305feab
```

## OTel collector image

```
otel/opentelemetry-collector-contrib:0.123.0
```

## .NET SDK and OpenTelemetry package versions (from app source)

```
--- sensor-producer ---
<TargetFramework>net6.0</TargetFramework>
<PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.9.0" />
<PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="1.9.0" />
<PackageReference Include="OpenTelemetry.Instrumentation.Runtime" Version="1.9.0" />

--- mqtt-bridge ---
<TargetFramework>net6.0</TargetFramework>
<PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.9.0" />
<PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="1.9.0" />

--- event-consumer ---
<TargetFramework>net6.0</TargetFramework>
<PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.9.0" />
<PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="1.9.0" />

```

## Git commit at time of capture

```
not a git checkout (/home/andrew/Projects/poc)
```
