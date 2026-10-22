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

output "replication_role_arn" {
  description = "Replication role ARN (null when replication is disabled)."
  value       = one(aws_iam_role.replication[*].arn)
}

output "db_instance_arn" {
  description = "DB instance ARN (null without a database); a replica stack takes the primary's as db_source_db_arn."
  value       = one(aws_db_instance.db[*].arn)
}

output "db_endpoint" {
  description = "DB endpoint host:port (null without a database)."
  value       = one(aws_db_instance.db[*].endpoint)
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed master user secret (primary only; ARN, never the value)."
  value       = try(aws_db_instance.db[0].master_user_secret[0].secret_arn, null)
}

output "db_security_group_id" {
  description = "Database security group ID (null without a database)."
  value       = one(aws_security_group.db[*].id)
}

output "db_backup_replication_arn" {
  description = "ARN of the replicated automated backups in this region (null when off)."
  value       = one(aws_db_instance_automated_backups_replication.db[*].id)
}
