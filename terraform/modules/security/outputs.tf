output "kms_key_arns" {
  description = "Key ARNs by name: data, logs, audit, secrets, compute."
  value       = { for k, m in module.kms : k => m.key_arn }
}
