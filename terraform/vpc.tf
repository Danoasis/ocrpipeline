# =============================================================================
# terraform/vpc.tf
# =============================================================================
#
# This file provisions the entire network layer for the project.
#
# NETWORK ARCHITECTURE:
#
#   ┌─────────────────────────────────────────────────┐
#   │  VPC  10.0.0.0/16                               │
#   │                                                 │
#   │  ┌──────────────┐    ┌──────────────┐           │
#   │  │ Public Subnet│    │ Public Subnet│           │
#   │  │ 10.0.101.0/24│    │ 10.0.102.0/24│           │
#   │  │    us-east-1a│    │   us-east-1b │           │
#   │  │              │    │              │           │
#   │  │ [NAT Gateway]│    │              │           │
#   │  │ [Load Balancer]   │              │           │
#   │  └──────┬───────┘    └──────────────┘           │
#   │         │ (routes outbound traffic)              │
#   │  ┌──────▼───────┐    ┌──────────────┐           │
#   │  │Private Subnet│    │Private Subnet│           │
#   │  │ 10.0.1.0/24  │    │ 10.0.2.0/24  │           │
#   │  │    us-east-1a│    │   us-east-1b │           │
#   │  │              │    │              │           │
#   │  │ [EKS Nodes]  │    │ [EKS Nodes]  │           │
#   │  └──────────────┘    └──────────────┘           │
#   └─────────────────────────────────────────────────┘
#              │
#        Internet Gateway
#              │
#          Internet
#
# WHY PRIVATE SUBNETS FOR NODES?
# Worker nodes should never have public IPs. If they did, every port you
# accidentally open becomes a potential attack surface on the internet.
# Private nodes reach the internet through a NAT Gateway — outbound only.
# Inbound traffic goes: Internet → Load Balancer (public) → Node (private).
#
# =============================================================================


# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
#
# The VPC is the isolated network boundary for everything in this project.
# Resources in different VPCs cannot talk to each other by default.
#

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # enable_dns_support and enable_dns_hostnames are required for EKS.
  # They let pods resolve AWS service names (like ECR, S3) to IPs.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}


# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------
#
# The Internet Gateway (IGW) is what connects the VPC to the internet.
# Without it, nothing in the VPC can reach or be reached from outside.
# It's attached to the VPC — only one IGW per VPC.
#

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id   # reference to the VPC resource above

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}


# -----------------------------------------------------------------------------
# Public Subnets
# -----------------------------------------------------------------------------
#
# count = length(var.availability_zones) creates one subnet per AZ.
# If var.availability_zones = ["us-east-1a", "us-east-1b"], count = 2.
# Each resource gets a unique index: [0], [1], etc.
#

resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Instances launched in public subnets get a public IP automatically.
  # This is what makes them "public" — Load Balancers need this.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-public-${var.availability_zones[count.index]}"

    # These tags are REQUIRED for EKS to know which subnets to use
    # for load balancers. EKS reads these tags automatically.
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"   # for public load balancers
  }
}


# -----------------------------------------------------------------------------
# Private Subnets
# -----------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # No public IPs — nodes are not reachable from the internet directly
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.cluster_name}-private-${var.availability_zones[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"   # for internal load balancers
  }
}


# -----------------------------------------------------------------------------
# NAT Gateway
# -----------------------------------------------------------------------------
#
# Nodes in private subnets need to reach the internet for:
#   - Pulling Docker images from ECR
#   - Calling the Ollama API (if external)
#   - Sending logs to CloudWatch
#
# A NAT Gateway sits in the PUBLIC subnet and forwards outbound traffic
# from private subnets to the internet. It's one-directional — the internet
# cannot initiate connections to private resources through a NAT.
#
# We create one NAT Gateway (in the first public subnet).
# For full HA you'd create one per AZ, but that triples the cost.
# One NAT Gateway is a common cost/availability tradeoff for non-critical workloads.
#
# Elastic IP: a static public IP address. NAT Gateways need one.
#

resource "aws_eip" "nat" {
  domain = "vpc"   # "vpc" is required for EIPs used in VPCs

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id   # place NAT in first public subnet

  # NAT Gateway must be created after the Internet Gateway
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.cluster_name}-nat"
  }
}


# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------
#
# A route table is a set of rules that determines where network traffic goes.
# Every subnet must be associated with a route table.
#
# Public route table: sends all traffic (0.0.0.0/0) to the Internet Gateway.
# Private route table: sends all traffic (0.0.0.0/0) to the NAT Gateway.
#

# Public route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"                  # all traffic...
    gateway_id = aws_internet_gateway.main.id  # ...goes to the internet
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

# Associate each public subnet with the public route table
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"              # all traffic...
    nat_gateway_id = aws_nat_gateway.main.id   # ...goes to NAT (not directly to internet)
  }

  tags = {
    Name = "${var.cluster_name}-private-rt"
  }
}

# Associate each private subnet with the private route table
resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
