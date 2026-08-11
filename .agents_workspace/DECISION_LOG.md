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
dashboards. The `http_server_*` naming risk noted above was closed in Entry 4 by pinning
the semconv opt-in.

### Entry 4

**Type:** Decision
**Mode:** Autonomous
**Timestamp:** 2026-08-10T00:00:00Z
**Task:** Plan-compliance review of the implementation against SKELETON + ITER_01..04.

**Context:** Three findings needed a judgment call rather than a mechanical fix.
1. ITER_03 §04 requires OTLP log export, but `OTEL_LOGS_EXPORTER=otlp` alone does not make
   `opentelemetry-instrument` attach the SDK logging handler — this is exactly the "Loki stays
   empty" failure the plan warns about.
2. ITER_04 §04 says to pin the instrumentation version so the HTTP duration series name is
   deterministic. Pinning every `opentelemetry-*` package to a version I cannot build-verify is
   riskier than pinning the *convention*.
3. ITER_04 §04 names the gateway trace stage `attributes`/`filter`; only `attributes/scrub` exists.

**Decision:**
1. Added `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true` to the shared compose OTel env.
2. Set `OTEL_SEMCONV_STABILITY_OPT_IN=http` in the same block instead of pinning package versions.
   It fixes the emitted names (`http.server.request.duration` in seconds,
   `http.response.status_code`) to the stable set the RED dashboard already queries, is a no-op on
   instrumentation versions that predate the flag, and leaves the dependency ranges untouched.
3. Left the `filter` processor out. The plan's own excerpt configures only `attributes/scrub`, and
   nothing in the MVP names spans or metrics to drop; adding an empty `filter` would be dead config.

**Impact / Risk:** (1) and (2) change what telemetry the services emit — the intended change, and
both are documented in README "Notes & boundaries". Neither was verified against a running stack.

**Outcome:** Applied to `deploy/docker-compose.yml` and `README.md`; also added the hand-set pgx /
go-redis span attributes ITER_01 §03 calls for to `services/inventory/main.go`.

### Entry 5

**Type:** Decision
**Mode:** Autonomous
**Timestamp:** 2026-08-10T00:00:00Z
**Task:** Restructure docs/guide to the user-operator-guide skill structure.

**Context:** The skill forbids interleaving end-user steps with privileged operator
commands. The existing `how-to/slos-and-alerts.md` was a user page that also told the
reader to edit `.env` and recreate the payment container. Two resolutions were
possible: keep the drill in the how-to behind a warning, or split it into the
operator subtree.

**Decision:** Split it. `HT-03` is now read-only (what the SLOs measure, how the alert
threshold is built, how to check alert state); the config-changing drill moved to a new
`operations/OP-03-slo-alert-drill.md`. This keeps the index's promise that user pages
never ask for a privileged command, and it fits the `HT-`/`OP-` numbering the user
requested mid-task.

**Impact / Risk:** One extra operator page. Anyone with a bookmark to the old
`how-to/slos-and-alerts.md` path gets a 404 — all in-repo links were updated and
verified.

**Outcome:** All 5 guide subtree links resolve; no broken links repo-wide.

### Entry 6

**Type:** Decision
**Mode:** Autonomous
**Timestamp:** 2026-08-11T22:45:00Z
**Task:** Audit docs/guide against user-operator-guide skill v1.1.6 and close the gaps.

**Context:** `CLAUDE.md` (written in the previous session) claimed the guide enforces a hard
split in which the user pages "never contain a privileged command". That is not true of the
tree as it stands: `getting-started.md` runs `cp .env.example .env`, `docker compose up --build`
and `down -v`, and `troubleshooting.md` names one-line fixes such as "lower it in `.env`,
recreate `payment`". Two resolutions were possible: move those commands into the operator
subtree to make the claim true, or correct the claim.

**Decision:** Corrected the claim. The skill's own Getting Started spine is
"install → configure → run the smallest real task", so a getting-started page without the
install commands cannot get anyone started, and a troubleshooting table that only links out is
worse to use on a bad day. The `CLAUDE.md` repo-layout bullet now states the real rule: every
multi-step operator procedure lives under `operations/OP-nn-*` or `experiments/EX-nn-*`, the
`HT-nn-*` pages are read-only, and getting-started/troubleshooting carry only the commands their
own job needs.

**Impact / Risk:** Documentation-only. The audience split the guide actually implements is
unchanged; only its description is now accurate. Risk is that a future agent reads the looser
wording as licence to put operator procedures on user pages — the bullet names the boundary
explicitly to limit that.

**Outcome:** `CLAUDE.md` repo-layout bullet updated. Guide structure left as-is.
