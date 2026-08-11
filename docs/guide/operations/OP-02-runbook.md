# OP-02 — Runbook

[← Guide index](../index.md)

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

## Prerequisites

| Need | Detail |
|---|---|
| Shell | Run every command from the repo root. Snippets are POSIX shell — on Windows use Git Bash or WSL, because PowerShell does not expand `{8000,8001}` brace lists |
| Docker | Engine + Compose v2 (`docker compose version`) |
| Files | Write access to `.env` and `deploy/docker-compose.yml` |
| Credentials | None beyond the local defaults; RabbitMQ UI uses `brewline` / `brewline` |
| Tools | `curl`; k6 only to drive load |

First-time install and every tunable setting live in
[Install and configure](OP-01-install-and-configure.md).

## Routine operations

### Start the stack

```bash
docker compose -f deploy/docker-compose.yml up -d
```

**Verify:** `docker compose -f deploy/docker-compose.yml ps` shows the six app
services and the telemetry stack as `running`, and both migration containers as
`exited (0)`.

### Stop the stack

Pick the level of teardown you need. They are listed from least to most destructive.

```bash
docker compose -f deploy/docker-compose.yml stop      # stop, keep containers
docker compose -f deploy/docker-compose.yml down      # remove containers, keep volume
```

> **Warning:** the next command deletes the `pgdata` volume. Every order, order item,
> and inventory row is gone, and there is no backup. Recovery is a full
> `up --build`, which replays the Alembic migration and reseeds the eight SKUs.
> In-flight RabbitMQ messages are lost too, because the broker has no volume.

```bash
docker compose -f deploy/docker-compose.yml down -v   # also wipe Postgres data
```

**Verify:** `docker compose -f deploy/docker-compose.yml ps` lists nothing.

### Rebuild after a code change

```bash
docker compose -f deploy/docker-compose.yml up -d --build order
```

**Verify:** `docker compose -f deploy/docker-compose.yml logs --tail 20 order` shows a
fresh startup, and `curl -s localhost:8001/healthz` returns `{"ok":true}`.

### Recreate one service after an `.env` change

Compose reads `.env` at container creation, so an edit takes effect only on recreate.

```bash
docker compose -f deploy/docker-compose.yml up -d --force-recreate payment
```

**Verify:** the new value is in the running container:

```bash
docker compose -f deploy/docker-compose.yml exec payment printenv PAYMENT_FAILURE_RATE
```

### Check status and logs

```bash
docker compose -f deploy/docker-compose.yml ps
docker compose -f deploy/docker-compose.yml logs -f fulfillment
```

### Re-run migrations

Migrations are one-shot services that run on `up`. Both are idempotent — the order
migration is `alembic upgrade head`, and the inventory seed uses
`ON CONFLICT (sku) DO NOTHING` — so re-running them never destroys data.

```bash
docker compose -f deploy/docker-compose.yml run --rm order-migrate
docker compose -f deploy/docker-compose.yml run --rm inventory-migrate
```

**Verify:** both commands exit `0`. The inventory seed refills only missing SKU rows;
it does not reset `available_qty` on rows that already exist.

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

Each procedure runs detection → diagnosis → remediation → verification. All are
non-destructive unless the block says otherwise.

### Order trace fragments (async spans missing)

- **When:** a storefront trace ends at the `order.placed publish` span, and
  `fulfillment.process` appears as a separate root trace in Jaeger.
- **Time / impact:** ~2 minutes. Recreating the three services drops in-flight
  requests.

1. Read the flag that controls manual broker propagation:

   ```bash
   docker compose -f deploy/docker-compose.yml exec order printenv BROKER_PROPAGATION
   ```

   If it prints `off`, that is the cause
   ([EX-01](../experiments/EX-01-broken-broker-context.md)).
2. Set `BROKER_PROPAGATION=on` in `.env`.

3. Recreate every service that publishes or consumes on the broker:

   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate order fulfillment notification
   ```

**Verify:** place one order, wait ~5 seconds, then open its storefront trace in Jaeger.
`fulfillment.process` and `notification.notify` sit under the same root.

**If it fails:** the flag was already `on`, so the break is upstream of the broker.
Check that `inventory` spans are attached too — a Go-side propagator break produces the
same fragmentation at a different hop
([Concepts](../concepts.md#cross-language-propagation-python--go)).

### Prometheus series count climbing without bound

- **When:** `prometheus_tsdb_head_series` rises continuously instead of holding flat.
- **Time / impact:** ~2 minutes. Recreating `order` drops in-flight orders.

1. In Prometheus (**http://localhost:9090**), confirm the shape of the growth:

   ```
   prometheus_tsdb_head_series
   ```

2. Identify the offending metric:

   ```
   count by (__name__) ({__name__=~"brewline_orders_placed_total|brewline_order_value_count"})
   ```

   A count that tracks the number of orders placed means `order_id` has become a label
   ([EX-02](../experiments/EX-02-metric-cardinality.md)).

3. Set `CARDINALITY_MODE=normal` in `.env`.

4. Recreate the order service:

   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate order
   ```

**Verify:** no new `order_id`-labeled series appear and `prometheus_tsdb_head_series`
flattens. Existing series age out of the head block on their own; nothing to clean up.

### Telemetry dropped under load

- **When:** `rate(otelcol_processor_refused_spans[1m]) > 0`, or traces have gaps in
  Jaeger during a load spike.
- **Time / impact:** ~2 minutes. Recreating the edge collector loses whatever it is
  currently buffering.

1. In Prometheus, confirm the drop is at the collector:

   ```
   rate(otelcol_processor_refused_spans[1m])
   rate(otelcol_exporter_send_failed_spans[1m])
   ```

2. Check which config the running edge collector actually loaded:

   ```bash
   docker inspect --format '{{json .Config.Cmd}}' \
     $(docker compose -f deploy/docker-compose.yml ps -q edge-collector)
   ```

   Expected output on a healthy stack:

   ```
   ["--config=/etc/otelcol/edge.yaml"]
   ```

   `edge.weak.yaml` instead means the weak config is live — a 20 MiB memory limit and
   no batch processor ([EX-03](../experiments/EX-03-collector-backpressure.md)).

3. Restore `command: ["--config=/etc/otelcol/edge.yaml"]` for `edge-collector` in
   `deploy/docker-compose.yml`.

4. Recreate the collector:

   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate edge-collector
   ```

**Verify:** re-run the spike load; `rate(otelcol_processor_refused_spans[1m])` stays at
or near zero and Jaeger traces are continuous.

**If it fails:** the edge collector was already on `edge.yaml`, so the pipeline is
genuinely undersized for the offered load. Raise `memory_limiter.limit_mib` in
[`collector/edge.yaml`](../../../collector/edge.yaml) or reduce the k6 arrival rate.

### Messages stuck or dead-lettered

- **When:** the `brewline.dlq` queue has depth > 0 in the RabbitMQ UI
  (**http://localhost:15672**, login `brewline` / `brewline`).
- **Time / impact:** diagnosis is read-only. The optional purge in step 4 is
  irreversible.

1. Open the RabbitMQ UI and note the depth of `brewline.dlq` and of the two work
   queues, `fulfillment.order.placed` and `notification.order.ready`.

2. Find the exception that caused the dead-letter. A consumer nacks with requeue on the
   first failure and dead-letters on the redelivery, so the message failed twice:

   ```bash
   docker compose -f deploy/docker-compose.yml logs --tail 100 fulfillment notification
   ```

3. Fix the underlying cause — most often Postgres is unavailable, which you confirm
   with `docker compose -f deploy/docker-compose.yml ps postgres`. Once the consumers
   are healthy, new orders drain normally.
4. Decide what to do with the dead-lettered messages. They are already-paid orders
   whose fulfillment never completed.
   > **Warning:** purging `brewline.dlq` destroys those messages permanently. The
   > affected orders stay at `paid` in Postgres forever — no worker will advance them.
   > Only purge when you have confirmed the orders are stale test data. There is no
   > undo and no dead-letter backup.

   To purge, open the `brewline.dlq` queue in the RabbitMQ UI and use **Purge
   Messages**.

**Verify:** `brewline.dlq` holds at 0 while load runs, and new orders reach `ready`
within `PREP_SECONDS` + a second or two.

## Recovery / rollback

### Revert a config experiment

Every experiment in this guide is fully reversible and touches nothing but
configuration.

1. Restore the default value — `BROKER_PROPAGATION=on` or `CARDINALITY_MODE=normal` in
   `.env`, or the default `command:` (`edge.yaml` / `gateway.yaml`) in
   `deploy/docker-compose.yml`.

2. Recreate only the affected container:

   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate <service>
   ```

   For example, to revert EX-01 after setting `BROKER_PROPAGATION=on`:

   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate order fulfillment notification
   ```

**Verify:** the symptom named in the matching experiment page is gone.

### Reset all data

> **Warning:** this destroys the `pgdata` volume — all orders, order items, and
> inventory rows. There is no backup and no partial restore. The rebuild reseeds the
> eight SKUs at their starting quantities, so any reservation history is lost.

```bash
docker compose -f deploy/docker-compose.yml down -v
docker compose -f deploy/docker-compose.yml up --build -d
```

**Verify:** `docker compose -f deploy/docker-compose.yml ps` shows both migration
containers at `exited (0)`, and a fresh order returns `status: paid`.

## Escalation

This is a local teaching rig — there is no on-call. When the runbook runs out, the
authoritative sources are, in order:

1. [`.agents_workspace/ARCHITECTURE.md`](../../../.agents_workspace/ARCHITECTURE.md) —
   current system shape and the Key Decisions log ("why is it built this way?").
2. `.agents_workspace/planning/` (`SKELETON.md`, `ITER_01..04.md`) — the specs the
   implementation was built against.
3. `.agents_workspace/DECISION_LOG.md` — implementation-time decisions and their
   trade-offs.

---

[← OP-01 Install and configure](OP-01-install-and-configure.md) · [Guide index](../index.md) · [OP-03 SLO alert drill →](OP-03-slo-alert-drill.md)
