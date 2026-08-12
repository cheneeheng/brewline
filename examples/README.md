# Examples

Five short scripts that showcase what Brewline actually produces. Each one drives the
stack over its public HTTP surface, then reads the telemetry back out of Jaeger,
Prometheus, or Loki and prints it in the terminal — so the payoff is visible without
clicking through a UI first.

These are demos, not tests. They assert nothing and they change no configuration.

## Before you run them

```bash
cp .env.example .env
docker compose -f deploy/docker-compose.yml up -d --build
curl -s localhost:8000/healthz     # {"ok":true}
```

Every example exists twice — pick whichever shell you already use:

| Flavour | Needs | Notes |
|---|---|---|
| `*.sh` | `bash`, `curl`, `jq` | On Windows, Git Bash or WSL. |
| `*.ps1` | PowerShell 7+ (`pwsh`) | No extra tools — `Invoke-RestMethod` parses the JSON. |

The two sets do the same work and print the same output. The only difference: the
PowerShell version of `05` shows log timestamps in local time, the bash version in UTC.

## The examples

| Example | What it shows | Takes |
|---|---|---|
| **01-place-an-order** — [sh](01-place-an-order.sh) · [ps1](01-place-an-order.ps1) | The order lifecycle: 202 with `paid`, then the RabbitMQ consumers walk it to `ready` on their own. | ~10s |
| **02-follow-one-trace** — [sh](02-follow-one-trace.sh) · [ps1](02-follow-one-trace.ps1) | **The headline.** One `POST /orders` rendered as a single waterfall spanning six services, two of them reachable only through the broker. | ~30s |
| **03-metrics-snapshot** — [sh](03-metrics-snapshot.sh) · [ps1](03-metrics-snapshot.ps1) | The business and RED metrics as Prometheus stores them, plus how many series each one costs. | ~2s |
| **04-stock-shortage** — [sh](04-stock-shortage.sh) · [ps1](04-stock-shortage.ps1) | The failure path — an unfillable order, refused whole by the Go inventory service and never published. | ~5s |
| **05-logs-to-trace** — [sh](05-logs-to-trace.sh) · [ps1](05-logs-to-trace.ps1) | One order told by every service that touched it, with the trace ID that links each line back to its waterfall. | ~20s |

Run them from this directory:

```bash
cd examples
bash 02-follow-one-trace.sh
```

```powershell
cd examples
./02-follow-one-trace.ps1
```

Start with `01`, then `02`. `03` is more interesting after some load:

```bash
k6 run -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js
```

## Sample output — `02-follow-one-trace`

```
   service       span                           duration  offset/length
   storefront    POST /orders                       80ms  #
   order         POST /orders                       74ms  #
   order         INSERT                              1ms  #
   order         COMMIT;                             3ms  #
   payment       POST /charge                       34ms  #
   inventory     inventory                           4ms  .#
   order         order.placed publish               10ms  .#
   fulfillment   fulfillment.process              2025ms  .##########################################
   fulfillment   order.ready publish                 9ms  ...........................................#
   notification  notification.notify                 0ms  ...........................................#

   42 spans in one trace, from fulfillment, inventory, notification, order, payment, storefront
```

Abridged: a real run prints every span, which for this trace is 42 rows. The rest are
auto-instrumented detail — one span per asyncpg statement (`BEGIN;`, `INSERT`,
`COMMIT;`) and the ASGI `http receive` / `http send` pairs. Timings come from your run.

The part that matters: `fulfillment` and `notification` are in the same trace as
`storefront`, seconds after the HTTP request finished, because the `traceparent`
travelled inside the AMQP message headers.

Every inventory span is named `inventory`, not `POST /reserve` — the Go service passes
one fixed operation name to `otelhttp.NewHandler`, so the route does not reach the span
name.

## Why an example may print nothing

| Symptom | Cause |
|---|---|
| `02` finds no trace | The gateway holds each trace for `decision_wait` (15s) before deciding; the script already waits. If it still fails, see [troubleshooting](../docs/guide/troubleshooting.md). |
| `03` shows no series | Nothing has been ordered yet, or the 30s Prometheus scrape has not run. |
| `04`'s trace is missing from Jaeger | Expected. That trace is fast and carries no error, so tail sampling judges it by the 5% probabilistic policy. |
| `05` returns no log lines | Log export needs *two* environment switches. The script prints which ones. |

## What these examples deliberately do not do

None of them edits `.env`, swaps a collector config, or recreates a container. Every
example runs against a healthy default stack and leaves it healthy.

Breaking the telemetry on purpose — fragmenting a trace at the broker, exploding metric
cardinality, starving the collector, turning sampling off — is the job of the four
experiments in [`docs/guide/experiments/`](../docs/guide/experiments/), each of which is
a reversible set-flag → drive-load → observe → revert loop.

## Configuration

Every script, in both flavours, reads the same environment overrides and defaults to the
Compose port map:

```
STOREFRONT_URL   http://localhost:8000
INVENTORY_URL    http://localhost:8080
JAEGER_URL       http://localhost:16686
PROM_URL         http://localhost:9090
LOKI_URL         http://localhost:3100
```

Shared helpers — trace-ID generation, order placement, the waterfall renderer — live in
[`_lib.sh`](_lib.sh) and [`_lib.ps1`](_lib.ps1). Edit both when you change one.
