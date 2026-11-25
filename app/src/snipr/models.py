from datetime import datetime

from sqlalchemy import BigInteger, DateTime, String, Text, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Link(Base):
    __tablename__ = "links"

    code: Mapped[str] = mapped_column(String(16), primary_key=True)
    url: Mapped[str] = mapped_column(Text)
    hits: Mapped[int] = mapped_column(BigInteger, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
