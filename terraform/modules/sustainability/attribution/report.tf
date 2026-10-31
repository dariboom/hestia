# Monthly EED Article 12-aligned report: EventBridge Scheduler runs the eed_report Lambda, which queries the
# carbon workgroup and writes reports/eed-art12/<yyyy-mm>.json to the audit bucket (Object Lock keeps it).
# The security stack must list this role in key_usage_role_arns["audit"] (role name: see README).

locals {
  report_function = "${local.name_prefix}-eed-report"
  glue_arn_prefix = "arn:${local.partition}:glue:${data.aws_region.current.region}:${local.account_id}"
}

resource "aws_cloudwatch_log_group" "eed_report" {
  name              = "/aws/lambda/${local.report_function}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "eed_report" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.eed_report.arn}:*"]
  }

  statement {
    sid       = "RunCarbonQueries"
    actions   = ["athena:GetNamedQuery", "athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults"]
    resources = [aws_athena_workgroup.carbon.arn]
  }

  statement {
    sid     = "ReadCarbonCatalog"
    actions = ["glue:GetDatabase", "glue:GetTable", "glue:GetPartitions"]
    resources = concat(
      ["${local.glue_arn_prefix}:catalog", "${local.glue_arn_prefix}:database/${aws_glue_catalog_database.carbon.name}"],
      [for t in aws_glue_catalog_table.this : "${local.glue_arn_prefix}:table/${t.database_name}/${t.name}"],
    )
  }

  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [module.exports_bucket.arn, module.athena_results.arn]
  }

  statement {
    sid       = "ReadExports"
    actions   = ["s3:GetObject"]
    resources = ["${module.exports_bucket.arn}/cur/*", "${module.exports_bucket.arn}/carbon/*"]
  }

  statement {
    sid       = "AthenaResults"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${module.athena_results.arn}/results/*"]
  }

  statement {
    sid       = "ExportsKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [module.exports_key.key_arn]
  }

  statement {
    sid       = "WriteReport"
    actions   = ["s3:PutObject"]
    resources = ["${var.audit_bucket_arn}/reports/eed-art12/*"]
  }

  statement {
    sid       = "AuditKeyViaS3"
    actions   = ["kms:GenerateDataKey"]
    resources = [var.audit_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eed_report" {
  name                 = local.report_function
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
  permissions_boundary = local.boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy" "eed_report" {
  name   = local.report_function
  role   = aws_iam_role.eed_report.id
  policy = data.aws_iam_policy_document.eed_report.json
}

resource "aws_lambda_function" "eed_report" {
  #checkov:skip=CKV_AWS_117:Runs outside the VPC: it only calls regional Athena and S3 APIs and touches no VPC data, so a NAT path would add cost and nothing else.
  #checkov:skip=CKV_AWS_116:Async failures are retried by EventBridge Scheduler; a monthly run can be re-invoked by hand with {"month": "yyyy-mm"}.
  #checkov:skip=CKV_AWS_50:X-Ray needs xray:PutTraceSegments on Resource "*"; errors in the log group cover a monthly batch job.
  #checkov:skip=CKV_AWS_272:Code is zipped from this repository by CI, not uploaded by a third party; code signing adds no provenance here.
  function_name                  = local.report_function
  description                    = "Monthly EED Article 12-aligned carbon report"
  role                           = aws_iam_role.eed_report.arn
  runtime                        = "python3.12"
  architectures                  = ["arm64"]
  handler                        = "handler.handler"
  filename                       = var.package_path
  source_code_hash               = filebase64sha256(var.package_path)
  timeout                        = 900
  memory_size                    = 256
  reserved_concurrent_executions = 1
  kms_key_arn                    = module.exports_key.key_arn
  tags                           = var.tags

  environment {
    variables = {
      ENVIRONMENT        = var.environment
      WORKGROUP          = aws_athena_workgroup.carbon.name
      EED_QUERY_ID       = aws_athena_named_query.this["eed_art12_report"].id
      TENANT_QUERY_ID    = aws_athena_named_query.this["tenant_carbon_monthly"].id
      AUDIT_BUCKET       = element(split(":", var.audit_bucket_arn), 5)
      DATACENTRE_FACTORS = jsonencode(var.datacentre_factors)
      REPORT_LAG_MONTHS  = tostring(var.report_lag_months)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.eed_report.name
  }

  depends_on = [aws_iam_role_policy.eed_report]
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "InvokeReport"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.eed_report.arn]
  }
}

resource "aws_iam_role" "scheduler" {
  name                 = "${local.report_function}-scheduler"
  assume_role_policy   = data.aws_iam_policy_document.scheduler_assume.json
  permissions_boundary = local.boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${local.report_function}-scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "eed_report" {
  name                         = local.report_function
  schedule_expression          = var.report_schedule
  schedule_expression_timezone = "UTC"
  kms_key_arn                  = module.exports_key.key_arn

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.eed_report.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }
}
