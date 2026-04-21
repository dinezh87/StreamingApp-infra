# ── IAM Role for EKS Control Plane ───────────────────────────────────────────
resource "aws_iam_role" "cluster" {
  name = "${var.project}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    # Include both app and data subnets so the control plane ENIs can
    # reach nodes in either node group
    subnet_ids              = concat(var.private_app_subnet_ids, [var.private_data_subnet_id])
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]

  tags = { Name = var.cluster_name }
}

# ── OIDC Provider (required for IRSA) ────────────────────────────────────────
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

# ── IAM Role for Node Group (worker nodes) ───────────────────────────────────
resource "aws_iam_role" "node" {
  name = "${var.project}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ── App Node Group (auth, streaming, admin, chat, frontend pods) ──────────────
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-app-node-group"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_app_subnet_ids
  instance_types  = [var.node_instance_type]

  scaling_config {
    min_size     = var.node_min
    max_size     = var.node_max
    desired_size = var.node_desired
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  tags = { Name = "${var.project}-app-node-group" }
}

# ── Data Node Group (MongoDB pod only — tainted to repel all other pods) ──────
resource "aws_eks_node_group" "data" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-data-node-group"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [var.private_data_subnet_id]
  instance_types  = [var.data_node_instance_type]

  scaling_config {
    min_size     = 1
    max_size     = 1
    desired_size = 1
  }

  update_config {
    max_unavailable = 1
  }

  # Taint ensures ONLY pods with a matching toleration land on this node.
  # The MongoDB StatefulSet will carry this toleration; all other pods will not.
  taint {
    key    = "workload"
    value  = "database"
    effect = "NO_SCHEDULE"
  }

  labels = {
    workload = "database"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  tags = { Name = "${var.project}-data-node-group" }
}
