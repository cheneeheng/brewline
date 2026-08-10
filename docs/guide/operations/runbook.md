# Runbook

Terse operator procedures for running Brewline locally. Commands assume you run them
from the repo root. All use the project compose file:
`docker compose -f deploy/docker-compose.yml`.

## System overview

Six app services (storefront, order, payment, inventory, fulfillment, notification)
backed by Postgres, Redis, and RabbitMQ. All telemetry flows
service → **edge-collector** → **gateway-collector** → Jaeger / Prometheus / Loki,
viewed in Grafana. See [the architecture diagram](../index.md#architecture), or
[`.agents_workspace/ARCHITECTURE.md`](../../../.agents_workspace/ARCHITECTURE.md) for the
full component, sequence, data-model, and state-machine views.

## Routine operations

### Start / stop

```bash
docker compose -f deploy/docker-compose.yml up -d            # start (after build)
docker compose -f deploy/docker-compose.yml stop             # stop, keep containers
docker compose -f deploy/docker-compose.yml down             # remove containers, keep volume
docker compose -f deploy/docker-compose.yml down -v          # also wipe Postgres data
```

### Rebuild after a code change

```bash
docker compose -f deploy/docker-compose.yml up -d --build <service>
```

### Recreate one service after an `.env` change

```bash
docker compose -f deploy/docker-compose.yml up -d --force-recreate <service>
```

### Status and logs

```bash
docker compose -f deploy/docker-compose.yml ps
docker compose -f deploy/docker-compose.yml logs -f <service>
```

### Re-run migrations

Migrations are one-shot services that run on `up`. To re-run manually:

```bash
docker compose -f deploy/docker-compose.yml run --rm order-migrate
docker compose -f deploy/docker-compose.yml run --rm inventory-migrate
```

The order migration is `alembic upgrade head` (idempotent); inventory seeds with
`ON CONFLICT DO NOTHING` (idempotent).

## Monitoring — what to watch

| Signal | Where | Healthy |
|---|---|---|
| Service health | `curl localhost:{8000,8001,8002,8080}/healthz` | `{"ok":true}` |
| Request rate / errors / latency | Grafana `/d/brewline-red` | errors near 0, p99 < 800ms |
| Orders + payment failures | Grafana `/d/brewline-orders` | failures track `PAYMENT_FAILURE_RATE` |
| Queue depth | Grafana `/d/brewline-orders` (RabbitMQ panel) | drains to ~0 between bursts |
| SLOs + alerts | Grafana `/d/brewline-slo`, Prometheus `/alerts` | no firing alerts |
| Collector health | Prometheus: `otelcol_processor_refused_spans`, `otelcol_exporter_send_failed_spans` | ~0 |
| Dead letters | RabbitMQ UI (http://localhost:15672), queue `brewline.dlq` | empty |

## Incident procedures

### Order trace fragments (async spans missing)

- **Detect:** storefront trace ends at `order.placed publish`; fulfillment shows as a
  separate root in Jaeger.
- **Diagnose:** check `BROKER_PROPAGATION` — if `off`, that is the cause
  ([Experiment 1](../experiments/01-broken-broker-context.md)).
- **Remediate:** set `BROKER_PROPAGATION=on`; recreate `order fulfillment notification`.
- **Verify:** a new order's spans rejoin one trace.

### Prometheus memory / series climbing

- **Detect:** `prometheus_tsdb_head_series` rising without bound.
- **Diagnose:** check `CARDINALITY_MODE` — `high` adds `order_id` to metric labels
  ([Experiment 2](../experiments/02-metric-cardinality.md)).
- **Remediate:** set `CARDINALITY_MODE=normal`; recreate `order`.

### Telemetry being dropped under load

- **Detect:** `rate(otelcol_processor_refused_spans[1m]) > 0`; gaps in Jaeger.
- **Diagnose:** confirm `edge-collector` is on `edge.yaml`, not `edge.weak.yaml`.
- **Remediate:** set the `edge-collector` command back to `edge.yaml`; recreate it.
- See [Experiment 3](../experiments/03-collector-backpressure.md).

### Messages stuck / dead-lettered

- **Detect:** `brewline.dlq` depth > 0 in the RabbitMQ UI.
- **Diagnose:** a consumer raised twice on the same message (it is requeued once, then
  dead-lettered). Check `fulfillment` / `notification` logs for the exception.
- **Remediate:** fix the underlying error (often Postgres unavailable), then redeliver
  by re-publishing or purging the DLQ if the orders are stale.

## Recovery / rollback

- **Reset all data:** `docker compose ... down -v` then `up --build`. This wipes the
  Postgres volume; migrations and inventory seed re-run on next start.
- **Revert a config experiment:** restore the default `command:` (`edge.yaml` /
  `gateway.yaml`) or the default `.env` values, then `--force-recreate` the affected
  container. Every experiment in this guide is fully reversible.

## Escalation

This is a local teaching rig — there is no on-call. When the runbook runs out, the
authoritative sources are, in order:

1. [`.agents_workspace/ARCHITECTURE.md`](../../../.agents_workspace/ARCHITECTURE.md) —
   current system shape and the Key Decisions log ("why is it built this way?").
2. `.agents_workspace/planning/` (`SKELETON.md`, `ITER_01..04.md`) — the specs the
   implementation was built against.
3. `.agents_workspace/DECISION_LOG.md` — implementation-time decisions and their
   trade-offs.
