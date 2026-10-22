output "private_zone_id" {
  description = "Private hosted zone shared by the regional VPCs."
  value       = aws_route53_zone.private.zone_id
}

output "public_zone_id" {
  description = "Public hosted zone, or null when both enable_public_ingress and enable_cloudfront are false."
  value       = one(aws_route53_zone.public[*].zone_id)
}

output "cloudfront_distribution_id" {
  description = "Dashboard distribution ID, or null when enable_cloudfront = false."
  value       = one(aws_cloudfront_distribution.dashboard[*].id)
}

output "dashboard_origin_policy_json" {
  description = "Bucket policy statement for dashboard_origin (modules/s3-bucket additional_policy_statements), or null when enable_cloudfront = false."
  value       = one(data.aws_iam_policy_document.dashboard_origin[*].json)
}
