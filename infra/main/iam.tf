# Role for the EC2 node: pull from ECR, use the backup prefix, connect to SSM.

resource "aws_iam_role" "node" {
  name = "snipr-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "node" {
  name = "snipr-node"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*" # this action has no resource-level permissions
      },
      {
        Sid      = "EcrPull"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = [for r in aws_ecr_repository.repo : r.arn]
      },
      {
        Sid       = "BackupList"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.backups.arn
        Condition = { StringLike = { "s3:prefix" = ["db/*"] } }
      },
      {
        Sid      = "BackupObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"] # Get is for restore tests
        Resource = "${aws_s3_bucket.backups.arn}/db/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "snipr-node"
  role = aws_iam_role.node.name
}
