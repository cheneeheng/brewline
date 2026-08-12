#!/usr/bin/env bash
# Example 3 — what the metrics pipeline produced, read straight from Prometheus.
#
# The point of this one is the name translation. Services emit OTel instruments
# with dots (brewline.orders.placed); the gateway's Prometheus exporter rewrites
# dots to underscores and appends _total to monotonic counters. Every query below
# uses the *translated* name — the same names the Grafana panels and the SLO rules
# use. Read-only: this places no orders.

set -euo pipefail
. "$(dirname "$0")/_lib.sh"

curl -fsS --max-time 3 -o /dev/null "$PROM_URL/-/healthy" || {
  echo "Prometheus is not answering at $PROM_URL" >&2
  exit 1
}

# show <title> <promql> <label to break out, or "">
show() {
  say "$1"
  note "$2"
  printf '\n'
  curl -fsSG "$PROM_URL/api/v1/query" --data-urlencode "query=$2" \
    | jq -r --arg lbl "$3" '
        if (.data.result | length) == 0 then
          "     (no series yet — place an order or run k6 first)"
        else
          .data.result[]
          | (if $lbl == "" then "total" else (.metric[$lbl] // "-") end) as $k0
          # Pad to 20, never truncate: recording-rule names run to 37 characters,
          # and PadRight in the .ps1 flavour does not cut them either.
          | (if ($k0 | length) >= 20 then $k0
             else ($k0 + "                    ")[0:20] end) as $k
          | (.value[1]) as $v
          | "     " + $k + " = "
            + (if ($v | test("NaN|Inf")) then $v
               else ($v | tonumber * 1000 | round / 1000 | tostring) end)
        end'
}

show "Orders placed, by outcome  (OTel: brewline.orders.placed)" \
  'sum by (outcome) (brewline_orders_placed_total)' outcome

show "Stock reservations, by outcome  (OTel: brewline.inventory.reserved, from Go)" \
  'sum by (outcome) (brewline_inventory_reserved_total)' outcome

show "Declined charges  (OTel: brewline.payment.failures)" \
  'sum(brewline_payment_failures_total)' ""

show "Order latency p95, last 5m  (OTel: brewline.order.duration, unit s)" \
  'histogram_quantile(0.95, sum(rate(brewline_order_duration_seconds_bucket[5m])) by (le))' ""

show "Request rate by service, last 5m  (HTTP RED, stable semconv)" \
  'sum by (service_name) (rate(http_server_request_duration_seconds_count[5m]))' service_name

printf '\n'
note "Only the Python services appear. inventory serves HTTP too, but the Go side"
note "still emits the legacy http_server_duration_milliseconds_* series, so a"
note "stable-semconv query cannot see it — the RED dashboard has the same gap."

# A name selector, not "A or B": the set operators match on label sets with __name__
# excluded, so two rules that carry no other labels look identical to `or` and only
# the first would ever print.
show "SLI recording rules, evaluated by Prometheus" \
  '{__name__=~"brewline:.+:5m"}' __name__

say "Cardinality: how many series each metric actually costs"
note 'count by (__name__) ({__name__=~"brewline_.+"})'
printf '\n'
curl -fsSG "$PROM_URL/api/v1/query" \
  --data-urlencode 'query=count by (__name__) ({__name__=~"brewline_.+"})' \
  | jq -r '.data.result | sort_by(-(.value[1] | tonumber))[]
           | "     " + ((.metric.__name__ + "                                        ")[0:40])
             + " = " + .value[1] + " series"'

printf '\n'
note "Those counts stay small because identifiers never become metric labels:"
note "order_id lives on spans and log lines only. EX-02 breaks that on purpose"
note "with CARDINALITY_MODE=high and you watch this list grow without bound."
printf '\n'
note "Dashboards: http://localhost:3000/d/brewline-red and /d/brewline-orders"
note "Alert rules: $PROM_URL/alerts"
