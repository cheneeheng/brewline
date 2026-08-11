#requires -Version 7.0
# Shared helpers for the PowerShell examples. Dot-sourced by each script, never run
# directly. Mirrors _lib.sh one for one.
#
# Every example talks to a *running* stack over HTTP only: it places orders through
# the public storefront and reads the telemetry back out of Jaeger, Prometheus, and
# Loki. Nothing here edits .env, swaps a collector config, or recreates a container —
# procedures that change configuration live in docs/guide/operations and
# docs/guide/experiments.

$ErrorActionPreference = 'Stop'

$StorefrontUrl = $env:STOREFRONT_URL ?? 'http://localhost:8000'
$InventoryUrl = $env:INVENTORY_URL ?? 'http://localhost:8080'
$JaegerUrl = $env:JAEGER_URL ?? 'http://localhost:16686'
$PromUrl = $env:PROM_URL ?? 'http://localhost:9090'
$LokiUrl = $env:LOKI_URL ?? 'http://localhost:3100'

function Write-Say { param([string]$Text) Write-Host "`n== $Text`n" }
function Write-Note { param([string]$Text = '') Write-Host "   $Text" }

function Test-Stack {
    try {
        Invoke-RestMethod -Uri "$StorefrontUrl/healthz" -TimeoutSec 3 | Out-Null
    } catch {
        Write-Host "storefront is not answering at $StorefrontUrl"
        Write-Host 'start the stack:  docker compose -f deploy/docker-compose.yml up -d'
        exit 1
    }
}

# We choose the trace ID instead of hunting for it afterwards. The storefront is
# auto-instrumented, so it extracts the inbound traceparent and every downstream
# span — HTTP and broker alike — lands under this ID. A GUID without separators is
# already 32 hex characters, which is exactly the W3C trace-ID shape.
function New-TraceId { [guid]::NewGuid().ToString('N') }
function New-SpanId { [guid]::NewGuid().ToString('N').Substring(0, 16) }

function New-Order {
    param(
        [string]$Sku,
        [string]$Name,
        [int]$Qty,
        [string]$UnitPrice,
        [string]$TraceId
    )
    $body = @{ items = @(@{ sku = $Sku; name = $Name; qty = $Qty; unit_price = $UnitPrice }) } |
        ConvertTo-Json -Depth 5 -Compress
    Invoke-RestMethod -Method Post -Uri "$StorefrontUrl/orders" `
        -ContentType 'application/json' `
        -Headers @{ traceparent = "00-$TraceId-$(New-SpanId)-01" } `
        -Body $body
}

function Get-OrderStatus {
    param([string]$OrderId)
    (Invoke-RestMethod -Uri "$StorefrontUrl/orders/$OrderId").status
}

# Takes a parsed Jaeger /api/traces/<id> response and emits a text waterfall:
# service, span name, duration, and a bar positioned by start offset.
function Show-Waterfall {
    param($Trace)

    $t = $Trace.data[0]
    $t0 = ($t.spans | Measure-Object -Property startTime -Minimum).Minimum
    $end = ($t.spans | ForEach-Object { $_.startTime + $_.duration } | Measure-Object -Maximum).Maximum
    $total = [math]::Max($end - $t0, 1)

    foreach ($s in $t.spans | Sort-Object startTime) {
        $service = $t.processes.($s.processID).serviceName ?? '?'
        $offset = [math]::Floor(($s.startTime - $t0) / $total * 44)
        $length = [math]::Max([math]::Floor($s.duration / $total * 44), 1)
        '{0}{1}{2}  {3}' -f `
            $service.PadRight(14),
            $s.operationName.PadRight(30),
            "$([math]::Round($s.duration / 1000))ms".PadLeft(9),
        (('.' * $offset) + ('#' * $length))
    }
}
