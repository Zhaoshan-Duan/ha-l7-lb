# ECR repository for storing Docker images. Used by both LB and backend.
resource "aws_ecr_repository" "this" { name = var.repository_name }
