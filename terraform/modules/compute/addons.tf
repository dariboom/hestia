# EKS add-ons. Every add-on that calls AWS runs under its own IRSA role (compute/irsa-role);
# none of them borrows the node role.

locals {
  oidc_provider_arn = aws_iam_openid_connect_provider.this.arn

  irsa_addons = {
    vpc-cni = {
      role            = "vpc-cni"
      namespace       = "kube-system"
      service_account = "aws-node"
      managed         = ["AmazonEKS_CNI_Policy"]
    }
    aws-ebs-csi-driver = {
      role            = "ebs-csi"
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
      managed         = ["service-role/AmazonEBSCSIDriverPolicy"]
    }
    amazon-cloudwatch-observability = {
      role            = "cloudwatch"
      namespace       = "amazon-cloudwatch"
      service_account = "cloudwatch-agent"
      managed         = ["CloudWatchAgentServerPolicy"]
    }
  }

  # Networking add-ons go in alongside the nodes (nodes need the CNI to become Ready); the rest
  # need schedulable nodes first.
  addons_before_nodes = toset(["vpc-cni", "kube-proxy"])
  addons_after_nodes  = toset(["coredns", "aws-ebs-csi-driver", "amazon-cloudwatch-observability"])
}

# Persistent volumes are encrypted with the compute key, so the CSI controller needs it.
data "aws_iam_policy_document" "ebs_csi_kms" {
  statement {
    sid       = "UseComputeKey"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid       = "GrantForEbs"
    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = [var.kms_key_arn]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

module "addon_irsa" {
  source   = "./irsa-role"
  for_each = local.irsa_addons

  name                     = "${local.cluster_name}-${each.value.role}"
  oidc_provider_arn        = local.oidc_provider_arn
  namespace                = each.value.namespace
  service_account          = each.value.service_account
  managed_policy_arns      = [for p in each.value.managed : "arn:${local.partition}:iam::aws:policy/${p}"]
  policy_json              = each.key == "aws-ebs-csi-driver" ? data.aws_iam_policy_document.ebs_csi_kms.json : null
  permissions_boundary_arn = local.boundary_arn
  tags                     = var.tags
}

resource "aws_eks_addon" "before_nodes" {
  for_each = local.addons_before_nodes

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  service_account_role_arn    = try(module.addon_irsa[each.key].role_arn, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

resource "aws_eks_addon" "after_nodes" {
  for_each = local.addons_after_nodes

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  service_account_role_arn    = try(module.addon_irsa[each.key].role_arn, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags

  depends_on = [aws_eks_node_group.this]
}

# Cluster Autoscaler (installed by the platform Helm release) may only resize this cluster's
# groups: EKS tags managed node group ASGs with k8s.io/cluster-autoscaler/<cluster> = owned.
data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid = "AutoscalingDescribe"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeOwnNodegroups"
    actions   = ["eks:DescribeNodegroup"]
    resources = ["arn:${local.partition}:eks:${var.region}:${local.account_id}:nodegroup/${local.cluster_name}/*"]
  }

  statement {
    sid       = "ScaleOwnedGroups"
    actions   = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
    resources = ["arn:${local.partition}:autoscaling:${var.region}:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${local.cluster_name}"
      values   = ["owned"]
    }
  }
}

module "cluster_autoscaler_irsa" {
  source = "./irsa-role"

  name                     = "${local.cluster_name}-cluster-autoscaler"
  oidc_provider_arn        = local.oidc_provider_arn
  namespace                = "kube-system"
  service_account          = "cluster-autoscaler"
  policy_json              = data.aws_iam_policy_document.cluster_autoscaler.json
  permissions_boundary_arn = local.boundary_arn
  tags                     = var.tags
}
