# Canonical's published pointer to the current Ubuntu 24.04 LTS image.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "owner" {
  key_name   = "snipr-ec2"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_instance" "node" {
  ami                    = data.aws_ssm_parameter.ubuntu.insecure_value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  key_name               = aws_key_pair.owner.key_name
  iam_instance_profile   = aws_iam_instance_profile.node.name
  user_data              = file("${path.module}/../../scripts/bootstrap-node.sh")

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # pods cannot reach the instance credentials
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  lifecycle {
    # A newer AMI or an edited bootstrap script would replace the instance and
    # delete the database disk. Replace deliberately instead (terraform apply -replace).
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "snipr-node" }
}

resource "aws_eip" "node" {
  domain     = "vpc"
  instance   = aws_instance.node.id
  depends_on = [aws_internet_gateway.main]
  tags       = { Name = "snipr-node" }
}
