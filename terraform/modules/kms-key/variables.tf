variable "alias" {
  description = "Alias name without the 'alias/' prefix, e.g. hestia-prod-de-data."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9/_-]{1,250}$", var.alias)) && !startswith(var.alias, "alias/") && !startswith(var.alias, "aws/")
    error_message = "alias must be 1-250 chars of [a-zA-Z0-9/_-], without the 'alias/' prefix, and must not start with 'aws/'."
  }
}

variable "description" {
  description = "Human-readable purpose of the key."
  type        = string
}

variable "tags" {
  description = "Tags applied to the key (merged with provider default_tags)."
  type        = map(string)
  default     = {}
}

variable "allowed_account_ids" {
  description = "AWS account IDs whose principals may use the key. Supplied at run time (TF_VAR_account_id); never committed."
  type        = list(string)

  validation {
    condition     = length(var.allowed_account_ids) > 0 && alltrue([for id in var.allowed_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "allowed_account_ids must contain at least one 12-digit account ID."
  }
}

variable "admin_role_arns" {
  description = "IAM role ARNs allowed to administer (not use) the key."
  type        = list(string)
  default     = []
}

variable "usage_role_arns" {
  description = "IAM role ARNs allowed to encrypt/decrypt with the key."
  type        = list(string)
  default     = []
}

variable "service_principals" {
  description = <<-EOT
    AWS service principals allowed to use the key, e.g. { service = "logs.eu-central-1.amazonaws.com" }.
    Always scoped by aws:SourceAccount. source_arn_like optionally narrows to one resource;
    source_arn_condition_key overrides the condition key (CloudWatch Logs uses kms:EncryptionContext:aws:logs:arn).
  EOT
  type = list(object({
    service                  = string
    source_arn_like          = optional(string)
    source_arn_condition_key = optional(string, "aws:SourceArn")
  }))
  default = []
}

variable "deletion_window_in_days" {
  description = "Waiting period before a scheduled deletion takes effect."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}
