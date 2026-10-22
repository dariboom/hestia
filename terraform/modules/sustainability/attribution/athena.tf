# Glue tables over the exports (partition projection, so no crawler and no partition maintenance), an enforced
# Athena workgroup with KMS-encrypted results, and the named queries the eed_report Lambda runs. Each query takes
# exactly one execution parameter, the month as 'yyyy-mm'.

locals {
  glue_database = "hestia_${var.environment}_carbon"
  exports_root  = "s3://${module.exports_bucket.id}"

  tables = {
    cur = {
      columns  = local.cur_columns
      location = "${local.exports_root}/cur/${local.exports.cur.name}/data/"
      partitions = {
        billing_period = {
          "projection.billing_period.type"          = "date"
          "projection.billing_period.format"        = "yyyy-MM"
          "projection.billing_period.range"         = "${var.projection_start_month},NOW"
          "projection.billing_period.interval"      = "1"
          "projection.billing_period.interval.unit" = "MONTHS"
        }
      }
      template = "${local.exports_root}/cur/${local.exports.cur.name}/data/BILLING_PERIOD=$${billing_period}"
    }
    carbon_emissions = {
      columns  = local.carbon_columns
      location = "${local.exports_root}/carbon/${local.exports.carbon.name}/data/"
      partitions = {
        model_version = {
          "projection.model_version.type"   = "enum"
          "projection.model_version.values" = var.carbon_model_version
        }
        usage_period = {
          "projection.usage_period.type"          = "date"
          "projection.usage_period.format"        = "yyyy-MM"
          "projection.usage_period.range"         = "${var.projection_start_month},NOW"
          "projection.usage_period.interval"      = "1"
          "projection.usage_period.interval.unit" = "MONTHS"
        }
      }
      template = "${local.exports_root}/carbon/${local.exports.carbon.name}/data/model_version=$${model_version}/usage_period=$${usage_period}"
    }
  }

  queries = {
    eed_art12_report = {
      description = "CCFT emissions per region for one month (parameter: 'yyyy-mm')."
      sql         = <<-SQL
        WITH p AS (SELECT CAST(? AS varchar) AS month)
        SELECT c.region_code,
               SUM(c.total_lbm_emissions_value) AS lbm_mtco2e,
               SUM(c.total_mbm_emissions_value) AS mbm_mtco2e
        FROM carbon_emissions c CROSS JOIN p
        WHERE c.usage_period = p.month
        GROUP BY c.region_code
      SQL
    }
    tenant_carbon_monthly = {
      description = "CCFT emissions per tenant for one month, split by cost share per region and service (parameter: 'yyyy-mm')."
      # Emissions with no matching cost, and untagged cost, go to tenant 'shared', so tenant totals equal region totals.
      sql = <<-SQL
        WITH p AS (SELECT CAST(? AS varchar) AS month),
        cost AS (
          SELECT u.product_region_code AS region_code,
                 u.line_item_product_code AS product_code,
                 COALESCE(NULLIF(element_at(u.resource_tags, 'user_hestia_tenant'), ''), 'shared') AS tenant,
                 SUM(COALESCE(u.split_line_item_split_cost, u.line_item_unblended_cost)) AS cost
          FROM cur u CROSS JOIN p
          WHERE u.billing_period = p.month
            AND u.line_item_line_item_type IN ('Usage', 'DiscountedUsage', 'SavingsPlanCoveredUsage')
          GROUP BY 1, 2, 3
        ),
        share AS (
          SELECT region_code, product_code, tenant,
                 cost / NULLIF(SUM(cost) OVER (PARTITION BY region_code, product_code), 0) AS share
          FROM cost
        ),
        emissions AS (
          SELECT c.region_code, c.product_code,
                 SUM(c.total_lbm_emissions_value) AS lbm,
                 SUM(c.total_mbm_emissions_value) AS mbm
          FROM carbon_emissions c CROSS JOIN p
          WHERE c.usage_period = p.month
          GROUP BY 1, 2
        )
        SELECT COALESCE(s.tenant, 'shared') AS tenant,
               SUM(e.lbm * COALESCE(s.share, 1)) AS lbm_mtco2e,
               SUM(e.mbm * COALESCE(s.share, 1)) AS mbm_mtco2e
        FROM emissions e
        LEFT JOIN share s ON s.region_code = e.region_code AND s.product_code = e.product_code
        GROUP BY 1
      SQL
    }
  }
}

resource "aws_glue_catalog_database" "carbon" {
  name        = local.glue_database
  description = "Hestia ${var.environment} CUR 2.0 and carbon exports"
  tags        = var.tags
}

resource "aws_glue_catalog_table" "this" {
  for_each = local.tables

  name          = each.key
  database_name = aws_glue_catalog_database.carbon.name
  table_type    = "EXTERNAL_TABLE"

  parameters = merge(
    {
      classification                = "parquet"
      "projection.enabled"          = "true"
      "storage.location.template"   = each.value.template
      EXTERNAL                      = "TRUE"
      "parquet.compression"         = "SNAPPY"
      "has_encrypted_data"          = "true"
      "projection.columns.observed" = join(",", keys(each.value.partitions))
    },
    merge(values(each.value.partitions)...)
  )

  dynamic "partition_keys" {
    for_each = keys(each.value.partitions)
    content {
      name = partition_keys.value
      type = "string"
    }
  }

  storage_descriptor {
    location      = each.value.location
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = each.value.columns
      content {
        name = columns.key
        type = columns.value
      }
    }
  }
}

module "athena_results" {
  source = "../../s3-bucket"

  name                   = "${local.name_prefix}-carbon-athena-${local.account_id}"
  kms_key_arn            = module.exports_key.key_arn
  tags                   = local.bucket_tags
  policy_admin_role_arns = var.bucket_admin_role_arns
  access_log_bucket      = var.access_log_bucket

  lifecycle_rules = [{
    id                         = "athena-results"
    expiration_days            = 30
    noncurrent_expiration_days = 1
  }]
}

resource "aws_athena_workgroup" "carbon" {
  name        = "${local.name_prefix}-carbon"
  description = "Carbon attribution and EED reporting queries"
  tags        = var.tags

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff

    result_configuration {
      output_location       = "s3://${module.athena_results.id}/results/"
      expected_bucket_owner = local.account_id

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = module.exports_key.key_arn
      }
    }
  }
}

resource "aws_athena_named_query" "this" {
  for_each = local.queries

  name        = each.key
  description = each.value.description
  workgroup   = aws_athena_workgroup.carbon.id
  database    = aws_glue_catalog_database.carbon.name
  query       = each.value.sql
}

# Public dashboard carbon label inputs; values come from the caller, never invented here.
resource "aws_ssm_parameter" "label_coefficients" {
  #checkov:skip=CKV2_AWS_34:Public, non-secret coefficients shared as an SSM String per the cross-stack convention (plan Global Constraints)
  name        = "/hestia/${var.environment}/carbon/label-coefficients"
  description = "gCO2e per vCPU-second and per GB scanned for the public carbon label, with their source"
  type        = "String"
  value       = jsonencode(var.label_coefficients)
  tags        = var.tags
}
