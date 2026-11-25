# Phase 0: environment and project setup

Date: 2026-11-25

## What was implemented

- Verified tools, Docker, GitHub and AWS access.
- Renamed the branch from `master` to `main`.
- Set a repo-local GitHub noreply commit email.
- Created `.gitignore`, `.dockerignore` and `.env.example`.
- Created the empty public repo `Reno07Matthew/snipr` and added it as `origin`.

## Why

| Choice | Reason |
|---|---|
| Docker Desktop (`desktop-linux`) | Owner's decision. The native Docker service, its enablement and its data-root are left alone. |
| Project data under `/home` | Owner's decision; `/` is 95% used. |
| `TF_PLUGIN_CACHE_DIR` | The AWS provider is large; one cached copy serves both Terraform stacks. |
| Allowlist `.dockerignore` | New files stay out of the image unless explicitly added. The build context must be the repo root. |
| Branch `main` | CI, CD and the OIDC trust policy expect `refs/heads/main`. |
| Explicit `ap-south-1` | The local AWS default is `ap-south-2`; the global config was not changed. |

## Working rules

- Set these in each Terraform/AWS shell:

  ```bash
  export TF_PLUGIN_CACHE_DIR="$HOME/.cache/terraform/plugin-cache"
  export AWS_REGION=ap-south-1
  ```

- Check `df -h /home` before image pulls, builds, `terraform init` and similar.
  **Warn the owner before a step could take free space below 2 GB.**
- Docker Desktop's `Docker.raw` uses 20 GB but may grow to 76 GiB, the size of
  the whole `/home` partition. Docker itself will not stop at 2 GB free.
- Never prune Docker without approval; it holds other projects' data.

## Tool versions

| Tool | Version |
|---|---|
| Git | 2.56.1 |
| Docker client / Docker Desktop | 29.10.0 / 4.98.0 |
| Compose / Buildx | 5.6.1 / 0.38.1 |
| Python | 3.12.16 via uv 0.13.9 (system: 3.14.10) |
| AWS CLI | 2.37.9 |
| Terraform / TFLint | 1.15.9 / 0.65.0 (newer releases exist; native S3 locking needs 1.10+) |
| kubectl / Helm | 1.37.2 / 4.3.0 |
| GitHub CLI | 2.67.0 (`~/.local/bin`, hides packaged 2.105.0) |
| ShellCheck | 0.11.0 |
| Trivy | 0.76.2 |
| Gitleaks | 8.30.1 (from pacman; the binary reports no version) |
| Make / jq / OpenSSH | 4.4.1 / 1.8.2 / 10.6p2 |
| minikube | 1.38.1 (stopped) |
| Session Manager plugin, kind, k3d | not installed (optional) |

### `docker info`

| Field | Value |
|---|---|
| Context | `desktop-linux` |
| Server | 29.9.2, Docker Desktop, linux/x86_64 |
| CPUs / memory | 8 / 3.67 GiB |
| Storage driver | overlayfs (containerd snapshotter) |
| Cgroup | v2, cgroupfs |
| Kernel | 7.0.14-linuxkit |
| Root dir | `/var/lib/docker` inside the VM; on the host, `~/.docker/desktop` |
| Existing data | 27 containers (0 running), 22 images, 6 volumes |

The native `docker` service was already active and enabled. It was not changed.

## Commands and results

| Check | Result |
|---|---|
| `df -h /home` | 7.1 GB free |
| `.gitignore` via `git check-ignore` | 17 of 17 sensitive paths ignored; 7 of 7 needed paths kept |
| `.dockerignore` via a real build | only the 4 allowed files copied; fake `.env`, key, state and `.git` excluded |
| `terraform init` with the cache | provider symlinked to `~/.cache/terraform/plugin-cache`; test files removed |
| `aws sts get-caller-identity` | passed: IAM user, not root (permissions not tested) |
| `gh repo view` | public, empty |
| `gitleaks dir .` | no leaks found, exit 0 |

## Problems and fixes

- `/home` had 144 MB free: owner cleared space.
- Trivy was a broken 768 KiB file: owner removed it and installed the package.
- AWS CLI v1 was installed: owner replaced it with v2.

## Limitations and open items

- Budget alert email and SSH source IP are still needed before Phase 2.
- No SSH key files were found; EC2 access needs a key pair in Phase 2.
- The AWS CLI uses a long-lived access key locally. It must never go to GitHub.
- The project path contains a space; quote paths in scripts and Makefile.
- The USD 5 budget is tight for a `t3.medium`; check prices before any apply.
- 3.67 GiB is tight for local Kubernetes plus monitoring.

## Key concepts & Q&A

- **Why not use the AWS root user?** It has unrestricted access to the account. An
  IAM user or role can be limited and revoked.
- **Is `.gitignore` enough to protect secrets?** No. It does not affect files
  already tracked, so Gitleaks scans the history too.
- **Why commit `.terraform.lock.hcl`?** It pins provider versions and checksums so
  everyone gets the same providers.
- **What does `.dockerignore` do?** It limits what is sent to the build, which
  keeps builds small and secrets out of image layers.
