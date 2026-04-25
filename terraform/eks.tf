# =============================================================================
# terraform/eks.tf
# =============================================================================
#
# This file provisions the EKS (Elastic Kubernetes Service) cluster.
#
# EKS has two layers:
#
#   CONTROL PLANE (managed by AWS, you don't see these):
#     - API server:    receives kubectl commands
#     - etcd:          stores all cluster state (the "database" of Kubernetes)
#     - Scheduler:     decides which node runs each pod
#     - Controllers:   maintain desired state (restart crashed pods, etc.)
#   You pay a flat hourly fee for the control plane. AWS handles HA, backups,
#   upgrades of the control plane components.
#
#   DATA PLANE (your EC2 instances, you manage these):
#     - Worker nodes:  EC2 instances that run your pods
#   You pay for the EC2 instances. You choose the size, count, and OS.
#
# IAM ROLES:
# Both the cluster and the nodes need IAM roles — they define what AWS
# permissions they have. The cluster role lets EKS manage load balancers,
# security groups, etc. The node role lets nodes pull images from ECR,
# write logs to CloudWatch, etc.
#
# =============================================================================


# -----------------------------------------------------------------------------
# IAM Role for the EKS Control Plane
# -----------------------------------------------------------------------------
#
# IAM roles have two parts:
#   1. Trust policy:    WHO can assume this role (in this case, eks.amazonaws.com)
#   2. Permission policy: WHAT the role can do (attached via aws_iam_role_policy_attachment)
#

data "aws_iam_policy_document" "eks_cluster_trust" {
  # "data" sources READ existing AWS resources instead of creating them.
  # Here we're building the trust policy JSON programmatically.
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_trust.json

  tags = {
    Name = "${var.cluster_name}-cluster-role"
  }
}

# Attach the AWS-managed EKS cluster policy to the role.
# AmazonEKSClusterPolicy gives EKS permission to manage EC2, load balancers,
# security groups, and other resources on your behalf.
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}


# -----------------------------------------------------------------------------
# IAM Role for Worker Nodes
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "eks_node_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]   # EC2, not EKS — nodes are EC2 instances
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_trust.json
}

# Three policies are required for EKS worker nodes:
#   AmazonEKSWorkerNodePolicy:          allows nodes to join the cluster
#   AmazonEKS_CNI_Policy:               allows the CNI plugin to manage pod networking
#   AmazonEC2ContainerRegistryReadOnly: allows nodes to pull images from ECR
resource "aws_iam_role_policy_attachment" "eks_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_ecr_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node.name
}


# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------

resource "aws_eks_cluster" "main" {
  name    = var.cluster_name
  version = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    # The cluster's API server is placed in these subnets.
    # We use private subnets — the API server should not be directly
    # reachable from the internet.
    subnet_ids = aws_subnet.private[*].id

    # endpoint_private_access: kubectl from within the VPC works
    # endpoint_public_access:  kubectl from outside (your laptop) works
    # In production you'd set public_access to false and use a VPN or bastion.
    endpoint_private_access = true
    endpoint_public_access  = true

    # Restrict public API access to your office/home IP
    # Replace with your actual IP: ["1.2.3.4/32"]
    # "0.0.0.0/0" = accessible from anywhere (fine for learning, not production)
    public_access_cidrs = ["0.0.0.0/0"]
  }

  # Enable control plane logging to CloudWatch.
  # "api" and "audit" are the most valuable for debugging and security.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # The cluster must be created after the IAM policy attachments.
  # Without this, the cluster might start before it has permission to
  # manage load balancers, causing cryptic errors.
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]

  tags = {
    Name = var.cluster_name
  }
}


# -----------------------------------------------------------------------------
# EKS Node Group
# -----------------------------------------------------------------------------
#
# A Node Group is a set of EC2 instances that act as Kubernetes worker nodes.
# EKS manages the instances — it handles OS updates, node replacement, and
# cluster joining automatically.
#
# This is a MANAGED node group — AWS handles provisioning.
# The alternative is SELF-MANAGED nodes, where you manage the EC2 instances
# yourself. Managed is simpler; self-managed gives more control.
#

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn

  # Place nodes in PRIVATE subnets — they have no public IPs
  subnet_ids = aws_subnet.private[*].id

  # The EC2 instance type for worker nodes
  instance_types = [var.node_instance_type]

  scaling_config {
    min_size     = var.node_min_count
    max_size     = var.node_max_count
    desired_size = var.node_desired_count
  }

  # Update config: how many nodes can be replaced at once during updates.
  # max_unavailable = 1 means EKS replaces nodes one at a time,
  # so the cluster stays healthy during node OS updates.
  update_config {
    max_unavailable = 1
  }

  # Use the latest EKS-optimized Amazon Linux AMI for this k8s version.
  # "AL2_x86_64" = Amazon Linux 2, standard x86 nodes.
  # "AL2_x86_64_GPU" = for GPU instances (g4dn, g5 families).
  ami_type = "AL2_x86_64"

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_policy,
  ]

  tags = {
    Name = "${var.cluster_name}-node-group"
  }
}
