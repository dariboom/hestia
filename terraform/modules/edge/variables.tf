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

variable "enable_cloudfront" {
  description = "Serve the anonymized dashboard through CloudFront at dashboard.<domain>; the only switch that creates us-east-1 resources (ADR-005)."
  type        = bool
  default     = false
}

variable "dashboard_origin" {
  description = "Existing S3 bucket (modules/s3-bucket) holding the anonymized dashboard, in an allowed region. Required when enable_cloudfront; give it the dashboard_origin_policy_json output."
  type = object({
    bucket_arn                  = string
    bucket_regional_domain_name = string
  })
  default = null

  validation {
    condition     = !var.enable_cloudfront || var.dashboard_origin != null
    error_message = "dashboard_origin is required when enable_cloudfront = true."
  }

  validation {
    condition     = var.dashboard_origin == null || can(regex("\\.s3\\.(eu-central-1|eu-west-3)\\.amazonaws\\.com$", var.dashboard_origin.bucket_regional_domain_name))
    error_message = "dashboard_origin must be an S3 bucket in eu-central-1 or eu-west-3."
  }
}

variable "cloudfront_origin_paths" {
  description = "S3 key prefixes CloudFront may read (anonymized dashboard only); everything else in the bucket stays denied. The first one holds index.html."
  type        = list(string)
  default     = ["/dashboard"]

  validation {
    condition     = length(var.cloudfront_origin_paths) > 0 && alltrue([for p in var.cloudfront_origin_paths : can(regex("^(/[a-z0-9][a-z0-9_-]*)+$", p))])
    error_message = "cloudfront_origin_paths must be non-empty prefixes like /dashboard (no wildcards, no trailing slash)."
  }
}

variable "cloudfront_log_bucket" {
  description = "Name of the existing eu-central-1 (DE) bucket that receives CloudFront standard logs. Required when enable_cloudfront."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_cloudfront || var.cloudfront_log_bucket != null
    error_message = "cloudfront_log_bucket is required when enable_cloudfront = true."
  }
}

variable "cloudfront_geo_allowlist" {
  description = "ISO 3166-1 alpha-2 countries CloudFront serves; default EU27 plus EEA (IS, LI, NO)."
  type        = list(string)
  default = [
    "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
    "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
    "IS", "LI", "NO",
  ]

  validation {
    condition     = length(var.cloudfront_geo_allowlist) > 0 && alltrue([for c in var.cloudfront_geo_allowlist : can(regex("^[A-Z]{2}$", c))])
    error_message = "cloudfront_geo_allowlist must be a non-empty list of upper-case two-letter country codes."
  }
}

variable "waf_rule_config" {
  description = "CloudFront WAF: AWS managed rule groups in order (priority = index, default block mode) and the per-IP 5-minute rate limit."
  type = object({
    managed_rule_groups = optional(list(string), [
      "AWSManagedRulesCommonRuleSet",
      "AWSManagedRulesKnownBadInputsRuleSet",
      "AWSManagedRulesAmazonIpReputationList",
    ])
    rate_limit_per_5min = optional(number, 2000)
  })
  default = {}

  validation {
    condition     = length(var.waf_rule_config.managed_rule_groups) > 0 && alltrue([for g in var.waf_rule_config.managed_rule_groups : can(regex("^AWSManagedRules[A-Za-z0-9]+$", g))])
    error_message = "waf_rule_config.managed_rule_groups must be a non-empty list of AWSManagedRules* group names."
  }

  validation {
    condition     = var.waf_rule_config.rate_limit_per_5min >= 100 && var.waf_rule_config.rate_limit_per_5min <= 2000000000
    error_message = "waf_rule_config.rate_limit_per_5min must be between 100 and 2000000000."
  }
}
