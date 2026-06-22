"""RabbitMQ publishing with manual W3C trace-context injection.

The broker is a non-HTTP boundary, so trace context does not propagate
automatically — it must be serialized into the AMQP message headers by hand
(ITER_02). A single missed inject is exactly what fragments the trace; ITER_04
experiment #1 toggles this off via BROKER_PROPAGATION to demonstrate the break.
"""

import json

import aio_pika
from opentelemetry import trace
from opentelemetry.propagate import inject

from .settings import get_settings

EXCHANGE_NAME = "brewline"
_tracer = trace.get_tracer("brewline.order.broker")


async def get_exchange(channel: aio_pika.abc.AbstractChannel) -> aio_pika.abc.AbstractExchange:
    return await channel.declare_exchange(
        EXCHANGE_NAME, aio_pika.ExchangeType.TOPIC, durable=True
    )


async def publish_order_placed(
    exchange: aio_pika.abc.AbstractExchange, order_id: str
) -> None:
    headers: dict[str, str] = {}
    if get_settings().broker_propagation == "on":
        inject(headers)  # writes traceparent/tracestate into the carrier
    with _tracer.start_as_current_span("order.placed publish") as span:
        span.set_attribute("messaging.system", "rabbitmq")
        span.set_attribute("messaging.destination.name", EXCHANGE_NAME)
        span.set_attribute("messaging.rabbitmq.routing_key", "order.placed")
        span.set_attribute("brewline.order_id", order_id)
        await exchange.publish(
            aio_pika.Message(
                body=json.dumps({"order_id": order_id}).encode(),
                headers=headers,
                delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
            ),
            routing_key="order.placed",
        )
