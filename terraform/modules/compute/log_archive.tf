# Container and control-plane logs are archived to an S3 bucket in var.region through a regional
# Firehose stream, so log personal data never leaves the region (data residency, GDPR).

module "log_archive" {
  source = "../s3-bucket"

  name        = "${local.name_prefix}-log-archive-${local.account_id}"
  kms_key_arn = var.log_archive_kms_key_arn
  tags = merge(var.tags, {
    "hestia:environment"         = var.environment
    "hestia:data-classification" = "personal"
  })
  policy_admin_role_arns = var.bucket_admin_role_arns

  lifecycle_rules = [{
    id                         = "log-archive-retention"
    transitions                = [{ days = var.log_archive_lifecycle.transition_days, storage_class = "GLACIER_IR" }]
    expiration_days            = var.log_archive_lifecycle.expiration_days
    noncurrent_expiration_days = 1
  }]
}

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "firehose" {
  statement {
    sid       = "ArchiveBucket"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
    resources = [module.log_archive.arn]
  }

  statement {
    sid       = "ArchiveObjects"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
    resources = ["${module.log_archive.arn}/*"]
  }

  # Bucket keys are on, so the S3 encryption context is the bucket ARN.
  statement {
    sid       = "ArchiveKeyViaS3"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.log_archive_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [module.log_archive.arn]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name                 = "${local.cluster_name}-log-firehose"
  assume_role_policy   = data.aws_iam_policy_document.firehose_assume.json
  permissions_boundary = local.boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy" "firehose" {
  name   = "log-archive"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

resource "aws_kinesis_firehose_delivery_stream" "logs" {
  name        = "${local.cluster_name}-logs"
  destination = "extended_s3"

  server_side_encryption {
    enabled  = true
    key_type = "CUSTOMER_MANAGED_CMK"
    key_arn  = var.log_archive_kms_key_arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = module.log_archive.arn
    kms_key_arn         = var.log_archive_kms_key_arn
    prefix              = "logs/!{timestamp:yyyy/MM/dd}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/!{timestamp:yyyy/MM/dd}/"
    compression_format  = "GZIP"
    buffering_size      = 64
    buffering_interval  = 300

    # CloudWatch Logs delivers gzip'd envelopes; unpack them so the archive holds plain log lines.
    processing_configuration {
      enabled = true

      processors {
        type = "Decompression"

        parameters {
          parameter_name  = "CompressionFormat"
          parameter_value = "GZIP"
        }
      }

      processors {
        type = "CloudWatchLogProcessing"

        parameters {
          parameter_name  = "DataMessageExtraction"
          parameter_value = "true"
        }
      }
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.firehose]

  lifecycle {
    precondition {
      condition     = data.aws_region.current.region == var.region
      error_message = "var.region does not match the provider region; the log archive must stay in-region."
    }
  }
}
