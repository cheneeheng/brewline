"""Hand-instrumented business metrics for the order service.

Cardinality discipline (ITER_03): metric attributes are restricted to
bounded-cardinality values only — `outcome`, `service.name`. High-cardinality
identifiers like `order_id` are NEVER metric labels under normal operation; they
live on spans and log lines. ITER_04 experiment #2 violates this on purpose via
CARDINALITY_MODE=high.
"""

from decimal import Decimal

from opentelemetry import metrics

from .settings import get_settings

_meter = metrics.get_meter("brewline.order")

# orders.placed — counter, attribute outcome={paid|failed}
orders_placed = _meter.create_counter(
    "brewline.orders.placed", description="Orders accepted, by outcome"
)

# order.value — histogram of total_amount (no unit: keeps the exported series name
# clean as brewline_order_value_* rather than a unit-suffixed variant).
order_value = _meter.create_histogram(
    "brewline.order.value", description="Distribution of order totals (USD)"
)

# order.duration — explicit-bucket histogram with a boundary at the 0.8s SLO
# threshold (ITER_04). Advisory boundaries give a deterministic `_bucket` series
# for the Prometheus histogram_quantile SLO rule, independent of HTTP semconv drift.
order_duration = _meter.create_histogram(
    "brewline.order.duration",
    unit="s",
    description="End-to-end POST /orders handler duration",
    explicit_bucket_boundaries_advisory=[
        0.05, 0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 6.4,
    ],
)


def _attrs(outcome: str, order_id: str) -> dict[str, str]:
    attrs = {"outcome": outcome}
    # less-code: experiment #2 toggle — high-cardinality label injected on purpose.
    if get_settings().cardinality_mode == "high":
        attrs["order_id"] = order_id
    return attrs


def record_order(outcome: str, order_id: str, total_amount: Decimal, duration_s: float) -> None:
    attrs = _attrs(outcome, order_id)
    orders_placed.add(1, attrs)
    order_value.record(float(total_amount), attrs)
    order_duration.record(duration_s, {"outcome": outcome})
