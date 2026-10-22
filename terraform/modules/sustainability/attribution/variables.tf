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

variable "carbon_model_version" {
  description = "CCFT model_version partition of the carbon export to query (e.g. v3.0.0). Pinning one version avoids double counting when AWS restates under a new model."
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.carbon_model_version))
    error_message = "carbon_model_version must look like v<major>.<minor>.<patch>."
  }
}

variable "projection_start_month" {
  description = "First month (yyyy-MM) the Athena partition projection covers."
  type        = string
  default     = "2025-01"

  validation {
    condition     = can(regex("^[0-9]{4}-(0[1-9]|1[0-2])$", var.projection_start_month))
    error_message = "projection_start_month must be yyyy-MM."
  }
}

variable "athena_bytes_scanned_cutoff" {
  description = "Per-query scan limit in bytes for the carbon workgroup."
  type        = number
  default     = 10737418240 # 10 GiB

  validation {
    condition     = var.athena_bytes_scanned_cutoff >= 10485760
    error_message = "athena_bytes_scanned_cutoff must be at least 10 MiB (Athena minimum)."
  }
}

variable "label_coefficients" {
  description = "Public carbon label coefficients and where they come from; published as SSM String /hestia/<env>/carbon/label-coefficients."
  type = object({
    gco2e_per_vcpu_second = number
    gco2e_per_gb_scanned  = number
    source                = string
  })

  validation {
    condition     = var.label_coefficients.gco2e_per_vcpu_second >= 0 && var.label_coefficients.gco2e_per_gb_scanned >= 0 && length(trimspace(var.label_coefficients.source)) > 0
    error_message = "label_coefficients must be non-negative and name their source."
  }
}
