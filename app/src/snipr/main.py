import os
import secrets
import threading
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel, HttpUrl
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session

from .db import create_schema, get_session, log
from .metrics import REDIRECTS, setup_metrics
from .models import Link

BASE_URL = os.environ["BASE_URL"].rstrip("/")
INDEX = Path(__file__).parents[2] / "static" / "index.html"


@asynccontextmanager
async def lifespan(_: FastAPI):
    # In the background, so /healthz answers while the database is still down.
    threading.Thread(target=create_schema, daemon=True).start()
    yield


app = FastAPI(title="snipr", lifespan=lifespan)
setup_metrics(app)

DB = Annotated[Session, Depends(get_session)]


class LinkIn(BaseModel):
    url: HttpUrl  # http/https only, max 2083 characters


class LinkOut(BaseModel):
    code: str
    short_url: str


class LinkStats(BaseModel):
    code: str
    url: str
    hits: int
    created_at: datetime


@app.exception_handler(SQLAlchemyError)
def database_error(_: Request, exc: SQLAlchemyError) -> JSONResponse:
    log.error("database error: %s", exc)
    return JSONResponse({"detail": "database unavailable"}, status_code=503)


def new_code() -> str:
    return secrets.token_urlsafe(6)  # 48 random bits, 8 characters


@app.get("/", include_in_schema=False)
def index() -> FileResponse:
    return FileResponse(INDEX)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz(db: DB) -> dict[str, str]:
    db.execute(select(Link.code).limit(1))  # also fails until the table exists
    return {"status": "ready"}


@app.post("/api/links", status_code=201)
def create_link(body: LinkIn, db: DB) -> LinkOut:
    for _ in range(5):
        code = new_code()
        db.add(Link(code=code, url=str(body.url)))
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            continue
        return LinkOut(code=code, short_url=f"{BASE_URL}/{code}")
    raise HTTPException(503, "could not allocate a short code")


@app.get("/api/links/{code}")
def link_stats(code: str, db: DB) -> LinkStats:
    link = db.get(Link, code)
    if link is None:
        raise HTTPException(404, "link not found")
    return LinkStats(code=link.code, url=link.url, hits=link.hits, created_at=link.created_at)


# Keep this last: it matches any single path segment.
@app.get("/{code}", status_code=307)
def follow(code: str, db: DB) -> RedirectResponse:
    # One atomic statement, so concurrent clicks are never lost.
    url = db.scalar(
        update(Link).where(Link.code == code).values(hits=Link.hits + 1).returning(Link.url)
    )
    if url is None:
        raise HTTPException(404, "link not found")
    db.commit()
    REDIRECTS.inc()
    return RedirectResponse(url, status_code=307)
