# Experiment 3 — Collector backpressure

**Teaches:** the collector is a choke point with finite capacity; sizing
`memory_limiter` and `batch` correctly is what keeps it from dropping your telemetry
under load.

**Time:** ~10 minutes. **Reversible:** yes.

## Background

The healthy edge config ([`collector/edge.yaml`](../../collector/edge.yaml)) has a
reasonable `memory_limiter` and a `batch` processor. The weak variant
([`collector/edge.weak.yaml`](../../collector/edge.weak.yaml)) deliberately uses a
tiny memory limit and **no batching** — so under a load spike it refuses and drops
data. Both files are already mounted into the `edge-collector` container; you switch by
pointing its `command:` at the weak file.

## Induce the failure

1. In [`deploy/docker-compose.yml`](../../deploy/docker-compose.yml), find the
   `edge-collector` service and change its command to the weak config:
   ```yaml
       command: ["--config=/etc/otelcol/edge.weak.yaml"]
   ```
2. Recreate just that collector:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate edge-collector
   ```
3. Drive the **spike** load scenario (ramping arrival rate):
   ```bash
   k6 run -e SCENARIO=spike -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js
   ```

## Observe

The collector publishes its own metrics, scraped by Prometheus (job
`otel-collectors`). Open **http://localhost:9090** and run:

```
rate(otelcol_processor_refused_spans[1m])
```
then:
```
rate(otelcol_exporter_send_failed_spans[1m])
```

**Verify:** during the spike both rise above zero — the weak edge collector is
**refusing and failing to send spans** because it has no headroom and no batching.

Now look at the downstream effect:

1. Open Jaeger (**http://localhost:16686**) and search **storefront** traces during
   the spike window.

**Verify:** there are **gaps** — traces are missing or incomplete, because their spans
were dropped at the edge before ever reaching the gateway or Jaeger.

## Fix and verify

1. Restore the healthy config in `deploy/docker-compose.yml`:
   ```yaml
       command: ["--config=/etc/otelcol/edge.yaml"]
   ```
2. Recreate the collector:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate edge-collector
   ```
3. Run the spike again.

**Verify:** `rate(otelcol_processor_refused_spans[1m])` stays at/near zero through the
spike, and Jaeger traces are continuous again. `memory_limiter` (sized with headroom)
plus `batch` absorb the burst.

## Takeaway

Telemetry has a delivery cost and the collector has limits. `memory_limiter` protects
the collector from OOM by shedding early (which is why it runs *first* in the
pipeline), and `batch` makes export efficient. Undersize either and you lose data
exactly when you need it most — during a spike.
