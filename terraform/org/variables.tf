variable "management_account_id" {
  description = "Organization management account ID. Supplied at run time as TF_VAR_management_account_id; never committed."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account ID."
  }
}

variable "target_ou_ids" {
  description = "Organizational units (or the root) the guardrail SCPs are attached to."
  type        = list(string)

  validation {
    condition     = length(var.target_ou_ids) > 0 && alltrue([for id in var.target_ou_ids : can(regex("^(ou-[0-9a-z]{4,32}-[0-9a-z]{8,32}|r-[0-9a-z]{4,32})$", id))])
    error_message = "target_ou_ids must be a non-empty list of OU IDs (ou-...) or a root ID (r-...)."
  }
}

variable "break_glass_role_name" {
  description = "Role name, in any member account, exempt from the audit-control denies (incident response and audit store changes)."
  type        = string
  default     = "hestia-break-glass"

  validation {
    condition     = can(regex("^hestia-[a-z0-9-]+$", var.break_glass_role_name))
    error_message = "break_glass_role_name must be a hestia-* role name."
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
