# OP-01 — Install and configure

[← Guide index](../index.md)

Operator reference for standing Brewline up and tuning it. For the learner happy-path
see [Getting started](../getting-started.md).

## Requirements

| Requirement | Notes |
|---|---|
| Docker Engine + Compose v2 | `docker compose version` must work |
| RAM | ~4 GB free for the full stack |
| Ports free on host | 8000–8002, 8080, 3000, 9090, 3100, 16686, 5432, 5672, 15672, 15692, 4317, 4318, 8889 |
| k6 (optional) | Only needed to drive load from the host |

No host Python or Go toolchain is required; services build in containers.

## Pinned images

These are pinned in [`deploy/docker-compose.yml`](../../../deploy/docker-compose.yml).
The collector pin matters most — processor config schemas drift across releases.

| Component | Image / tag |
|---|---|
| OpenTelemetry Collector | `otel/opentelemetry-collector-contrib:0.105.0` |
| PostgreSQL | `postgres:16` |
| Redis | `redis:7` |
| RabbitMQ | `rabbitmq:3.13-management` |
| Jaeger | `jaegertracing/all-in-one:1.57` |
| Prometheus | `prom/prometheus:v2.53.0` |
| Loki | `grafana/loki:3.1.0` |
| Grafana | `grafana/grafana:11.1.0` |

## Install

1. Create the env file:

   ```bash
   cp .env.example .env
   ```

2. Build and start:

   ```bash
   docker compose -f deploy/docker-compose.yml up --build -d
   ```

3. Post-install health check — all app services answer `/healthz`:

   ```bash
   for p in 8000 8001 8002 8080; do curl -s localhost:$p/healthz; echo; done
   ```

   Expected:

   ```
   {"ok":true}
   {"ok":true}
   {"ok":true}
   {"ok":true}
   ```

4. Confirm the migrations ran and exited cleanly:

   ```bash
   docker compose -f deploy/docker-compose.yml ps order-migrate inventory-migrate
   ```

   Both should show state `exited (0)`.

**Verify:** Grafana (http://localhost:3000), Jaeger (http://localhost:16686), and
Prometheus (http://localhost:9090) all load.

**If it fails:**

- `port is already allocated` → another process holds one of the host ports listed
  under *Requirements*. Free the port, or delete that host port mapping in
  [`deploy/docker-compose.yml`](../../../deploy/docker-compose.yml).
- An app service never starts and its migration container did not exit `0` → the app
  services wait on `service_completed_successfully`, so a failed migration blocks them.
  Read the reason, then re-run `up`:

  ```bash
  docker compose -f deploy/docker-compose.yml logs order-migrate inventory-migrate
  ```

The full symptom → cause → fix table is in
[Troubleshooting](../troubleshooting.md#stack-wont-start).

## Configuration

All operator-tunable settings are environment variables in `.env`. After changing one,
recreate the affected service(s):
`docker compose -f deploy/docker-compose.yml up -d --force-recreate <service>`.

### Credentials

| Variable | Default | Effect |
|---|---|---|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `brewline` / `brewline` / `brewline` | Postgres bootstrap. Used in service `DATABASE_URL`s. |
| `RABBITMQ_DEFAULT_USER` / `RABBITMQ_DEFAULT_PASS` | `brewline` / `brewline` | RabbitMQ login (also the management UI at :15672). |

> These defaults are for local use only. `.env` is gitignored; do not commit real
> credentials.

### Behavior / experiment knobs

| Variable | Default | Range | Effect | Recreate |
|---|---|---|---|---|
| `PAYMENT_FAILURE_RATE` | `0.02` | 0.0–1.0 | Fraction of charges declined. Drives the payment-success SLO; raise it for [OP-03](OP-03-slo-alert-drill.md). | `payment` |
| `PAYMENT_LATENCY_MS` | `40` | ≥ 0 | Base charge latency (jittered). Raise to breach the latency SLO. | `payment` |
| `PREP_SECONDS` | `2` | ≥ 0 | Simulated kitchen prep delay. Extends end-to-end trace time. | `fulfillment` |
| `BROKER_PROPAGATION` | `on` | `on`/`off` | Manual broker context inject/extract. `off` = [EX-01](../experiments/EX-01-broken-broker-context.md). | `order fulfillment notification` |
| `CARDINALITY_MODE` | `normal` | `normal`/`high` | `high` adds `order_id` as a metric label = [EX-02](../experiments/EX-02-metric-cardinality.md). | `order` |

> **Coupling:** `PREP_SECONDS` must stay well under the gateway's
> `tail_sampling.decision_wait` (15s in [`collector/gateway.yaml`](../../../collector/gateway.yaml)).
> If you raise prep time near or past that, the sampler decides before async spans
> arrive and persists incomplete traces.

### Collector configs (file-based, not env)

Swapped by changing a collector's `command:` in `deploy/docker-compose.yml`
(both variants are mounted). Used by EX-03 and EX-04.

| File | Used by | Purpose |
|---|---|---|
| [`collector/edge.yaml`](../../../collector/edge.yaml) | `edge-collector` (default) | Healthy edge: memory_limiter + batch |
| [`collector/edge.weak.yaml`](../../../collector/edge.weak.yaml) | [EX-03](../experiments/EX-03-collector-backpressure.md) | Undersized edge (backpressure) |
| [`collector/gateway.yaml`](../../../collector/gateway.yaml) | `gateway-collector` (default) | Tail sampling + scrub + fan-out |
| [`collector/gateway.nosample.yaml`](../../../collector/gateway.nosample.yaml) | [EX-04](../experiments/EX-04-sampling-and-cost.md) | Same, minus tail sampling |

### Service-level telemetry env

Every service shares one `OTEL_*` block in
[`deploy/docker-compose.yml`](../../../deploy/docker-compose.yml) (the `x-otel-env`
anchor). You normally do not change these — they are what makes all three pillars flow.
Two of them are easy to lose and cause silent, partial breakage, so they are listed
explicitly.

| Variable | Value | Effect if removed |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://edge-collector:4317` | Nothing is exported; all UIs stay empty. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | Exporter falls back to the default protocol and may not reach the edge collector. |
| `OTEL_TRACES_EXPORTER` / `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` | `otlp` | The corresponding pillar is not exported. |
| `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED` | `"true"` | **Loki stays empty.** `OTEL_LOGS_EXPORTER=otlp` alone does not attach the SDK logging handler to the root logger — records get a `trace_id` but are never shipped. |
| `OTEL_SEMCONV_STABILITY_OPT_IN` | `http` | **RED dashboard goes empty.** Instrumentation reverts to the old `http_server_duration_milliseconds_*` names; the panels query the stable `http_server_request_duration_seconds_*`. |
| `OTEL_SERVICE_NAME` | per service | Spans and metrics lose their service identity. |
| `OTEL_RESOURCE_ATTRIBUTES` | `service.namespace=brewline,deployment.environment=local` | The Loki query `{service_namespace="brewline"}` matches nothing. |

> The SLO latency rule and panel use the custom `brewline_order_duration_seconds`
> histogram, so they survive HTTP semantic-convention drift regardless of the opt-in.

## Next

- Day-to-day operation, monitoring, and incident procedures:
  [OP-02 — Runbook](OP-02-runbook.md).
- Prove the alerting path works: [OP-03 — SLO alert drill](OP-03-slo-alert-drill.md).
- The four deliberate-failure labs, starting with
  [EX-01](../experiments/EX-01-broken-broker-context.md).

---

[Guide index](../index.md) · [OP-02 Runbook →](OP-02-runbook.md)
