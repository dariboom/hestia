# One multi-region trail per environment, created by the home_region stack into its own audit bucket. CloudWatch
# Logs gets a short-lived copy for metric filters; the audit bucket keeps the WORM record.

locals {
  trail_name = "${local.name_prefix}-trail"
  # Built, not referenced, so the audit bucket policy can name the trail before the trail exists.
  trail_arn = "${local.arn_prefix}:cloudtrail:${var.region}:${local.account_id}:trail/${local.trail_name}"
}

data "aws_iam_policy_document" "audit_bucket_cloudtrail" {
  count = local.is_home ? 1 : 0

  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = ["${local.arn_prefix}:s3:::${local.name_prefix}-audit-${local.account_id}"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${local.arn_prefix}:s3:::${local.name_prefix}-audit-${local.account_id}/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  count = local.is_home ? 1 : 0

  name              = "/aws/cloudtrail/${local.trail_name}"
  retention_in_days = var.cloudtrail_log_retention_days
  kms_key_id        = module.kms["logs"].key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "cloudtrail_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_iam_role" "cloudtrail_logs" {
  count = local.is_home ? 1 : 0

  name                 = "${local.trail_name}-logs"
  assume_role_policy   = data.aws_iam_policy_document.cloudtrail_logs_assume.json
  permissions_boundary = "${local.arn_prefix}:iam::${local.account_id}:policy/hestia-${var.environment}-boundary"
  tags                 = var.tags
}

data "aws_iam_policy_document" "cloudtrail_logs" {
  count = local.is_home ? 1 : 0

  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.cloudtrail[0].arn}:log-stream:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail_logs" {
  count = local.is_home ? 1 : 0

  name   = "${local.trail_name}-logs"
  role   = aws_iam_role.cloudtrail_logs[0].id
  policy = data.aws_iam_policy_document.cloudtrail_logs[0].json
}

resource "aws_cloudtrail" "this" {
  #checkov:skip=CKV_AWS_252:No delivery SNS topic; high-severity findings alert through EventBridge (alerts.tf).
  count = local.is_home ? 1 : 0

  name                          = local.trail_name
  s3_bucket_name                = module.audit_bucket.id
  kms_key_id                    = module.kms["audit"].key_arn
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_logs[0].arn
  tags                          = var.tags

  advanced_event_selector {
    name = "Management events"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  dynamic "advanced_event_selector" {
    for_each = length(var.cloudtrail_data_event_bucket_arns) > 0 ? [1] : []
    content {
      name = "Data bucket object reads and writes"

      field_selector {
        field  = "eventCategory"
        equals = ["Data"]
      }

      field_selector {
        field  = "resources.type"
        equals = ["AWS::S3::Object"]
      }

      field_selector {
        field       = "resources.ARN"
        starts_with = [for b in var.cloudtrail_data_event_bucket_arns : "${b}/"]
      }
    }
  }

  # Reads only: logging writes to the bucket the trail itself writes to would log its own deliveries.
  advanced_event_selector {
    name = "Audit bucket object reads"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field  = "readOnly"
      equals = ["true"]
    }

    field_selector {
      field       = "resources.ARN"
      starts_with = ["${module.audit_bucket.arn}/"]
    }
  }

  depends_on = [aws_iam_role_policy.cloudtrail_logs, module.audit_bucket]
}
