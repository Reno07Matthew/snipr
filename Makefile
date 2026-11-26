# Run from the repo root. Needs: aws, terraform (infra/main initialised), ssh.
export AWS_REGION := ap-south-1
TF := terraform -chdir=infra/main
INSTANCE = $(shell $(TF) output -raw instance_id)
IP = $(shell $(TF) output -raw public_ip)
SSH_KEY := $(HOME)/.ssh/snipr-ec2

.PHONY: start stop node-scripts

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
	scp -i $(SSH_KEY) scripts/ecr-refresh.sh ubuntu@$(IP):/tmp/
	ssh -i $(SSH_KEY) ubuntu@$(IP) 'sudo install -D -m 0755 /tmp/ecr-refresh.sh /opt/snipr/bin/ecr-refresh.sh && rm /tmp/ecr-refresh.sh'
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
