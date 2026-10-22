output "kms_key_arns" {
  description = "Key ARNs by name: data, logs, audit, secrets, compute."
  value       = { for k, m in module.kms : k => m.key_arn }
}

output "security_alerts_topic_arn" {
  description = "KMS-encrypted SNS topic receiving GuardDuty (severity >= 7) and Security Hub CRITICAL/HIGH findings."
  value       = aws_sns_topic.security_alerts.arn
}

output "audit_bucket_arn" {
  description = "WORM audit bucket of this region."
  value       = module.audit_bucket.arn
}

output "cloudtrail_arn" {
  description = "Multi-region trail ARN in home_region; null in the other region."
  value       = one(aws_cloudtrail.this[*].arn)
}
