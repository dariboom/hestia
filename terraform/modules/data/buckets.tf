data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  region_code = { "eu-central-1" = "de", "eu-west-3" = "fr" }[var.region]
  name_prefix = "hestia-${var.environment}-${local.region_code}"
  account_id  = data.aws_caller_identity.current.account_id

  # classification drives the hestia:data-classification tag; noncurrent days add to the erasure bound.
  buckets = {
    artifacts = { classification = "internal", storage_class = "STANDARD_IA", noncurrent_days = 30 }
    logs      = { classification = "personal", storage_class = "STANDARD_IA", noncurrent_days = 1 }
    backups   = { classification = "personal", storage_class = "GLACIER_IR", noncurrent_days = 7 }
  }
}

module "bucket" {
  source   = "../s3-bucket"
  for_each = local.buckets

  name        = "${local.name_prefix}-${each.key}-${local.account_id}"
  kms_key_arn = var.kms_key_arn
  tags = merge(var.tags, {
    "hestia:environment"         = var.environment
    "hestia:data-classification" = each.value.classification
  })
  policy_admin_role_arns = var.bucket_admin_role_arns

  lifecycle_rules = [{
    id                         = "${each.key}-retention"
    transitions                = var.bucket_lifecycle[each.key].transition_days == null ? [] : [{ days = var.bucket_lifecycle[each.key].transition_days, storage_class = each.value.storage_class }]
    expiration_days            = var.bucket_lifecycle[each.key].expiration_days
    noncurrent_expiration_days = each.value.noncurrent_days
  }]
}

# The provider region must match var.region, otherwise names and tags lie about data residency.
resource "terraform_data" "region_guard" {
  input = var.region

  lifecycle {
    precondition {
      condition     = data.aws_region.current.region == var.region
      error_message = "var.region does not match the provider region."
    }
  }
}
