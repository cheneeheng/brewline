"""Stateless payment simulator.

No DB — returns a result and a payment_ref. PAYMENT_FAILURE_RATE and
PAYMENT_LATENCY_MS (ITER_03) make SLOs and burn-rate alerts meaningful: defaults
are low so normal traffic is healthy, and ITER_04 dials the failure rate up.
"""

import asyncio
import json
import logging
import os
import random
from uuid import uuid4

from fastapi import FastAPI
from opentelemetry import metrics
from pydantic import BaseModel, ConfigDict

FAILURE_RATE = float(os.environ.get("PAYMENT_FAILURE_RATE", "0.02"))
LATENCY_MS = float(os.environ.get("PAYMENT_LATENCY_MS", "40"))

_meter = metrics.get_meter("brewline.payment")
# bounded-cardinality only — no order_id label (ITER_03 cardinality discipline).
payment_failures = _meter.create_counter(
    "brewline.payment.failures", description="Declined charges"
)


class ChargeIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    order_id: str
    amount: str
    currency: str


def _configure_logging() -> None:
    class JsonFormatter(logging.Formatter):
        def format(self, record: logging.LogRecord) -> str:
            payload = {"level": record.levelname, "logger": record.name, "event": record.getMessage()}
            for key in ("otelTraceID", "otelSpanID", "otelServiceName"):
                if (value := getattr(record, key, None)) is not None:
                    payload[key] = value
            return json.dumps(payload)

    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [h for h in root.handlers if not isinstance(h, logging.StreamHandler)]
    root.addHandler(handler)
    root.setLevel(logging.INFO)


_configure_logging()
log = logging.getLogger("brewline.payment")

app = FastAPI()


@app.get("/healthz")
async def healthz() -> dict[str, bool]:
    return {"ok": True}


@app.post("/charge")
async def charge(body: ChargeIn) -> dict[str, str | None]:
    # Simulated processing latency (jittered around the base).
    await asyncio.sleep(random.uniform(0.5, 1.5) * LATENCY_MS / 1000.0)

    if random.random() < FAILURE_RATE:
        payment_failures.add(1)
        log.warning("payment.declined order_id=%s", body.order_id)
        return {"status": "declined", "payment_ref": None}

    ref = "pay_" + uuid4().hex[:12]
    log.info("payment.approved order_id=%s payment_ref=%s", body.order_id, ref)
    return {"status": "approved", "payment_ref": ref}
