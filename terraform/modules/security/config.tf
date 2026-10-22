# AWS Config: a recorder in each region, global resource types (IAM) only in home_region so they are
# recorded once, delivery to this region's audit bucket, and the account aggregator in home_region only.

locals {
  audit_bucket_arn = module.audit_bucket.arn
}

data "aws_iam_policy_document" "config_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "config_delivery" {
  statement {
    sid       = "CheckAuditBucket"
    actions   = ["s3:GetBucketAcl"]
    resources = [local.audit_bucket_arn]
  }

  statement {
    sid       = "DeliverToAuditBucket"
    actions   = ["s3:PutObject"]
    resources = ["${local.audit_bucket_arn}/AWSLogs/${local.account_id}/Config/*"]
  }

  statement {
    sid       = "EncryptWithAuditKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [module.kms["audit"].key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

# IAM names are global: the region code keeps the DE and FR roles apart.
resource "aws_iam_role" "config" {
  name                 = "${local.name_prefix}-config"
  assume_role_policy   = data.aws_iam_policy_document.config_assume.json
  permissions_boundary = "${local.arn_prefix}:iam::${local.account_id}:policy/hestia-${var.environment}-boundary"
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "${local.arn_prefix}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_delivery" {
  name   = "${local.name_prefix}-config-delivery"
  role   = aws_iam_role.config.id
  policy = data.aws_iam_policy_document.config_delivery.json
}

resource "aws_config_configuration_recorder" "this" {
  #checkov:skip=CKV2_AWS_48:All supported types are recorded; global types (IAM) only in home_region to avoid duplicate items.
  name     = "${local.name_prefix}-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = local.is_home
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "${local.name_prefix}-delivery"
  s3_bucket_name = module.audit_bucket.id
  s3_kms_key_arn = module.kms["audit"].key_arn

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.this, aws_iam_role_policy.config_delivery]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

resource "aws_config_configuration_aggregator" "this" {
  count = local.is_home ? 1 : 0

  name = "${local.name_prefix}-config"
  tags = var.tags

  account_aggregation_source {
    account_ids = [local.account_id]
    regions     = [var.region, local.other_region]
  }
}
