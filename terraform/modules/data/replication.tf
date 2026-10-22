# Cross-region replication of the backups bucket only: backups are the DR copy (RPO bound by the
# backup schedule). Artifacts are rebuildable and logs stay in their region of origin, so neither
# leaves it. Delete markers are not replicated so a deletion in the source cannot erase the DR copy;
# expiry on both sides is bounded by the backups lifecycle (<= 90 days, GDPR erasure bound).

locals {
  replicate        = var.enable_cross_region_replication
  backups_arn      = module.bucket["backups"].arn
  replication_name = "${local.name_prefix}-data-replication"
}

data "aws_iam_policy_document" "replication_assume" {
  count = local.replicate ? 1 : 0

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

resource "aws_iam_role" "replication" {
  count = local.replicate ? 1 : 0

  name                 = local.replication_name
  assume_role_policy   = data.aws_iam_policy_document.replication_assume[0].json
  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:policy/hestia-${var.environment}-boundary"
  tags                 = var.tags
}

data "aws_iam_policy_document" "replication" {
  count = local.replicate ? 1 : 0

  statement {
    sid       = "SourceBucket"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [local.backups_arn]
  }

  statement {
    sid       = "SourceObjects"
    actions   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${local.backups_arn}/*"]
  }

  statement {
    sid       = "DestinationObjects"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["${var.replication_destination.bucket_arn}/*"]
  }

  # Bucket keys are enabled, so the encryption context is the bucket ARN; object ARNs cover the rest.
  statement {
    sid       = "DecryptSource"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [local.backups_arn, "${local.backups_arn}/*"]
    }
  }

  statement {
    sid       = "EncryptDestination"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = [var.replication_destination.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.replication_destination.region}.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [var.replication_destination.bucket_arn, "${var.replication_destination.bucket_arn}/*"]
    }
  }
}

resource "aws_iam_role_policy" "replication" {
  count = local.replicate ? 1 : 0

  name   = local.replication_name
  role   = aws_iam_role.replication[0].id
  policy = data.aws_iam_policy_document.replication[0].json
}

resource "aws_s3_bucket_replication_configuration" "backups" {
  count = local.replicate ? 1 : 0

  bucket = module.bucket["backups"].id
  role   = aws_iam_role.replication[0].arn

  rule {
    id     = "backups-dr"
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
      bucket        = var.replication_destination.bucket_arn
      storage_class = "GLACIER_IR"

      encryption_configuration {
        replica_kms_key_id = var.replication_destination.kms_key_arn
      }
    }
  }

  # Replication needs versioning, which module.bucket enables.
  depends_on = [module.bucket]
}
