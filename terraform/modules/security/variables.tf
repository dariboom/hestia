variable "region" {
  description = "Region of this security stack; must match the provider region."
  type        = string

  validation {
    condition     = contains(["eu-central-1", "eu-west-3"], var.region)
    error_message = "region must be eu-central-1 or eu-west-3 (ADR-005)."
  }
}

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

variable "home_region" {
  description = "Region that holds the cross-region aggregators, the global Config resources and the CloudTrail trail."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = contains(["eu-central-1", "eu-west-3"], var.home_region)
    error_message = "home_region must be eu-central-1 or eu-west-3 (ADR-005)."
  }
}

variable "securityhub_standards" {
  description = "Security Hub standards to enable, as the part of the standards ARN after 'standards/'."
  type        = list(string)
  default = [
    "aws-foundational-security-best-practices/v/1.0.0",
    "cis-aws-foundations-benchmark/v/3.0.0",
  ]

  validation {
    condition     = alltrue([for s in var.securityhub_standards : can(regex("^[a-z0-9-]+/v/[0-9.]+$", s))])
    error_message = "securityhub_standards entries look like aws-foundational-security-best-practices/v/1.0.0."
  }
}

variable "allowed_account_ids" {
  description = "AWS account IDs whose principals may use the keys. Supplied at run time (TF_VAR_account_id); never committed."
  type        = list(string)
}

variable "key_admin_role_arns" {
  description = "IAM role ARNs allowed to administer (not use) every key in the set."
  type        = list(string)
  default     = []
}

variable "key_usage_role_arns" {
  description = "Extra IAM role ARNs allowed to use each key, by key name (data, logs, audit, secrets, compute)."
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.key_usage_role_arns) : contains(["data", "logs", "audit", "secrets", "compute"], k)])
    error_message = "key_usage_role_arns keys must be data, logs, audit, secrets or compute."
  }
}

variable "alert_email_ssm_parameter_name" {
  description = "SSM String parameter holding the security-alerts email address (e.g. <SSM_PARAMETER_NAME>); read at plan time."
  type        = string

  validation {
    condition     = can(regex("^/hestia/", var.alert_email_ssm_parameter_name))
    error_message = "alert_email_ssm_parameter_name must be under /hestia/."
  }
}

variable "audit_bucket_admin_role_arns" {
  description = "IAM role ARNs that alone may change the audit bucket policy or ACLs."
  type        = list(string)
}

variable "audit_access_log_bucket" {
  description = "Bucket for the audit bucket's server access logs, or null. S3 access logs need an SSE-S3 target."
  type        = string
  default     = null
}

variable "audit_retention_days" {
  description = "Object Lock retention and expiry of audit records, in days. prod needs at least 3650 (10 years)."
  type        = number
  default     = 3650

  validation {
    condition     = var.audit_retention_days > 365
    error_message = "audit_retention_days must exceed 365, the Deep Archive transition."
  }

  validation {
    condition     = var.environment != "prod" || var.audit_retention_days >= 3650
    error_message = "audit_retention_days must be at least 3650 in prod."
  }
}

variable "object_lock_mode" {
  description = "Object Lock mode of the audit bucket: COMPLIANCE in prod, GOVERNANCE allowed in dev and staging."
  type        = string
  default     = "COMPLIANCE"

  validation {
    condition     = contains(["COMPLIANCE", "GOVERNANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be COMPLIANCE or GOVERNANCE."
  }

  validation {
    condition     = var.environment != "prod" || var.object_lock_mode == "COMPLIANCE"
    error_message = "object_lock_mode must be COMPLIANCE in prod."
  }
}

variable "cloudtrail_data_event_bucket_arns" {
  description = "S3 bucket ARNs whose object reads and writes the trail records (data, backups, data lake). Used in home_region only."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for b in var.cloudtrail_data_event_bucket_arns : can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9.-]+$", b))])
    error_message = "cloudtrail_data_event_bucket_arns entries must be S3 bucket ARNs."
  }
}

variable "cloudtrail_log_retention_days" {
  description = "Retention of the CloudTrail copy in CloudWatch Logs; capped at 400 days. The audit bucket keeps the WORM record."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400], var.cloudtrail_log_retention_days)
    error_message = "cloudtrail_log_retention_days must be a CloudWatch retention value <= 400."
  }
}

variable "audit_replication_destination" {
  description = "Peer-region audit bucket and its KMS key to replicate the audit bucket into, or null for no replication."
  type = object({
    bucket_arn  = string
    kms_key_arn = string
    region      = string
  })
  default = null

  validation {
    # || does not short-circuit in HCL, hence try().
    condition = var.audit_replication_destination == null || try(
      can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9.-]+$", var.audit_replication_destination.bucket_arn)) &&
      can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.audit_replication_destination.kms_key_arn)) &&
      contains(["eu-central-1", "eu-west-3"], var.audit_replication_destination.region),
    false)
    error_message = "audit_replication_destination needs an S3 bucket ARN, a KMS key ARN (not an alias) and an EU region in the allowlist (ADR-005)."
  }

  validation {
    condition     = var.audit_replication_destination == null ? true : var.audit_replication_destination.region != var.region
    error_message = "audit_replication_destination.region must differ from var.region."
  }
}
