# =============================================================================
# terraform/ecr.tf
# =============================================================================
#
# ECR (Elastic Container Registry) is AWS's managed Docker registry.
# It's where your built container images live before Kubernetes pulls them.
#
# THE FLOW:
#   1. GitHub Actions builds your Docker image
#   2. GitHub Actions pushes it to ECR with a tag (e.g. git commit SHA)
#   3. You update the image tag in k8s/api/deployment.yaml
#   4. kubectl apply → Kubernetes pulls the new image from ECR
#
# Later, step 3 and 4 will be automated — that's Continuous Delivery (CD).
#
# WHY ECR OVER DOCKER HUB?
#   - ECR lives inside AWS — pulling images from EKS is fast and free (no egress)
#   - IAM controls access — no separate credentials to manage
#   - Private by default — your images aren't public
#   - Scanning built-in — ECR can scan images for known CVEs
#
# =============================================================================

resource "aws_ecr_repository" "app" {
  name = var.cluster_name    # repository name = project name

  # MUTABLE tags can be overwritten (pushing "latest" replaces the old "latest").
  # IMMUTABLE tags cannot — each tag can only be pushed once.
  # IMMUTABLE is safer for production: you can always trace exactly which
  # image is running from the tag alone, with no risk of silent overwriting.
  image_tag_mutability = "MUTABLE"
  # Change to "IMMUTABLE" when you move to production.

  # Enable vulnerability scanning on every image push.
  # Results are visible in the AWS console and can trigger alerts.
  image_scanning_configuration {
    scan_on_push = true
  }

  # Encrypt images at rest using AWS KMS.
  # AES256 uses an AWS-managed key (free).
  # KMS uses a customer-managed key (more control, small cost per month).
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.cluster_name}-ecr"
  }
}


# -----------------------------------------------------------------------------
# Lifecycle Policy
# -----------------------------------------------------------------------------
#
# Without a lifecycle policy, every image you push stays forever.
# ECR storage costs money — you'd accumulate thousands of old images.
#
# This policy keeps the most recent N images and deletes older ones.
# It only applies to untagged images and images beyond the count threshold.
#
# The policy is JSON — aws_ecr_lifecycle_policy takes it as a string.
# The jsonencode() function converts a Terraform map to a JSON string.
#

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last N images, delete older ones"
        selection = {
          tagStatus   = "any"   # applies to both tagged and untagged images
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_image_retention_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
