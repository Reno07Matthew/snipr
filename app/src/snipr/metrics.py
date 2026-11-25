from fastapi import FastAPI
from prometheus_client import Counter
from prometheus_fastapi_instrumentator import Instrumentator

# Exposed as snipr_redirects_total. No labels: codes and URLs are unbounded.
REDIRECTS = Counter("snipr_redirects", "Successful short-link redirects")


def setup_metrics(app: FastAPI) -> None:
    # Probes are excluded so they do not distort request rate and error ratio.
    Instrumentator(excluded_handlers=["/metrics", "/healthz", "/readyz"]).instrument(app).expose(
        app, include_in_schema=False
    )
