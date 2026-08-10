# OP-03 — SLO alert drill

Force `BrewlinePaymentSuccessBurnRate` to fire, then clear it. Run this to prove the
alerting path works end to end before you trust it.

Read [HT-03 — SLOs and burn-rate alerts](../how-to/HT-03-slos-and-alerts.md) first for
what the SLOs measure and how the alert threshold is built.

**Prerequisites:** a running stack; shell access to the repo root; write access to
`.env`; permission to recreate containers; k6 to drive load.
**Time / impact:** ~30 minutes, most of it waiting for the 1h window. No downtime and
no data loss. While the drill runs, about half of all orders return `status: failed` —
those are real rows in Postgres with status `failed`. Reverting stops new failures; it
does not rewrite the failed orders already recorded.

## What has to be true for the alert to fire

| Term | Value | Meaning |
|---|---|---|
| Error budget | `0.005` | 0.5% of orders may fail payment |
| Fast-burn factor | `14.4` | Standard SRE multiplier: burn a 30-day budget in ~2 days |
| Alert threshold | failure ratio > `0.072` | `14.4 × 0.005`, on the 5m **and** 1h windows |
| `for:` | `2m` | The condition must hold this long before `FIRING` |

The rule is in
[`deploy/prometheus/rules.yml`](../../../deploy/prometheus/rules.yml). Because both
windows must be over threshold at once, the 1h window sets the pace of this drill.

## Fire the alert

1. Edit `.env` and raise the payment failure rate far above the 7.2% threshold:
   ```bash
   PAYMENT_FAILURE_RATE=0.50
   ```
2. Recreate just the payment service:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate payment
   ```
   **Verify:** the new value is live in the container:
   ```bash
   docker compose -f deploy/docker-compose.yml exec payment printenv PAYMENT_FAILURE_RATE
   ```
   Expected output (compose passes the `.env` value through verbatim):
   ```
   0.50
   ```
3. Keep steady load running for the whole drill:
   ```bash
   k6 run -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js
   ```
   The steady scenario lasts 5 minutes — rerun it until the alert fires.
4. Watch the **Payment-success burn rate** panel on `/d/brewline-slo`. `5m burn`
   crosses 14.4 within about five minutes. `1h burn` climbs far more slowly, because
   the 1h window still averages in the healthy traffic that preceded the change —
   expect **10 to 20 minutes** before it crosses.

**Verify:** once both series sit above 14.4 for 2 minutes, the alert
**BrewlinePaymentSuccessBurnRate** appears in two places:
- Prometheus → **http://localhost:9090/alerts** — it goes `PENDING`, then `FIRING`.
- The SLO dashboard **Active Brewline alerts** table.

**If it fails:**
- Only `5m burn` is above 14.4 → the 1h window has not caught up. Keep load running.
- Neither climbs → no traffic is reaching payment. Confirm k6 is running and that
  `/d/brewline-orders` shows a non-zero order rate.

## Revert

1. Restore the default in `.env`:
   ```bash
   PAYMENT_FAILURE_RATE=0.02
   ```
2. Recreate payment:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate payment
   ```

**Verify:** `5m burn` drops below 14.4 within about five minutes and the alert leaves
`FIRING`. `1h burn` keeps decaying for up to an hour — that lag is the long window
doing its job, not a stuck alert.

## Variant: breach the latency SLO instead

Same shape, different knob. Set `PAYMENT_LATENCY_MS=900` in `.env`, recreate `payment`,
and the order p99 crosses the 800ms target, firing `BrewlineLatencySLOBreach` after its
`for: 5m`. Restore `PAYMENT_LATENCY_MS=40` to revert.

## Note

There is intentionally **no Alertmanager**. The alert is viewed in Prometheus and
Grafana only; paging integrations are out of scope for this rig. That means firing the
alert has no outward-facing effect — nobody is paged by this drill.
