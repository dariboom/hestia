output "bucket_arns" {
  description = "Data bucket ARNs keyed by purpose: artifacts, logs, backups."
  value       = { for k, b in module.bucket : k => b.arn }
}
