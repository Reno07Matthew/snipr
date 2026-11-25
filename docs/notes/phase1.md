# Phase 1: application, Docker and CI

Date: 2026-11-25

## What was implemented

- FastAPI app with the six API routes and a small homepage.
- PostgreSQL storage through SQLAlchemy 2 and psycopg 3.
- 14 test functions (20 cases) on an isolated SQLite file.
- Multi-stage, non-root Docker image and a Compose stack.
- GitHub Actions CI: Ruff, pytest, image build, Trivy, Gitleaks. No AWS access.

## Why

| Choice | Reason |
|---|---|
| Schema created in a background thread | `/healthz` answers while the database is down, so a database outage cannot cause a restart loop. |
| `/readyz` queries the `links` table | It fails if the database is down or the schema is missing. |
| `UPDATE ... hits + 1 ... RETURNING` | One atomic statement, so concurrent clicks are not lost. |
| `secrets.token_urlsafe(6)` plus retry | 48 random bits make collisions rare; the primary key catches any. |
| No labels on `snipr_redirects_total` | Codes and URLs are unbounded and would overload Prometheus. |
| Probes excluded from HTTP metrics | They would distort request rate and error ratio. |
| `hide_parameters=True` | Submitted URLs stay out of database error logs. |
| Hash-locked requirements | pip refuses a package whose content changed. |
| Actions pinned to SHAs, images to digests | A moved tag cannot change what CI runs. |
| Trivy scans a tarball | The scanner does not need the Docker socket. |
| `postgres:16-alpine` | Supported, small official image. |

## Commands

```bash
# tests
cd app && uv venv --python 3.12 .venv
uv pip install --python .venv --require-hashes -r requirements-dev.txt
.venv/bin/ruff check . && .venv/bin/ruff format --check . && .venv/bin/pytest

# after changing dependencies in pyproject.toml (run in app/)
uv pip compile pyproject.toml --python-version 3.12 --generate-hashes -o requirements.txt
uv pip compile pyproject.toml --extra dev --python-version 3.12 --generate-hashes \
  -c requirements.txt -o requirements-dev.txt

# local stack: copy .env.example to .env and change the password first
docker compose up --build -d --wait
docker compose down        # keeps data; adding -v DELETES the database volume
```

## Results

| Check | Result |
|---|---|
| Ruff lint and format | passed |
| Pytest | 20 passed, 1 warning |
| Create, 307 redirect, stats (real Postgres) | passed |
| 200 concurrent clicks after 1 click | 201 hits |
| `javascript:` URL / unknown code | 422 / 404 |
| Database stopped | `/healthz` 200, `/readyz` 503, redirect 503, container not restarted |
| Database started again | ready in 2 s, hits kept |
| App started without a database, read-only root | `/healthz` 200, `/readyz` 503 |
| Data after `docker compose down` and `up` | kept |
| Container user | uid 10001 |
| Database password in logs | not found |
| Trivy image scan | 0 CRITICAL, 54 HIGH (1 fixable), 81 MEDIUM, 78 LOW, 18 UNKNOWN |
| Trivy gate on a vulnerable fixture (PyYAML 5.3) | exit 1, as intended |
| Failing test | pytest exit 1 |
| CI's Gitleaks command, run locally | no leaks |
| CI on GitHub | pending first push |

## Problems and fixes

- **Docker data reset:** Docker Desktop's disk limit was lowered while testing, which
  recreated its disk and deleted all containers, images and volumes. The stack was
  rebuilt from the repo. Compose volumes are not backups.
- **First Trivy scan failed:** the image had been deleted by that reset. Rescanned
  after the rebuild.

## Limitations

- `create_all` cannot change existing tables; use Alembic when the schema changes.
- Tests use SQLite; Postgres was checked by hand through Compose, not in CI.
- The gate blocks CRITICAL only. One HIGH (`libzstd1`) has a fix; update the base
  image digest when a rebuilt image is published.
- The base image keeps an unused `pip` with MEDIUM findings.
- Starlette warns that using `httpx` with its test client is deprecated.
- No authentication or rate limiting; anyone who can reach it can create links.

## Key concepts & Q&A

- **Liveness or readiness?** Liveness: is the process alive, else restart it.
  Readiness: can it serve traffic, else stop sending it requests.
- **Why not check the database in liveness?** Restarting the app does not fix the
  database and adds load while it recovers.
- **Why a multi-stage build?** Build steps stay out of the final image.
- **Why non-root?** A process that is broken into has fewer privileges.
- **Image or container?** An image is a read-only template; a container is a running
  instance of it.
- **Why 307?** It is temporary, so browsers keep asking snipr and clicks are counted.
- **What is a pipeline artifact?** A file saved from a run; here, the Trivy report.
- **Why does CI have no AWS credentials?** It runs on pull requests, and code under
  review should not get cloud access.
