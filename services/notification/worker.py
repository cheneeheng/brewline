"""Notification worker.

Consumes order.ready and performs a simulated notify (a structured log line in
the MVP; real channels are deferred). Mirrors fulfillment's extract -> attach ->
span -> ack pattern so its span lands under the original order trace.
"""

import asyncio
import json
import logging
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

import aio_pika
from opentelemetry import context as otel_context
from opentelemetry import trace
from opentelemetry.propagate import extract

RABBITMQ_URL = os.environ.get("RABBITMQ_URL", "amqp://brewline:brewline@rabbitmq:5672/")
BROKER_PROPAGATION = os.environ.get("BROKER_PROPAGATION", "on")

EXCHANGE_NAME = "brewline"
DLX_NAME = "brewline.dlx"

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("brewline.notification")
_tracer = trace.get_tracer("brewline.notification")


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


async def on_order_ready(message: aio_pika.abc.AbstractIncomingMessage) -> None:
    token = None
    if BROKER_PROPAGATION == "on":
        token = otel_context.attach(extract(dict(message.headers or {})))
    try:
        with _tracer.start_as_current_span("notification.notify") as span:
            order_id = json.loads(message.body)["order_id"]
            span.set_attribute("brewline.order_id", order_id)
            # Simulated notify (real channels deferred — see ITER_04 Out of MVP scope).
            log.info(json.dumps({"event": "notification.sent", "order_id": order_id}))
        await message.ack()
    except Exception:
        log.exception("notification.error")
        await message.nack(requeue=not message.redelivered)
    finally:
        if token is not None:
            otel_context.detach(token)


async def main() -> None:
    _start_health_server()
    connection = await aio_pika.connect_robust(RABBITMQ_URL)
    channel = await connection.channel()
    await channel.set_qos(prefetch_count=8)

    exchange = await channel.declare_exchange(
        EXCHANGE_NAME, aio_pika.ExchangeType.TOPIC, durable=True
    )
    await channel.declare_exchange(DLX_NAME, aio_pika.ExchangeType.TOPIC, durable=True)

    queue = await channel.declare_queue(
        "notification.order.ready",
        durable=True,
        arguments={"x-dead-letter-exchange": DLX_NAME},
    )
    await queue.bind(exchange, routing_key="order.ready")
    await queue.consume(on_order_ready)

    log.info(json.dumps({"event": "notification.started"}))
    await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
