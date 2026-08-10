# HT-03 — SLOs and burn-rate alerts

Goal: read Brewline's two SLOs and know exactly when the burn-rate alert fires.

**Prerequisites:** the stack is running with traffic flowing. Steady load helps the
numbers move:

```bash
k6 run -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js
```

**Time:** ~5 minutes. This page is read-only — it changes nothing. To force the alert
to fire, see [OP-03 — SLO alert drill](../operations/OP-03-slo-alert-drill.md).

## The two SLOs

Defined as Prometheus rules in
[`deploy/prometheus/rules.yml`](../../../deploy/prometheus/rules.yml):

- **Latency SLO** — 99% of `POST /orders` under **800ms**, from the
  `brewline_order_duration_seconds` histogram.
- **Payment-success SLO** — **≥ 99.5%** success, i.e. `1 - failures/placed`. Error
  budget is the remaining 0.5%.

## Read the SLO dashboard

Open **http://localhost:3000**, dashboard **SLO & error budget** (`/d/brewline-slo`).
Panels:

- **Latency SLI: p99 POST /orders vs 800ms target** — green under target, red over.
- **Payment-success SLI (target 99.5%)** — a stat panel; green at/above 0.995.
- **Payment-success burn rate (budget 0.5%)** — failure ratio ÷ 0.005 budget, plotted
  as `5m burn` and `1h burn`. A value above 1 means you are spending error budget
  faster than the SLO allows.
- **Active Brewline alerts** — a table of firing alerts.

**Verify:** with defaults, the success SLI reads ~0.98–1.00 and the alerts table is
empty.

### Read the alert threshold correctly

The panel crossing 1 is *not* the alert condition. `BrewlinePaymentSuccessBurnRate` in
[`deploy/prometheus/rules.yml`](../../../deploy/prometheus/rules.yml) needs a burn rate
above the fast-burn factor **14.4** on *both* windows at once, held for 2 minutes:

| Term | Value | Meaning |
|---|---|---|
| Error budget | `0.005` | 0.5% of orders may fail payment |
| Fast-burn factor | `14.4` | Standard SRE multiplier: burn a 30-day budget in ~2 days |
| Alert threshold | failure ratio > `0.072` | `14.4 × 0.005`, on the 5m **and** 1h windows |
| `for:` | `2m` | The condition must hold this long before `FIRING` |

So the failure rate must exceed **7.2%** on both windows. The two-window requirement is
the point of a multi-window burn-rate alert: the 5m window reacts fast, and the 1h
window stops it flapping on a brief blip.

## Check whether an alert is firing

1. Open **http://localhost:9090/alerts**.
2. Read the state of each `Brewline*` rule: `INACTIVE`, `PENDING` (condition true, `for:`
   not yet elapsed), or `FIRING`.

**Verify:** on a healthy default stack, both `BrewlineLatencySLOBreach` and
`BrewlinePaymentSuccessBurnRate` read `INACTIVE`, and the dashboard's **Active Brewline
alerts** table is empty.

## If it fails

| Symptom | Likely cause | Fix |
|---|---|---|
| SLO panels say "No data" | No traffic, or Prometheus has not evaluated the recording rules yet | Run k6 and wait one evaluation interval (15s) |
| Latency SLI is empty but RED panels work | The `brewline_order_duration_seconds` histogram has no samples — no order completed | Place one order, then refresh |
| Success SLI sits at exactly 1 | No payment failures in the window; with the 2% default that is normal | Nothing to fix |

## Next

- Force the alert to fire and clear it:
  [OP-03 — SLO alert drill](../operations/OP-03-slo-alert-drill.md).

## Note

There is intentionally **no Alertmanager**. The alert is viewed in Prometheus and
Grafana only; paging integrations are out of scope for this rig.
