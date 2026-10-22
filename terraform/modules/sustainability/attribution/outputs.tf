output "exports_bucket_arn" {
  description = "DE bucket holding the CUR 2.0 and carbon exports."
  value       = module.exports_bucket.arn
}
