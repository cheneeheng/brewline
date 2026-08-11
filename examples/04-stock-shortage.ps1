#requires -Version 7.0
# Example 4 — the failure path, without touching any configuration.
#
# Order more Chai Lattes than exist. The Go inventory service refuses the whole
# reservation (all-or-nothing, inside one transaction), so the order ends "failed"
# and nothing is ever published to RabbitMQ — no fulfillment, no notification.
# This is the one failure you can trigger with a plain request; the four that need
# a config change are docs/guide/experiments/EX-0*.

. "$PSScriptRoot\_lib.ps1"
Test-Stack

$sku = 'CHA-001'
$qty = 500

Write-Say '1. how much Chai Latte the rig actually stocks'
Write-Note "GET $InventoryUrl/inventory/$sku"
Write-Note (Invoke-RestMethod -Uri "$InventoryUrl/inventory/$sku" | ConvertTo-Json -Compress)
Write-Host ''
Write-Note 'available_qty is the stocked amount. Reservations accumulate separately in'
Write-Note 'reserved_qty; a reservation succeeds only while available_qty - reserved_qty'
Write-Note 'covers it. Nothing in this rig ever releases a reservation.'

Write-Say "2. order $qty of them"
$traceId = New-TraceId
$reply = New-Order -Sku $sku -Name 'Chai Latte' -Qty $qty -UnitPrice '4.25' -TraceId $traceId
Write-Note "202 $($reply | ConvertTo-Json -Compress)"
$orderId = $reply.order_id
Write-Host ''
Write-Note 'Still HTTP 202 — the request was well-formed. The business outcome is in'
Write-Note 'the body, and it is "failed".'

Write-Say '3. the order stays failed'
Start-Sleep -Seconds 3
Write-Note "GET $StorefrontUrl/orders/$orderId"
$order = Invoke-RestMethod -Uri "$StorefrontUrl/orders/$orderId"
Write-Host "     status = $($order.status), total = $($order.total_amount)"
Write-Host ''
Write-Note 'It never moves past failed: order.placed was not published, so the two'
Write-Note 'consumers never learned this order exists.'
Write-Note
Write-Note 'Note the ordering — the charge happens before the reservation, so this order'
Write-Note 'was charged and then failed. There is no compensating refund step; that is a'
Write-Note 'recorded scope boundary of the rig, not an oversight to fix.'

Write-Say '4. what the inventory service replied to the order service'
Write-Note "POST $InventoryUrl/reserve  (safe to call directly: a short reservation"
Write-Note 'rolls the transaction back, so no stock moves)'
Write-Host ''
$probe = @{ order_id = 'example-04-probe'; items = @(@{ sku = $sku; qty = $qty }) } |
    ConvertTo-Json -Depth 5 -Compress
Write-Host ('     ' + (Invoke-RestMethod -Method Post -Uri "$InventoryUrl/reserve" `
            -ContentType 'application/json' -Body $probe | ConvertTo-Json -Depth 5 -Compress))

Write-Say '5. where this shows up in telemetry'
Write-Note "metric   brewline_inventory_shortages_total{sku=`"$sku`"}  (bounded label: sku,"
Write-Note '         never order_id) — allow ~30s for the Prometheus scrape'
Write-Note "log      the order service logged `"inventory.short order_id=$orderId`""
Write-Note "trace    $JaegerUrl/trace/$traceId"
Write-Host ''
Write-Note "That trace is short and carries no span error, so the gateway's tail sampler"
Write-Note 'judges it by the 5% probabilistic policy — it is usually *not* in Jaeger.'
Write-Note 'Which policy keeps which trace is exactly what EX-04 measures.'
