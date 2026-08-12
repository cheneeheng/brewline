#requires -Version 7.0
# Example 5 — the log-to-trace pivot, the third pillar.
#
# Take one order_id, ask Loki for every log line that mentions it across all six
# services, and show that those lines carry the trace ID of the trace we placed.
# That correlation is what turns "something was slow" into "this exact request was
# slow, here is its waterfall". The Grafana version of this pivot is
# docs/guide/how-to/HT-02-observe-metrics-and-logs.md.

. "$PSScriptRoot\_lib.ps1"
Test-Stack

try {
    Invoke-RestMethod -Uri "$LokiUrl/ready" -TimeoutSec 3 | Out-Null
} catch {
    Write-Host "Loki is not answering at $LokiUrl"
    exit 1
}

$traceId = New-TraceId

Write-Say '1. place an order and remember its ID'
$reply = New-Order -Sku MOC-001 -Name Mocha -Qty 1 -UnitPrice '5.00' -TraceId $traceId
$orderId = $reply.order_id
Write-Note "order_id  $orderId"
Write-Note "trace_id  $traceId"

Write-Say '2. ask Loki for every line mentioning that order'
$query = '{service_namespace="brewline"} |= "' + $orderId + '"'
Write-Note $query
Write-Note
Write-Note 'service_namespace is a Loki label because the services set'
Write-Note 'OTEL_RESOURCE_ATTRIBUTES=service.namespace=brewline; Loki''s OTLP endpoint'
Write-Note 'promotes resource attributes to labels.'
Write-Host '   waiting for the async branch and the collector batch timeouts' -NoNewline

$entries = @()
foreach ($attempt in 1..12) {
    Start-Sleep -Seconds 3
    Write-Host '.' -NoNewline

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $fetched = try {
        Invoke-RestMethod -Uri "$LokiUrl/loki/api/v1/query_range" -Body @{
            query = $query
            start = ($now - 600) * 1000000000
            end   = $now * 1000000000
            limit = 100
        }
    } catch { $null }

    # trace_id rides in the per-stream map, not in the value tuple: Loki splits a
    # stream whenever the structured metadata differs, so every distinct trace_id
    # comes back as its own result entry alongside the resource labels.
    $found = foreach ($stream in $fetched.data.result) {
        foreach ($value in $stream.values) {
            [pscustomobject]@{
                Ts      = [long]$value[0]
                Service = $stream.stream.service_name ?? '?'
                Line    = $value[1]
                TraceId = $stream.stream.trace_id
            }
        }
    }
    if ($found) { $entries = @($found) }
    # Keep waiting for the last hop rather than stopping at the first line to land.
    if ($entries.Count -ge 4) { break }
}
Write-Host ''

if (-not $entries) {
    Write-Note 'Loki returned nothing for that order.'
    Write-Note
    Write-Note 'Log export needs two switches, not one: OTEL_LOGS_EXPORTER=otlp picks the'
    Write-Note 'exporter, and OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true attaches'
    Write-Note 'the SDK handler to the root logger. With only the first, records get a'
    Write-Note 'trace_id and are never shipped — and Loki stays exactly this empty.'
    exit 1
}

Write-Say '3. one order, told by every service that touched it (times local)'
foreach ($entry in $entries | Sort-Object Ts) {
    $at = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($entry.Ts / 1000000)).LocalDateTime
    $clock = $at.ToString('HH:mm:ss', [cultureinfo]::InvariantCulture)
    Write-Host ('   {0}  {1}{2}' -f $clock, $entry.Service.PadRight(14), $entry.Line)
}

Write-Say '4. the pivot'
$foundId = ($entries | Where-Object TraceId | Select-Object -First 1).TraceId
if ($foundId) {
    Write-Note "trace_id on the log lines : $foundId"
    Write-Note "trace_id we sent          : $traceId"
    if ($foundId -eq $traceId) {
        Write-Note '-> same trace. Log line to waterfall in one click.'
    }
} else {
    Write-Note 'These lines carry no trace_id, which means the log records reached Loki'
    Write-Note 'without span context — the SDK handler is attached but the lines were'
    Write-Note 'emitted outside any active span. Grafana shows the same field as the'
    Write-Note 'TraceID derived field on the Loki datasource.'
}
Write-Host ''
Write-Note 'In Grafana that field is a link: http://localhost:3000/d/brewline-logs'
Write-Note "Straight to the trace: $JaegerUrl/trace/$traceId"
