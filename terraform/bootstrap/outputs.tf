output "state_buckets" {
  description = "State bucket names per region code; feed into live/<env>/<stack>/backend.tf in place of <STATE_BUCKET_NAME>."
  value = {
    de = module.state_bucket_de.id
    fr = module.state_bucket_fr.id
  }
}

output "state_kms_key_arns" {
  description = "State KMS key ARNs per region code; used as the backend kms_key_id."
  value = {
    de = module.state_kms_de.key_arn
    fr = module.state_kms_fr.key_arn
  }
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "tf_deploy_role_arn" {
  description = "Role assumed by CI plan/apply jobs in the GitHub environment named after var.environment."
  value       = aws_iam_role.deploy.arn
}

output "tf_readonly_role_arn" {
  description = "Role assumed by CI jobs that only read state (GitHub environment <env>-readonly)."
  value       = aws_iam_role.readonly.arn
}

output "permissions_boundary_arn" {
  description = "Boundary every role created by CI must carry (permissions_boundary argument)."
  value       = aws_iam_policy.boundary.arn
}
