variable "region" {
  description = "Region of this stack; must match the provider region."
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

variable "entsoe_token_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the ENTSO-E API token. Only the ARN: the token is read at run time by the Lambda role and never enters Terraform."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:(eu-central-1|eu-west-3):[0-9]{12}:secret:hestia/", var.entsoe_token_secret_arn))
    error_message = "entsoe_token_secret_arn must be a Secrets Manager ARN under hestia/ in eu-central-1 or eu-west-3."
  }
}

variable "secrets_kms_key_arn" {
  description = "Customer-managed KMS key that encrypts the ENTSO-E token secret (security module 'secrets' key)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.secrets_kms_key_arn))
    error_message = "secrets_kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for the Lambda environment variables."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias)."
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
  description = "Retention of the collector logs; capped at 400 days."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch retention value <= 400."
  }
}

variable "best_window_hours" {
  description = "Length of the lowest-carbon window published to best_window, in hours."
  type        = number
  default     = 4

  validation {
    condition     = var.best_window_hours >= 1 && var.best_window_hours <= 12 && floor(var.best_window_hours) == var.best_window_hours
    error_message = "best_window_hours must be a whole number from 1 to 12."
  }
}

variable "package_path" {
  description = "Path to the collector zip, built by CI from src/carbon_signal/handler.py (see README)."
  type        = string

  validation {
    condition     = endswith(var.package_path, ".zip")
    error_message = "package_path must point to a .zip file."
  }
}
