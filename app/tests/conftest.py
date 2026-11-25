import os
import tempfile

# Must be set before snipr is imported: configuration is read at import time.
_dir = tempfile.TemporaryDirectory()
os.environ["DATABASE_URL"] = f"sqlite:///{_dir.name}/test.db"
os.environ["BASE_URL"] = "http://short.test/"

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from snipr.db import engine  # noqa: E402
from snipr.main import app  # noqa: E402
from snipr.models import Base  # noqa: E402


@pytest.fixture
def client():
    Base.metadata.create_all(engine)
    # Not used as a context manager, so the startup thread does not run.
    yield TestClient(app, follow_redirects=False)
    Base.metadata.drop_all(engine)


@pytest.fixture
def client_without_db():
    """The table does not exist, so every query fails."""
    Base.metadata.drop_all(engine)
    return TestClient(app, follow_redirects=False)
