output "state_buckets" {
  description = "State bucket names per region code; feed into live/<env>/<stack>/backend.tf in place of <STATE_BUCKET_NAME>."
  value = {
    de = module.state_bucket_de.id
    fr = module.state_bucket_fr.id
  }
}

output "state_kms_key_arns" {
  description = "State KMS key ARNs per region code; used as the backend kms_key_id."
  value = {
    de = module.state_kms_de.key_arn
    fr = module.state_kms_fr.key_arn
  }
}
