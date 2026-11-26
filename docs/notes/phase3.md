# Phase 3: Helm chart and first deployment

Date: 2026-11-26.

## What was implemented

- **Helm chart `helm/snipr`:**
  - App Deployment: 2 replicas, rolling updates, probes, non-root user, read-only
    root filesystem, all capabilities dropped.
  - ConfigMap (`BASE_URL`), Service, Traefik Ingress, HPA (2–4 replicas at 70% CPU).
  - PostgreSQL StatefulSet on a 2 Gi `local-path` PVC, with a headless internal Service.
  - A second Ingress rule that returns 403 for `/metrics` from outside.
- **`scripts/ecr-refresh.sh`:** rewrites the `ecr-creds` pull secret from the
  node's IAM role. Cron runs it as root at boot and every 6 hours
  (`/etc/cron.d/snipr`, logrotate weekly).
- **`Makefile`:**
  - `make start` / `make stop`: start or stop the instance.
  - `make node-scripts`: install the script, the cron file and logrotate on the node.
- **First manual deploy:** the image was pushed to ECR with the full commit SHA as
  its tag, then the chart was copied to the node and run with Helm there.

## Why

| Choice | Reason |
|---|---|
| ECR refresh on the host, not a CronJob | IMDS hop limit 1 blocks pods from the instance role, on purpose. |
| Password piped into `kubectl`, never in argv | Command arguments are visible in `ps`. |
| Database secret created once on the node, not by Helm | CD never carries the password, and Helm never overwrites it. Changing it after Postgres starts would lock the app out. |
| Password copy in `/root/snipr-db.env` (root, 600) | The only other copy is the Kubernetes Secret. |
| `DATABASE_URL` built from `$(POSTGRES_…)` env vars | One Secret serves both Postgres and the app. The password is hex, so URL-safe. |
| `required` for image repo, tag and base URL | The account ID and IP stay out of Git, and a deploy cannot silently use a wrong tag. |
| No `replicas` when the HPA is on | Otherwise each `helm upgrade` resets what the HPA chose. |
| `maxUnavailable: 0` | A rollout never drops below full capacity. |
| Liveness `/healthz`, readiness `/readyz` | A database outage removes pods from traffic but does not restart them. |
| Generous Postgres liveness (30 s delay, 6 failures) | A slow crash recovery is not killed half-way. |
| `/metrics` blocked at the Ingress | Prometheus will scrape the Service from inside the cluster; the internet has no need for it. |
| `automountServiceAccountToken: false` | Neither container talks to the Kubernetes API. |

## Commands

```bash
# 1. push the image (from the laptop)
REG=$(terraform -chdir=infra/main output -raw ecr_registry); SHA=$(git rev-parse HEAD)
aws ecr get-login-password | docker login --username AWS --password-stdin "$REG"
docker build -f app/Dockerfile -t "$REG/snipr:$SHA" . && docker push "$REG/snipr:$SHA"

# 2. pull-secret refresh and cron on the node
make node-scripts

# 3. database secret, once, on the node (see "Database secret" below)

# 4. deploy: copy the chart, then on the node
helm upgrade --install snipr /tmp/chart/snipr -n snipr \
  --set image.repository="$REG/snipr" --set image.tag="$SHA" \
  --set baseUrl=http://<public IP> --rollback-on-failure --wait --timeout 5m
```

Database secret, created on the node so the password is never typed or shown:

```bash
sudo sh -c 'umask 077; printf "POSTGRES_USER=snipr\nPOSTGRES_DB=snipr\nPOSTGRES_PASSWORD=%s\n" "$(openssl rand -hex 24)" > /root/snipr-db.env'
sudo cat /root/snipr-db.env | kubectl -n snipr create secret generic snipr-db --from-env-file=/dev/stdin
```

## Results

| Check | Result |
|---|---|
| ShellCheck, `helm lint` | clean |
| Render without required values | fails with "baseUrl is required", as intended |
| Server-side dry run | all 9 objects accepted |
| `helm upgrade --install` | revision 1, `deployed` |
| Pods | 2 app + 1 Postgres Ready, 0 restarts |
| PVC | `Bound`, 2 Gi, `local-path` |
| Public `/healthz`, `/readyz`, `/` | 200 |
| Public `/metrics` | 403 |
| Create link / follow / stats | 201 / 307 to the stored URL / hit count shown |
| Postgres pod deleted | new pod (new UID), ready again in seconds |
| Data after the restart | same link, same hit count, redirect still 307 |
| App pods during the Postgres restart | not restarted; readiness failed briefly, then recovered |
| ECR refresh, as root and under cron's environment | exit 0, secret `kubernetes.io/dockerconfigjson` |
| ECR refresh with no AWS CLI on PATH | exit 1 with "missing command: aws" |
| Fresh pull (`Always`) with `ecr-creds` | pulled from ECR |
| Same pull without the secret | `ImagePullBackOff`, as expected |
| Password in app logs or refresh log | not found |
| Memory | app pods about 65 Mi each; node 1.4 of 7.6 GiB used |

## Problems and fixes

- **`kubectl` over a one-off SSH command:** "permission denied". Ubuntu's `.bashrc`
  exits early for non-interactive shells, so `KUBECONFIG` was not set. Interactive
  logins are fine. Scripted SSH commands set `KUBECONFIG` themselves.
- **App logs at startup:** "failed to resolve host 'snipr-postgres'", because the app
  started at the same moment as Postgres. The retry loop handled it and pods were
  not restarted. This is the intended behaviour, not a fault.

## Limitations

- **The database is on the node's disk.** The PV reclaim policy is `Delete`:
  deleting the PVC, or terminating the instance, deletes the data. There are no
  backups until Phase 6.
- **Plain HTTP;** HTTPS needs a domain and a certificate.
- **Deploying is manual** until Phase 4 (CD).
- **The cron job and scripts are installed by `make node-scripts`,** not by
  `user_data`. Run it again after replacing the node.
- **`make start` / `make stop` were not run**, to avoid an outage; `make -n`
  shows the commands. A stopped instance still pays for its disk and Elastic IP.

## Key concepts & Q&A

- **Deployment or StatefulSet?** Deployment pods are interchangeable. A
  StatefulSet pod keeps its name (`snipr-postgres-0`) and its own volume across
  restarts.
- **What is a PVC?** A request for storage. Here the local-path provisioner turns
  it into a folder on the node's disk, so data outlives the pod but not the node.
- **Service or Ingress?** A Service is a stable internal address for pods. An
  Ingress is an HTTP routing rule that Traefik serves on port 80.
- **What is an image pull secret?** Registry credentials the kubelet uses to pull a
  private image. ECR tokens last 12 hours, so cron refreshes them.
- **Why immutable SHA tags?** A tag always means one exact build, so what is
  running can be traced to a commit, and a rollback brings back exactly that build.
- **What does Helm add?** Templating and releases: `helm history` shows revisions,
  and `--rollback-on-failure` undoes an upgrade that does not become ready.
- **What is an HPA?** It adds or removes replicas to keep average CPU near a
  target. It needs metrics-server and CPU requests.
- **How would you debug `ImagePullBackOff`?** Read `kubectl describe pod`, check
  the pull secret exists and is fresh, check the tag exists in ECR, and check the
  node can reach ECR.
