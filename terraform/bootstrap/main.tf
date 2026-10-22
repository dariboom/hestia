locals {
  # One state bucket and key per region (ADR-004): de/peering/edge roots use DE, fr uses FR.
  # The account ID suffix keeps bucket names globally unique without hard-coding anything.
  state_bucket_name = {
    de = "hestia-${var.environment}-de-tfstate-${var.account_id}"
    fr = "hestia-${var.environment}-fr-tfstate-${var.account_id}"
  }

  state_lifecycle_rules = [{
    id                         = "state-noncurrent"
    noncurrent_expiration_days = 90
  }]

  state_usage_role_arns = [aws_iam_role.deploy.arn, aws_iam_role.readonly.arn]
  state_writer_arns     = concat([aws_iam_role.deploy.arn], var.admin_role_arns)
}

# Only tf-deploy (and humans via admin roles) may write or delete state objects.
data "aws_iam_policy_document" "state_write_guard" {
  for_each = local.state_bucket_name

  statement {
    sid       = "DenyStateWritesExceptDeploy"
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["arn:${local.partition}:s3:::${each.value}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = local.state_writer_arns
    }
  }
}

# --- DE (eu-central-1)

module "state_kms_de" {
  source = "../modules/kms-key"

  alias               = "hestia-${var.environment}-de-tfstate"
  description         = "Terraform state encryption for hestia ${var.environment} (DE)"
  allowed_account_ids = [var.account_id]
  admin_role_arns     = var.admin_role_arns
  usage_role_arns     = local.state_usage_role_arns
}

module "state_bucket_de" {
  source = "../modules/s3-bucket"

  name                         = local.state_bucket_name.de
  kms_key_arn                  = module.state_kms_de.key_arn
  tags                         = { "hestia:environment" = var.environment }
  lifecycle_rules              = local.state_lifecycle_rules
  policy_admin_role_arns       = var.admin_role_arns
  additional_policy_statements = [data.aws_iam_policy_document.state_write_guard["de"].json]
}

# --- FR (eu-west-3)

module "state_kms_fr" {
  source    = "../modules/kms-key"
  providers = { aws = aws.fr }

  alias               = "hestia-${var.environment}-fr-tfstate"
  description         = "Terraform state encryption for hestia ${var.environment} (FR)"
  allowed_account_ids = [var.account_id]
  admin_role_arns     = var.admin_role_arns
  usage_role_arns     = local.state_usage_role_arns
}

module "state_bucket_fr" {
  source    = "../modules/s3-bucket"
  providers = { aws = aws.fr }

  name                         = local.state_bucket_name.fr
  kms_key_arn                  = module.state_kms_fr.key_arn
  tags                         = { "hestia:environment" = var.environment }
  lifecycle_rules              = local.state_lifecycle_rules
  policy_admin_role_arns       = var.admin_role_arns
  additional_policy_statements = [data.aws_iam_policy_document.state_write_guard["fr"].json]
}
