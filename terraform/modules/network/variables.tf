variable "region" {
  description = "Region this VPC lives in; must match the provider region."
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

variable "vpc_cidr" {
  description = "VPC CIDR, a /16 from the plan in README.md (e.g. 10.10.0.0/16 for dev DE)."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16 CIDR."
  }
}

variable "public_subnet_cidrs" {
  description = "Three public subnet CIDRs (ALB, NAT), one per AZ."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) == 3 && alltrue([for c in var.public_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "public_subnet_cidrs must be exactly 3 valid CIDRs."
  }
}

variable "private_subnet_cidrs" {
  description = "Three private subnet CIDRs (EKS nodes, Lambda), one per AZ."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == 3 && alltrue([for c in var.private_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "private_subnet_cidrs must be exactly 3 valid CIDRs."
  }
}

variable "isolated_subnet_cidrs" {
  description = "Three isolated subnet CIDRs (RDS), one per AZ. No internet route."
  type        = list(string)

  validation {
    condition     = length(var.isolated_subnet_cidrs) == 3 && alltrue([for c in var.isolated_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "isolated_subnet_cidrs must be exactly 3 valid CIDRs."
  }
}

variable "nat_mode" {
  description = "per_az: one NAT gateway per AZ (AZ-independent egress). single: one shared NAT (dev/staging cost saving)."
  type        = string
  default     = "per_az"

  validation {
    condition     = contains(["per_az", "single"], var.nat_mode)
    error_message = "nat_mode must be per_az or single."
  }

  validation {
    condition     = var.environment != "prod" || var.nat_mode == "per_az"
    error_message = "prod requires nat_mode = per_az."
  }
}

variable "peer_vpc_cidr" {
  description = "CIDR of the peer-region VPC allowed through the isolated-tier NACL, or null before peering exists."
  type        = string
  default     = null

  validation {
    condition     = var.peer_vpc_cidr == null || can(cidrhost(var.peer_vpc_cidr, 0))
    error_message = "peer_vpc_cidr must be a valid CIDR or null."
  }
}
