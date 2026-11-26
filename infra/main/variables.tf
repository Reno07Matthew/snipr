variable "my_ip" {
  description = "Your public IP as a /32 CIDR; the only SSH source. Check: curl -s https://checkip.amazonaws.com"
  type        = string
  validation {
    condition     = can(cidrhost(var.my_ip, 0)) && endswith(var.my_ip, "/32")
    error_message = "my_ip must be a single address in /32 form, such as 203.0.113.10/32."
  }
}

variable "ssh_public_key_path" {
  description = "Public half of the SSH key for the ubuntu user"
  type        = string
  default     = "~/.ssh/snipr-ec2.pub"
}

variable "github_repo" {
  description = "owner/repo allowed to deploy through GitHub OIDC"
  type        = string
  default     = "Reno07Matthew/snipr"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_gb" {
  description = "Root disk size; also holds the k3s local-path PostgreSQL volume"
  type        = number
  default     = 20
}
