# snipr

A small URL-shortener API used to build and document an end-to-end
DevOps / DevSecOps pipeline on AWS.

> **Work in progress.** The app runs on AWS (k3s) and every push to `main` that passes CI is deployed automatically. Prometheus, Grafana and Discord alerts are live. Database backups are not built yet. Sections marked
> "planned" describe the design, not finished work.

## Status

| Phase | Name | Status |
|---|---|---|
| 0 | Environment and project setup | done |
| 1 | Application, Docker and CI | done |
| 2 | Terraform infrastructure | done |
| 3 | Helm chart and first deployment | done |
| 4 | Automated CD | done |
| 5 | Monitoring and alerting | done |
| 6 | Ops scripts and Jenkins | next |
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

## CD

After CI passes on a push to `main`, `.github/workflows/cd.yml`:

1. assumes an AWS role through GitHub OIDC (no stored AWS keys);
2. pushes the image, tagged with the full commit SHA, and the chart, versioned
   `0.1.<run number>`, to ECR (skipped if they already exist);
3. runs `scripts/deploy.sh` on the node through SSM Run Command, which runs
   `helm upgrade --install --rollback-on-failure --wait`;
4. smoke-tests `/healthz` and `/readyz`, and writes the SHA and chart version to
   the job summary.

A failed rollout rolls back automatically; the demo is in
[docs/notes/phase4.md](docs/notes/phase4.md).

## Monitoring

- **Stack:** a trimmed kube-prometheus-stack on the node (`make monitoring`).
  Prometheus scrapes the app's Service inside the cluster, and Grafana shows the
  `snipr` dashboard.
- **Alerts:** `SniprDown`, `SniprHighErrorRate` and `NodeHighMemory` go to Discord,
  with a message when each one resolves. `make test-rules` unit-tests them.
- **Access:** nothing is public. Reach Grafana through an SSH tunnel.

Details in [docs/notes/phase5.md](docs/notes/phase5.md).

## Infrastructure

Terraform in `ap-south-1`, in two stacks:

- **`infra/bootstrap`:** S3 state bucket and a monthly budget alert.
- **`infra/main`:** VPC, public subnet, security group (SSH from one address,
  HTTP 80 public), one EC2 `m7i-flex.large` running k3s, Elastic IP, ECR repos for
  the image and Helm chart, a backup bucket, and a GitHub OIDC deploy role.

The node bootstraps itself with `scripts/bootstrap-node.sh`. Steps and results are
in [docs/notes/phase2.md](docs/notes/phase2.md).

## Kubernetes deployment

The Helm chart in `helm/snipr` deploys:

- the app: 2 replicas behind Traefik on port 80, scaled by an HPA;
- PostgreSQL: a StatefulSet with its data on a `local-path` volume on the node.

`/metrics` is blocked from outside. Image pulls from ECR use a secret that a cron
job on the node refreshes (`scripts/ecr-refresh.sh`). Deploy steps and results are
in [docs/notes/phase3.md](docs/notes/phase3.md).

```bash
make stop     # stop the instance; disk and data are kept
make start    # start it again
```

## Cost

The node is about USD 2.54/day: instance USD 0.10075/h, public IPv4 USD 0.005/h,
and a 20 GB gp3 disk. Resources cost money until they are destroyed.

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
