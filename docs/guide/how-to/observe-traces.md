# How-to: Observe traces

Goal: read a Brewline order trace in Jaeger and recognize each hop.

**Prerequisites:** the stack is running and you have placed at least one order
(see [Getting started](../getting-started.md)).

## Find a trace

1. Open **http://localhost:16686**.
2. Set **Service** to **storefront** (the root of every order trace).
3. Optionally set **Operation** to `POST /orders`.
4. Click **Find Traces**.

**Verify:** a list of recent traces appears, each tagged with a duration and span
count.

## Read the waterfall

Open a trace. Top to bottom you should see, roughly:

```
storefront  POST /orders
└─ order    POST /orders
   ├─ order    (INSERT orders / order_items)
   ├─ payment  POST /charge
   ├─ inventory POST /reserve        <-- Python → Go hop
   └─ order.placed publish           <-- enters the broker
   ... (a few seconds later, same trace) ...
   fulfillment.process               <-- consumed from RabbitMQ
   └─ order.ready publish
   notification.notify               <-- consumed from RabbitMQ
```

**Verify each teaching point:**

- **Cross-language hop:** the `inventory` spans are present and nested under the order
  call. That means the Python→Go `traceparent` propagation worked
  (see [Concepts](../concepts.md#cross-language-propagation-python--go)).
- **Sync + async in one trace:** the `fulfillment.process` and `notification.notify`
  spans share the same trace as the storefront root. That is broker context
  propagation working.
- **Span attributes:** click `fulfillment.process` and look at **Tags** — you should
  see `brewline.order_id`. Click `order.placed publish` instead and you also get
  `messaging.system=rabbitmq`, `messaging.destination.name=brewline`, and
  `messaging.rabbitmq.routing_key=order.placed`. Note `order_id` lives on the span:
  high-cardinality data belongs here, not on metric labels.
- **Hand-instrumented datastore hops:** open the `inventory POST /reserve` span. It
  carries `brewline.order_id`, `brewline.item_count`, and `db.system=postgresql`, set
  by hand because pgx and go-redis are not auto-instrumented. A `GET /inventory/{sku}`
  trace also contains a child `inventory.available_qty` span whose
  `brewline.cache_hit` tag tells you whether the read came from Redis or Postgres.

## Useful searches

- **Errors only:** in Jaeger, add the tag `error=true` to find failed orders (a
  declined payment or stock shortage). These are always kept by tail sampling.
- **Slow traces:** sort the results by **Longest first**. Traces over 800ms are also
  always kept.

## What you will *not* see, and why

Under normal load you will not see every order in Jaeger — the gateway's tail sampler
keeps all errors and slow traces but only 5% of the rest. That is intentional; quantify
it in [Experiment 4](../experiments/04-sampling-and-cost.md).

## If it fails

| Symptom | Likely cause | Fix |
|---|---|---|
| Async spans never join the trace | Broker propagation off | Confirm `BROKER_PROPAGATION=on`; see [Experiment 1](../experiments/01-broken-broker-context.md) |
| `inventory` spans missing / separate trace | Go propagator not set | Cross-language break; see [Concepts](../concepts.md#cross-language-propagation-python--go) |
| No traces at all | Collector or Jaeger down | See [Troubleshooting](../troubleshooting.md) |
