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

variable "subject_alternative_names" {
  description = "Extra hostnames on the certificate, e.g. portal.<domain> when api.<domain> is domain_name; validated in the same hosted_zone_id."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.subject_alternative_names : can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", n))])
    error_message = "subject_alternative_names must be lower-case DNS names without a trailing dot."
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

variable "waf_managed_rule_groups" {
  description = "AWS managed rule groups evaluated in order (priority = list index), all in their default block mode."
  type        = list(string)
  default = [
    "AWSManagedRulesCommonRuleSet",
    "AWSManagedRulesKnownBadInputsRuleSet",
    "AWSManagedRulesSQLiRuleSet",
    "AWSManagedRulesAmazonIpReputationList",
  ]

  validation {
    condition     = length(var.waf_managed_rule_groups) > 0 && alltrue([for g in var.waf_managed_rule_groups : can(regex("^AWSManagedRules[A-Za-z0-9]+$", g))])
    error_message = "waf_managed_rule_groups must be a non-empty list of AWSManagedRules* group names."
  }
}

variable "rate_limit_per_5min" {
  description = "Requests per client IP per 5 minutes before the rate rule blocks it."
  type        = number
  default     = 2000

  validation {
    condition     = var.rate_limit_per_5min >= 100 && var.rate_limit_per_5min <= 2000000000
    error_message = "rate_limit_per_5min must be between 100 and 2000000000."
  }
}

variable "log_kms_key_arn" {
  description = "KMS key for the WAF log group; its policy must allow logs.<region>.amazonaws.com (security module 'logs' key)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.log_kms_key_arn))
    error_message = "log_kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "log_retention_days" {
  description = "Retention of WAF logs; capped at 400 days (GDPR erasure bound: logs hold client IPs)."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch retention value <= 400."
  }
}
