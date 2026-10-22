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
}

# --- DE (eu-central-1)

module "state_kms_de" {
  source = "../modules/kms-key"

  alias               = "hestia-${var.environment}-de-tfstate"
  description         = "Terraform state encryption for hestia ${var.environment} (DE)"
  allowed_account_ids = [var.account_id]
  admin_role_arns     = var.admin_role_arns
}

module "state_bucket_de" {
  source = "../modules/s3-bucket"

  name                   = local.state_bucket_name.de
  kms_key_arn            = module.state_kms_de.key_arn
  tags                   = { "hestia:environment" = var.environment }
  lifecycle_rules        = local.state_lifecycle_rules
  policy_admin_role_arns = var.admin_role_arns
}

# --- FR (eu-west-3)

module "state_kms_fr" {
  source    = "../modules/kms-key"
  providers = { aws = aws.fr }

  alias               = "hestia-${var.environment}-fr-tfstate"
  description         = "Terraform state encryption for hestia ${var.environment} (FR)"
  allowed_account_ids = [var.account_id]
  admin_role_arns     = var.admin_role_arns
}

module "state_bucket_fr" {
  source    = "../modules/s3-bucket"
  providers = { aws = aws.fr }

  name                   = local.state_bucket_name.fr
  kms_key_arn            = module.state_kms_fr.key_arn
  tags                   = { "hestia:environment" = var.environment }
  lifecycle_rules        = local.state_lifecycle_rules
  policy_admin_role_arns = var.admin_role_arns
}
