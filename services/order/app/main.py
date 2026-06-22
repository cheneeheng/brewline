import logging
import time
from contextlib import asynccontextmanager
from decimal import Decimal
from uuid import UUID, uuid4

import aio_pika
import httpx
from fastapi import Depends, FastAPI, HTTPException
from pydantic import BaseModel, ConfigDict
from sqlalchemy.ext.asyncio import AsyncSession

from . import metrics
from .broker import get_exchange, publish_order_placed
from .db import get_session
from .logging_setup import configure_logging
from .models import Order, OrderItem
from .settings import get_settings

configure_logging()
log = logging.getLogger("brewline.order")


class ItemIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sku: str
    name: str
    qty: int
    unit_price: str


class OrderIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    items: list[ItemIn]


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    app.state.http = httpx.AsyncClient(timeout=10.0)
    app.state.amqp = await aio_pika.connect_robust(settings.rabbitmq_url)
    channel = await app.state.amqp.channel()
    app.state.exchange = await get_exchange(channel)
    try:
        yield
    finally:
        await app.state.http.aclose()
        await app.state.amqp.close()


# NOTE: OTel ASGI instrumentation is registered as the outermost middleware by
# opentelemetry-instrument so spans wrap the entire request (middleware applies
# in reverse registration order).
app = FastAPI(lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict[str, bool]:
    return {"ok": True}


@app.post("/orders", status_code=202)
async def create_order(
    body: OrderIn, session: AsyncSession = Depends(get_session)
) -> dict[str, str]:
    settings = get_settings()
    started = time.perf_counter()

    total = sum((Decimal(i.unit_price) * i.qty for i in body.items), Decimal("0"))
    order = Order(id=uuid4(), status="placed", total_amount=total, currency="USD")
    order.items = [
        OrderItem(
            id=uuid4(), sku=i.sku, name=i.name, qty=i.qty, unit_price=Decimal(i.unit_price)
        )
        for i in body.items
    ]
    session.add(order)
    await session.commit()
    order_id = str(order.id)
    log.info("order.placed order_id=%s total=%s", order_id, total)

    def fail() -> dict[str, str]:
        metrics.record_order("failed", order_id, total, time.perf_counter() - started)
        return {"order_id": order_id, "status": "failed"}

    # Payment
    pay = await app.state.http.post(
        f"{settings.payment_url}/charge",
        json={"order_id": order_id, "amount": str(total), "currency": "USD"},
    )
    pj = pay.json()
    if pj.get("status") != "approved":
        order.status = "failed"
        await session.commit()
        log.warning("payment.declined order_id=%s", order_id)
        return fail()
    order.payment_ref = pj["payment_ref"]
    order.status = "paid"
    await session.commit()

    # Inventory reservation
    resv = await app.state.http.post(
        f"{settings.inventory_url}/reserve",
        json={
            "order_id": order_id,
            "items": [{"sku": i.sku, "qty": i.qty} for i in body.items],
        },
    )
    if not resv.json().get("reserved"):
        order.status = "failed"
        await session.commit()
        log.warning("inventory.short order_id=%s", order_id)
        return fail()

    # Hand off to the async branch: publish order.placed. The fulfillment worker
    # advances paid -> fulfilling -> ready (ITER_02 §04 consumer sample).
    await publish_order_placed(app.state.exchange, order_id)
    metrics.record_order("paid", order_id, total, time.perf_counter() - started)
    log.info("order.paid order_id=%s payment_ref=%s", order_id, order.payment_ref)
    return {"order_id": order_id, "status": "paid"}


@app.get("/orders/{order_id}")
async def get_order(
    order_id: UUID, session: AsyncSession = Depends(get_session)
) -> dict[str, object]:
    order = await session.get(Order, order_id)
    if order is None:
        raise HTTPException(status_code=404, detail="order not found")
    return {
        "order_id": str(order.id),
        "status": order.status,
        "total_amount": str(order.total_amount),
        "items": [
            {"sku": it.sku, "name": it.name, "qty": it.qty, "unit_price": str(it.unit_price)}
            for it in order.items
        ],
    }
