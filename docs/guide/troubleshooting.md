# Troubleshooting

[← Guide index](index.md)

Symptom → cause → fix for common stumbles. For deliberate failures you induced, see the
experiments listed on the [Guide index](index.md#experiments--deliberate-failure-labs-operator);
for operational incidents see the [Runbook](operations/OP-02-runbook.md).

## Stack won't start

| Symptom | Cause | Fix |
|---|---|---|
| `port is already allocated` | Another process holds a port (e.g. 3000, 5432, 8000) | Stop the conflicting process, or remove the host port mapping in `deploy/docker-compose.yml` |
| App service exits immediately at startup | It started before Postgres/RabbitMQ were ready | The compose `depends_on` health gates handle this; if you started a single service manually, start its dependencies first |
| `order` service never becomes healthy | `order-migrate` failed | `docker compose ... logs order-migrate`; fix the DB connection, then `up` again |
| Build fails downloading Python/Go deps | No network during build | Dependencies are unpinned and fetched at build time; ensure the build host has internet |

## No traces in Jaeger

1. Confirm Jaeger is up: open http://localhost:16686.

2. Confirm the collectors are healthy:

   ```bash
   docker compose -f deploy/docker-compose.yml logs gateway-collector | tail
   ```

3. Confirm services export to the edge collector (the `OTEL_EXPORTER_OTLP_ENDPOINT`
   env is `http://edge-collector:4317`).

| Symptom | Cause | Fix |
|---|---|---|
| No traces at all | Collector down or misconfigured | Check `edge-collector` / `gateway-collector` logs for config errors |
| Traces appear, then stop under load | Edge collector dropping spans | You may be on `edge.weak.yaml`; see [EX-03](experiments/EX-03-collector-backpressure.md) |
| Async spans never join | Broker propagation off | Set `BROKER_PROPAGATION=on`; see [EX-01](experiments/EX-01-broken-broker-context.md) |
| Few traces under steady load | Expected — tail sampling keeps 5% of normal traces | Search by `error=true` or longest-duration; those are always kept |

## Grafana panels empty

| Symptom | Cause | Fix |
|---|---|---|
| All dashboards empty | No traffic yet | Run `k6 run loadgen/k6_order.js`; wait ~30s for the first scrape |
| RED rate/error panels: "No data" | HTTP metric series name mismatch | Confirm `OTEL_SEMCONV_STABILITY_OPT_IN=http` is set on the services (compose `x-otel-env`). Without it, instrumentation emits `http_server_duration_milliseconds_*` while the panels query `http_server_request_duration_seconds_*`. Check what actually arrives: `curl -s localhost:8889/metrics \| grep http_server`. The SLO latency panel/rule uses the custom `brewline_order_duration_seconds` histogram and is unaffected |
| Loki logs panel empty but traces work | Logs injected but not exported | Most likely `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true` is missing — `OTEL_LOGS_EXPORTER=otlp` alone enriches records without shipping them. Confirm both are set, then check the gateway → Loki (`otlphttp/loki`) export in `gateway-collector` logs |
| trace_id link does nothing | Derived field not matching | The Loki datasource derives `TraceID` from the `trace_id` structured-metadata field; confirm logs carry it (expand a log line's fields) |

## Metrics naming gotchas

| Looking for | Query as | Why |
|---|---|---|
| `brewline.orders.placed` | `brewline_orders_placed_total` | Dots → underscores; counters get `_total` |
| `brewline.payment.failures` | `brewline_payment_failures_total` | Same |
| `brewline.order.duration` | `brewline_order_duration_seconds_bucket` (for quantiles) | Unit `s` → `_seconds`; histograms expose `_bucket`/`_sum`/`_count` |
| Queue depth | `rabbitmq_queue_messages_ready`, `rabbitmq_queue_messages_unacked` | From RabbitMQ's Prometheus plugin (`:15692`), not a service metric |

## Orders fail unexpectedly

| Symptom | Cause | Fix |
|---|---|---|
| `status: failed` on most orders | `PAYMENT_FAILURE_RATE` set high | Lower it in `.env`, recreate `payment` |
| `status: failed` with stock shortages | Inventory exhausted for a SKU | Reseed: `docker compose ... run --rm inventory-migrate` (only refills missing rows) or `down -v` to reset all data |
| Order stuck at `paid`, never `ready` | Fulfillment worker not consuming | Check `fulfillment` logs and RabbitMQ queue `fulfillment.order.placed`; ensure `rabbitmq` is healthy |
