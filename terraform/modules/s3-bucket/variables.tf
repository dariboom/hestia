variable "name" {
  description = "Globally unique bucket name, e.g. hestia-prod-de-audit-<suffix>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.name))
    error_message = "name must be a valid S3 bucket name (3-63 chars, lowercase, digits, dots, hyphens)."
  }
}

variable "kms_key_arn" {
  description = "ARN of the customer-managed KMS key used for SSE-KMS (modules/kms-key)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "tags" {
  description = "Tags applied to the bucket. Must include hestia:environment (drives the prod force_destroy guard)."
  type        = map(string)

  validation {
    condition     = contains(["dev", "staging", "prod"], lookup(var.tags, "hestia:environment", ""))
    error_message = "tags must include hestia:environment = dev | staging | prod."
  }
}

variable "lifecycle_rules" {
  description = "Lifecycle rules. At least one is required so no bucket grows unbounded."
  type = list(object({
    id                         = string
    prefix                     = optional(string, "")
    transitions                = optional(list(object({ days = number, storage_class = string })), [])
    expiration_days            = optional(number)
    noncurrent_expiration_days = optional(number, 90)
  }))

  validation {
    condition     = length(var.lifecycle_rules) > 0
    error_message = "At least one lifecycle rule is required."
  }
}

variable "object_lock" {
  description = "Default Object Lock retention, or null to disable. Can only be enabled at bucket creation."
  type = object({
    mode = string
    days = number
  })
  default = null

  validation {
    condition     = var.object_lock == null || try(contains(["COMPLIANCE", "GOVERNANCE"], var.object_lock.mode) && var.object_lock.days > 0, false)
    error_message = "object_lock.mode must be COMPLIANCE or GOVERNANCE and days must be > 0."
  }
}

variable "policy_admin_role_arns" {
  description = "Only these principals may change the bucket policy or ACLs."
  type        = list(string)

  validation {
    condition     = length(var.policy_admin_role_arns) > 0
    error_message = "At least one policy admin role ARN is required."
  }
}

variable "additional_policy_statements" {
  description = "Extra bucket policy JSON documents merged with the baseline (e.g. service write access)."
  type        = list(string)
  default     = []
}

variable "access_log_bucket" {
  description = "Target bucket name for server access logs, or null to disable (the log bucket itself)."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow destroying a non-empty bucket. Rejected when hestia:environment = prod."
  type        = bool
  default     = false
}
