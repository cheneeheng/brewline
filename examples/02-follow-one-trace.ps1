#requires -Version 7.0
# Example 2 — one trace across HTTP *and* the broker, printed in the terminal.
#
# The headline claim of this rig is that a single POST /orders produces one
# connected trace over six services, two of which are only reachable through
# RabbitMQ. This fetches that trace from Jaeger by ID and renders the waterfall,
# so you can see the claim without opening a UI. The UI version is
# docs/guide/how-to/HT-01-observe-traces.md.

. "$PSScriptRoot\_lib.ps1"
Test-Stack

$traceId = New-TraceId

Write-Say '1. place an order, choosing the trace ID ourselves'
Write-Note "traceparent: 00-$traceId-<span>-01"
$reply = New-Order -Sku CAP-001 -Name Cappuccino -Qty 2 -UnitPrice '4.25' -TraceId $traceId
Write-Note "202 $($reply | ConvertTo-Json -Compress)"
Write-Host ''
Write-Note "The storefront's auto-instrumentation extracts that header, so every"
Write-Note 'downstream span — including the ones the broker carries — uses this ID.'

Write-Say '2. wait for Jaeger to receive it'
Write-Note 'The trace is not queryable the moment the order returns:'
Write-Note '  ~2s   fulfillment prep (PREP_SECONDS) is inside the trace'
Write-Note '  15s   the gateway holds the trace for tail_sampling.decision_wait'
Write-Note '  ~5s   collector batch timeouts on the way out'
Write-Host '   waiting' -NoNewline

$trace = $null
foreach ($attempt in 1..20) {
    Start-Sleep -Seconds 3
    Write-Host '.' -NoNewline
    $fetched = try { Invoke-RestMethod -Uri "$JaegerUrl/api/traces/$traceId" } catch { $null }
    if ($fetched.data.Count -gt 0) {
        $trace = $fetched
        break
    }
}
Write-Host ''

if (-not $trace) {
    Write-Note "Jaeger has no trace $traceId."
    Write-Note
    Write-Note 'The gateway keeps every error trace, every trace over 800ms, and 5% of the'
    Write-Note 'rest. An order trace normally clears 800ms on the prep delay alone, so an'
    Write-Note 'absence here usually means the pipeline, not the sampler. Start with'
    Write-Note 'docs/guide/troubleshooting.md, then EX-04 for the sampling side.'
    exit 1
}

Write-Say '3. the waterfall'
Write-Host ('   {0}{1}{2}  {3}' -f 'service'.PadRight(14), 'span'.PadRight(30), 'duration'.PadLeft(9), 'offset/length')
Show-Waterfall $trace | ForEach-Object { Write-Host "   $_" }

# Distinct service names, not processes: Jaeger records one process per service
# *instance*, so order and storefront repeat once per worker without the dedupe.
$services = ($trace.data[0].processes.PSObject.Properties.Value.serviceName | Sort-Object -Unique) -join ', '
Write-Host ''
Write-Note "$($trace.data[0].spans.Count) spans in one trace, from $services"
Write-Host ''
Write-Note 'What to look for:'
Write-Note '  * inventory spans nested under order — that hop is Python -> Go, and it'
Write-Note "    only stays connected because the Go SDK's no-op default propagator is"
Write-Note '    replaced explicitly (services/inventory/main.go).'
Write-Note '  * fulfillment and notification spans in the *same* trace, seconds later.'
Write-Note '    Nothing called them over HTTP; the traceparent rode inside the AMQP'
Write-Note '    message headers. Turning that off is EX-01.'
Write-Note '  * the inventory span carries brewline.order_id and db.system, hand-set on'
Write-Note '    the inbound server span because pgx is not auto-instrumented here. The'
Write-Note '    cache_hit attribute sits on the GET path instead — example 04 shows it.'
Write-Host ''
Write-Note "Full detail, tags included: $JaegerUrl/trace/$traceId"
