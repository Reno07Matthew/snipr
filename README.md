# snipr

A small URL-shortener API used to build and document an end-to-end
DevOps / DevSecOps pipeline on AWS.

> **Work in progress.** Only the project setup is complete. Sections marked
> "planned" describe the design, not finished work.

## Status

| Phase | Name | Status |
|---|---|---|
| 0 | Environment and project setup | done |
| 1 | Application, Docker and CI | in progress |
| 2 | Terraform infrastructure | planned |
| 3 | Helm chart and first deployment | planned |
| 4 | Automated CD | planned |
| 5 | Monitoring and alerting | planned |
| 6 | Ops scripts and Jenkins | planned |
| 7 | Documentation and demo | planned |

Evidence and design notes for each finished phase are in [docs/notes](docs/notes).

## Planned design

Push to GitHub → GitHub Actions lints, tests, builds and scans → on `main`, the
image and Helm chart go to Amazon ECR using GitHub OIDC → SSM Run Command runs
`helm upgrade` on a single EC2 instance running k3s in `ap-south-1` → smoke tests.

- **App:** Python 3.12, FastAPI, PostgreSQL
- **Infrastructure:** Terraform, with state in S3 using native locking
- **Monitoring:** Prometheus, Grafana and Alertmanager (to Discord), all private
- **Security:** no AWS keys in GitHub, SSH only from one address, only HTTP 80 public

## Known limitations

- Single EC2 node, so it is not highly available.
- Public HTTP only; HTTPS is future work.
