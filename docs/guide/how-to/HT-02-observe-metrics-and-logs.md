# HT-02 — Observe metrics and logs

[← Guide index](../index.md)

Goal: read Brewline's RED + business metrics in Grafana, and pivot from a log line to
its trace.

- **Prerequisites:** the stack is running with traffic flowing (see the load generator
  command below).
- **Time:** ~10 minutes.
- **Impact:** none. This page is read-only — it changes nothing.

Start the steady load generator so the dashboards have data:

```bash
k6 run -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js
```

## Open the dashboards

Grafana is at **http://localhost:3000** (anonymous admin is enabled — no login). The
provisioned dashboards are in the **Brewline** folder:

| Dashboard | Route | Shows |
|---|---|---|
| Service overview (RED) | `/d/brewline-red` | Request rate, error rate, order latency p50/p95/p99 |
| Order business metrics | `/d/brewline-orders` | Orders placed (paid vs failed), order value, payment failure rate, queue depth |
| Logs explore | `/d/brewline-logs` | Brewline service logs with trace links |
| SLO & error budget | `/d/brewline-slo` | Covered in [SLOs and burn-rate alerts](HT-03-slos-and-alerts.md) |

**Verify:** open `/d/brewline-orders`; within a minute of load you see the "Orders
placed" panel rising and a non-zero queue-depth series.

## Read the business metrics

On **Order business metrics**:

- **Orders placed (paid vs failed)** — `rate(brewline_orders_placed_total)` split by
  `outcome`. With default settings almost all are `paid`.
- **Payment failure rate** — climbs only when you raise `PAYMENT_FAILURE_RATE`, which
  is operator work: see
  [OP-03 — SLO alert drill](../operations/OP-03-slo-alert-drill.md).
- **Queue depth (RabbitMQ)** — `rabbitmq_queue_messages_ready` /
  `_unacked`. This comes from RabbitMQ's own Prometheus plugin, not a worker gauge.

> Remember the name translation: the OTel instrument `brewline.orders.placed` is the
> Prometheus series `brewline_orders_placed_total`. Counters gain `_total`; dots
> become underscores.

## Query metrics directly in Prometheus

1. Open **http://localhost:9090**.
2. In the expression box, run:

   ```
   sum by (outcome) (rate(brewline_orders_placed_total[5m]))
   ```

3. Click **Execute**, then the **Graph** tab.

**Verify:** one line per `outcome` value.

## Pivot from a log to its trace

This is the trace-correlated-logs payoff.

1. Open the **Logs explore** dashboard (`/d/brewline-logs`), or use Grafana's
   **Explore** view with the **Loki** datasource and query `{service_namespace="brewline"}`.
2. Expand any log line to see its fields.
3. Find the **trace_id** field — it renders as a link labeled **TraceID**.
4. Click it.

**Verify:** Grafana opens the **Jaeger** view for that exact trace. You have gone from
a log line to its full distributed trace in one click — because the same `trace_id` is
stamped on both.

## If it fails

| Symptom | Likely cause | Fix |
|---|---|---|
| Dashboards empty | No traffic yet, or scrape not ready | Run k6; wait ~30s for the first scrape |
| Loki panel empty but traces work | Log records enriched but never shipped | Confirm **both** `OTEL_LOGS_EXPORTER=otlp` and `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true`; see [Troubleshooting](../troubleshooting.md) |
| RED rate/error panels say "No data" | HTTP metric series name differs from the query | Confirm `OTEL_SEMCONV_STABILITY_OPT_IN=http`; the panels query `http_server_request_duration_seconds_*`. See [Troubleshooting](../troubleshooting.md). The order-latency panel uses the custom `brewline_order_duration_seconds` histogram and is unaffected |

---

[← HT-01 Observe traces](HT-01-observe-traces.md) · [Guide index](../index.md) · [HT-03 SLOs and burn-rate alerts →](HT-03-slos-and-alerts.md)
