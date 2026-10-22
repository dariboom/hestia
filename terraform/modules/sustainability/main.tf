# Carbon-intensity signal (ADR-008): a collector Lambda, run every 15 minutes by EventBridge
# Scheduler, publishes grid gCO2e/kWh for DE-LU and FR to CloudWatch and SSM. Batch workloads
# read the SSM parameters through signal_read_policy_json.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  region_code   = { "eu-central-1" = "de", "eu-west-3" = "fr" }[var.region]
  name_prefix   = "hestia-${var.environment}-${local.region_code}"
  function_name = "${local.name_prefix}-carbon-signal"
  partition     = data.aws_partition.current.partition
  account_id    = data.aws_caller_identity.current.account_id
  boundary_arn  = "arn:${local.partition}:iam::${local.account_id}:policy/hestia-${var.environment}-boundary"
  signal_path   = "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/hestia/${var.environment}/carbon"
}

resource "aws_cloudwatch_log_group" "carbon_signal" {
  name              = "/aws/lambda/${local.function_name}"
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

data "aws_iam_policy_document" "carbon_signal" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.carbon_signal.arn}:*"]
  }

  statement {
    sid       = "ReadEntsoeToken"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.entsoe_token_secret_arn]
  }

  statement {
    sid       = "DecryptEntsoeToken"
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "DecryptEnvironment"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:LambdaFunctionName"
      values   = [local.function_name]
    }
  }

  statement {
    sid       = "WriteSignal"
    actions   = ["ssm:PutParameter"]
    resources = ["${local.signal_path}/*"]
  }

  # PutMetricData has no resource-level permissions; the namespace condition scopes it.
  statement {
    sid       = "PutCarbonMetric"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Hestia/Carbon"]
    }
  }
}

resource "aws_iam_role" "carbon_signal" {
  name                 = local.function_name
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
  permissions_boundary = local.boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy" "carbon_signal" {
  name   = local.function_name
  role   = aws_iam_role.carbon_signal.id
  policy = data.aws_iam_policy_document.carbon_signal.json
}

resource "aws_lambda_function" "carbon_signal" {
  #checkov:skip=CKV_AWS_117:Runs outside the VPC by design (ADR-008): it only calls the public ENTSO-E API and regional AWS APIs and touches no VPC data, so a NAT path would add cost and nothing else.
  #checkov:skip=CKV_AWS_116:Async failures are retried by EventBridge Scheduler and the next run supersedes a missed one 15 minutes later; a DLQ would hold stale signals.
  #checkov:skip=CKV_AWS_50:X-Ray needs xray:PutTraceSegments on Resource "*"; errors and the CloudWatch metric already cover a 15-minute batch job.
  #checkov:skip=CKV_AWS_272:Code is zipped from this repository by CI, not uploaded by a third party; code signing adds no provenance here.
  function_name                  = local.function_name
  description                    = "Grid carbon intensity for DE-LU and FR (ADR-008)"
  role                           = aws_iam_role.carbon_signal.arn
  runtime                        = "python3.12"
  architectures                  = ["arm64"]
  handler                        = "handler.handler"
  filename                       = var.package_path
  source_code_hash               = filebase64sha256(var.package_path)
  timeout                        = 120
  memory_size                    = 256
  reserved_concurrent_executions = 1
  kms_key_arn                    = var.kms_key_arn
  tags                           = var.tags

  environment {
    variables = {
      ENVIRONMENT             = var.environment
      ENTSOE_TOKEN_SECRET_ARN = var.entsoe_token_secret_arn
      BEST_WINDOW_HOURS       = tostring(var.best_window_hours)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.carbon_signal.name
  }

  depends_on = [aws_iam_role_policy.carbon_signal]

  lifecycle {
    precondition {
      condition     = data.aws_region.current.region == var.region
      error_message = "var.region does not match the provider region."
    }
  }
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
    sid       = "InvokeCollector"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.carbon_signal.arn]
  }
}

resource "aws_iam_role" "scheduler" {
  name                 = "${local.function_name}-scheduler"
  assume_role_policy   = data.aws_iam_policy_document.scheduler_assume.json
  permissions_boundary = local.boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${local.function_name}-scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "carbon_signal" {
  name                = local.function_name
  schedule_expression = "rate(15 minutes)"
  kms_key_arn         = var.kms_key_arn

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.carbon_signal.arn
    role_arn = aws_iam_role.scheduler.arn

    # A run older than 10 minutes is superseded by the next one.
    retry_policy {
      maximum_event_age_in_seconds = 600
      maximum_retry_attempts       = 2
    }
  }
}

# For batch workloads (irsa-role policy_json): read the signal, nothing else.
data "aws_iam_policy_document" "signal_read" {
  statement {
    sid       = "ReadCarbonSignal"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.signal_path, "${local.signal_path}/*"]
  }
}
