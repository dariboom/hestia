variable "region" {
  description = "Region of this edge stack; must match the provider region."
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

variable "vpc_id" {
  description = "VPC of the ALB and its targets (modules/network)."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (modules/network public tier) for the ALB, at least two AZs."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "public_subnet_ids needs at least two subnets in different AZs."
  }
}

variable "domain_name" {
  description = "Public hostname served by the ALB, e.g. api.dev.example.eu; the regional ACM certificate is issued for it."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a lower-case DNS name without a trailing dot."
  }
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone that holds domain_name; used only for the ACM DNS validation records."
  type        = string
}

variable "access_log_bucket" {
  description = "Name of the existing S3 bucket that receives ALB access logs. ELB log delivery supports only SSE-S3, and the bucket policy must allow the regional ELB log-delivery principal."
  type        = string
}

variable "target_port" {
  description = "Pod port the target group sends HTTPS traffic to (bound by the LB Controller TargetGroupBinding)."
  type        = number
  default     = 8443

  validation {
    condition     = var.target_port >= 1024 && var.target_port <= 65535
    error_message = "target_port must be an unprivileged port (1024-65535)."
  }
}

variable "health_check_path" {
  description = "HTTPS health-check path on the targets."
  type        = string
  default     = "/healthz"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path must start with /."
  }
}
