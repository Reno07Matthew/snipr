# Phase 2: Terraform infrastructure and the k3s node

Date: 2026-11-26. Region: `ap-south-1`.

## What was implemented

- **`infra/bootstrap`** (6 resources): S3 bucket for Terraform state (versioned,
  encrypted, public access blocked, HTTPS only, `prevent_destroy`) and a USD 10
  monthly budget. It counts usage before credits and emails at 50, 80 and 100%
  of actual spend. Its own state was moved into that bucket after the first apply.
- **`infra/main`** (27 resources):
  - VPC, public subnet, internet gateway and route table; the default security
    group is emptied.
  - Security group: SSH from one /32 only, HTTP 80 public, all egress.
  - EC2 `m7i-flex.large` running Ubuntu 24.04 with an Elastic IP.
  - Node IAM role and instance profile.
  - Two ECR repos: `snipr` and `charts/snipr`.
  - Backup bucket.
  - GitHub OIDC provider and deploy role.
- **`scripts/bootstrap-node.sh`**: cloud-init user data. Installs AWS CLI, k3s
  `v1.37.2+k3s1` and Helm `v4.3.0` (SHA-256 checked), checks the SSM agent, sets
  up kubeconfig and creates the `snipr` and `monitoring` namespaces.

## Why

| Choice | Reason |
|---|---|
| Two stacks | The state bucket must exist before any stack can store state in it. |
| Bucket passed with `-backend-config` | Its name contains the account ID; backend blocks cannot use variables. |
| `use_lockfile = true` | Native S3 locking; no DynamoDB table. |
| Budget excludes credits | Credits would otherwise hide real usage. A budget is an alert, not a cap. |
| `ignore_changes = [ami, user_data]` | A new image or script edit would otherwise replace the node and delete its disk. |
| IMDSv2, hop limit 1 | Pods cannot fetch the node's AWS credentials. |
| No NAT gateway | Not needed with a public subnet and an Elastic IP; it would add cost. |
| Open egress | apt, ECR, SSM and image pulls use many changing addresses. Inbound is locked down. |
| OIDC subject `repo:<owner>/<repo>:ref:refs/heads/main` | Only workflows on `main` of this repo can deploy; PRs and forks cannot. |
| `ssm:SendCommand` on one instance and one document | CD can run commands only on this node. |
| SSH host key checked against the console output | The first connection is not blind trust. |

## Commands

```bash
export TF_PLUGIN_CACHE_DIR="$HOME/.cache/terraform/plugin-cache" AWS_REGION=ap-south-1

# bootstrap (first time: local state; then moved to S3)
cd infra/bootstrap
terraform init && terraform plan -out=tfplan && terraform apply tfplan
terraform init -migrate-state -backend-config="bucket=snipr-tfstate-<account-id>"

# main
cd ../main
terraform init -backend-config="bucket=snipr-tfstate-<account-id>"
terraform plan -out=tfplan && terraform apply tfplan

# checks
terraform fmt -check -recursive infra
terraform validate
tflint --chdir=infra/main --config="$PWD/.tflint.hcl"
shellcheck scripts/*.sh
```

## Results

| Check | Result |
|---|---|
| `fmt`, `validate`, TFLint, ShellCheck | clean |
| Bootstrap apply | 6 added, 0 changed, 0 destroyed |
| State moved to S3 | object present, AES256; plan afterwards: "No changes" |
| Main apply | 23 added, then 4 more after the two fixes below; 0 destroyed |
| Plan after apply | "No changes" (no drift) |
| SSH host key | ED25519 fingerprint matched the instance console output |
| SSH from the allowed IP | works |
| SSM | `Online`, agent 3.3.4793.0 |
| `kubectl get nodes` | `Ready`, k3s `v1.37.2+k3s1`, containerd 2.3.7 |
| System pods | coredns, traefik, local-path-provisioner, metrics-server running |
| Bootstrap log | all steps logged, no error lines; cloud-init `errors: []` |
| Script rerun twice | exit 0, nothing reinstalled, `.bashrc` line added once |
| HTTP 80 from outside | 404 from Traefik (no app yet) |
| 6443, 5432, 3000, 9090, 10250 from outside | closed |
| Node at idle | 8% CPU, about 1 GiB of 7.6 GiB used, root disk 19% used |

Versions on the node: Ubuntu 24.04.5, kernel 7.0.0-1018-aws, AWS CLI 2.35.21,
Helm v4.3.0. Locally: Terraform 1.15.9, AWS provider 6.74.0, TFLint 0.65.0 with
the AWS ruleset 0.50.0.

## Problems and fixes

| Symptom | Root cause | Fix |
|---|---|---|
| `t3.medium` "not eligible for Free Tier" | The account is on the AWS free plan, which allows free-tier types only | Switched to `m7i-flex.large` (2 vCPU, 8 GiB), kept as a variable; removed the `t3`-only CPU credit setting |
| SSH rule rejected: "Invalid rule description" | An apostrophe is not allowed in rule descriptions | Removed it |
| First state migration failed | The backend block was added before reading the bucket name, so `terraform output` refused to run | Read the name from the state file; nothing had changed |
| `kubectl` as `ubuntu`: permission denied | k3s's `kubectl` defaults to the root-only `/etc/rancher/k3s/k3s.yaml` | The script now sets `KUBECONFIG` in `~/.bashrc` |
| Partial apply | Terraform keeps what succeeded, so the next plan showed only the 4 missing resources | Re-planned and applied those |

## Limitations

- One node in one availability zone, so it is not highly available.
- The root disk is deleted when the instance is terminated, and PostgreSQL will
  live on it. Backups to S3 come in Phase 6.
- The free plan ends on 2027-01-04. Before then, upgrade the account or tear down.
- SSH was tested only from the allowed address, not refused from another one; the
  security group rule was checked in AWS.
- Script changes reach a running node only by rerunning it by hand
  (`user_data` changes are ignored on purpose).
- The bootstrap local state backup is kept outside the repo.

## Key concepts & Q&A

- **What is Terraform state?** Terraform's record of which real resources match
  the code. Without it, Terraform would try to create everything again.
- **Why keep state in S3?** It survives the laptop, is versioned and encrypted, and
  locking stops two applies running at once.
- **What does a plan show?** What apply would add, change or destroy. The saved
  plan file is applied exactly, so what was reviewed is what runs.
- **VPC, subnet, internet gateway?** A private network; one address range inside
  it; the door to the internet. A subnet is public when its route table points
  at the gateway.
- **Security group?** A stateful firewall on the instance. Replies to allowed
  traffic are allowed automatically.
- **Instance profile?** How an EC2 instance gets an IAM role, so it uses
  temporary credentials instead of stored keys.
- **Why OIDC?** GitHub proves which repo and branch is running, and AWS issues
  credentials for about an hour. No long-lived secret can leak.
- **Why SSM instead of SSH from CI?** GitHub runner IPs change, and SSM connects
  outbound from the node, so no inbound port or SSH key is needed. Commands are
  logged by AWS.
- **k3s or Kubernetes?** k3s is a certified Kubernetes distribution in a single
  small binary, with Traefik, local-path storage and metrics-server built in.
