locals {
  # "charts/snipr" receives: helm push <tgz> oci://<registry>/charts
  ecr_repos = ["snipr", "charts/snipr"]
}

resource "aws_ecr_repository" "repo" {
  for_each             = toset(local.ecr_repos)
  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # a SHA tag always means the same build

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "keep_10" {
  for_each   = aws_ecr_repository.repo
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the latest 10"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
