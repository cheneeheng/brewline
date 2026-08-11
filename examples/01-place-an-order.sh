#!/usr/bin/env bash
# Example 1 — the order lifecycle.
#
# Shows what a single POST /orders actually does: the synchronous half answers 202
# with status "paid", then the RabbitMQ consumers advance the order
# paid -> fulfilling -> ready on their own. Read-only apart from the one order.

set -euo pipefail
. "$(dirname "$0")/_lib.sh"
require_stack

TRACE_ID=$(new_trace_id)

say "1. place one Latte through the storefront"
note "POST $STOREFRONT_URL/orders"
REPLY=$(place_order LAT-001 Latte 1 4.50 "$TRACE_ID")
note "202 $REPLY"
ORDER_ID=$(jq -r .order_id <<<"$REPLY")
printf '\n'
note "The 202 arrives as soon as the sync half is done: persist -> charge ->"
note "reserve stock -> publish order.placed. Everything after that is async."

say "2. poll the order until the workers finish it"
STARTED=$SECONDS
LAST=""
for _ in $(seq 1 40); do
  STATUS=$(order_status "$ORDER_ID")
  if [ "$STATUS" != "$LAST" ]; then
    note "$(printf 't+%2ds  %s' "$((SECONDS - STARTED))" "$STATUS")"
    LAST=$STATUS
  fi
  if [ "$STATUS" = "ready" ] || [ "$STATUS" = "failed" ]; then break; fi
  sleep 0.5
done

printf '\n'
if [ "$LAST" = "ready" ]; then
  note "fulfillment consumed order.placed, slept PREP_SECONDS, and published"
  note "order.ready; notification consumed that. Two services you never called."
elif [ "$LAST" = "failed" ]; then
  note "This one failed — a declined charge (PAYMENT_FAILURE_RATE, 2% by default)"
  note "or a stock shortage. Nothing was published, so no worker ever saw it."
else
  note "Still $LAST after $((SECONDS - STARTED))s. Check the fulfillment worker:"
  note "  docker compose -f deploy/docker-compose.yml logs fulfillment"
fi

say "3. the same order as one distributed trace"
note "order_id  $ORDER_ID"
note "trace_id  $TRACE_ID"
note "$JAEGER_URL/trace/$TRACE_ID"
note ""
note "Run 02-follow-one-trace.sh to print that waterfall in the terminal."
