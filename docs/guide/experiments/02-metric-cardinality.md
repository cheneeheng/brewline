# Experiment 2 — Metric cardinality explosion

**Teaches:** why high-cardinality identifiers belong on traces and logs, never on
metric labels.

**Time:** ~10 minutes. **Reversible:** yes.

## Background

Each distinct combination of metric labels creates a separate time series. Bounded
labels (`outcome`, `sku`) are cheap. Attach an unbounded identifier like `order_id`
and you mint a brand-new series for every order — memory and scrape cost grow without
limit. Brewline keeps `order_id` off metrics by default; `CARDINALITY_MODE=high` adds
it on purpose (see
[`services/order/app/metrics.py`](../../services/order/app/metrics.py)).

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

## Fix and verify

1. Restore the default in `.env`:
   ```bash
   CARDINALITY_MODE=normal
   ```
2. Recreate the order service:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate order
   ```

**Verify:** no *new* `order_id`-labeled series are created (the old ones age out of the
head block over time). `prometheus_tsdb_head_series` flattens again.

3. Confirm you did not lose the ability to find a specific order: open any trace in
   Jaeger and check the `brewline.order_id` span tag, or filter logs by order in
   Grafana. The identifier still lives where it belongs — on traces and logs.

## Takeaway

Metrics are for **aggregate** questions ("what fraction of orders failed?"), so their
labels must be bounded. Per-entity questions ("what happened to *this* order?") are
answered by traces and logs, which are built for high cardinality.
