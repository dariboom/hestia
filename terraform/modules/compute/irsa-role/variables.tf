variable "name" {
  description = "Role name (hestia-<env>-<rc>-<cluster purpose>-<service>)."
  type        = string

  validation {
    condition     = can(regex("^hestia-[a-z0-9-]{1,57}$", var.name))
    error_message = "name must start with hestia- (tf-deploy may only manage hestia-* roles) and fit IAM's 64-char limit."
  }
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/.+", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be an IAM OIDC provider ARN."
  }
}

variable "namespace" {
  description = "Kubernetes namespace of the service account."
  type        = string
}

variable "service_account" {
  description = "Kubernetes service account name (exact; no wildcards)."
  type        = string

  validation {
    condition     = !strcontains(var.service_account, "*") && var.service_account != ""
    error_message = "service_account must be an exact name; wildcards would let any service account assume the role."
  }
}

variable "policy_json" {
  description = "Inline least-privilege policy document (JSON), or null."
  type        = string
  default     = null
}

variable "managed_policy_arns" {
  description = "AWS-managed policies to attach (only for add-ons whose permissions AWS maintains)."
  type        = list(string)
  default     = []
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary (hestia-<env>-boundary); mandatory, tf-deploy cannot create roles without it."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/hestia-(dev|staging|prod)-boundary$", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be the hestia-<env>-boundary policy ARN."
  }
}

variable "tags" {
  description = "Tags for the role."
  type        = map(string)
  default     = {}
}
