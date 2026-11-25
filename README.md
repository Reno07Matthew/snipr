# snipr

A small URL-shortener API used to build and document an end-to-end
DevOps / DevSecOps pipeline on AWS.

> **Work in progress.** The application, container and CI exist. Sections marked
> "planned" describe the design, not finished work.

## Status

| Phase | Name | Status |
|---|---|---|
| 0 | Environment and project setup | done |
| 1 | Application, Docker and CI | done |
| 2 | Terraform infrastructure | next |
| 3 | Helm chart and first deployment | planned |
| 4 | Automated CD | planned |
| 5 | Monitoring and alerting | planned |
| 6 | Ops scripts and Jenkins | planned |
| 7 | Documentation and demo | planned |

Evidence and design notes for each finished phase are in [docs/notes](docs/notes).

## Run locally

Needs Docker with Compose.

```bash
cp .env.example .env            # then change POSTGRES_PASSWORD
docker compose up --build -d --wait
curl -i http://localhost:8000/healthz
curl -i http://localhost:8000/readyz
docker compose down             # keeps data; adding -v DELETES the database volume
```

| Variable | Purpose |
|---|---|
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | Compose database settings |
| `BASE_URL` | Prefix for returned short links |
| `DATABASE_URL` | Read by the app; Compose builds it from the values above |

## API

| Method | Route | Behaviour |
|---|---|---|
| `POST` | `/api/links` | Create a short link |
| `GET` | `/{code}` | Redirect with 307 and count the hit |
| `GET` | `/api/links/{code}` | Link statistics |
| `GET` | `/healthz` | Liveness, no database needed |
| `GET` | `/readyz` | Readiness, checks the database |
| `GET` | `/metrics` | Prometheus metrics |

```bash
curl -X POST http://localhost:8000/api/links \
  -H 'Content-Type: application/json' -d '{"url": "https://example.com"}'
# use the code it returns
curl -i http://localhost:8000/<code>
curl http://localhost:8000/api/links/<code>
```

## CI

Runs on pull requests and pushes to `main`, without AWS credentials:

1. **test:** Ruff lint and format check, then pytest.
2. **image:** Docker build, Trivy report saved as an artifact, then a gate that
   fails on CRITICAL vulnerabilities.
3. **secrets:** Gitleaks over the full Git history.

Test commands are in [docs/notes/phase1.md](docs/notes/phase1.md).

## Planned design

Push to GitHub → GitHub Actions lints, tests, builds and scans → on `main`, the
image and Helm chart go to Amazon ECR using GitHub OIDC → SSM Run Command runs
`helm upgrade` on a single EC2 instance running k3s in `ap-south-1` → smoke tests.

- **App:** Python 3.12, FastAPI, PostgreSQL
- **Infrastructure:** Terraform, with state in S3 using native locking
- **Monitoring:** Prometheus, Grafana and Alertmanager (to Discord), all private
- **Security:** no AWS keys in GitHub, SSH only from one address, only HTTP 80 public

## Known limitations

- No authentication or rate limiting.
- The planned deployment is a single EC2 node, so it is not highly available.
- Public HTTP only; HTTPS is future work.
