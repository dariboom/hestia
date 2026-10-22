variable "account_id" {
  description = "Target AWS account ID for this environment. Supplied at run time as TF_VAR_account_id; never committed."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "environment" {
  description = "Environment this account hosts."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "owner" {
  description = "Owning team, used for the hestia:owner tag."
  type        = string
}

variable "cost_center" {
  description = "Cost center, used for the hestia:cost-center tag."
  type        = string
}

variable "admin_role_arns" {
  description = "Human platform-admin / break-glass role ARNs. They administer the state keys and are the only principals allowed to change state bucket policies."
  type        = list(string)

  validation {
    condition = length(var.admin_role_arns) > 0 && alltrue([
      for arn in var.admin_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", arn))
    ])
    error_message = "admin_role_arns must contain at least one concrete IAM role ARN (no wildcards)."
  }
}
