# LogQL queries used for this capture

**Captured:** 2026-04-22T17:24:21Z
**Window:** 2026-04-22T17:22:21Z → 2026-04-22T17:24:21Z (2 minutes)
**Loki endpoint:** http://127.0.0.1:3100

## Per-service raw record queries

One query per service, one file per service:

```logql
{service_name="sensor-producer"}
{service_name="mqtt-bridge"}
{service_name="event-consumer"}
```

## API call shape

```
GET http://127.0.0.1:3100/loki/api/v1/query_range
  ?query={service_name="<svc>"}
  &start=1776878541000000000
  &end=1776878661000000000
  &limit=2000
  &direction=forward
```

## Equivalent Grafana Explore queries

To reproduce the same record set in Grafana Explore (which the screenshots
in this directory were taken from):

```logql
{service_name=~"sensor-producer|mqtt-bridge|event-consumer"}
```

Set the time range to the window above.
