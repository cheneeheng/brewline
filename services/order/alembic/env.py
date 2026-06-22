import os

from alembic import context
from sqlalchemy import engine_from_config, pool

# Import every model module so autogenerate can see the tables — an unimported
# model is silently invisible to Alembic.
from app.models import Base  # noqa: E402

config = context.config

target_metadata = Base.metadata


def _sync_url() -> str:
    """Alembic runs migrations with a SYNCHRONOUS driver.

    The app uses postgresql+asyncpg at runtime, but Alembic must not; rewrite the
    URL to the sync psycopg driver here.
    """
    url = os.environ.get("DATABASE_URL", config.get_main_option("sqlalchemy.url", ""))
    return url.replace("+asyncpg", "+psycopg")


def run_migrations_offline() -> None:
    context.configure(
        url=_sync_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    section = config.get_section(config.config_ini_section, {})
    section["sqlalchemy.url"] = _sync_url()
    engine = engine_from_config(section, prefix="sqlalchemy.", poolclass=pool.NullPool)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
