# Run from the repo root. Needs: aws, terraform (infra/main initialised), ssh.
export AWS_REGION := ap-south-1
TF := terraform -chdir=infra/main
INSTANCE = $(shell $(TF) output -raw instance_id)
IP = $(shell $(TF) output -raw public_ip)
SSH_KEY := $(HOME)/.ssh/snipr-ec2

.PHONY: start stop node-scripts monitoring test-rules

# Stopping keeps the disk (and the database). While stopped, the disk and the
# Elastic IP are still billed; the instance is not.
start:
	aws ec2 start-instances --instance-ids $(INSTANCE) --query 'StartingInstances[0].CurrentState.Name' --output text
	aws ec2 wait instance-running --instance-ids $(INSTANCE)
	@echo "running: http://$(IP)/healthz (k3s needs about a minute)"

stop:
	aws ec2 stop-instances --instance-ids $(INSTANCE) --query 'StoppingInstances[0].CurrentState.Name' --output text
	aws ec2 wait instance-stopped --instance-ids $(INSTANCE)
	@echo "stopped"

# shortcut: scripts are copied by hand, not by user_data; rerun after replacing the node.
node-scripts:
	scp -i $(SSH_KEY) scripts/ecr-refresh.sh scripts/deploy.sh ubuntu@$(IP):/tmp/
	ssh -i $(SSH_KEY) ubuntu@$(IP) 'for f in ecr-refresh.sh deploy.sh; do sudo install -D -m 0755 /tmp/$$f /opt/snipr/bin/$$f && rm /tmp/$$f; done'
	ssh -i $(SSH_KEY) ubuntu@$(IP) 'printf "%s\n" \
	  "# Managed by make node-scripts" \
	  "SHELL=/bin/bash" \
	  "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin" \
	  "@reboot root /opt/snipr/bin/ecr-refresh.sh >> /var/log/snipr-ecr-refresh.log 2>&1" \
	  "0 */6 * * * root /opt/snipr/bin/ecr-refresh.sh >> /var/log/snipr-ecr-refresh.log 2>&1" \
	  | sudo tee /etc/cron.d/snipr >/dev/null && sudo chmod 0644 /etc/cron.d/snipr'
	ssh -i $(SSH_KEY) ubuntu@$(IP) 'printf "%s\n" "/var/log/snipr-*.log {" "  weekly" "  rotate 4" "  compress" "  missingok" "  notifempty" "}" \
	  | sudo tee /etc/logrotate.d/snipr >/dev/null'
	ssh -i $(SSH_KEY) ubuntu@$(IP) 'sudo /opt/snipr/bin/ecr-refresh.sh 2>&1 | sudo tee -a /var/log/snipr-ecr-refresh.log'

# Install or upgrade the monitoring stack on the node (needs the secrets
# alertmanager-discord and grafana-admin in namespace monitoring).
KPS_VERSION := 93.11.1
monitoring:
	scp -i $(SSH_KEY) monitoring/kps-values.yaml monitoring/dashboards/snipr.json ubuntu@$(IP):/tmp/
	ssh -i $(SSH_KEY) ubuntu@$(IP) 'export KUBECONFIG=$$HOME/.kube/config && \
	  kubectl -n monitoring create configmap snipr-dashboard --from-file=/tmp/snipr.json --dry-run=client -o yaml \
	    | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f - && \
	  helm upgrade --install kps oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
	    --version $(KPS_VERSION) -n monitoring -f /tmp/kps-values.yaml --timeout 10m && \
	  rm /tmp/kps-values.yaml /tmp/snipr.json'

# Unit-test the alert rules with promtool (same version as the cluster's Prometheus).
PROMETHEUS_IMAGE := prom/prometheus:v3.16.0
test-rules:
	helm template snipr helm/snipr -n snipr --api-versions monitoring.coreos.com/v1 \
	  --set image.repository=x --set image.tag=x --set baseUrl=http://x -s templates/prometheusrule.yaml \
	  | python3 -c 'import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin)["spec"]))' > monitoring/tests/rules.yaml
	docker run --rm -v "$(CURDIR)/monitoring/tests:/t:ro" -w /t --entrypoint promtool $(PROMETHEUS_IMAGE) test rules rules.test.yaml
	rm -f monitoring/tests/rules.yaml
