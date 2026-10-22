# Per-tenant carbon attribution, account-wide, so one instance per account in eu-central-1: cost allocation
# tags, and BCM Data Exports of CUR 2.0 (split cost allocation data for EKS) and CCFT carbon emissions into a
# DE bucket. The export API is us-east-1 only; the data itself never leaves eu-central-1 (ADR-005).

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix  = "hestia-${var.environment}-de"
  partition    = data.aws_partition.current.partition
  account_id   = data.aws_caller_identity.current.account_id
  boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/hestia-${var.environment}-boundary"
  bucket_tags  = merge(var.tags, { "hestia:environment" = var.environment })
  export_arns  = "arn:${local.partition}:bcm-data-exports:us-east-1:${local.account_id}:export/*"

  exports = {
    cur = {
      name = "${local.name_prefix}-cur2"
      # Data Exports takes column lists only (no aggregation); keep in sync with glue.tf.
      query = "SELECT ${join(", ", keys(local.cur_columns))} FROM COST_AND_USAGE_REPORT"
      table_configurations = {
        COST_AND_USAGE_REPORT = {
          TIME_GRANULARITY                      = "DAILY"
          INCLUDE_RESOURCES                     = "TRUE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "TRUE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"
          BILLING_VIEW_ARN                      = "arn:${local.partition}:billing::${local.account_id}:billingview/primary"
        }
      }
    }
    carbon = {
      name                 = "${local.name_prefix}-carbon"
      query                = "SELECT ${join(", ", keys(local.carbon_columns))} FROM CARBON_EMISSIONS"
      table_configurations = null # the carbon table has none
    }
  }

  # CUR 2.0 columns used by the attribution queries.
  cur_columns = {
    line_item_usage_start_date         = "timestamp"
    line_item_usage_account_id         = "string"
    line_item_line_item_type           = "string"
    line_item_product_code             = "string"
    line_item_resource_id              = "string"
    line_item_unblended_cost           = "double"
    product_region_code                = "string"
    resource_tags                      = "map<string,string>"
    split_line_item_parent_resource_id = "string"
    split_line_item_split_cost         = "double"
    split_line_item_unused_cost        = "double"
  }

  carbon_columns = {
    payer_account_id          = "string"
    usage_account_id          = "string"
    region_code               = "string"
    location                  = "string"
    product_code              = "string"
    total_lbm_emissions_value = "double"
    total_lbm_emissions_unit  = "string"
    total_mbm_emissions_value = "double"
    total_mbm_emissions_unit  = "string"
    usage_period_start        = "timestamp"
    usage_period_end          = "timestamp"
    last_refresh_timestamp    = "timestamp"
  }
}

# Cost allocation tags are account-wide and only take effect for usage after activation.
resource "aws_ce_cost_allocation_tag" "this" {
  for_each = toset(["hestia:tenant", "hestia:workload"])

  tag_key = each.key
  status  = "Active"
}

module "exports_key" {
  source = "../../kms-key"

  alias               = "${local.name_prefix}-cost-exports"
  description         = "BCM Data Exports (CUR 2.0, carbon) and their Athena results"
  tags                = var.tags
  allowed_account_ids = var.allowed_account_ids
  admin_role_arns     = var.key_admin_role_arns
  service_principals  = [{ service = "bcm-data-exports.amazonaws.com", source_arn_like = local.export_arns }]
}

data "aws_iam_policy_document" "exports_delivery" {
  statement {
    sid       = "DataExportsDelivery"
    actions   = ["s3:PutObject", "s3:GetBucketPolicy"]
    resources = [module.exports_bucket.arn, "${module.exports_bucket.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["bcm-data-exports.amazonaws.com", "billingreports.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.export_arns, "arn:${local.partition}:cur:us-east-1:${local.account_id}:definition/*"]
    }
  }
}

module "exports_bucket" {
  source = "../../s3-bucket"

  name                         = "${local.name_prefix}-cost-exports-${local.account_id}"
  kms_key_arn                  = module.exports_key.key_arn
  tags                         = local.bucket_tags
  policy_admin_role_arns       = var.bucket_admin_role_arns
  access_log_bucket            = var.access_log_bucket
  additional_policy_statements = [data.aws_iam_policy_document.exports_delivery.json]

  lifecycle_rules = [{
    id                         = "exports-retention"
    transitions                = [{ days = 90, storage_class = "STANDARD_IA" }]
    expiration_days            = var.export_retention_days
    noncurrent_expiration_days = 7 # OVERWRITE_REPORT replaces each month's files while it is open
  }]
}

resource "aws_bcmdataexports_export" "this" {
  for_each = local.exports
  provider = aws.us_east_1

  export {
    name        = each.value.name
    description = "Hestia ${var.environment} ${each.key} export for carbon attribution"

    data_query {
      query_statement      = each.value.query
      table_configurations = each.value.table_configurations
    }

    destination_configurations {
      s3_destination {
        s3_bucket = module.exports_bucket.id
        s3_prefix = each.key
        s3_region = data.aws_region.current.region

        s3_output_configurations {
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
          overwrite   = "OVERWRITE_REPORT"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = data.aws_region.current.region == "eu-central-1"
      error_message = "Carbon attribution runs once per account, in eu-central-1 (ADR-005)."
    }
  }
}
