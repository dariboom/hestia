output "exports_bucket_arn" {
  description = "DE bucket holding the CUR 2.0 and carbon exports."
  value       = module.exports_bucket.arn
}

output "athena_workgroup_name" {
  description = "Enforced Athena workgroup for the carbon queries."
  value       = aws_athena_workgroup.carbon.name
}

output "label_coefficients_parameter_name" {
  description = "SSM String holding the public carbon label coefficients."
  value       = aws_ssm_parameter.label_coefficients.name
}

output "eed_report_role_arn" {
  description = "Report Lambda role; add it to the security stack's key_usage_role_arns[\"audit\"] so it can write to the audit bucket."
  value       = aws_iam_role.eed_report.arn
}
