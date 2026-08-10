# How-to: SLOs and burn-rate alerts

Goal: read Brewline's SLOs and make the payment-success burn-rate alert fire on
demand.

**Prerequisites:** the stack is running; steady load helps the numbers move:

```bash
k6 run -e STOREFRONT_URL=http://localhost:8000 loadgen/k6_order.js
```

## The two SLOs

Defined as Prometheus rules in
[`deploy/prometheus/rules.yml`](../../deploy/prometheus/rules.yml):

- **Latency SLO** — 99% of `POST /orders` under **800ms**, from the
  `brewline_order_duration_seconds` histogram.
- **Payment-success SLO** — **≥ 99.5%** success, i.e. `1 - failures/placed`. Error
  budget is the remaining 0.5%.

## Read the SLO dashboard

Open **http://localhost:3000**, dashboard **SLO & error budget** (`/d/brewline-slo`).
Panels:

- **Latency SLI: p99 vs 800ms target** — green under target, red over.
- **Payment-success SLI (target 99.5%)** — a stat panel; green at/above 0.995.
- **Payment-success burn rate** — failure ratio ÷ 0.005 budget over 5m and 1h
  windows; a value above 1 means you are burning budget faster than allowed.
- **Active Brewline alerts** — a table of firing alerts.

**Verify:** with defaults, the success SLI reads ~0.98–1.00 and no alerts are firing.

## Make the burn-rate alert fire

> **Note:** this changes a runtime setting and forces failures. It is fully reversible.

1. Edit `.env` and raise the payment failure rate well above the 0.5% budget:
   ```bash
   PAYMENT_FAILURE_RATE=0.20
   ```
2. Recreate just the payment service:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate payment
   ```
3. Keep load running (`k6 ... loadgen/k6_order.js`).
4. Watch the **Payment-success burn rate** panel climb above 1 on the 5m window first,
   then the 1h window.

**Verify:** within a few minutes the alert **BrewlinePaymentSuccessBurnRate** appears.
Check it in two places:
- Prometheus → **http://localhost:9090/alerts** — the alert goes `PENDING` then
  `FIRING`.
- The SLO dashboard **Active Brewline alerts** table.

The alert needs *both* the short (5m) and long (1h) windows over threshold, so the 1h
window takes a while to catch up — that two-window requirement is the point of a
multi-window burn-rate alert: it reacts fast but resists flapping.

## Revert

1. Restore the default in `.env`:
   ```bash
   PAYMENT_FAILURE_RATE=0.02
   ```
2. Recreate payment:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate payment
   ```

**Verify:** the burn-rate panels fall back below 1 and the alert resolves.

## Notes

- There is intentionally **no Alertmanager** — the alert is viewed in Prometheus and
  Grafana only. Paging integrations are out of scope for this rig.
- You can make the **latency** SLO breach instead by raising `PAYMENT_LATENCY_MS`
  (e.g. to `900`) and recreating payment; the order p99 will cross 800ms.
