# Optional replication of the audit bucket into the peer region's audit bucket, so the WORM record survives a
# region loss. Object Lock retention travels with each replica; delete markers are not replicated. The peer
# stack must list this role in key_usage_role_arns["audit"] for its audit key to accept the replicas.

locals {
  replicate_audit        = var.audit_replication_destination != null
  audit_replication_name = "${local.name_prefix}-audit-replication"
}

data "aws_iam_policy_document" "audit_replication_assume" {
  count = local.replicate_audit ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "audit_replication" {
  count = local.replicate_audit ? 1 : 0

  name                 = local.audit_replication_name
  assume_role_policy   = data.aws_iam_policy_document.audit_replication_assume[0].json
  permissions_boundary = "${local.arn_prefix}:iam::${local.account_id}:policy/hestia-${var.environment}-boundary"
  tags                 = var.tags
}

data "aws_iam_policy_document" "audit_replication" {
  count = local.replicate_audit ? 1 : 0

  statement {
    sid       = "SourceBucket"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [module.audit_bucket.arn]
  }

  statement {
    sid = "SourceObjects"
    actions = [
      "s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging",
      "s3:GetObjectRetention", "s3:GetObjectLegalHold",
    ]
    resources = ["${module.audit_bucket.arn}/*"]
  }

  statement {
    sid       = "DestinationObjects"
    actions   = ["s3:ReplicateObject", "s3:ReplicateTags"]
    resources = ["${var.audit_replication_destination.bucket_arn}/*"]
  }

  # Bucket keys are enabled, so the encryption context is the bucket ARN; object ARNs cover the rest.
  statement {
    sid       = "DecryptSource"
    actions   = ["kms:Decrypt"]
    resources = [module.kms["audit"].key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [module.audit_bucket.arn, "${module.audit_bucket.arn}/*"]
    }
  }

  statement {
    sid       = "EncryptDestination"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = [var.audit_replication_destination.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.audit_replication_destination.region}.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [var.audit_replication_destination.bucket_arn, "${var.audit_replication_destination.bucket_arn}/*"]
    }
  }
}

resource "aws_iam_role_policy" "audit_replication" {
  count = local.replicate_audit ? 1 : 0

  name   = local.audit_replication_name
  role   = aws_iam_role.audit_replication[0].id
  policy = data.aws_iam_policy_document.audit_replication[0].json
}

resource "aws_s3_bucket_replication_configuration" "audit" {
  count = local.replicate_audit ? 1 : 0

  bucket = module.audit_bucket.id
  role   = aws_iam_role.audit_replication[0].arn

  rule {
    id     = "audit-dr"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Disabled"
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }

    destination {
      bucket        = var.audit_replication_destination.bucket_arn
      storage_class = "GLACIER_IR"

      encryption_configuration {
        replica_kms_key_id = var.audit_replication_destination.kms_key_arn
      }
    }
  }

  # Replication needs versioning, which module.audit_bucket enables (Object Lock requires it).
  depends_on = [module.audit_bucket, aws_iam_role_policy.audit_replication]
}
