# Getting started

Goal: from a fresh checkout to seeing your **first distributed trace** in Jaeger.

**Time:** ~10 minutes (most of it the first image build).

## Before you begin

You need:

- **Docker** with Compose v2 (`docker compose version` works).
- About 4 GB of free RAM for the stack.
- Optional: **k6** (`k6 version`) to drive load. You can use `curl` instead.

You do **not** need Python or Go installed locally — everything runs in containers.
For deeper environment/version details see
[Install and configure](operations/install-and-configure.md).

## 1. Create your environment file

```bash
cp .env.example .env
```

The defaults work as-is for local use.

**Verify:** `.env` exists and contains `PAYMENT_FAILURE_RATE=0.02`.

## 2. Start the stack

```bash
docker compose -f deploy/docker-compose.yml up --build
```

This builds the six services and starts Postgres, Redis, RabbitMQ, both collectors,
and Jaeger/Prometheus/Loki/Grafana. The first run pulls images and builds — give it a
few minutes. Database migrations run as one-shot `order-migrate` and
`inventory-migrate` containers that exit `0` before the app services start.

**Verify:** the storefront answers its health check:

```bash
curl -s localhost:8000/healthz
```

Expected output:

```
{"ok":true}
```

## 3. Place your first order

```bash
curl -s localhost:8000/orders \
  -H 'content-type: application/json' \
  -d '{"items":[{"sku":"LAT-001","name":"Latte","qty":1,"unit_price":"4.50"}]}'
```

Expected output (a fresh UUID, status `paid`):

```
{"order_id":"<uuid>","status":"paid"}
```

> Status `paid` means the synchronous half succeeded (charged + stock reserved) and
> `order.placed` was published. The async workers then advance the order
> `fulfilling → ready` over the next couple of seconds.

**Verify:** fetch the order back and watch it reach `ready`:

```bash
curl -s localhost:8001/orders/<uuid>
```

After ~2 seconds (`PREP_SECONDS`), `status` becomes `ready`.

## 4. See the trace

1. Open Jaeger at **http://localhost:16686**.
2. In the **Service** dropdown, select **storefront**.
3. Click **Find Traces**. The most recent trace is your order.
4. Click it to open the waterfall.

**Verify:** the waterfall is a single connected trace that includes spans from
**storefront → order → payment** and **order → inventory** (the Python→Go hop), plus
an `order.placed publish` span and, a few seconds later, `fulfillment.process` and
`notification.notify` spans — the asynchronous broker hops joined to the *same* trace.

That single connected waterfall across HTTP *and* the broker is the whole point of
Brewline.

**If it fails:**
- Only storefront/order spans appear, async ones missing → wait a few seconds and
  refresh; the prep delay means async spans arrive late. If they never join, check
  [Experiment 1](experiments/01-broken-broker-context.md) symptoms and confirm
  `BROKER_PROPAGATION=on`.
- No traces at all → see [Troubleshooting](troubleshooting.md).

## 5. Drive continuous traffic (optional)

```bash
k6 run -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js
```

This runs the steady `constant-arrival-rate` scenario (~10 orders/s for 5 minutes),
which lights up the Grafana dashboards.

## Next steps

- Understand what you just saw: [Concepts](concepts.md).
- Explore the telemetry: [Observe traces](how-to/observe-traces.md),
  [metrics and logs](how-to/observe-metrics-and-logs.md).
- Break things on purpose: [Experiments](experiments/index.md).

## Stopping

```bash
docker compose -f deploy/docker-compose.yml down        # keep data
docker compose -f deploy/docker-compose.yml down -v     # also wipe Postgres volume
```
