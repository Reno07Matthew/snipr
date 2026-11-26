output "instance_id" {
  description = "For SSM and the GitHub Actions variable"
  value       = aws_instance.node.id
}

output "public_ip" {
  description = "Elastic IP: http://<this>/healthz"
  value       = aws_eip.node.public_ip
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/snipr-ec2 ubuntu@${aws_eip.node.public_ip}"
}

output "ecr_registry" {
  value = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.repo : k => r.repository_url }
}

output "github_deploy_role_arn" {
  value = aws_iam_role.github_deploy.arn
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}
