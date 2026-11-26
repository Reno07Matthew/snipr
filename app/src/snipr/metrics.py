from fastapi import FastAPI
from prometheus_client import Counter
from prometheus_fastapi_instrumentator import Instrumentator

# Exposed as snipr_redirects_total. No labels: codes and URLs are unbounded.
REDIRECTS = Counter("snipr_redirects", "Successful short-link redirects")

# Buckets of http_request_duration_seconds (labelled by route). The library default
# (0.1, 0.5, 1) is too coarse for a meaningful p95 on a fast API.
LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5)


def setup_metrics(app: FastAPI) -> None:
    # Probes are excluded so they do not distort request rate and error ratio.
    Instrumentator(excluded_handlers=["/metrics", "/healthz", "/readyz"]).instrument(
        app, latency_lowr_buckets=LATENCY_BUCKETS
    ).expose(app, include_in_schema=False)
