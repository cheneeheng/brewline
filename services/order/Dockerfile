FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && opentelemetry-bootstrap -a install

COPY . .

# opentelemetry-instrument wraps the process for zero-code auto-instrumentation
# (FastAPI, httpx, SQLAlchemy/asyncpg, aio-pika, logging). Custom metrics and the
# manual broker context propagation live in application code.
CMD ["opentelemetry-instrument", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
