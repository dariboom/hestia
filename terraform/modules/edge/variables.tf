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

variable "domain_name" {
  description = "Public DNS zone of this environment, e.g. dev.example.eu; portal.<domain> and api.<domain> live in it."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a lower-case DNS name without a trailing dot."
  }
}

variable "internal_domain_name" {
  description = "Private DNS zone shared by the DE and FR VPCs, e.g. dev.hestia.internal."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.internal_domain_name))
    error_message = "internal_domain_name must be a lower-case DNS name without a trailing dot."
  }
}

variable "vpc_associations" {
  description = "VPCs the private zone is associated with (one per regional stack)."
  type = list(object({
    vpc_id = string
    region = string
  }))

  validation {
    condition     = length(var.vpc_associations) > 0 && alltrue([for v in var.vpc_associations : contains(["eu-central-1", "eu-west-3"], v.region)])
    error_message = "vpc_associations needs at least one VPC, each in eu-central-1 or eu-west-3."
  }
}

variable "enable_public_ingress" {
  description = "Create the public zone and the portal/api records that point at regional_albs."
  type        = bool
  default     = false
}

variable "regional_albs" {
  description = "Regional ALBs (modules/edge/regional outputs, read from SSM by the live stack), keyed by region. Empty on the first apply, which only creates the zones the regional certificates validate in."
  type = map(object({
    dns_name = string
    zone_id  = string
  }))
  default = {}

  validation {
    condition     = alltrue([for r in keys(var.regional_albs) : contains(["eu-central-1", "eu-west-3"], r)])
    error_message = "regional_albs keys must be eu-central-1 or eu-west-3."
  }

  validation {
    condition     = length(var.regional_albs) == 0 || contains(keys(var.regional_albs), "eu-central-1")
    error_message = "regional_albs must include eu-central-1 (api failover PRIMARY = DE)."
  }
}

variable "health_check_path" {
  description = "HTTPS path the Route 53 health checks probe on each ALB."
  type        = string
  default     = "/healthz"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path must start with /."
  }
}
