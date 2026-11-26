# The bucket name contains the account ID, so it is passed at init time:
#   terraform init -backend-config="bucket=$(terraform -chdir=../bootstrap output -raw state_bucket)"
terraform {
  backend "s3" {
    key          = "main/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true # native S3 locking, no DynamoDB table
  }
}
