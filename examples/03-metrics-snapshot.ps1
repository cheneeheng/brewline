#requires -Version 7.0
# Example 3 — what the metrics pipeline produced, read straight from Prometheus.
#
# The point of this one is the name translation. Services emit OTel instruments
# with dots (brewline.orders.placed); the gateway's Prometheus exporter rewrites
# dots to underscores and appends _total to monotonic counters. Every query below
# uses the *translated* name — the same names the Grafana panels and the SLO rules
# use. Read-only: this places no orders.

. "$PSScriptRoot\_lib.ps1"

try {
    Invoke-RestMethod -Uri "$PromUrl/-/healthy" -TimeoutSec 3 | Out-Null
} catch {
    Write-Host "Prometheus is not answering at $PromUrl"
    exit 1
}

function Get-PromResult {
    param([string]$Query)
    (Invoke-RestMethod -Uri "$PromUrl/api/v1/query" -Body @{ query = $Query }).data.result
}

function Show-PromQuery {
    param([string]$Title, [string]$Query, [string]$Label)

    Write-Say $Title
    Write-Note $Query
    Write-Host ''

    $result = Get-PromResult $Query
    if (-not $result) {
        Write-Host '     (no series yet — place an order or run k6 first)'
        return
    }
    foreach ($series in $result) {
        $key = if ($Label) { [string]($series.metric.$Label ?? '-') } else { 'total' }
        $raw = $series.value[1]
        # Invariant formatting on purpose: a comma-decimal locale would otherwise
        # print 0,142 for a value Prometheus and every dashboard call 0.142.
        $value = if ($raw -match 'NaN|Inf') { $raw }
        else { [math]::Round([double]$raw, 3).ToString([cultureinfo]::InvariantCulture) }
        Write-Host ('     {0} = {1}' -f $key.PadRight(20), $value)
    }
}

Show-PromQuery 'Orders placed, by outcome  (OTel: brewline.orders.placed)' `
    'sum by (outcome) (brewline_orders_placed_total)' 'outcome'

Show-PromQuery 'Stock reservations, by outcome  (OTel: brewline.inventory.reserved, from Go)' `
    'sum by (outcome) (brewline_inventory_reserved_total)' 'outcome'

Show-PromQuery 'Declined charges  (OTel: brewline.payment.failures)' `
    'sum(brewline_payment_failures_total)' ''

Show-PromQuery 'Order latency p95, last 5m  (OTel: brewline.order.duration, unit s)' `
    'histogram_quantile(0.95, sum(rate(brewline_order_duration_seconds_bucket[5m])) by (le))' ''

Show-PromQuery 'Request rate by service, last 5m  (HTTP RED, stable semconv)' `
    'sum by (service_name) (rate(http_server_request_duration_seconds_count[5m]))' 'service_name'

Show-PromQuery 'SLI recording rules, evaluated by Prometheus' `
    'brewline:order_latency_p99_seconds:5m or brewline:payment_failure_ratio:5m' '__name__'

Write-Say 'Cardinality: how many series each metric actually costs'
Write-Note 'count by (__name__) ({__name__=~"brewline_.+"})'
Write-Host ''
Get-PromResult 'count by (__name__) ({__name__=~"brewline_.+"})' |
    Sort-Object { [int]$_.value[1] } -Descending |
    ForEach-Object { Write-Host ('     {0} = {1} series' -f $_.metric.__name__.PadRight(40), $_.value[1]) }

Write-Host ''
Write-Note 'Those counts stay small because identifiers never become metric labels:'
Write-Note 'order_id lives on spans and log lines only. EX-02 breaks that on purpose'
Write-Note 'with CARDINALITY_MODE=high and you watch this list grow without bound.'
Write-Host ''
Write-Note 'Dashboards: http://localhost:3000/d/brewline-red and /d/brewline-orders'
Write-Note "Alert rules: $PromUrl/alerts"
