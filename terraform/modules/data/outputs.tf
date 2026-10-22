output "bucket_arns" {
  description = "Data bucket ARNs keyed by purpose: artifacts, logs, backups."
  value       = { for k, b in module.bucket : k => b.arn }
}

output "app_secret_arns" {
  description = "Secrets Manager container ARNs keyed by app secret name (no values)."
  value       = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
}

output "ssm_secure_parameter_arns" {
  description = "SecureString parameter ARNs keyed by name, for ssm:GetParameter grants (no values)."
  value       = local.ssm_secure_parameter_arns
}
