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

variable "interface_endpoints" {
  description = "Interface endpoint service suffixes (com.amazonaws.<region>.<suffix>) placed in the private subnets."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "sts", "logs", "kms", "secretsmanager", "ssm", "ec2", "elasticloadbalancing", "eks", "firehose"]
}

variable "flow_log_retention_days" {
  description = "Days flow logs are kept before expiry (also the GDPR erasure bound for IP metadata)."
  type        = number

  validation {
    condition     = var.flow_log_retention_days >= 1 && var.flow_log_retention_days <= 400
    error_message = "flow_log_retention_days must be between 1 and 400."
  }

  validation {
    condition     = var.environment != "prod" || var.flow_log_retention_days >= 90
    error_message = "prod requires flow_log_retention_days >= 90."
  }
}

variable "flow_log_bucket_kms_key_arn" {
  description = "KMS key for the flow-log bucket (security module 'logs' key); its policy must allow delivery.logs.amazonaws.com."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.flow_log_bucket_kms_key_arn))
    error_message = "flow_log_bucket_kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "flow_log_bucket_admin_role_arns" {
  description = "Principals allowed to change the flow-log bucket policy (passed to modules/s3-bucket)."
  type        = list(string)

  validation {
    condition     = length(var.flow_log_bucket_admin_role_arns) > 0
    error_message = "At least one admin role ARN is required."
  }
}
