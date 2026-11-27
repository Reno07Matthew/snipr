# Phase 5: monitoring and alerting

Date: 2026-11-26.

## What was implemented

- **kube-prometheus-stack** chart `93.11.1`, trimmed in `monitoring/kps-values.yaml`
  and installed with `make monitoring`:
  - Prometheus v3.16.0: 30 s scrape, 2 days or 2 GB retention, 3 Gi `local-path` PVC.
  - Grafana, Alertmanager v0.35.1, kube-state-metrics, node-exporter.
  - Off: etcd, scheduler, controller-manager, kube-proxy and CoreDNS scraping
    (k3s does not expose them), and the default rules and dashboards.
- **In the snipr chart, shipped by CD:** a ServiceMonitor (scrapes the `snipr`
  Service inside the cluster) and a PrometheusRule with three alerts. Both are
  rendered only when the monitoring CRDs exist.

  | Alert | Fires when | For |
  |---|---|---|
  | `SniprDown` | 0 available app pods, or the Deployment metric is missing | 1 m |
  | `SniprHighErrorRate` | 5xx responses above 5% of all app responses | 5 m |
  | `NodeHighMemory` | node memory above 85% | 5 m |

- **Alertmanager to Discord:** native `discord_configs` with `send_resolved: true`.
  The webhook is read from a file mounted from Secret `alertmanager-discord`,
  which the owner created on the node with `read -rs`.
- **Grafana dashboard `snipr`** (`monitoring/dashboards/snipr.json`, loaded from a
  ConfigMap): request rate by route, p95 latency, 5xx ratio, redirects/min, app pod
  CPU and memory, node memory, available pods and restarts.
- **Finer latency buckets** for `http_request_duration_seconds`: 0.005–2.5 s
  (were 0.1, 0.5, 1).
- **`make test-rules`:** unit tests for all three alerts with `promtool`.

## Why

| Choice | Reason |
|---|---|
| Scrape the Service, not the Ingress | `/metrics` stays 403 from the internet; Prometheus reads it from inside. |
| No Ingress for Grafana, Prometheus or Alertmanager | Monitoring stays private; Grafana is reached through an SSH tunnel. |
| Grafana admin from Secret `grafana-admin` (random, made on the node) | The chart's default `admin`/`prom-operator` would otherwise work. |
| Webhook in a mounted file | It never appears in Helm values, Git or `helm get values`. |
| `routes: []` in the Alertmanager config | The chart's default child route points at a `"null"` receiver (see Problems). |
| Default rules and dashboards off | They need dozens of recording rules and target k3s parts that are not scraped. |
| Alert rules tested with `promtool` | Proves the expressions and `for:` timings without breaking production. |
| `or vector(0)` in the 5xx panel | With no 5xx yet, the series does not exist; the panel shows 0 instead of "no data". |

## Commands

```bash
make monitoring     # install or upgrade the stack and the dashboard ConfigMap
make test-rules     # promtool unit tests for the alert rules (Docker)

# Grafana, from the laptop:
ssh -i ~/.ssh/snipr-ec2 -L 3000:127.0.0.1:3000 ubuntu@<EIP>
#   then on the node:
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n monitoring port-forward svc/kps-grafana 3000:80
#   then open http://localhost:3000 and log in as admin
```

Discord webhook Secret, created by the owner in an interactive shell on the node:

```bash
read -rs -p 'Discord webhook URL: ' url; echo
printf '%s' "$url" | kubectl -n monitoring create secret generic alertmanager-discord --from-file=webhook-url=/dev/stdin
unset url
```

## Results

**Node memory** (`kubectl top node`, every 10 s during install): peak **31%**
(2.4 of 7.6 GiB), steady 31%; the threshold to report was 75%. Grafana is the
largest user (about 390 Mi), then Prometheus (about 330 Mi). Disk is 41% used.

**SniprDown test** (`kubectl scale deploy/snipr --replicas=0`, then back to 2):

| Time (UTC) | Event |
|---|---|
| 15:32:37 | scaled to 0 |
| 15:33:18 | `SniprDown` pending |
| 15:34:19 | firing |
| 15:34:50 | Alertmanager sent to Discord (`notifications_total{integration="discord"}` 0 → 1, 0 failed) |
| 15:34:50 | scaled back to 2 |
| 15:35:28 | rule inactive |
| 15:35:48 | resolved message sent (1 → 2, 0 failed) |

The owner confirmed both Discord messages arrived: `[FIRING:1] SniprDown` at
9:04 PM IST (15:34 UTC) and `[RESOLVED] SniprDown`.

The HPA was paused at 0 replicas, as Kubernetes does, and resumed at 2.

**Other checks:**

| Check | Result |
|---|---|
| Prometheus targets | all up, including both snipr pods |
| Rules loaded | `SniprDown`, `SniprHighErrorRate`, `NodeHighMemory`: health ok |
| Dashboard data (about 7 req/s of test traffic) | p95 **5.4 ms**, p50 2.6 ms; redirects/min, pod CPU and memory, node memory 34%; 5xx ratio 0 |
| Buckets in Prometheus | 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2.5 +Inf |
| `make test-rules` | 5 tests pass. With the threshold set to 15%, the 10% case **fails**, so the tests do check the rule. |
| `test_latency_histogram_has_fine_buckets` | passes; fails with the old buckets |
| Exposure | 3000, 9090, 9093, 9100, 8080 closed from outside; only Ingresses are `snipr` and `snipr-metrics-blocked`; all monitoring Services are ClusterIP |

## How SniprHighErrorRate is tested

A live 5xx burst is not practical here. The app returns 5xx only when the database
fails. That also fails `/readyz`, so Kubernetes takes the pods out of the Service
within seconds. Traefik then answers 503 itself, and those 503s never reach the
app's metrics. Producing app-side 5xx while pods stay ready would need a fault
endpoint in production code.

Instead, `make test-rules` feeds `promtool` synthetic counters:

- 10% 5xx for 12 minutes: no alert at 4 minutes, firing at 12 minutes.
- 2% 5xx: never fires.

The same file tests `SniprDown` and `NodeHighMemory` (90% fires, 80% does not).

**Gap:** an outage where Traefik itself answers 503 shows up as `SniprDown`, not
as `SniprHighErrorRate`.

## Problems and fixes

| Symptom | Root cause | Fix |
|---|---|---|
| Grafana `CrashLoopBackOff` | OOMKilled at the 256 Mi limit | Limit 512 Mi, request 256 Mi |
| No Alertmanager pod; "undefined receiver \"null\" used in route" | The chart's default child route uses receiver `null`; replacing `receivers` removed it. I first wrongly said it was waiting for the Secret. | `routes: []` |
| CD failed: "conflict … with kubectl-client-side-apply" | For a test I had applied the ServiceMonitor and rule with `kubectl`. Helm 4 uses server-side apply and refused to take over fields owned by another manager. Adoption labels do not fix field ownership. Helm rolled back; the site stayed up. | The rollback removed both objects; the re-run created them owned by `helm`. Ship chart resources only through Helm. |
| 5xx panel "no data" | No 5xx series exists yet | `or vector(0)` |

## Limitations

- **Short retention:** 2 days; the PVC is on the node's disk.
- **Grafana has no persistence:** UI edits are lost on restart; change the JSON
  file instead.
- **Alert labels:** the first Discord messages carried kube-state-metrics' own
  labels (pod, instance, job, endpoint) in the title. Fixed on 2026-11-27: each
  rule now aggregates (`sum by (namespace, deployment)`, `sum by (namespace)`,
  `max by (instance)`). The rule tests feed series with those extra labels and
  expect only the kept ones; the old rules fail them.
- **`NodeHighMemory` was not fired live,** on purpose, to avoid stressing the only node.
- **The rule tests run locally** with `make test-rules`, not in CI.

## Key concepts & Q&A

- **Metrics, logs, traces?** Metrics are numbers over time (rates, latencies). Logs
  are event records. Traces follow one request across services. This project has
  metrics and logs.
- **What does Prometheus scrape?** It pulls `/metrics` from each target on an
  interval. ServiceMonitors tell it which Services to scrape.
- **Prometheus or Alertmanager?** Prometheus evaluates the rules. Alertmanager
  groups, de-duplicates and routes alerts, and sends "resolved" when they clear.
- **What do pending and firing mean?** The condition is true but the `for:` time
  has not passed yet (pending); then it has (firing). This avoids alerts on brief
  blips.
- **What does p95 latency mean?** 95% of requests finished faster than this. It is
  estimated from histogram buckets, so the buckets must surround typical latencies.
- **How would you investigate a high 5xx rate?** Open the dashboard and find which
  route, then check pod logs (`kubectl logs`), `/readyz`, database health, and recent
  deploys (`helm history`).
- **Why can't the label be the short code?** Every code would create a new time
  series; unbounded label values overload Prometheus.
