#!/usr/bin/env bash
# Example 4 — the failure path, without touching any configuration.
#
# Order more Chai Lattes than exist. The Go inventory service refuses the whole
# reservation (all-or-nothing, inside one transaction), so the order ends "failed"
# and nothing is ever published to RabbitMQ — no fulfillment, no notification.
# This is the one failure you can trigger with a plain request; the four that need
# a config change are docs/guide/experiments/EX-0*.

set -euo pipefail
. "$(dirname "$0")/_lib.sh"
require_stack

SKU=CHA-001
QTY=500

say "1. how much Chai Latte the rig actually stocks"
note "GET $INVENTORY_URL/inventory/$SKU"
note "$(curl -fsS "$INVENTORY_URL/inventory/$SKU")"
printf '\n'
note "available_qty is the stocked amount. Reservations accumulate separately in"
note "reserved_qty; a reservation succeeds only while available_qty - reserved_qty"
note "covers it. Nothing in this rig ever releases a reservation."

say "2. order $QTY of them"
TRACE_ID=$(new_trace_id)
REPLY=$(place_order "$SKU" "Chai Latte" "$QTY" 4.25 "$TRACE_ID")
note "202 $REPLY"
ORDER_ID=$(jq -r .order_id <<<"$REPLY")
printf '\n'
note "Still HTTP 202 — the request was well-formed. The business outcome is in"
note "the body, and it is \"failed\"."

say "3. the order stays failed"
sleep 3
note "GET $STOREFRONT_URL/orders/$ORDER_ID"
curl -fsS "$STOREFRONT_URL/orders/$ORDER_ID" | jq -r '"     status = \(.status), total = \(.total_amount)"'
printf '\n'
note "It never moves past failed: order.placed was not published, so the two"
note "consumers never learned this order exists."
note ""
note "Note the ordering — the charge happens before the reservation, so this order"
note "was charged and then failed. There is no compensating refund step; that is a"
note "recorded scope boundary of the rig, not an oversight to fix."

say "4. what the inventory service replied to the order service"
note "POST $INVENTORY_URL/reserve  (safe to call directly: a short reservation"
note "rolls the transaction back, so no stock moves)"
printf '\n'
curl -fsS -X POST "$INVENTORY_URL/reserve" \
  -H 'content-type: application/json' \
  -d "{\"order_id\":\"example-04-probe\",\"items\":[{\"sku\":\"$SKU\",\"qty\":$QTY}]}" \
  | jq -r '"     " + tostring'

say "5. where this shows up in telemetry"
note "metric   brewline_inventory_shortages_total{sku=\"$SKU\"}  (bounded label: sku,"
note "         never order_id) — allow ~30s for the Prometheus scrape"
note "log      the order service logged \"inventory.short order_id=$ORDER_ID\""
note "trace    $JAEGER_URL/trace/$TRACE_ID"
printf '\n'
note "That trace is short and carries no span error, so the gateway's tail sampler"
note "judges it by the 5% probabilistic policy — it is usually *not* in Jaeger."
note "Which policy keeps which trace is exactly what EX-04 measures."
