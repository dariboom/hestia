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

variable "audit_bucket_arn" {
  description = "Audit bucket (security module output audit_bucket_arn); the report goes to reports/eed-art12/."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9.-]+$", var.audit_bucket_arn))
    error_message = "audit_bucket_arn must be an S3 bucket ARN."
  }
}

variable "audit_kms_key_arn" {
  description = "The audit bucket's KMS key (security module kms_key_arns[\"audit\"])."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.audit_kms_key_arn))
    error_message = "audit_kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "log_kms_key_arn" {
  description = "KMS key for the Lambda log group; its policy must allow logs.<region>.amazonaws.com (security module 'logs' key)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.log_kms_key_arn))
    error_message = "log_kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "log_retention_days" {
  description = "Retention of the report Lambda logs; capped at 400 days."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch retention value <= 400."
  }
}

variable "package_path" {
  description = "Path to the report zip, built by CI from ../src/eed_report/handler.py (see README)."
  type        = string

  validation {
    condition     = endswith(var.package_path, ".zip")
    error_message = "package_path must point to a .zip file."
  }
}

variable "datacentre_factors" {
  description = "AWS-published PUE and WUE (L/kWh) per region code, with the page they come from. Regions missing here are reported with null factors."
  type = map(object({
    pue        = number
    wue        = number
    source_url = string
  }))

  validation {
    condition     = alltrue([for f in values(var.datacentre_factors) : f.pue >= 1 && f.wue >= 0 && startswith(f.source_url, "https://")])
    error_message = "Each factor needs pue >= 1, wue >= 0 and an https source_url."
  }
}

variable "report_lag_months" {
  description = "How many months back the scheduled run reports; CCFT data for a month arrives after it ends."
  type        = number
  default     = 1

  validation {
    condition     = var.report_lag_months >= 1 && var.report_lag_months <= 6
    error_message = "report_lag_months must be 1 to 6."
  }
}

variable "report_schedule" {
  description = "EventBridge Scheduler expression (UTC) for the monthly report."
  type        = string
  default     = "cron(0 6 25 * ? *)"
}
