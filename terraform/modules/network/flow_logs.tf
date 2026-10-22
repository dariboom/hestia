# VPC flow logs: ALL traffic, Parquet, hourly Hive partitions (Athena-ready), expiring at retention.

locals {
  flow_log_bucket_name = "${local.name}-flowlogs-${data.aws_caller_identity.current.account_id}"
  flow_log_bucket_arn  = "arn:${data.aws_partition.current.partition}:s3:::${local.flow_log_bucket_name}"
  logs_source_arn      = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
}

data "aws_iam_policy_document" "flow_log_delivery" {
  statement {
    sid       = "AWSLogDeliveryWrite"
    actions   = ["s3:PutObject"]
    resources = ["${local.flow_log_bucket_arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.logs_source_arn]
    }
  }

  statement {
    sid       = "AWSLogDeliveryCheck"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [local.flow_log_bucket_arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.logs_source_arn]
    }
  }
}

module "flow_log_bucket" {
  source = "../s3-bucket"

  name                         = local.flow_log_bucket_name
  kms_key_arn                  = var.flow_log_bucket_kms_key_arn
  tags                         = merge(var.tags, { "hestia:environment" = var.environment })
  policy_admin_role_arns       = var.flow_log_bucket_admin_role_arns
  additional_policy_statements = [data.aws_iam_policy_document.flow_log_delivery.json]
  lifecycle_rules = [{
    id                         = "flow-log-retention"
    expiration_days            = var.flow_log_retention_days
    noncurrent_expiration_days = 1
  }]
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = module.flow_log_bucket.arn
  max_aggregation_interval = 600

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = merge(var.tags, { Name = local.name })
}
