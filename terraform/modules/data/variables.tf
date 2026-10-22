variable "region" {
  description = "Region of this data stack; must match the provider region."
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

variable "kms_key_arn" {
  description = "Customer-managed KMS key for the data buckets (security module 'data' key)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "bucket_admin_role_arns" {
  description = "Principals allowed to change the data bucket policies (passed to modules/s3-bucket)."
  type        = list(string)

  validation {
    condition     = length(var.bucket_admin_role_arns) > 0
    error_message = "At least one admin role ARN is required."
  }
}

# Named bucket_lifecycle because "lifecycle" is a reserved variable name.
variable "bucket_lifecycle" {
  description = <<-EOT
    Per-bucket lifecycle. Transitions go to STANDARD_IA (artifacts, logs) or GLACIER_IR (backups).
    logs and backups hold personal data, so their expiration is mandatory and capped: it is the
    GDPR erasure bound (plus 1 day / 7 days of noncurrent versions respectively).
  EOT
  type = object({
    artifacts = optional(object({
      transition_days = optional(number, 30)
      expiration_days = optional(number)
    }), {})
    logs = optional(object({
      transition_days = optional(number, 30)
      expiration_days = optional(number, 400)
    }), {})
    backups = optional(object({
      transition_days = optional(number, 30)
      expiration_days = optional(number, 90)
    }), {})
  })
  default = {}

  validation {
    condition = alltrue([for k, v in var.bucket_lifecycle : v.transition_days == null || try(v.transition_days >= 30, false)])
    # STANDARD_IA rejects transitions earlier than 30 days.
    error_message = "transition_days must be null or >= 30."
  }

  validation {
    condition     = alltrue([for k, v in var.bucket_lifecycle : v.expiration_days == null || v.transition_days == null || try(v.expiration_days > v.transition_days, false)])
    error_message = "expiration_days must be greater than transition_days."
  }

  validation {
    condition     = var.bucket_lifecycle.logs.expiration_days != null && try(var.bucket_lifecycle.logs.expiration_days <= 400, false)
    error_message = "logs.expiration_days is required and must be <= 400 (GDPR erasure bound for log personal data)."
  }

  validation {
    condition     = var.bucket_lifecycle.backups.expiration_days != null && try(var.bucket_lifecycle.backups.expiration_days <= 90, false)
    error_message = "backups.expiration_days is required and must be <= 90 (GDPR erasure bound: deletions reach backups within 90 days)."
  }
}

variable "secrets_kms_key_arn" {
  description = "Customer-managed KMS key for Secrets Manager containers (security module 'secrets' key)."
  type        = string
  default     = null

  validation {
    condition     = var.secrets_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.secrets_kms_key_arn))
    error_message = "secrets_kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "app_secret_names" {
  description = "Secrets Manager containers to create as hestia/<env>/<rc>/app/<name>. Names only: values are injected by external CI/CD secret store."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.app_secret_names : can(regex("^[a-z0-9][a-z0-9-]{0,62}$", n))])
    error_message = "app_secret_names must be lowercase kebab-case names (max 63 chars)."
  }
}

variable "ssm_secure_parameter_names" {
  description = "Existing SecureString parameter names (created out-of-band) to expose as ARNs for IAM grants. Never values."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.ssm_secure_parameter_names : startswith(n, "/hestia/${var.environment}/")])
    error_message = "ssm_secure_parameter_names must start with /hestia/<environment>/."
  }
}
