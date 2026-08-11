# Shared helpers for the examples. Sourced by each script, never run directly.
#
# Every example talks to a *running* stack over HTTP only: it places orders through
# the public storefront and reads the telemetry back out of Jaeger, Prometheus, and
# Loki. Nothing here edits .env, swaps a collector config, or recreates a container —
# procedures that change configuration live in docs/guide/operations and
# docs/guide/experiments.

STOREFRONT_URL="${STOREFRONT_URL:-http://localhost:8000}"
INVENTORY_URL="${INVENTORY_URL:-http://localhost:8080}"
JAEGER_URL="${JAEGER_URL:-http://localhost:16686}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"

for _dep in curl jq od; do
  command -v "$_dep" >/dev/null || { echo "missing dependency: $_dep" >&2; exit 1; }
done

say()  { printf '\n== %s\n\n' "$*"; }
note() { printf '   %s\n' "$*"; }

require_stack() {
  curl -fsS --max-time 3 -o /dev/null "$STOREFRONT_URL/healthz" || {
    echo "storefront is not answering at $STOREFRONT_URL" >&2
    echo "start the stack:  docker compose -f deploy/docker-compose.yml up -d" >&2
    exit 1
  }
}

# We choose the trace ID instead of hunting for it afterwards. The storefront is
# auto-instrumented, so it extracts the inbound traceparent and every downstream
# span — HTTP and broker alike — lands under this ID.
new_trace_id() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n'; }
_new_span_id() { od -An -tx1 -N8 /dev/urandom | tr -d ' \n'; }

# place_order <sku> <name> <qty> <unit_price> <trace_id>
place_order() {
  curl -fsS -X POST "$STOREFRONT_URL/orders" \
    -H 'content-type: application/json' \
    -H "traceparent: 00-$5-$(_new_span_id)-01" \
    -d "{\"items\":[{\"sku\":\"$1\",\"name\":\"$2\",\"qty\":$3,\"unit_price\":\"$4\"}]}"
}

order_status() { curl -fsS "$STOREFRONT_URL/orders/$1" | jq -r '.status // "?"'; }

# Reads a Jaeger /api/traces/<id> response on stdin and prints a text waterfall:
# service, span name, duration, and a bar positioned by start offset.
render_waterfall() {
  jq -r '
    def pad($n): (. + "                                        ")[0:$n];
    def lpad($n): ("          " + .)[-$n:];
    def rep($c; $n): if $n > 0 then $c * $n else "" end;
    .data[0] as $t
    | $t.processes as $procs
    | ([$t.spans[].startTime] | min) as $t0
    | ([$t.spans[] | .startTime + .duration] | max) as $tend
    | (if ($tend - $t0) > 0 then ($tend - $t0) else 1 end) as $total
    | $t.spans
    | sort_by(.startTime)[]
    | (($procs[.processID].serviceName // "?") | pad(14))
      + (.operationName | pad(30))
      + (((.duration / 1000 | round | tostring) + "ms") | lpad(9))
      + "  "
      + rep("."; (((.startTime - $t0) / $total * 44) | floor))
      + rep("#"; (((.duration / $total * 44) | floor) | if . < 1 then 1 else . end))
  '
}
