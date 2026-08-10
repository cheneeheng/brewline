# Experiment 1 — Broken trace context at the broker

**Teaches:** how trace context is carried across a non-HTTP boundary (a message
broker), and what a fragmented trace looks like.

**Prerequisites:** a running stack ([Getting started](../getting-started.md)); write
access to `.env`; permission to recreate containers.
**Time / impact:** ~5 minutes. No downtime; recreating the three services drops
in-flight requests. Fully reversible — the flag changes instrumentation only.

## Background

Across HTTP, `traceparent` propagates automatically. Across RabbitMQ it does not —
Brewline injects context into the AMQP headers on publish and extracts it on consume
(see [Concepts](../concepts.md#one-trace-two-kinds-of-boundary)). The
`BROKER_PROPAGATION` flag skips that inject/extract so you can see the break.

## Induce the failure

1. Edit `.env`:
   ```bash
   BROKER_PROPAGATION=off
   ```
2. Recreate the services that publish/consume on the broker:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate order fulfillment notification
   ```
3. Place an order (or run k6):
   ```bash
   curl -s localhost:8000/orders -H 'content-type: application/json' \
     -d '{"items":[{"sku":"LAT-001","name":"Latte","qty":1,"unit_price":"4.50"}]}'
   ```

## Observe

1. Open Jaeger (**http://localhost:16686**).
2. Find the **storefront** trace for your order and open the waterfall.

**Verify the break:** the storefront-rooted trace now **ends at the `order.placed
publish` span**. The `fulfillment.process` and `notification.notify` spans are no
longer in it.

3. Change the **Service** dropdown to **fulfillment**, then **Find Traces**.

**Verify:** fulfillment (and notification) now appear as **separate root traces** with
their own trace IDs — the work still happens, but the trace is fragmented. There is no
error anywhere; this is a *silent* failure, the same shape as the cross-language Go
break described in [Concepts](../concepts.md#cross-language-propagation-python--go).

## Fix and verify

1. Restore the flag in `.env`:
   ```bash
   BROKER_PROPAGATION=on
   ```
2. Recreate again:
   ```bash
   docker compose -f deploy/docker-compose.yml up -d --force-recreate order fulfillment notification
   ```
3. Place another order and open its storefront trace.

**Verify:** the waterfall reconnects — `fulfillment.process` and `notification.notify`
are back under the same trace as the storefront root.

## Takeaway

Any boundary that is not plain instrumented HTTP — a broker, a queue, a cross-language
hop, a custom RPC — needs explicit context propagation. The carrier changes (AMQP
headers here), but the inject-on-send / extract-on-receive pattern is always the same.
