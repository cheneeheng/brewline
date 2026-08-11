# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Brewline is a coffee order-and-fulfillment backend that exists to be a **teaching rig for
OpenTelemetry**. Six services turn one `POST /orders` into a single distributed trace that
crosses synchronous HTTP *and* an asynchronous RabbitMQ broker, plus metrics, logs, SLOs, and
four deliberate-failure experiments.

This purpose changes what "correct" means. Telemetry behaviour is the product, not a
side-effect. Code that makes a failure mode *unreproducible* is a regression, even if it looks
like a bug fix — the experiment flags (`BROKER_PROPAGATION`, `CARDINALITY_MODE`) and the weak
collector configs exist on purpose.

## Commands

Everything runs through Docker Compose from the repo root. There is no Makefile and no task
runner.

```bash
cp .env.example .env                                   # defaults work as-is
docker compose -f deploy/docker-compose.yml up --build  # whole stack
docker compose -f deploy/docker-compose.yml up -d --build order fulfillment  # rebuild a subset
docker compose -f deploy/docker-compose.yml logs -f order
docker compose -f deploy/docker-compose.yml down -v     # -v also drops pgdata
```

Migrations run as one-shot compose services (`order-migrate` runs `alembic upgrade head`,
`inventory-migrate` pipes `deploy/db/inventory_init.sql` through psql). Dependents wait on
`service_completed_successfully`, so a schema change means re-running those services, not
restarting the app.

Drive traffic:

```bash
k6 run -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js           # steady, 10 rps, 5m
k6 run -e SCENARIO=spike -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js
curl -s localhost:8000/orders -H 'content-type: application/json' \
  -d '{"items":[{"sku":"LAT-001","name":"Latte","qty":1,"unit_price":"4.50"}]}'
```

New Alembic revision (order service owns `orders` / `order_items`):

```bash
docker compose -f deploy/docker-compose.yml run --rm order-migrate \
  alembic revision --autogenerate -m "<message>"
```

### Testing and linting

**There is no test suite, no pytest config, no ruff/mypy config, and no CI.** Do not claim tests
pass. Do not add a test suite unless asked. Available cheap checks:

- Python syntax: `python -m compileall services/<svc>`
- Go: `cd services/inventory && go build ./... && go vet ./...`
- Compose schema: `docker compose -f deploy/docker-compose.yml config`
- Collector config: validated only by starting the container — check its logs.

The root `.venv/` is a bare uv venv for editor tooling; services always run in containers.

### Ports

storefront 8000 · order 8001 · payment 8002 · inventory 8080 · Grafana 3000 · Jaeger 16686 ·
Prometheus 9090 · RabbitMQ mgmt 15672 (brewline/brewline) · gateway Prometheus exporter 8889 ·
collector self-telemetry 8888.

## Architecture

### Request path

```
k6/curl -> storefront -> order -> payment
                          |  \--> inventory (Go) -- Redis, Postgres
                          |  \--- Postgres
                          \--(order.placed)--> RabbitMQ --> fulfillment --(order.ready)--> notification
```

`order` is the only service with business logic worth the name: persist (`placed`), charge,
reserve, publish, return 202. Everything after the publish is async and advances the order
`paid -> fulfilling -> ready` through **guarded conditional UPDATEs** (`WHERE id=$ AND status=$`),
so a redelivered message cannot move an order backward. Preserve that guard shape in any
consumer work.

### Telemetry path

All six services export OTLP/gRPC to the **edge collector** (memory_limiter, batch — deliberately
dumb), which forwards to the single **gateway collector** (tail_sampling, attributes/scrub, batch)
which fans out to Jaeger, Prometheus (`prometheus` exporter on :8889, scraped), and Loki
(`otlphttp` to `/otlp`).

Python services get zero-code instrumentation: the Dockerfile CMD is
`opentelemetry-instrument <cmd>`, and images run `opentelemetry-bootstrap -a install` at build.
Hand-written instrumentation is limited to what auto-instrumentation cannot do — custom business
metrics and broker context propagation. Go has no auto-instrumentation and builds its
TracerProvider/MeterProvider by hand in `initTelemetry`.

## Invariants that break silently

These are the failure modes the rig teaches. Each one produces **no error** — just missing or
wrong telemetry. Do not "clean up" any of them.

1. **Broker context is injected and extracted by hand.** `inject(headers)` before every AMQP
   publish; `extract()` + `context.attach()` (and `detach()` in a `finally`) around every consume.
   A missed call fragments the trace with no log line. Gated by `BROKER_PROPAGATION` for
   experiment #1 — keep the flag.
2. **Go sets the W3C propagator explicitly.** The Go SDK's default text-map propagator is a
   **no-op**. `otel.SetTextMapPropagator(...)` plus `otelhttp.NewHandler` in
   `services/inventory/main.go` are the only reason the Python→Go hop stays connected.
3. **`OTEL_SEMCONV_STABILITY_OPT_IN=http`** must stay in the compose `x-otel-env` block.
   Without it Python emits the legacy `http_server_duration_milliseconds_*` names and the RED
   dashboard panels go empty.
4. **OTLP logs need two switches.** `OTEL_LOGS_EXPORTER=otlp` picks the exporter;
   `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true` attaches the SDK handler to the root
   logger. With only the first, records are enriched with `trace_id` but never shipped and Loki
   stays empty.
5. **`PREP_SECONDS` (2s) must stay well under the gateway `tail_sampling.decision_wait` (15s).**
   Raising prep without raising decision_wait persists half-finished traces, which looks exactly
   like a propagation bug.
6. **One gateway only.** Tail sampling is correct because every span of a trace reaches the same
   collector. Scaling the gateway needs trace-ID-aware routing via the `loadbalancing` exporter
   and is out of scope.

## Metrics conventions

**Cardinality discipline:** identifiers (`order_id`) live on **spans and log lines only**. Metric
attributes are bounded sets — `outcome`, `sku`, `service.name`. The gateway's `attributes/scrub`
deliberately does *not* delete `brewline.order_id`, because the Loki→Jaeger pivot needs it.
`CARDINALITY_MODE=high` violates this on purpose in `order/app/metrics.py`; that branch stays.

**Names are translated on export.** OTel instrument names use dots; the collector's Prometheus
exporter converts to underscores and appends `_total` to monotonic counters. Prometheus rules,
Grafana panels, and alerts must reference the *translated* series:

| OTel instrument | Prometheus series |
|---|---|
| `brewline.orders.placed` (counter) | `brewline_orders_placed_total` |
| `brewline.payment.failures` (counter) | `brewline_payment_failures_total` |
| `brewline.order.duration` (histogram, unit `s`) | `brewline_order_duration_seconds_bucket` |
| `brewline.inventory.reserved` (counter) | `brewline_inventory_reserved_total` |

The SLO latency rule uses the custom `brewline.order.duration` histogram — not the HTTP server
histogram — because `histogram_quantile` needs an explicit bucket boundary at the 0.8s threshold.
Its `explicit_bucket_boundaries_advisory` list must keep `0.8`, or the SLO rule and dashboard
break.

## Code conventions

- Python 3.12, type hints on every signature, Pydantic v2 with `ConfigDict(extra="forbid")` on
  every request model. Config via `pydantic-settings` (`order`) or plain `os.environ.get` with a
  default (the smaller services) — follow whichever the file already uses.
- Structured JSON logs to stdout via a local `JsonFormatter` that forwards `otelTraceID` /
  `otelSpanID` / `otelServiceName`. The stdout copy is for container readability; the OTLP copy
  is the real one.
- Go 1.22, chi router, pgx + go-redis. Datastore hops are hand-instrumented with span attributes
  (`db.system`, `brewline.cache_hit`) because neither library is auto-instrumented here.
- Comments cite the plan section that motivated the code (`ITER_03 §04`). Keep that style when
  editing instrumented paths; it is the trail from behaviour back to intent.
- Deliberate shortcuts carry a `// less-code:` comment naming the ceiling.

## Repo layout notes

- `.agents_workspace/` — not shipped docs. `ARCHITECTURE.md` is the living diagram set plus a
  **Key Decisions** log; `planning/ITER_0*.md` are the iteration plans the code was built from;
  `DECISION_LOG.md` is the append-only agent decision record. Update `ARCHITECTURE.md` when the
  system's *shape* changes (new component, new data flow, reversed decision).
- `docs/guide/` — the shipped user/operator guide. It keeps the two audiences apart: every
  multi-step operator procedure — anything that edits `.env`, swaps a collector config, or
  recreates a container to change behaviour — lives under `operations/OP-nn-*` or
  `experiments/EX-nn-*`. The how-to pages (`how-to/HT-nn-*`) are read-only and never ask the
  reader to change configuration; `getting-started` carries only the install and teardown
  commands a first run needs, and `troubleshooting` names one-line fixes and links out for the
  rest. Three structural rules hold across the tree:
  root-level pages are unnumbered, every subfolder file is `<PREFIX>-<NN>-<name>.md` with the
  number carrying reading order, and only the root `index.md` is a hub — it lists every page.
  Each page opens with a breadcrumb and (inside a subfolder) closes with a prev/next footer that
  never links across two subfolders' chains. Renumbering a subfolder means fixing those footers
  in the same pass.
- `collector/` — `edge.yaml` / `gateway.yaml` are the good configs; `edge.weak.yaml` and
  `gateway.nosample.yaml` are the experiment configs, swapped in by editing the container
  `command` in compose. Collector images are pinned to `0.105.0` because processor config schemas
  drift between releases.
- No auth, no CORS, no rate limiting anywhere: the only callers are k6 and internal compose-network
  traffic. That is a recorded scope decision, not an oversight.
