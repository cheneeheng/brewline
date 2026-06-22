from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Service settings, loaded once from the environment.

    Tests must override the cached instance via a fixture rather than mutating
    env vars after import (the cache would otherwise capture the wrong values).
    """

    model_config = SettingsConfigDict(extra="ignore")

    database_url: str = "postgresql+asyncpg://brewline:brewline@postgres:5432/brewline"
    payment_url: str = "http://payment:8000"
    inventory_url: str = "http://inventory:8080"
    rabbitmq_url: str = "amqp://brewline:brewline@rabbitmq:5672/"

    # ITER_04 experiment flags.
    broker_propagation: str = "on"      # "on" | "off" — experiment #1
    cardinality_mode: str = "normal"    # "normal" | "high" — experiment #2


@lru_cache
def get_settings() -> Settings:
    return Settings()
