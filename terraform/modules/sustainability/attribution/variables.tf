variable "environment" {
  description = "Environment name."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "tags" {
  description = "Tags merged onto every resource (mandatory hestia:* tags normally come from provider default_tags)."
  type        = map(string)
  default     = {}
}

variable "allowed_account_ids" {
  description = "Account IDs allowed to use the exports key. Supplied at run time (TF_VAR_account_id); never committed."
  type        = list(string)

  validation {
    condition     = length(var.allowed_account_ids) > 0 && alltrue([for id in var.allowed_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "allowed_account_ids must be a non-empty list of 12-digit account IDs."
  }
}

variable "key_admin_role_arns" {
  description = "Roles that administer (not use) the exports key."
  type        = list(string)
  default     = []
}

variable "bucket_admin_role_arns" {
  description = "Only these roles may change the exports and Athena results bucket policies or ACLs."
  type        = list(string)

  validation {
    condition     = length(var.bucket_admin_role_arns) > 0
    error_message = "At least one bucket admin role ARN is required."
  }
}

variable "access_log_bucket" {
  description = "SSE-S3 bucket for server access logs of the exports and results buckets, or null."
  type        = string
  default     = null
}

variable "export_retention_days" {
  description = "Days the cost and carbon exports are kept."
  type        = number
  default     = 1095

  validation {
    condition     = var.export_retention_days >= 400
    error_message = "export_retention_days must be at least 400, so a full year plus the CCFT delay stays queryable."
  }
}
