"""Storefront BFF — the only public surface. Forwards to the order service.

Synchronous HTTP, so W3C traceparent propagates automatically once httpx is
auto-instrumented; the storefront span is the root of the whole order trace.
"""

import json
import logging
import os
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, ConfigDict

ORDER_URL = os.environ.get("ORDER_URL", "http://order:8000")


class Item(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sku: str
    name: str
    qty: int
    unit_price: str


class OrderIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    items: list[Item]


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
log = logging.getLogger("brewline.storefront")


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.http = httpx.AsyncClient(base_url=ORDER_URL, timeout=15.0)
    try:
        yield
    finally:
        await app.state.http.aclose()


app = FastAPI(lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict[str, bool]:
    return {"ok": True}


@app.post("/orders", status_code=202)
async def place_order(body: OrderIn, request: Request) -> dict[str, object]:
    resp = await request.app.state.http.post("/orders", json=body.model_dump())
    log.info("storefront.forwarded status=%s", resp.status_code)
    return resp.json()


@app.get("/orders/{order_id}")
async def get_order(order_id: str, request: Request) -> dict[str, object]:
    resp = await request.app.state.http.get(f"/orders/{order_id}")
    if resp.status_code == 404:
        raise HTTPException(status_code=404, detail="order not found")
    return resp.json()
