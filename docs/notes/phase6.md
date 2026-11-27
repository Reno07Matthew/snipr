# Phase 6: ops scripts and Jenkins

Date: 2026-11-27.

## What was implemented

All scripts are installed to `/opt/snipr/bin` on the node by `make node-scripts`,
which also writes `/etc/cron.d/snipr` and `/etc/logrotate.d/snipr`.

| Script | What it does | Runs |
|---|---|---|
| `backup-db.sh` | `pg_dump` inside the Postgres pod → gzip → integrity checks → `s3://snipr-backups-<account>/db/snipr-<UTC time>.sql.gz` (AES256) → size check → keep the newest 7 | cron, daily 21:30 UTC (03:00 IST) |
| `restore-test.sh` | Restores a backup (default: newest) into scratch database `snipr_restore_test`, compares the row count with the backup's metadata, drops the scratch database | by hand |
| `healthcheck.sh` | Checks `/healthz` and `/readyz` through Traefik with a 5 s timeout; logs status codes only; exits 1 if either fails | cron, every 5 minutes |
| `ecr-refresh.sh` (Phase 3) | Refreshes the ECR pull secret | cron, at boot and every 6 hours |

**Jenkins** (`Jenkinsfile`, `jenkins/`), run locally in Docker Desktop:

- Jenkins 2.580.3 LTS, with the Docker CLI, Trivy 0.76.2 and uv 0.13.9 copied in
  from pinned images.
- Plugins installed at build time.
- Admin user, permissions and the `snipr` pipeline job defined as code (JCasC
  and Job DSL); no setup wizard.
- The pipeline mirrors CI: Checkout → Install → Ruff → Pytest (JUnit report) →
  Docker build → Trivy (report archived; fails on CRITICAL).

Also new: `make update-ip`. It writes your current public IP to `my_ip`, then runs
`terraform apply` on the SSH rule alone, which waits for you to type `yes`.

## Why

| Choice | Reason |
|---|---|
| `pg_dump` runs inside the pod | It uses the pod's local socket, so no password is needed, passed or logged. |
| Plain SQL plus gzip, not the custom format | Readable, and restorable with plain `psql`. |
| Check the gzip and the dump's "dump complete" trailer | A truncated dump is caught before upload. |
| Row count stored as S3 metadata | The restore test compares with the data as it was at backup time, not the live table. |
| Retention after the upload is verified, only on our own key names | A failed run never deletes anything, and there are always at least the new and the previous good backups. |
| Restore into a separate scratch database | Proves the backup without touching live data. The script refuses the live database name. |
| Health check through `127.0.0.1` | Tests the same Traefik path that real users hit. |
| Jenkins config as code | Rebuildable with one command; nothing configured by clicking. |
| Python 3.12 from `uv` in Jenkins | Same version as CI, without a separate agent image. |
| Jenkins in group 0 for the Docker socket | Builds images without running Jenkins as root. |

## Commands

```bash
make node-scripts                          # install or refresh scripts and cron
sudo /opt/snipr/bin/backup-db.sh           # on the node: back up now
sudo /opt/snipr/bin/restore-test.sh        # on the node: test the newest backup
sudo /opt/snipr/bin/restore-test.sh db/snipr-20261127T052733Z.sql.gz   # a specific one
sudo /opt/snipr/bin/healthcheck.sh; echo $?
make update-ip                             # after your IP changes

# Jenkins, locally:
(umask 077; printf 'JENKINS_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 16)" > jenkins/.env)
docker compose -f jenkins/docker-compose.yml up -d --build   # http://127.0.0.1:8080, user admin
docker compose -f jenkins/docker-compose.yml down            # keeps Jenkins data; -v deletes it
```

**Restoring for real**, into the live database, is a deliberate manual step and is
not scripted. Stop the app first (`kubectl -n snipr scale deploy/snipr --replicas=0`),
then:

```bash
aws s3 cp s3://snipr-backups-<account>/db/<file>.sql.gz - | gzip -dc |
  kubectl -n snipr exec -i snipr-postgres-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'
```

The dump has no `DROP` statements, so restore into an empty database. Then scale
back to 2.

## Results

| Check | Result |
|---|---|
| ShellCheck (all scripts) | clean (one intended SC2016 marked) |
| Backup under cron's environment | 912-byte dump, 11 link rows; S3 object AES256, size matches, metadata `links-rows=11` |
| Restore test | "backup 11, restored 11, live now 11", passed; scratch database removed |
| Restore test with a bad key (`db/../etc/passwd`) | rejected, exit 1 |
| Keep 7 | 9 runs: the two oldest deleted, newest 7 kept |
| Failed backup (pod name changed in a test copy) | "pg_dump failed", exit 1, still 7 backups |
| Password in the backup log | not found |
| Health check: healthy / dead port | exit 0 (200, 200) / exit 1 (000, 000) |
| Health check from cron | ran at 05:30:01 UTC and logged 200/200 |
| Jenkins | anonymous gets 403; Jenkinsfile passes Jenkins' declarative linter, and a broken copy fails it |
| Jenkins build #1 (commit `c6f83e5`) | **SUCCESS** in 144 s: Ruff clean, 21 tests passed, image built, Trivy found no CRITICAL; `trivy-report.json` archived (HIGH 54, MEDIUM 84, LOW 78, UNKNOWN 15) |
| `make update-ip` | applied once for real; when declined, Terraform printed "Apply cancelled" and the rule stayed the same |
| Failure drill: delete one app pod | replacement Running and ready in 6 s; 46 public requests during it, 0 failed |

## Problems and fixes

| Symptom | Root cause | Fix |
|---|---|---|
| Commands after `restore-test.sh` in the same shell never ran | Its `kubectl exec -i` read the caller's stdin (cron has none, so cron was fine) | `</dev/null` on every call that sends no SQL |
| Jenkins exited at startup: "No AuthorizationStrategy implementation found for loggedInUsersCanDo" | That strategy is not available in Jenkins 2.580 | `matrix-auth` plugin; only `admin` has permissions |
| Availability monitor logged nonsense | The scratchpad was cleared by a laptop reboot | Recreated it and repeated the drill |

## Limitations

- **The daily backup cron** had not fired yet when this was written (first run
  21:30 UTC). The same cron set-up runs the health check, and the script passed
  under cron's environment.
- **Backups live in the same AWS account and region** as the node. There is no
  bucket versioning or object lock on the backup bucket.
- **The backup has no alert:** a failure is only in `/var/log/snipr-backup.log`.
- **Jenkins can drive Docker Desktop** through its socket, which is root-equivalent
  in Docker Desktop's VM. Fine on a laptop, not on a shared server. It is bound
  to `127.0.0.1`.
- **Jenkins does not deploy;** GitHub Actions remains the real pipeline.

## Key concepts & Q&A

- **How do you know a backup works?** Restore it. Here every test restores into a
  scratch database and compares row counts with the backup's own record.
- **Why can cron behave differently from your shell?** It starts with almost no
  `PATH` or environment and no terminal. The scripts set `PATH` themselves and were
  tested under `env -i`.
- **What does `set -euo pipefail` do?** Stop on any error (`-e`), on unset
  variables (`-u`), and when any command in a pipe fails (`pipefail`), so
  `pg_dump | gzip` cannot hide a failed dump.
- **GitHub Actions or Jenkins?** Actions is hosted and configured in YAML in the
  repo. Jenkins is self-hosted: you run the controller and agents, manage plugins
  and credentials, and write a Groovy-based Jenkinsfile. Both are pipeline as code.
- **Controller or agent?** The controller schedules jobs and serves the UI; agents
  run the builds. Here one container does both (`agent any`, one executor).
- **Where are credentials in Jenkins?** In Jenkins' credential store, used through
  `withCredentials`. This pipeline needs none, and the admin password comes from an
  untracked `.env`.
