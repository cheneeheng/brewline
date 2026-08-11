#requires -Version 7.0
# Example 1 — the order lifecycle.
#
# Shows what a single POST /orders actually does: the synchronous half answers 202
# with status "paid", then the RabbitMQ consumers advance the order
# paid -> fulfilling -> ready on their own. Read-only apart from the one order.

. "$PSScriptRoot\_lib.ps1"
Test-Stack

$traceId = New-TraceId

Write-Say '1. place one Latte through the storefront'
Write-Note "POST $StorefrontUrl/orders"
$reply = New-Order -Sku LAT-001 -Name Latte -Qty 1 -UnitPrice '4.50' -TraceId $traceId
Write-Note "202 $($reply | ConvertTo-Json -Compress)"
$orderId = $reply.order_id
Write-Host ''
Write-Note 'The 202 arrives as soon as the sync half is done: persist -> charge ->'
Write-Note 'reserve stock -> publish order.placed. Everything after that is async.'

Write-Say '2. poll the order until the workers finish it'
$clock = [diagnostics.stopwatch]::StartNew()
$last = ''
foreach ($attempt in 1..40) {
    $status = Get-OrderStatus $orderId
    if ($status -ne $last) {
        Write-Note ('t+{0,2}s  {1}' -f [int]$clock.Elapsed.TotalSeconds, $status)
        $last = $status
    }
    if ($status -in 'ready', 'failed') { break }
    Start-Sleep -Milliseconds 500
}

Write-Host ''
switch ($last) {
    'ready' {
        Write-Note 'fulfillment consumed order.placed, slept PREP_SECONDS, and published'
        Write-Note 'order.ready; notification consumed that. Two services you never called.'
    }
    'failed' {
        Write-Note 'This one failed — a declined charge (PAYMENT_FAILURE_RATE, 2% by default)'
        Write-Note 'or a stock shortage. Nothing was published, so no worker ever saw it.'
    }
    default {
        Write-Note "Still $last after $([int]$clock.Elapsed.TotalSeconds)s. Check the fulfillment worker:"
        Write-Note '  docker compose -f deploy/docker-compose.yml logs fulfillment'
    }
}

Write-Say '3. the same order as one distributed trace'
Write-Note "order_id  $orderId"
Write-Note "trace_id  $traceId"
Write-Note "$JaegerUrl/trace/$traceId"
Write-Note
Write-Note 'Run 02-follow-one-trace.ps1 to print that waterfall in the terminal.'
