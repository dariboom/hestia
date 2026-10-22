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

variable "de_vpc_id" {
  description = "DE (eu-central-1) VPC ID, the requester. Read from SSM /hestia/<env>/de/network/vpc_id."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.de_vpc_id))
    error_message = "de_vpc_id must be a VPC ID."
  }
}

variable "fr_vpc_id" {
  description = "FR (eu-west-3) VPC ID, the accepter. Read from SSM /hestia/<env>/fr/network/vpc_id."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.fr_vpc_id))
    error_message = "fr_vpc_id must be a VPC ID."
  }
}

variable "de_vpc_cidr" {
  description = "DE VPC CIDR."
  type        = string

  validation {
    condition     = can(cidrhost(var.de_vpc_cidr, 0))
    error_message = "de_vpc_cidr must be a valid CIDR."
  }
}

variable "fr_vpc_cidr" {
  description = "FR VPC CIDR; must not overlap the DE CIDR."
  type        = string

  validation {
    condition     = can(cidrhost(var.fr_vpc_cidr, 0)) && var.fr_vpc_cidr != var.de_vpc_cidr
    error_message = "fr_vpc_cidr must be a valid CIDR different from de_vpc_cidr."
  }
}

variable "de_route_table_ids" {
  description = "DE private + isolated route table IDs that get a route to FR. Never public tables (checked by precondition)."
  type        = list(string)

  validation {
    condition     = length(var.de_route_table_ids) > 0 && alltrue([for id in var.de_route_table_ids : can(regex("^rtb-[0-9a-f]+$", id))])
    error_message = "de_route_table_ids must be a non-empty list of route table IDs."
  }
}

variable "fr_route_table_ids" {
  description = "FR private + isolated route table IDs that get a route to DE. Never public tables (checked by precondition)."
  type        = list(string)

  validation {
    condition     = length(var.fr_route_table_ids) > 0 && alltrue([for id in var.fr_route_table_ids : can(regex("^rtb-[0-9a-f]+$", id))])
    error_message = "fr_route_table_ids must be a non-empty list of route table IDs."
  }
}

variable "de_ingress_security_group_ids" {
  description = "DE security groups (e.g. RDS writer, app) that accept traffic from the FR CIDR on allowed_ports."
  type        = list(string)
  default     = []
}

variable "fr_ingress_security_group_ids" {
  description = "FR security groups (e.g. RDS replica, app) that accept traffic from the DE CIDR on allowed_ports."
  type        = list(string)
  default     = []
}

variable "allowed_ports" {
  description = "TCP ports opened to the peer CIDR on the ingress security groups."
  type        = list(number)
  default     = [5432, 443]

  validation {
    condition     = alltrue([for p in var.allowed_ports : p >= 1 && p <= 65535 && floor(p) == p])
    error_message = "allowed_ports must be integer TCP ports (1-65535)."
  }
}
