output "id" {
  description = "Bucket name."
  value       = aws_s3_bucket.this.id
}

output "arn" {
  description = "Bucket ARN."
  value       = aws_s3_bucket.this.arn
}

output "domain_name" {
  description = "Regional bucket domain name (for CloudFront OAC origins)."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}
