# Per-region customer-managed keys. Other modules take these ARNs as inputs and never edit key policies,
# so every service principal they rely on is granted here (see each module's "Key policies required").

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  region_code = { "eu-central-1" = "de", "eu-west-3" = "fr" }[var.region]
  name_prefix = "hestia-${var.environment}-${local.region_code}"
  partition   = data.aws_partition.current.partition
  account_id  = data.aws_caller_identity.current.account_id
  arn_prefix  = "arn:${local.partition}"

  keys = {
    data = {
      description        = "Application data at rest: RDS, S3 data buckets"
      service_principals = []
    }
    logs = {
      description = "CloudWatch Logs, VPC flow logs and WAF logs"
      service_principals = [
        {
          service                  = "logs.${var.region}.amazonaws.com"
          source_arn_like          = "${local.arn_prefix}:logs:${var.region}:${local.account_id}:log-group:*"
          source_arn_condition_key = "kms:EncryptionContext:aws:logs:arn"
        },
        { service = "delivery.logs.amazonaws.com" },
      ]
    }
    audit = {
      description = "CloudTrail, AWS Config delivery and security alerts"
      service_principals = [
        {
          service         = "cloudtrail.amazonaws.com"
          source_arn_like = "${local.arn_prefix}:cloudtrail:*:${local.account_id}:trail/hestia-${var.environment}-*"
        },
      ]
    }
    secrets = {
      description        = "Secrets Manager secrets and SSM SecureString parameters"
      service_principals = []
    }
    compute = {
      description = "EKS secrets envelope encryption, EBS volumes, Lambda environment and schedules"
      service_principals = [
        {
          service         = "scheduler.amazonaws.com"
          source_arn_like = "${local.arn_prefix}:scheduler:${var.region}:${local.account_id}:schedule/*/${local.name_prefix}-*"
        },
      ]
    }
  }
}

module "kms" {
  source   = "../kms-key"
  for_each = local.keys

  alias               = "${local.name_prefix}-${each.key}"
  description         = "${local.name_prefix} ${each.key}: ${each.value.description}"
  tags                = var.tags
  allowed_account_ids = var.allowed_account_ids
  admin_role_arns     = var.key_admin_role_arns
  usage_role_arns     = concat(lookup(var.key_usage_role_arns, each.key, []), each.key == "audit" ? [aws_iam_role.config.arn] : [])
  service_principals  = each.value.service_principals
}
