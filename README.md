# Brewline

An instrumented coffee order & fulfillment system whose real purpose is to be a
teaching rig for **OpenTelemetry**. A single `POST /orders` becomes one distributed
trace that crosses synchronous HTTP calls *and* an asynchronous RabbitMQ broker,
plus the metrics, logs, SLOs, and failure modes that come with running it.

## What's inside

Six services emit traces, metrics, and logs over OTLP to an edge collector, which
forwards to a gateway collector that fans out to Jaeger, Prometheus, and Loki,
visualized in Grafana.

```
k6 -> storefront -> order -> payment
                     |  \--> inventory (Go) --- Redis
                     |  \--- PostgreSQL
                     \--(order.placed)--> RabbitMQ --> fulfillment --(order.ready)--> notification
                                                            \--- PostgreSQL
all services --OTLP--> edge collector --> gateway collector --> Jaeger / Prometheus / Loki --> Grafana
```

| Service | Lang | Role |
|---|---|---|
| storefront | Python/FastAPI | Public BFF, forwards to order |
| order | Python/FastAPI | Validate, persist (Postgres), charge, reserve, publish `order.placed` |
| payment | Python/FastAPI | Stateless charge simulator (tunable failure/latency) |
| inventory | Go/chi | Stock reservation (atomic), Redis cache-first reads |
| fulfillment | Python worker | Consumes `order.placed`, simulates prep, publishes `order.ready` |
| notification | Python worker | Consumes `order.ready`, simulated notify |

## Run it

```bash
cp .env.example .env          # defaults work as-is
docker compose -f deploy/docker-compose.yml up --build
```

Migrations run as one-shot services (`order-migrate`, `inventory-migrate`) that
complete before their dependents start.

Drive traffic:

```bash
# steady baseline
k6 run -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js
# or just one order
curl -s localhost:8000/orders -H 'content-type: application/json' \
  -d '{"items":[{"sku":"LAT-001","name":"Latte","qty":1,"unit_price":"4.50"}]}'
```

### Examples

[`examples/`](examples/) holds five scripts that drive the stack and print the
telemetry back in the terminal — the order lifecycle, a full trace waterfall across
HTTP *and* the broker, the metrics as Prometheus stores them, the shortage failure
path, and the log→trace pivot. They change no configuration. Each one comes as
`bash` (needs `curl` + `jq`) and PowerShell 7 (needs nothing else):

```bash
cd examples && bash 02-follow-one-trace.sh
```

```powershell
cd examples; ./02-follow-one-trace.ps1
```

### UIs

| UI | URL |
|---|---|
| Grafana (dashboards) | http://localhost:3000 (anonymous admin) |
| Jaeger (traces) | http://localhost:16686 |
| Prometheus (metrics, alerts) | http://localhost:9090 |
| RabbitMQ management | http://localhost:15672 (brewline/brewline) |
| Storefront API | http://localhost:8000 |

Grafana dashboards (Brewline folder): `/d/brewline-red`, `/d/brewline-orders`,
`/d/brewline-logs`, `/d/brewline-slo`.

## Failure experiments (ITER_04)

Each is a repeatable set-flag → drive-k6 → observe → revert loop.

**1. Broken trace context at the broker.** Set `BROKER_PROPAGATION=off` in `.env`,
`docker compose up -d order fulfillment notification`. *Observe:* in Jaeger the order
trace ends at the publish; fulfillment/notification appear as separate root traces.
*Fix:* set back to `on` and recreate — the waterfall reconnects.

**2. Metric cardinality explosion.** Set `CARDINALITY_MODE=high`, recreate `order`.
*Observe:* `prometheus_tsdb_head_series` climbs without bound as `order_id` becomes a
metric label. *Fix:* revert to `normal` — identifiers stay on spans/logs.

**3. Collector backpressure.** Override the edge collector to the weak config:
edit `edge-collector.command` to `["--config=/etc/otelcol/edge.weak.yaml"]`, recreate
it, then run `k6 run -e SCENARIO=spike loadgen/k6_order.js`. *Observe:*
`otelcol_processor_refused_spans` / `otelcol_exporter_send_failed_spans` rise and gaps
appear in Jaeger. *Fix:* swap back to `edge.yaml`.

**4. Sampling & cost.** Override the gateway to `gateway.nosample.yaml`, run steady
load, and compare `otelcol_exporter_sent_spans` against a run with `gateway.yaml`.
*Observe:* sampling keeps every error/slow trace + 5% of the rest. *Fix:* keep
sampling on. (Don't use Jaeger storage as the yardstick — the all-in-one image stores
in memory; use the exporter counter.)

## Notes & boundaries

- **HTTP RED metric naming.** Compose sets `OTEL_SEMCONV_STABILITY_OPT_IN=http` for
  every service, so instrumentation emits the stable HTTP conventions
  (`http.server.request.duration` in seconds, `http.response.status_code`) that the
  RED panels query. Drop that variable and the older
  `http_server_duration_milliseconds_*` names come back and the panels go empty. The
  SLO latency panel/rule uses the custom `brewline_order_duration_seconds` histogram,
  which is stable either way.
- **Log export needs two switches.** `OTEL_LOGS_EXPORTER=otlp` picks the exporter;
  `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true` attaches the SDK logging
  handler to the root logger. Set only the first and records are enriched with
  `trace_id` but never shipped — Loki stays empty.
- **Single gateway only.** Tail sampling is correct because every span of a trace
  reaches the one gateway. Multi-gateway needs trace-ID-aware routing via the
  `loadbalancing` exporter (deliberately out of MVP scope).
- **`PREP_SECONDS` ↔ `decision_wait`.** The async prep delay is included in the
  end-to-end trace; the gateway `tail_sampling.decision_wait` (15s) must exceed it.
- No auth/CORS: the only callers are the load generator and internal service-to-service
  traffic on the compose network (deferred, see ITER_04 Out of MVP scope).
