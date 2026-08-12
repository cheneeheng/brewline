#!/usr/bin/env bash
# Example 2 — one trace across HTTP *and* the broker, printed in the terminal.
#
# The headline claim of this rig is that a single POST /orders produces one
# connected trace over six services, two of which are only reachable through
# RabbitMQ. This fetches that trace from Jaeger by ID and renders the waterfall,
# so you can see the claim without opening a UI. The UI version is
# docs/guide/how-to/HT-01-observe-traces.md.

set -euo pipefail
. "$(dirname "$0")/_lib.sh"
require_stack

TRACE_ID=$(new_trace_id)

say "1. place an order, choosing the trace ID ourselves"
note "traceparent: 00-$TRACE_ID-<span>-01"
REPLY=$(place_order CAP-001 Cappuccino 2 4.25 "$TRACE_ID")
note "202 $REPLY"
printf '\n'
note "The storefront's auto-instrumentation extracts that header, so every"
note "downstream span — including the ones the broker carries — uses this ID."

say "2. wait for Jaeger to receive it"
note "The trace is not queryable the moment the order returns:"
note "  ~2s   fulfillment prep (PREP_SECONDS) is inside the trace"
note "  15s   the gateway holds the trace for tail_sampling.decision_wait"
note "  ~5s   collector batch timeouts on the way out"
printf '   waiting'
TRACE=""
for _ in $(seq 1 20); do
  sleep 3
  printf '.'
  FETCHED=$(curl -fsS "$JAEGER_URL/api/traces/$TRACE_ID" || echo '{"data":[]}')
  if [ "$(jq -r '.data | length' <<<"$FETCHED")" != "0" ]; then
    TRACE=$FETCHED
    break
  fi
done
printf '\n'

if [ -z "$TRACE" ]; then
  note "Jaeger has no trace $TRACE_ID."
  note ""
  note "The gateway keeps every error trace, every trace over 800ms, and 5% of the"
  note "rest. An order trace normally clears 800ms on the prep delay alone, so an"
  note "absence here usually means the pipeline, not the sampler. Start with"
  note "docs/guide/troubleshooting.md, then EX-04 for the sampling side."
  exit 1
fi

say "3. the waterfall"
printf '   %-14s%-30s%9s  %s\n' service span duration "offset/length"
render_waterfall <<<"$TRACE" | sed 's/^/   /'

printf '\n'
# unique, not sort: Jaeger records one process per service *instance*, so order
# and storefront repeat once per worker without the dedupe.
note "$(jq -r '.data[0].spans | length | "\(.) spans"' <<<"$TRACE") in one trace, from $(jq -r '[.data[0].processes[].serviceName] | unique | join(", ")' <<<"$TRACE")"
printf '\n'
note "What to look for:"
note "  * inventory spans nested under order — that hop is Python -> Go, and it"
note "    only stays connected because the Go SDK's no-op default propagator is"
note "    replaced explicitly (services/inventory/main.go)."
note "  * fulfillment and notification spans in the *same* trace, seconds later."
note "    Nothing called them over HTTP; the traceparent rode inside the AMQP"
note "    message headers. Turning that off is EX-01."
note "  * the inventory span carries brewline.order_id and db.system, hand-set on"
note "    the inbound server span because pgx is not auto-instrumented here. The"
note "    cache_hit attribute sits on the GET path instead — example 04 shows it."
printf '\n'
note "Full detail, tags included: $JAEGER_URL/trace/$TRACE_ID"
