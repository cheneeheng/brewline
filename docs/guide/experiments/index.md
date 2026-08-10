# Experiments

The four deliberate-failure labs are the heart of Brewline. Each one follows the same
loop:

> **set a flag → drive load → observe the symptom in a real UI → revert the fix**

You are acting as an operator here (you change config and recreate containers), so
these labs assume shell access to the repo and a running stack
([Getting started](../getting-started.md)).

| # | Lab | Teaches | Toggle |
|---|---|---|---|
| 1 | [Broken trace context at the broker](01-broken-broker-context.md) | Context propagation across non-HTTP boundaries | `BROKER_PROPAGATION` |
| 2 | [Metric cardinality explosion](02-metric-cardinality.md) | Why identifiers belong on traces, not metrics | `CARDINALITY_MODE` |
| 3 | [Collector backpressure](03-collector-backpressure.md) | The collector as a choke point, and sizing it | `edge.weak.yaml` |
| 4 | [Sampling and cost](04-sampling-and-cost.md) | Telemetry as a budgeted product | `gateway.nosample.yaml` |

Each lab is independently runnable and fully reversible. Run them in any order, but 1
and 2 (env-flag toggles) are the gentlest starting point; 3 and 4 (collector config
swaps) go deeper into the pipeline.

## Two toggle mechanisms

- **Environment flags** (labs 1 and 2): edit `.env`, then recreate only the affected
  services with `docker compose ... up -d --force-recreate <service>`.
- **Collector config swaps** (labs 3 and 4): the alternate config files are already
  mounted into the collector containers. You point the container's `command:` at the
  alternate file in [`deploy/docker-compose.yml`](../../deploy/docker-compose.yml),
  then recreate that one collector.

Always **revert** at the end of a lab so later labs start from a healthy baseline.
