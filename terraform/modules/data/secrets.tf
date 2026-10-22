# Secret containers only: values are written out-of-band by the external CI/CD secret store and read
# at runtime through IAM (IRSA / task roles). No secret version or SecureString value ever passes
# through Terraform (enforced by policies/secrets.rego and the `make secrets` grep gate).

resource "aws_secretsmanager_secret" "app" {
  #checkov:skip=CKV2_AWS_57:Rotation is owned by the external secret store; Terraform holds no value to rotate.
  for_each = toset(var.app_secret_names)

  name                    = "hestia/${var.environment}/${local.region_code}/app/${each.key}"
  description             = "Hestia ${var.environment} app secret '${each.key}'; value injected by external CI/CD secret store."
  kms_key_id              = var.secrets_kms_key_arn
  recovery_window_in_days = var.environment == "prod" ? 30 : 7

  tags = merge(var.tags, {
    "hestia:environment"         = var.environment
    "hestia:data-classification" = "secret"
  })

  lifecycle {
    precondition {
      condition     = var.secrets_kms_key_arn != null
      error_message = "secrets_kms_key_arn is required when app_secret_names is set (no AWS-managed key for secrets)."
    }
  }
}

# SecureString parameters are created out-of-band; only their names are referenced, so consumers
# can be granted ssm:GetParameter on exact ARNs.
locals {
  ssm_secure_parameter_arns = {
    for n in var.ssm_secure_parameter_names :
    n => "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${local.account_id}:parameter${n}"
  }
}
