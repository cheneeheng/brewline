"""Fulfillment worker.

Consumes order.placed, advances paid -> fulfilling -> ready (simulated kitchen
prep), publishes order.ready. The whole point: the trace started at the storefront
continues across the broker because the W3C traceparent travels inside the AMQP
message headers (extract on consume, inject on the downstream publish). ITER_04
experiment #1 disables this via BROKER_PROPAGATION to show the trace fragment.
"""

import asyncio
import json
import logging
import os
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

import aio_pika
import asyncpg
from opentelemetry import context as otel_context
from opentelemetry import trace
from opentelemetry.propagate import extract, inject

RABBITMQ_URL = os.environ.get("RABBITMQ_URL", "amqp://brewline:brewline@rabbitmq:5672/")
DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql+asyncpg://brewline:brewline@postgres:5432/brewline"
)
# PREP_SECONDS extends the end-to-end trace; ITER_04's tail sampler decision_wait
# must exceed it, so the two are coupled (default kept small: 2s).
PREP_SECONDS = float(os.environ.get("PREP_SECONDS", "2"))
BROKER_PROPAGATION = os.environ.get("BROKER_PROPAGATION", "on")

EXCHANGE_NAME = "brewline"
DLX_NAME = "brewline.dlx"

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("brewline.fulfillment")
_tracer = trace.get_tracer("brewline.fulfillment")

_pool: asyncpg.Pool | None = None
_exchange: aio_pika.abc.AbstractExchange | None = None


def _pg_dsn() -> str:
    return DATABASE_URL.replace("+asyncpg", "").replace("+psycopg", "")


def _start_health_server() -> None:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            if self.path == "/healthz":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"ok": true}')
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, *_: object) -> None:
            pass

    Thread(target=HTTPServer(("0.0.0.0", 8000), Handler).serve_forever, daemon=True).start()


async def advance_status(order_id: str, nxt: str, expected: str) -> bool:
    """Guarded transition — idempotent under redelivery. Returns True if it moved."""
    assert _pool is not None
    async with _pool.acquire() as conn:
        result = await conn.execute(
            "UPDATE orders SET status=$1, updated_at=now() WHERE id=$2 AND status=$3",
            nxt,
            uuid.UUID(order_id),
            expected,
        )
    return result.endswith("1")


async def publish_order_ready(order_id: str) -> None:
    assert _exchange is not None
    headers: dict[str, str] = {}
    if BROKER_PROPAGATION == "on":
        inject(headers)  # re-inject context for the next hop (notification)
    with _tracer.start_as_current_span("order.ready publish") as span:
        span.set_attribute("messaging.system", "rabbitmq")
        span.set_attribute("messaging.destination.name", EXCHANGE_NAME)
        span.set_attribute("brewline.order_id", order_id)
        await _exchange.publish(
            aio_pika.Message(
                body=json.dumps({"order_id": order_id}).encode(),
                headers=headers,
                delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
            ),
            routing_key="order.ready",
        )


async def on_order_placed(message: aio_pika.abc.AbstractIncomingMessage) -> None:
    token = None
    if BROKER_PROPAGATION == "on":
        token = otel_context.attach(extract(dict(message.headers or {})))
    try:
        with _tracer.start_as_current_span("fulfillment.process") as span:
            order_id = json.loads(message.body)["order_id"]
            span.set_attribute("brewline.order_id", order_id)
            if not await advance_status(order_id, "fulfilling", "paid"):
                # Not in the expected state (redelivery / out of order) — idempotent skip.
                log.info(json.dumps({"event": "fulfillment.skip", "order_id": order_id}))
                await message.ack()
                return
            await asyncio.sleep(PREP_SECONDS)  # simulate kitchen prep
            await advance_status(order_id, "ready", "fulfilling")
            await publish_order_ready(order_id)
            log.info(json.dumps({"event": "fulfillment.ready", "order_id": order_id}))
        await message.ack()
    except Exception:
        log.exception("fulfillment.error")
        # Requeue once, then dead-letter to brewline.dlq (avoids poison loops).
        await message.nack(requeue=not message.redelivered)
    finally:
        if token is not None:
            otel_context.detach(token)


async def main() -> None:
    global _pool, _exchange
    _start_health_server()
    _pool = await asyncpg.create_pool(_pg_dsn(), min_size=1, max_size=5)

    connection = await aio_pika.connect_robust(RABBITMQ_URL)
    channel = await connection.channel()
    await channel.set_qos(prefetch_count=8)

    _exchange = await channel.declare_exchange(
        EXCHANGE_NAME, aio_pika.ExchangeType.TOPIC, durable=True
    )
    dlx = await channel.declare_exchange(DLX_NAME, aio_pika.ExchangeType.TOPIC, durable=True)
    dlq = await channel.declare_queue("brewline.dlq", durable=True)
    await dlq.bind(dlx, routing_key="#")

    queue = await channel.declare_queue(
        "fulfillment.order.placed",
        durable=True,
        arguments={"x-dead-letter-exchange": DLX_NAME},
    )
    await queue.bind(_exchange, routing_key="order.placed")
    await queue.consume(on_order_placed)

    log.info(json.dumps({"event": "fulfillment.started"}))
    await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())
