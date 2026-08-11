# EX-03 — Collector backpressure

[← Guide index](../index.md)

**Teaches:** the collector is a choke point with finite capacity; sizing
`memory_limiter` and `batch` correctly is what keeps it from dropping your telemetry
under load.

- **Prerequisites:** a running stack ([Getting started](../getting-started.md)); k6 to
  drive the spike; write access to `deploy/docker-compose.yml`; permission to recreate
  containers.
- **Time:** ~10 minutes.
- **Impact:** no application downtime, but this lab **deliberately destroys
  telemetry** — spans dropped during the spike are gone for good. Orders themselves are
  unaffected. Reverting the config restores the pipeline.

## Background

The healthy edge config ([`collector/edge.yaml`](../../../collector/edge.yaml)) has a
reasonable `memory_limiter` and a `batch` processor. The weak variant
([`collector/edge.weak.yaml`](../../../collector/edge.weak.yaml)) deliberately uses a
tiny memory limit and **no batching** — so under a load spike it refuses and drops
data. Both files are already mounted into the `edge-collector` container; you switch by
pointing its `command:` at the weak file.

## Induce the failure

1. In [`deploy/docker-compose.yml`](../../../deploy/docker-compose.yml), find the
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
`otel-collectors`). Open **http://localhost:9090** and run each of these:

```
rate(otelcol_processor_refused_spans[1m])
```

```
rate(otelcol_exporter_send_failed_spans[1m])
```

During the spike both rise above zero — the weak edge collector is **refusing and
failing to send spans** because it has no headroom and no batching.

Now look at the downstream effect: open Jaeger (**http://localhost:16686**) and search
**storefront** traces during the spike window.

**Verify:** there are **gaps** — traces are missing or incomplete, because their spans
were dropped at the edge before ever reaching the gateway or Jaeger.

**If it fails:**

- Both rates stay at zero → the collector never loaded the weak config. Check the
  command the running container actually got:

  ```bash
  docker inspect --format '{{json .Config.Cmd}}' \
    $(docker compose -f deploy/docker-compose.yml ps -q edge-collector)
  ```

  It must print `["--config=/etc/otelcol/edge.weak.yaml"]`. If it still shows
  `edge.yaml`, the recreate did not pick up your compose edit — re-run step 2.

- The rates stay at zero on the *weak* config → the spike is not reaching the
  collector. Confirm k6 ran the `spike` scenario (`-e SCENARIO=spike`) and that the
  order rate on Grafana `/d/brewline-orders` climbs during the run.

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

---

[← EX-02 Metric cardinality explosion](EX-02-metric-cardinality.md) · [Guide index](../index.md) · [EX-04 Sampling and cost →](EX-04-sampling-and-cost.md)
