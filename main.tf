provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {}

resource "aws_vpc" "nahid_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name                                        = "nahid-vpc"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Public Subnets
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.nahid_vpc.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "nahid-public-${count.index}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

# Private Subnets (For Nodes)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.nahid_vpc.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                                        = "nahid-private-${count.index}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

resource "aws_internet_gateway" "nahid_igw" {
  vpc_id = aws_vpc.nahid_vpc.id
  tags   = { Name = "nahid-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "nahid-nat" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.nahid_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.nahid_igw.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.nahid_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Security Group Hardening
resource "aws_security_group" "nahid_cluster_sg" {
  name   = "nahid-cluster-sg"
  vpc_id = aws_vpc.nahid_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "nahid-cluster-sg" }
}

resource "aws_security_group" "nahid_node_sg" {
  name   = "nahid-node-sg"
  vpc_id = aws_vpc.nahid_vpc.id

  ingress {
    description = "Allow nodes to communicate with each other"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description     = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.nahid_cluster_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "nahid-node-sg" }
}

resource "aws_eks_cluster" "nahid" {
  name                      = var.cluster_name
  role_arn                  = aws_iam_role.nahid_cluster_role.arn
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    security_group_ids      = [aws_security_group.nahid_cluster_sg.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [aws_iam_role_policy_attachment.nahid_cluster_role_policy]
}

resource "aws_eks_node_group" "nahid" {
  cluster_name    = aws_eks_cluster.nahid.name
  node_group_name = "nahid-node-group"
  node_role_arn   = aws_iam_role.nahid_node_group_role.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = 3
    max_size     = 3
    min_size     = 3
  }

  instance_types = ["t3.medium"] # t3 is generally better than t2 for EKS

  remote_access {
    ec2_ssh_key               = var.ssh_key_name
    source_security_group_ids = [aws_security_group.nahid_node_sg.id]
  }
}

# OIDC Provider for IRSA (Required for EBS CSI, Load Balancer Controller, etc.)
data "tls_certificate" "eks" {
  url = aws_eks_cluster.nahid.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.nahid.identity[0].oidc[0].issuer
}

resource "aws_iam_role" "nahid_cluster_role" {
  name = "nahid-cluster-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "nahid_cluster_role_policy" {
  role       = aws_iam_role.nahid_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "nahid_node_group_role" {
  name = "nahid-node-group-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "nahid_node_group_role_policy" {
  role       = aws_iam_role.nahid_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "nahid_node_group_cni_policy" {
  role       = aws_iam_role.nahid_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "nahid_node_group_registry_policy" {
  role       = aws_iam_role.nahid_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
