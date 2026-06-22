# Decision Log

### Entry 1

**Type:** Decision
**Mode:** Autonomous
**Timestamp:** 2026-06-22T00:00:00Z
**Task:** Implement all plans under `.agents_workspace/planning/` (SKELETON + ITER_01..04).

**Context:** The plan family is a single untagged sequence terminating at ITER_04 (`mvp: true`).
Each iteration layers real logic onto the same files the SKELETON scaffolds (e.g. order
`POST /orders` is a stub in SKELETON, real in ITER_01, gains broker publish in ITER_02, gains
metrics in ITER_03). Literally writing SKELETON stubs and then overwriting them four times would
produce large throwaway diffs and violates the "write less code" directive.

**Decision:** Implement the cumulative MVP end state directly — every section realized to the spec
of the latest iteration that changes it, resolving unchanged sections via the `depends_on` chain.
The deliverable is the ITER_04 MVP target. SKELETON scaffolding (dirs, Dockerfiles, compose,
provisioning) is created once in its final form rather than stubbed then replaced.

**Impact / Risk:** No intermediate-stub git history; the final tree reflects only the end state.
Acceptable because the goal is the working MVP, not a replay of each iteration. All six sections'
final specs are still honored.

**Outcome:** Implemented — all six sections across SKELETON + ITER_01..04 realized to
the MVP end state on branch `feat/brewline-otel-mvp`.

### Entry 2

**Type:** Decision
**Mode:** Autonomous
**Timestamp:** 2026-06-22T00:00:00Z
**Task:** Order status lifecycle across the sync→async boundary (ITER_02).

**Context:** ITER_02 §02 prose says "the order service advances paid → fulfilling when
it publishes," but the ITER_02 §04 consumer code sample shows the fulfillment worker
performing both `advance_status(order_id, "fulfilling")` and `..., "ready"`. The two
readings conflict on who owns the paid→fulfilling transition.

**Decision:** Followed the §04 code sample (the concrete implementation spec, which also
defines the guarded `advance_status`). The order service sets status `paid`, publishes
`order.placed`, and returns `paid` (consistent with ITER_01's `paid` return). The
fulfillment worker performs paid→fulfilling→ready via guarded transitions.

**Impact / Risk:** API `POST /orders` returns `"status":"paid"` on success rather than
`"fulfilling"`. Idempotent guarded transitions remain correct under redelivery.

**Outcome:** Implemented in `services/order/app/main.py` and `services/fulfillment/worker.py`.

### Entry 3

**Type:** Decision
**Mode:** Autonomous
**Timestamp:** 2026-06-22T00:00:00Z
**Task:** SLO latency histogram source (ITER_04 §04).

**Context:** ITER_04 wants an explicit-bucket histogram with a boundary at the 0.8s SLO,
and flags semconv drift in the HTTP server duration series name. SKELETON mandates
zero-code `opentelemetry-instrument`, whose auto-configured MeterProvider can't easily
accept a programmatic View without taking over telemetry bootstrap.

**Decision:** Instead of a View on the auto-instrumented HTTP histogram, added a custom
`brewline.order.duration` (seconds) histogram with `explicit_bucket_boundaries_advisory`
including 0.8, recorded around the order handler. Prometheus rules and the SLO/RED
dashboards target `brewline_order_duration_seconds_bucket` — a deterministic series
independent of HTTP semconv version. Keeps `opentelemetry-instrument` for everything else.

**Impact / Risk:** SLO latency is measured at the order handler (includes payment +
inventory calls, excludes async prep), which is the intended POST /orders latency. The
generic per-service RED latency panels still reference `http_server_*` and may show no
data if the pinned instrumentation uses a different name — documented in README.

**Outcome:** Implemented in `services/order/app/metrics.py`, `prometheus/rules.yml`,
dashboards.
