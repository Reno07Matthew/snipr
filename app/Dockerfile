# Build context is the repo root: docker build -f app/Dockerfile .
FROM python:3.12.16-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b AS build
RUN python -m venv /venv
COPY app/requirements.txt .
RUN /venv/bin/pip install --no-cache-dir --require-hashes -r requirements.txt \
    && /venv/bin/pip uninstall -y pip

FROM python:3.12.16-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b
# PGCONNECT_TIMEOUT: fail a database connection attempt after 3 s instead of minutes.
ENV PATH=/venv/bin:$PATH \
    PYTHONPATH=/app/src \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PGCONNECT_TIMEOUT=3
COPY --from=build /venv /venv
WORKDIR /app
COPY app/src src
COPY app/static static
# Numeric, so Kubernetes runAsNonRoot can verify it.
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"]
CMD ["uvicorn", "snipr.main:app", "--host", "0.0.0.0", "--port", "8000"]
