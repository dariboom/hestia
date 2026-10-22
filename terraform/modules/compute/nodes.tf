# Managed node groups. Pods get AWS credentials only through IRSA: IMDSv2 with a hop limit of 1
# keeps the node role out of reach of containers.

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name                 = "${local.cluster_name}-node"
  assume_role_policy   = data.aws_iam_policy_document.node_assume.json
  permissions_boundary = local.boundary_arn
  tags                 = var.tags
}

# AmazonEKS_CNI_Policy is deliberately absent: vpc-cni runs with its own IRSA role (addons.tf).
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryReadOnly"])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.key}"
}

# Rule-less identity group: traffic is carried by the EKS cluster security group; this one lets
# other stacks (e.g. data module db_allowed_security_group_ids) reference "the nodes".
resource "aws_security_group" "node" {
  #checkov:skip=CKV2_AWS_5:Attached to every node through the launch template network settings.
  name        = "${local.cluster_name}-node"
  description = "Identity of ${local.cluster_name} worker nodes"
  vpc_id      = aws_eks_cluster.this.vpc_config[0].vpc_id
  tags        = merge(var.tags, { Name = "${local.cluster_name}-node" })
}

resource "aws_launch_template" "node" {
  for_each = var.node_groups

  name_prefix            = "${local.cluster_name}-${each.key}-"
  update_default_version = true
  vpc_security_group_ids = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id, aws_security_group.node.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = each.value.disk_size
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  dynamic "tag_specifications" {
    for_each = ["instance", "volume", "network-interface"]

    content {
      resource_type = tag_specifications.value
      tags          = merge(var.tags, { Name = "${local.cluster_name}-${each.key}" })
    }
  }

  tags = var.tags
}

resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = each.value.ami_type
  instance_types  = each.value.instance_types
  capacity_type   = each.value.capacity_type
  labels          = each.value.labels

  scaling_config {
    min_size     = each.value.min_size
    max_size     = each.value.max_size
    desired_size = each.value.desired_size
  }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  dynamic "taint" {
    for_each = each.value.taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  update_config {
    max_unavailable_percentage = 33
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.node]

  lifecycle {
    # Cluster Autoscaler owns the live size.
    ignore_changes = [scaling_config[0].desired_size]
  }
}
