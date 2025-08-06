provider "aws" {
  region = "eu-north-1"
}

# Use existing VPC
data "aws_vpc" "existing" {
  id = "vpc-0a539f72bbda53119"
}

# Use existing subnets
data "aws_subnet" "existing_subnet_1" {
  id = "subnet-0bd71d19466c0fd64"
}

data "aws_subnet" "existing_subnet_2" {
  id = "subnet-00d340589350b29e9"
}

# Security Groups
resource "aws_security_group" "cluster_sg" {
  name   = "idp-cluster-sg"
  vpc_id = data.aws_vpc.existing.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.existing.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "idp-cluster-sg"
  }
}

resource "aws_security_group" "node_sg" {
  name   = "idp-node-sg"
  vpc_id = data.aws_vpc.existing.id
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.cluster_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "idp-node-sg"
  }
}

# EKS Cluster
resource "aws_eks_cluster" "idp_cluster" {
  name     = "idp-cluster"
  role_arn = aws_iam_role.eks_role.arn
  vpc_config {
    subnet_ids         = [data.aws_subnet.existing_subnet_1.id, data.aws_subnet.existing_subnet_2.id]
    security_group_ids = [aws_security_group.cluster_sg.id]
  }
  depends_on = [
    aws_iam_role_policy_attachment.eks_policy
  ]
}

# Rest of your IAM roles and node group configuration remains the same...
resource "aws_iam_role" "eks_role" {
  name = "idp-eks-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_policy" {
  role       = aws_iam_role.eks_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_node_group" "node_group" {
  cluster_name    = aws_eks_cluster.idp_cluster.name
  node_group_name = "idp-nodes"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = [data.aws_subnet.existing_subnet_1.id, data.aws_subnet.existing_subnet_2.id]
  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }
  instance_types = ["t3.medium"]
  ami_type       = "AL2023_x86_64_STANDARD" # Updated AMI type for newer Kubernetes versions
  disk_size      = 20
  remote_access {
    ec2_ssh_key = "project"
  }
  depends_on = [
    aws_iam_role_policy_attachment.node_policy,
    aws_iam_role_policy_attachment.cni_policy,
    aws_iam_role_policy_attachment.ecr_policy,
    aws_eks_cluster.idp_cluster
  ]
}

resource "aws_iam_role" "node_role" {
  name = "idp-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "node_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Add this to your eks.tf file

# ECR Repository for storing Docker images
resource "aws_ecr_repository" "platform_engineering" {
  name                 = "platform-engineering"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "platform-engineering-ecr"
  }
}

resource "aws_ecr_lifecycle_policy" "platform_engineering_policy" {
  repository = aws_ecr_repository.platform_engineering.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 production images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Output the ECR repository URL
output "ecr_repository_url" {
  description = "URL of the ECR repository"
  value       = aws_ecr_repository.platform_engineering.repository_url
}