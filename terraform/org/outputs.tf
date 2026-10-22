output "scp_ids" {
  description = "Guardrail SCP IDs by name."
  value       = { for k, p in aws_organizations_policy.this : k => p.id }
}
