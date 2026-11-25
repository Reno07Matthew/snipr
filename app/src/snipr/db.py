import logging
import os
import time
from collections.abc import Iterator

from sqlalchemy import create_engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from .models import Base

log = logging.getLogger("uvicorn.error")

engine = create_engine(
    os.environ["DATABASE_URL"],
    pool_pre_ping=True,  # replace connections that died when Postgres restarted
    pool_timeout=5,
    hide_parameters=True,  # keep submitted URLs out of error logs
)


def get_session() -> Iterator[Session]:
    with Session(engine) as session:
        yield session


def create_schema(retry_seconds: float = 2) -> None:
    """Create tables, retrying until the database is reachable."""
    # shortcut: create_all cannot alter existing tables, use Alembic once the schema changes
    while True:
        try:
            Base.metadata.create_all(engine)
            return
        except SQLAlchemyError as exc:
            log.warning("database not ready, retrying: %s", type(exc).__name__)
            time.sleep(retry_seconds)
