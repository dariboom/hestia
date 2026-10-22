# EKS control plane (ADR-001): private endpoint only, KMS envelope encryption of Secrets,
# every control-plane log type, and IAM access entries (no aws-auth ConfigMap).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  region_code  = { "eu-central-1" = "de", "eu-west-3" = "fr" }[var.region]
  name_prefix  = "hestia-${var.environment}-${local.region_code}"
  cluster_name = "${local.name_prefix}-eks"
  partition    = data.aws_partition.current.partition
  account_id   = data.aws_caller_identity.current.account_id
  boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/hestia-${var.environment}-boundary"
  log_types    = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name                 = "${local.cluster_name}-cluster"
  assume_role_policy   = data.aws_iam_policy_document.cluster_assume.json
  permissions_boundary = local.boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Created before the cluster so EKS writes into a KMS-encrypted, retention-bounded group.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_339:The pinned checkov release predates EKS 1.33; var.cluster_version is validated and kept on a supported release.
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    # Hard-coded: the API server is reachable only from the VPC and its peer (ADR-001).
    endpoint_public_access = false
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = var.kms_key_arn
    }
  }

  enabled_cluster_log_types = local.log_types

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  tags = merge(var.tags, { "hestia:environment" = var.environment })

  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]

  lifecycle {
    precondition {
      condition     = data.aws_region.current.region == var.region
      error_message = "var.region does not match the provider region."
    }
  }
}

# Cluster administrators are IAM principals mapped through access entries.
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# IRSA: the IAM OIDC provider for the cluster's issuer. IAM validates EKS issuers against its
# own trusted CAs, so no thumbprint is pinned here.
resource "aws_iam_openid_connect_provider" "this" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}
