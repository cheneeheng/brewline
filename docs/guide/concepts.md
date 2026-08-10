# Concepts

What each OpenTelemetry idea looks like in Brewline, and where it lives in the code.
Read this after [Getting started](getting-started.md) so you have a trace to look at.

## One trace, two kinds of boundary

A single order crosses two fundamentally different boundaries, and OpenTelemetry
handles them differently:

- **Synchronous HTTP** (`storefront → order → payment`, `order → inventory`). Once a
  service is instrumented, the W3C `traceparent` header is injected on outbound
  requests and extracted on inbound ones **automatically**. You write no propagation
  code.
- **Asynchronous broker** (`order → RabbitMQ → fulfillment → RabbitMQ →
  notification`). There is no automatic header to ride on. The trace context must be
  **serialized by hand into the AMQP message headers** on publish and rebuilt on
  consume.

The manual broker propagation is in
[`services/order/app/broker.py`](../../services/order/app/broker.py) (`inject` into
headers) and [`services/fulfillment/worker.py`](../../services/fulfillment/worker.py)
(`extract` → `attach` → start span → `ack`). Get the inject/extract pair right and the
async spans join the storefront-rooted trace; miss it and the trace fragments — which
is exactly [Experiment 1](experiments/01-broken-broker-context.md).

## Cross-language propagation (Python → Go)

The order→inventory hop crosses from Python into the Go inventory service. This is a
deliberate trap: **the Go OTel SDK ships a no-op text-map propagator by default**,
whereas Python defaults to W3C Trace Context. If you forget to set the propagator in
Go, the inbound `traceparent` is silently dropped and the trace breaks at the language
boundary — no error, just a disconnected span tree.

Brewline sets it explicitly in
[`services/inventory/main.go`](../../services/inventory/main.go):

```go
otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
    propagation.TraceContext{}, propagation.Baggage{},
))
```

with the handler wrapped in `otelhttp.NewHandler`. This is the *same class of bug* as
the broker fragment in Experiment 1, reached by a different cause — recognizing both is
a core lesson.

## The three pillars and the collector pipeline

Every service exports traces, metrics, and logs over **OTLP/gRPC** to an **edge
collector**, which forwards to a **gateway collector** that fans out to the three
backends:

| Pillar | Backend | Viewed in |
|---|---|---|
| Traces | Jaeger | Jaeger UI + Grafana |
| Metrics | Prometheus | Grafana + Prometheus |
| Logs | Loki | Grafana |

Why two collectors? It mirrors production: the **edge** is lightweight (receive,
memory-limit, batch, forward) and the **gateway** does the heavy, centralized work
(sampling, attribute scrubbing, fan-out). Configs:
[`collector/edge.yaml`](../../collector/edge.yaml),
[`collector/gateway.yaml`](../../collector/gateway.yaml). Processor order matters and
is commented in each file (`memory_limiter` first so it can shed load before the
batcher buffers it).

## Trace-correlated logs

Two separate steps make the log→trace pivot work, and doing only the first is a common
mistake that leaves Loki empty:

1. **Injection** — the logging instrumentation stamps `trace_id`/`span_id`/
   `service.name` into every log record. This only enriches records; it ships nothing.
2. **Export** — the OTel logs SDK ships records over OTLP to the gateway → Loki. This
   takes **two** environment variables, not one: `OTEL_LOGS_EXPORTER=otlp` selects the
   exporter, and `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true` makes
   `opentelemetry-instrument` attach the SDK logging handler to the root logger. Set
   only the first and Loki stays empty while your log lines still show a `trace_id` —
   the exact mistake this section warns about.

Because the same `trace_id` is on both the Jaeger span and the Loki line, Grafana's
Loki datasource has a **derived field** ([`deploy/grafana/datasources.yaml`](../../deploy/grafana/datasources.yaml))
that turns `trace_id` into a link straight to the Jaeger trace. See
[Observe metrics and logs](how-to/HT-02-observe-metrics-and-logs.md).

## Metrics: RED + business, and cardinality discipline

- **RED metrics** (Rate, Errors, Duration per service) come from auto-instrumentation.
- **Business metrics** are hand-instrumented in
  [`services/order/app/metrics.py`](../../services/order/app/metrics.py) and
  [`services/payment/app.py`](../../services/payment/app.py):
  `brewline.orders.placed` (by `outcome`), `brewline.order.value`,
  `brewline.payment.failures`. Queue depth comes from RabbitMQ's own Prometheus plugin
  (`rabbitmq_queue_messages_ready`/`_unacked`) — the honest source, because a consumer
  can't truthfully observe its own backlog.

**Cardinality discipline:** metric labels are restricted to bounded values
(`outcome`, `sku`, `service.name`). High-cardinality identifiers like `order_id` are
**never** metric labels — they live on spans and logs. Violating this on purpose is
[Experiment 2](experiments/02-metric-cardinality.md).

> The Prometheus exporter rewrites OTel metric names: dots become underscores and
> monotonic counters gain a `_total` suffix. So `brewline.orders.placed` is queried as
> `brewline_orders_placed_total`. Remember this whenever you write a PromQL query.

The RED metrics have a second naming trap. Auto-instrumentation emits the *old* HTTP
semantic conventions (`http_server_duration_milliseconds_*`) unless you opt in to the
stable ones. Brewline sets `OTEL_SEMCONV_STABILITY_OPT_IN=http` for every service, so
the emitted series is `http_server_request_duration_seconds_*` with a
`http_response_status_code` attribute — which is what the RED dashboard queries. Drop
that variable and the RED panels go empty while everything else keeps working.

## Tail sampling

The gateway uses **tail-based** sampling (decide after seeing the whole trace), not
head sampling. Policy in [`collector/gateway.yaml`](../../collector/gateway.yaml):
keep 100% of traces that have an error or exceed an 800ms latency threshold, and keep
5% of the boring rest.

The critical tuning knob is `decision_wait: 15s`. It **must exceed the full
end-to-end trace duration**, which includes the async `PREP_SECONDS` (default 2s)
delay — otherwise the sampler decides before the fulfillment/notification spans arrive
and persists incomplete traces (a failure that looks like a propagation bug but
isn't). This makes [Experiment 4](experiments/04-sampling-and-cost.md) measurable.

## SLOs and burn-rate alerting

Two SLOs are defined as Prometheus rules in
[`deploy/prometheus/rules.yml`](../../deploy/prometheus/rules.yml):

- **Latency:** 99% of `POST /orders` complete under 800ms, measured from the
  explicit-bucket `brewline_order_duration_seconds` histogram (a fixed-boundary
  histogram with a bucket exactly at the 0.8s SLO, so the quantile is meaningful).
- **Payment success:** ≥ 99.5%, i.e. `1 - failures/placed`.

A **multi-window burn-rate alert** (fast-burn factor 14.4 on a short *and* a long
window) fires when the error budget is burning too fast. Read what the SLOs measure in
[HT-03 — SLOs and burn-rate alerts](how-to/HT-03-slos-and-alerts.md); make the alert
fire by dialing `PAYMENT_FAILURE_RATE` up in
[OP-03 — SLO alert drill](operations/OP-03-slo-alert-drill.md).

## Where the knobs are

Everything you toggle while learning is an environment variable in `.env`
(documented in [Install and configure](operations/OP-01-install-and-configure.md)):
`PAYMENT_FAILURE_RATE`, `PAYMENT_LATENCY_MS`, `PREP_SECONDS`, `BROKER_PROPAGATION`,
`CARDINALITY_MODE`. The collector experiments swap config files instead
(`edge.weak.yaml`, `gateway.nosample.yaml`).
