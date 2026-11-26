# Added after the first apply: the bucket must exist before it can hold state.
# The bucket name contains the account ID, so it is passed at init time:
#   terraform init -backend-config="bucket=snipr-tfstate-<account-id>"
terraform {
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
