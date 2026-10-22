# WORM audit store, one per region: CloudTrail (home_region trail) and AWS Config deliver here. Records hold only
# pseudonymous IDs, so Object Lock retention does not conflict with GDPR erasure (plan, Global Constraints).

module "audit_bucket" {
  source = "../s3-bucket"

  name                         = "${local.name_prefix}-audit-${local.account_id}"
  kms_key_arn                  = module.kms["audit"].key_arn
  tags                         = merge(var.tags, { "hestia:environment" = var.environment })
  policy_admin_role_arns       = var.audit_bucket_admin_role_arns
  access_log_bucket            = var.audit_access_log_bucket
  object_lock                  = { mode = var.object_lock_mode, days = var.audit_retention_days }
  additional_policy_statements = data.aws_iam_policy_document.audit_bucket_cloudtrail[*].json

  lifecycle_rules = [{
    id = "audit-retention"
    transitions = [
      { days = 90, storage_class = "GLACIER_IR" },
      { days = 365, storage_class = "DEEP_ARCHIVE" },
    ]
    expiration_days = var.audit_retention_days
  }]
}
