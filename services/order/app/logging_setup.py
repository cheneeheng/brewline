"""Structured JSON logging to stdout.

opentelemetry-instrument (with OTEL_LOGS_EXPORTER=otlp) injects trace_id/span_id
and ships records over OTLP to the gateway -> Loki. This module only shapes the
local stdout copy as JSON so container logs are readable too.
"""

import json
import logging


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "level": record.levelname,
            "logger": record.name,
            "event": record.getMessage(),
        }
        for key in ("otelTraceID", "otelSpanID", "otelServiceName"):
            if (value := getattr(record, key, None)) is not None:
                payload[key] = value
        if record.exc_info:
            payload["exc_info"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def configure_logging(level: int = logging.INFO) -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [h for h in root.handlers if not isinstance(h, logging.StreamHandler)]
    root.addHandler(handler)
    root.setLevel(level)
