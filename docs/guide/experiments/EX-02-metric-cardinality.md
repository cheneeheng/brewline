# EX-02 — Metric cardinality explosion

[← Guide index](../index.md)

**Teaches:** why high-cardinality identifiers belong on traces and logs, never on
metric labels.

- **Prerequisites:** a running stack ([Getting started](../getting-started.md)); k6 to
  drive load; write access to `.env`; permission to recreate containers.
- **Time:** ~10 minutes.
- **Impact:** no downtime. Reversible, with one caveat: the series this creates stay in
  Prometheus until they age out of the head block. That is memory only — no data is
  lost and nothing needs cleaning up.

## Background

Each distinct combination of metric labels creates a separate time series. Bounded
labels (`outcome`, `sku`) are cheap. Attach an unbounded identifier like `order_id`
and you mint a brand-new series for every order — memory and scrape cost grow without
limit. Brewline keeps `order_id` off metrics by default; `CARDINALITY_MODE=high` adds
it on purpose (see
[`services/order/app/metrics.py`](../../../services/order/app/metrics.py)).

## Establish a baseline

1. With defaults running and load flowing (`k6 ... loadgen/k6_order.js`), open
   Prometheus (**http://localhost:9090**).

2. Run:

   ```
   prometheus_tsdb_head_series
   ```

3. Note the roughly flat value — total active series in the head block.

## Induce the failure

1. Edit `.env`:

   ```bash
   CARDINALITY_MODE=high
   ```

2. Recreate the order service:

   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate order
   ```

3. Keep load running for a few minutes so many distinct `order_id` values are emitted.

## Observe

In Prometheus, watch the same query over time:

```
prometheus_tsdb_head_series
```

**Verify:** the series count **climbs continuously** instead of staying flat — each
order now creates new `brewline_orders_placed_total` / `brewline_order_value` series
keyed by `order_id`. To see the culprit directly:

```
count by (__name__) ({__name__=~"brewline_orders_placed_total|brewline_order_value_count"})
```

**Verify:** the per-metric series count rises with the number of orders placed.

> **Why this matters:** left running, this is how a single careless label takes down a
> Prometheus. The growth is unbounded because `order_id` is unbounded.

**If it fails:**

- The series count stays flat → the order service still runs `normal`. Compose reads
  `.env` only when it *creates* a container, so confirm the value that is actually live
  and recreate if it still reads `normal`:

  ```bash
  docker compose -f deploy/docker-compose.yml exec order printenv CARDINALITY_MODE
  ```

- The count is flat but the flag is `high` → no orders are being placed. Check the
  order rate on Grafana `/d/brewline-orders`, and remember Prometheus needs one scrape
  interval (15s) before new series appear.

## Fix and verify

1. Restore the default in `.env`:

   ```bash
   CARDINALITY_MODE=normal
   ```

2. Recreate the order service:

   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate order
   ```

3. Confirm you did not lose the ability to find a specific order: open any trace in
   Jaeger and check the `brewline.order_id` span tag, or filter logs by order in
   Grafana. The identifier still lives where it belongs — on traces and logs.

**Verify:** no *new* `order_id`-labeled series are created (the old ones age out of the
head block over time), and `prometheus_tsdb_head_series` flattens again.

## Takeaway

Metrics are for **aggregate** questions ("what fraction of orders failed?"), so their
labels must be bounded. Per-entity questions ("what happened to *this* order?") are
answered by traces and logs, which are built for high cardinality.

---

[← EX-01 Broken trace context at the broker](EX-01-broken-broker-context.md) · [Guide index](../index.md) · [EX-03 Collector backpressure →](EX-03-collector-backpressure.md)
