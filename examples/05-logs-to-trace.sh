#!/usr/bin/env bash
# Example 5 — the log-to-trace pivot, the third pillar.
#
# Take one order_id, ask Loki for every log line that mentions it across all six
# services, and show that those lines carry the trace ID of the trace we placed.
# That correlation is what turns "something was slow" into "this exact request was
# slow, here is its waterfall". The Grafana version of this pivot is
# docs/guide/how-to/HT-02-observe-metrics-and-logs.md.

set -euo pipefail
. "$(dirname "$0")/_lib.sh"
require_stack

curl -fsS --max-time 3 -o /dev/null "$LOKI_URL/ready" || {
  echo "Loki is not answering at $LOKI_URL" >&2
  exit 1
}

TRACE_ID=$(new_trace_id)

say "1. place an order and remember its ID"
REPLY=$(place_order MOC-001 Mocha 1 5.00 "$TRACE_ID")
ORDER_ID=$(jq -r .order_id <<<"$REPLY")
note "order_id  $ORDER_ID"
note "trace_id  $TRACE_ID"

say "2. ask Loki for every line mentioning that order"
QUERY="{service_namespace=\"brewline\"} |= \"$ORDER_ID\""
note "$QUERY"
note ""
note "service_namespace is a Loki label because the services set"
note "OTEL_RESOURCE_ATTRIBUTES=service.namespace=brewline; Loki's OTLP endpoint"
note "promotes resource attributes to labels."
printf '   waiting for the async branch and the collector batch timeouts'

RESULT=""
for _ in $(seq 1 12); do
  sleep 3
  printf '.'
  FETCHED=$(curl -fsSG "$LOKI_URL/loki/api/v1/query_range" \
    --data-urlencode "query=$QUERY" \
    --data-urlencode "start=$(( ($(date +%s) - 600) * 1000000000 ))" \
    --data-urlencode "end=$(( $(date +%s) * 1000000000 ))" \
    --data-urlencode "limit=100" || echo '{"data":{"result":[]}}')
  COUNT=$(jq -r '[.data.result[].values[]] | length' <<<"$FETCHED")
  if [ "$COUNT" != "0" ]; then RESULT=$FETCHED; fi
  # Keep waiting for the last hop rather than stopping at the first line to land.
  if [ "$COUNT" -ge 4 ]; then break; fi
done
printf '\n'

if [ -z "$RESULT" ]; then
  note "Loki returned nothing for that order."
  note ""
  note "Log export needs two switches, not one: OTEL_LOGS_EXPORTER=otlp picks the"
  note "exporter, and OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true attaches"
  note "the SDK handler to the root logger. With only the first, records get a"
  note "trace_id and are never shipped — and Loki stays exactly this empty."
  exit 1
fi

say "3. one order, told by every service that touched it (times UTC)"
jq -r '
  [ .data.result[] as $s
    | $s.values[]
    | { ts: (.[0] | tonumber),
        svc: ($s.stream.service_name // "?"),
        line: .[1] } ]
  | sort_by(.ts)[]
  | "   " + (.ts / 1000000000 | floor | strftime("%H:%M:%S"))
    + "  " + ((.svc + "              ")[0:14])
    + .line' <<<"$RESULT"

say "4. the pivot"
FOUND_TID=$(jq -r '[.data.result[].values[][2].trace_id // empty] | first // ""' <<<"$RESULT")
if [ -n "$FOUND_TID" ]; then
  note "trace_id on the log lines : $FOUND_TID"
  note "trace_id we sent          : $TRACE_ID"
  if [ "$FOUND_TID" = "$TRACE_ID" ]; then
    note "-> same trace. Log line to waterfall in one click."
  fi
else
  note "This Loki build does not return structured metadata over the HTTP API, so"
  note "the trace_id is not visible here. It is attached to the records, and"
  note "Grafana's Loki datasource exposes it as the TraceID derived field."
fi
printf '\n'
note "In Grafana that field is a link: http://localhost:3000/d/brewline-logs"
note "Straight to the trace: $JAEGER_URL/trace/$TRACE_ID"
