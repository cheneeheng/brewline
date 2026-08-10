# Experiment 4 — Sampling and cost

**Teaches:** telemetry is a budgeted product. Tail sampling lets you keep every
interesting trace (errors, slow ones) while shedding the boring majority — and you can
measure exactly how much it saves.

**Prerequisites:** a running stack ([Getting started](../getting-started.md)); k6 to
drive two identical 5-minute runs; write access to `deploy/docker-compose.yml`;
permission to recreate containers.
**Time / impact:** ~15 minutes (two timed runs). No downtime. Fully reversible —
running without sampling only raises export volume.

## Background

The default gateway ([`collector/gateway.yaml`](../../../collector/gateway.yaml)) applies
**tail sampling**: keep 100% of error/slow traces + 5% of the rest. The variant
([`collector/gateway.nosample.yaml`](../../../collector/gateway.nosample.yaml)) removes
the `tail_sampling` processor so every trace is exported. You compare the gateway's own
exported-span counter across the two runs.

> **Measure with the exporter counter, not Jaeger storage.** The Jaeger all-in-one
> image stores traces in memory, so its volume is not a meaningful cost signal. The
> honest yardstick is `otelcol_exporter_sent_spans` on the gateway.

## Run A — sampling ON (baseline)

1. Ensure the gateway uses the default config (the `command:` for `gateway-collector`
   in [`deploy/docker-compose.yml`](../../../deploy/docker-compose.yml) points at
   `gateway.yaml`). If you changed it before, set it back and recreate:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate gateway-collector
   ```
2. Run a fixed amount of steady load (5 minutes):
   ```bash
   k6 run -e SCENARIO=steady -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js
   ```
3. In Prometheus (**http://localhost:9090**), record the increase over the run:
   ```
   sum(increase(otelcol_exporter_sent_spans{instance="gateway-collector:8888"}[5m]))
   ```
   Scope it to the gateway instance and sum it: the raw metric is also reported by the
   edge collector and is split per exporter, so an unscoped query returns several
   series instead of one number.

**Verify:** you get a concrete number — spans exported to Jaeger with sampling on.

## Run B — sampling OFF

1. Point the gateway at the no-sample config in `deploy/docker-compose.yml`:
   ```yaml
       command: ["--config=/etc/otelcol/gateway.nosample.yaml"]
   ```
2. Recreate the gateway:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate gateway-collector
   ```
3. Run the **same** 5-minute steady load again, then record the same metric:
   ```
   sum(increase(otelcol_exporter_sent_spans{instance="gateway-collector:8888"}[5m]))
   ```
   Scope it to the gateway instance and sum it: the raw metric is also reported by the
   edge collector and is split per exporter, so an unscoped query returns several
   series instead of one number.

**Verify:** Run B's number is substantially **higher** than Run A's. The ratio is your
sampling reduction — the volume (and cost) tail sampling sheds while still keeping
every error and slow trace.

## Confirm what sampling kept

With sampling back on, confirm you did not lose the traces that matter:

1. Raise the failure rate briefly to generate some errors
   (`PAYMENT_FAILURE_RATE=0.20`, recreate `payment`), run load, then revert.
2. In Jaeger, search **storefront** traces with tag `error=true`.

**Verify:** the error traces are present even though only 5% of normal traces are —
the `errors` and `slow` policies keep 100% of the interesting ones.

## Fix / restore

1. Set the gateway command back to the default:
   ```yaml
       command: ["--config=/etc/otelcol/gateway.yaml"]
   ```
2. Recreate:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate gateway-collector
   ```

**Verify:** the gateway's `increase(otelcol_exporter_sent_spans{...}[5m])` returns to
the lower, sampled volume.

## A scaling caveat worth knowing

This tail-sampling setup is correct **only because there is a single gateway** — every
span of a trace reaches the same collector, so the sampler sees the whole trace. Run
more than one gateway and spans for one trace can land on different collectors, silently
breaking sampling. The production fix is trace-ID-aware routing via the
`loadbalancing` exporter in front of the gateway tier. Brewline stays single-gateway on
purpose; this is the boundary of the rig.

## Takeaway

You rarely need 100% of traces. Tail sampling keeps the signal (errors, latency
outliers) and a small statistical sample of the rest, and the exporter counters let you
prove the savings instead of guessing.
