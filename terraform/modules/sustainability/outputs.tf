output "function_arn" {
  description = "Carbon-signal collector Lambda."
  value       = aws_lambda_function.carbon_signal.arn
}

output "signal_parameter_path" {
  description = "SSM path holding <zone>/current and <zone>/best_window (JSON String parameters)."
  value       = "/hestia/${var.environment}/carbon"
}

output "signal_read_policy_json" {
  description = "Read-only policy for the signal; pass as irsa-role policy_json for carbon-aware batch CronJobs."
  value       = data.aws_iam_policy_document.signal_read.json
}
