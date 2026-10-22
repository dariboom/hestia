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
