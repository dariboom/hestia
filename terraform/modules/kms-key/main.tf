data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  allowed_regions = ["eu-central-1", "eu-west-3"]
  account_root    = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"

  # Explicit list instead of kms:* so administrators can never use the key for crypto.
  admin_actions = [
    "kms:CancelKeyDeletion",
    "kms:CreateAlias",
    "kms:DeleteAlias",
    "kms:DescribeKey",
    "kms:DisableKey",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListAliases",
    "kms:ListGrants",
    "kms:ListResourceTags",
    "kms:PutKeyPolicy",
    "kms:RevokeGrant",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateAlias",
    "kms:UpdateKeyDescription",
  ]

  usage_actions = [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:Encrypt",
    "kms:GenerateDataKey",
    "kms:GenerateDataKeyWithoutPlaintext",
    "kms:ReEncryptFrom",
    "kms:ReEncryptTo",
  ]
}

# In a key policy, Resource "*" means "this key" (registered in policies/data/wildcard_exceptions.json).
data "aws_iam_policy_document" "this" {
  #checkov:skip=CKV_AWS_111:Key policy: Resource "*" is this key only (policies/data/wildcard_exceptions.json); principals and conditions constrain writes.
  #checkov:skip=CKV_AWS_356:Key policy: Resource "*" is this key only and cannot be narrowed (policies/data/wildcard_exceptions.json).
  # Account root keeps the key recoverable if every admin role is deleted; administrative
  # actions only, never Encrypt/Decrypt. Deletion is additionally blocked by SCP in prod (ADR-007).
  statement {
    sid       = "RootKeyAdministration"
    effect    = "Allow"
    actions   = local.admin_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }

  dynamic "statement" {
    for_each = length(var.admin_role_arns) > 0 ? [1] : []
    content {
      sid       = "KeyAdministrators"
      effect    = "Allow"
      actions   = local.admin_actions
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.admin_role_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.usage_role_arns) > 0 ? [1] : []
    content {
      sid       = "KeyUsage"
      effect    = "Allow"
      actions   = local.usage_actions
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.usage_role_arns
      }

      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalAccount"
        values   = var.allowed_account_ids
      }
    }
  }

  # EBS, RDS and similar services need grants; only for AWS resources, never ad hoc.
  dynamic "statement" {
    for_each = length(var.usage_role_arns) > 0 ? [1] : []
    content {
      sid       = "KeyUsageGrantsForAwsResources"
      effect    = "Allow"
      actions   = ["kms:CreateGrant"]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.usage_role_arns
      }

      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalAccount"
        values   = var.allowed_account_ids
      }
    }
  }

  dynamic "statement" {
    for_each = { for i, sp in var.service_principals : tostring(i) => sp }
    content {
      sid       = "Service${statement.key}"
      effect    = "Allow"
      actions   = local.usage_actions
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = [statement.value.service]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = var.allowed_account_ids
      }

      dynamic "condition" {
        for_each = statement.value.source_arn_like == null ? [] : [1]
        content {
          test     = "ArnLike"
          variable = statement.value.source_arn_condition_key
          values   = [statement.value.source_arn_like]
        }
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = var.description
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.this.json
  tags                    = var.tags

  lifecycle {
    precondition {
      condition     = contains(local.allowed_regions, data.aws_region.current.region)
      error_message = "Region lock (ADR-005): KMS keys may only be created in eu-central-1 or eu-west-3."
    }
    precondition {
      condition     = contains(var.allowed_account_ids, data.aws_caller_identity.current.account_id)
      error_message = "The deploying account must be listed in allowed_account_ids."
    }
  }
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.key_id
}
