# apps/event-consumer/Dockerfile
# Multi-stage build: SDK for compile, runtime-only image for the final layer.
# Build from the poc/apps/event-consumer/ directory:
#   docker build -t gitea.test/poc/event-consumer:<tag> .

FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
WORKDIR /src

COPY event-consumer.csproj ./
RUN dotnet restore

COPY . ./
RUN dotnet publish -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/runtime:6.0 AS runtime
WORKDIR /app

# Non-root user — consistent with devops-toolkit runtime image convention
RUN groupadd --gid 1000 appuser && useradd --uid 1000 --gid 1000 --no-create-home appuser
COPY --from=build --chown=appuser:appuser /app/publish ./
USER appuser

ENTRYPOINT ["dotnet", "event-consumer.dll"]
