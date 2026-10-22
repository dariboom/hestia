output "role_arn" {
  description = "Role ARN, for the eks.amazonaws.com/role-arn service account annotation or an add-on's service_account_role_arn."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Role name."
  value       = aws_iam_role.this.name
}
