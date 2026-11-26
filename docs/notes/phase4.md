# Phase 4: automated CD

Date: 2026-11-26.

## What was implemented

**`.github/workflows/cd.yml`** runs when CI completes. It continues only if CI
succeeded on a **push to `main`**, never for pull requests.

| Step | What it does |
|---|---|
| Concurrency | Group `deploy-production`; a new deploy waits instead of overlapping |
| Checkout | The exact commit CI tested (`workflow_run.head_sha`) |
| AWS login | GitHub OIDC; short-lived role credentials; account ID masked in logs |
| Image | Tagged with the full SHA; push skipped if that tag exists in ECR |
| Chart | Packaged as `0.1.<run_number>` with `appVersion` = SHA; pushed to `oci://<registry>/charts`; skipped if that version exists |
| Deploy | SSM Run Command (`AWS-RunShellScript`) runs `/opt/snipr/bin/deploy.sh <chart-version> <sha> <base-url>` |
| Wait | Polls the SSM result, prints its output, fails the job if it failed |
| Smoke test | `/healthz` and `/readyz` from the runner, with retries and timeouts |
| Summary | Commit SHA, chart version, endpoint and result, written even on failure |

**`scripts/deploy.sh`** (on the node):

1. Checks all three arguments against strict patterns.
2. Refreshes the ECR pull secret and logs Helm in to ECR (domain only, Helm 4).
3. Runs `helm upgrade --install snipr oci://…/charts/snipr --version <v>
   --set image.tag=<sha> --rollback-on-failure --wait --timeout 3m`.
4. Prints `helm status`.
5. Fails if the running image tag is not the SHA.

**Other changes:**

- **No secrets anywhere in CD.** The repo has 0 GitHub secrets and 5 non-secret
  variables: `AWS_REGION`, `ECR_REGISTRY`, `INSTANCE_ID`, `PUBLIC_IP`,
  `AWS_ROLE_ARN`. Only chart version, SHA and base URL go through SSM. The chart
  references the database Secret `snipr-db` by name.
- **OIDC trust policy** now matches GitHub's immutable subject format (see below).
- **preStop sleep (5 s)** on app pods, so rollouts do not drop requests.

## Why

| Choice | Reason |
|---|---|
| `workflow_run` on CI | Nothing is deployed unless lint, tests, the image scan and the secret scan passed. |
| Image rebuilt in CD from the tested commit | CI has no AWS access by design. Same commit, same Dockerfile, hash-locked dependencies. |
| `cancel-in-progress: false` | Cancelling a half-done `helm upgrade` could leave a release stuck. |
| Deploy logic in a script on the node | SSM runs commands with `sh`; a script is testable, ShellChecked and versioned. |
| `printf %q` quoting plus strict input checks | SSM passes its command through a shell (see Problems). |
| Polling instead of `aws ssm wait command-executed` | That waiter gives up after about 100 s; `helm --wait` alone may need 180 s. |
| Chart and image in ECR | The node never needs Git access; each release is a fixed chart plus image pair. |
| preStop sleep | A terminating pod keeps serving until Traefik has removed it. |

## Demonstrations

**1. Homepage change deployed automatically.** Commit `41a7497` added a tagline;
CI and CD ran on the push.

| Check | Result |
|---|---|
| Homepage | serves "Short links, shipped by an automated pipeline." |
| Running image tag | `41a7497b2fdddc3ceaa8050d3770c7f3fd171a1c` = commit SHA |
| Helm | revision 3, chart `0.1.2` |

**2. Failed rollout rolled back automatically.** Commit `a1c541a` pointed the
readiness probe at `/does-not-exist`.

- One new pod started and never became ready. `maxUnavailable: 0` kept both old
  pods serving.
- After 3 minutes Helm reported `UPGRADE FAILED … has been rolled back due to
  rollback-on-failure`. The SSM command failed, so the CD job went red, as intended.
- Commit `7d86e30` then reverted the change through the normal pipeline.

```
REVISION  STATUS      CHART        APP VERSION   DESCRIPTION
3         superseded  snipr-0.1.2  41a7497…      Upgrade complete
4         failed      snipr-0.1.3  a1c541a…      Upgrade "snipr" failed: … not ready
5         superseded  snipr-0.1.2  41a7497…      Rollback to 3
6         deployed    snipr-0.1.4  7d86e30…      Upgrade complete   (the revert)
```

**Availability.** A laptop monitor requested `/` and `/readyz` once a second:

| Window | Requests | Non-200 |
|---|---|---|
| Failed rollout and rollback (14:51–14:54 UTC) | part of 868 | **0** |
| Revert deploy, before the preStop fix | part of 868 | 2 (no response) |
| Deploy of the fix (old pods still without preStop) | 288 | 1 |
| 3 rolling restarts, all pods with preStop | 104 | **0** |

## Results

| Check | Result |
|---|---|
| actionlint (both workflows), ShellCheck | clean |
| First CD run | failed at OIDC (fixed below) |
| Re-run | green; revision 2, chart `0.1.1`, image = commit `6654fdf` |
| Every later push to `main` | CI then CD ran without manual steps |
| Long-lived AWS keys | none in GitHub; the role is assumed through OIDC |

## Problems and fixes

| Symptom | Root cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The repo uses GitHub's **immutable OIDC subject** `repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main`; the trust policy expected `repo:<owner>/<repo>:ref:…`. Found with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`. | Trust policy uses `var.github_oidc_subject_prefix`. A renamed or re-created repo cannot reuse the role. |
| A `;` inside an argument started a deploy | SSM passes the command string through a shell, which split it before `deploy.sh` checked anything. The deploy failed on a missing chart; the release was unchanged. | CD quotes each value with `printf %q`; the same input is now rejected. |
| 2 requests failed during a normal rollout | Old pods stopped before Traefik removed them | preStop sleep of 5 s; verified with 0 failures |

## Limitations

- **`deploy.sh` and `ecr-refresh.sh` are updated by `make node-scripts`,** not by
  CD. Changes to them need that step.
- **The demo commits stay in `main`'s history** (`a1c541a` and its revert `7d86e30`),
  on purpose, as evidence.
- **Actions logs are public** in a public repo. They show the instance ID and IP;
  the account ID is masked.
- **The smoke test checks the public URL,** not each new pod.
- **For Phase 5:** `/metrics` is blocked only at the Ingress (403 from outside).
  Prometheus will scrape the `snipr` Service inside the cluster; do not open it at
  the Ingress.

## Key concepts & Q&A

- **CI or CD?** CI checks every change (lint, tests, build, scan). CD ships
  changes that passed.
- **Why OIDC instead of access keys?** GitHub signs a token saying which repo and
  branch is running; AWS swaps it for credentials lasting about an hour. There is
  no stored secret to leak or rotate.
- **Why SSM instead of SSH?** No inbound port, no SSH key in GitHub, and AWS logs
  every command.
- **What does `--rollback-on-failure` do?** If the release does not become ready
  within the timeout, Helm restores the previous revision and exits with an error.
  It was called `--atomic` before Helm 4.
- **Why did the site stay up during the failed rollout?** With `maxUnavailable: 0`,
  old pods are removed only after new ones are ready. The new pod never was.
- **Why immutable SHA tags?** The running tag points to one commit, and a rollback
  restores exactly that build.
- **What is a concurrency group?** GitHub runs one job per group at a time, so
  two deploys cannot change the release together.
