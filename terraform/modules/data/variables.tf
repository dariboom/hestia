variable "region" {
  description = "Region of this data stack; must match the provider region."
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

variable "kms_key_arn" {
  description = "Customer-managed KMS key for the data buckets (security module 'data' key)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "bucket_admin_role_arns" {
  description = "Principals allowed to change the data bucket policies (passed to modules/s3-bucket)."
  type        = list(string)

  validation {
    condition     = length(var.bucket_admin_role_arns) > 0
    error_message = "At least one admin role ARN is required."
  }
}

# Named bucket_lifecycle because "lifecycle" is a reserved variable name.
variable "bucket_lifecycle" {
  description = <<-EOT
    Per-bucket lifecycle. Transitions go to STANDARD_IA (artifacts, logs) or GLACIER_IR (backups).
    logs and backups hold personal data, so their expiration is mandatory and capped: it is the
    GDPR erasure bound (plus 1 day / 7 days of noncurrent versions respectively).
  EOT
  type = object({
    artifacts = optional(object({
      transition_days = optional(number, 30)
      expiration_days = optional(number)
    }), {})
    logs = optional(object({
      transition_days = optional(number, 30)
      expiration_days = optional(number, 400)
    }), {})
    backups = optional(object({
      transition_days = optional(number, 30)
      expiration_days = optional(number, 90)
    }), {})
  })
  default = {}

  validation {
    condition = alltrue([for k, v in var.bucket_lifecycle : v.transition_days == null || try(v.transition_days >= 30, false)])
    # STANDARD_IA rejects transitions earlier than 30 days.
    error_message = "transition_days must be null or >= 30."
  }

  validation {
    condition     = alltrue([for k, v in var.bucket_lifecycle : v.expiration_days == null || v.transition_days == null || try(v.expiration_days > v.transition_days, false)])
    error_message = "expiration_days must be greater than transition_days."
  }

  validation {
    condition     = var.bucket_lifecycle.logs.expiration_days != null && try(var.bucket_lifecycle.logs.expiration_days <= 400, false)
    error_message = "logs.expiration_days is required and must be <= 400 (GDPR erasure bound for log personal data)."
  }

  validation {
    condition     = var.bucket_lifecycle.backups.expiration_days != null && try(var.bucket_lifecycle.backups.expiration_days <= 90, false)
    error_message = "backups.expiration_days is required and must be <= 90 (GDPR erasure bound: deletions reach backups within 90 days)."
  }
}

variable "secrets_kms_key_arn" {
  description = "Customer-managed KMS key for Secrets Manager containers (security module 'secrets' key)."
  type        = string
  default     = null

  validation {
    condition     = var.secrets_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.secrets_kms_key_arn))
    error_message = "secrets_kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "app_secret_names" {
  description = "Secrets Manager containers to create as hestia/<env>/<rc>/app/<name>. Names only: values are injected by external CI/CD secret store."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.app_secret_names : can(regex("^[a-z0-9][a-z0-9-]{0,62}$", n))])
    error_message = "app_secret_names must be lowercase kebab-case names (max 63 chars)."
  }
}

variable "ssm_secure_parameter_names" {
  description = "Existing SecureString parameter names (created out-of-band) to expose as ARNs for IAM grants. Never values."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.ssm_secure_parameter_names : startswith(n, "/hestia/${var.environment}/")])
    error_message = "ssm_secure_parameter_names must start with /hestia/<environment>/."
  }
}

variable "enable_cross_region_replication" {
  description = "Replicate the backups bucket to the peer region's backups bucket (DR copy)."
  type        = bool
  default     = false
}

variable "replication_destination" {
  description = "Peer-region backups bucket and its KMS key; required when enable_cross_region_replication is true."
  type = object({
    bucket_arn  = string
    kms_key_arn = string
    region      = string
  })
  default = null

  validation {
    # || does not short-circuit in HCL, hence try().
    condition = var.replication_destination == null || try(
      can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9.-]+$", var.replication_destination.bucket_arn)) &&
      can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.replication_destination.kms_key_arn)) &&
      contains(["eu-central-1", "eu-west-3"], var.replication_destination.region),
    false)
    error_message = "replication_destination needs an S3 bucket ARN, a KMS key ARN (not an alias) and an EU region in the allowlist (ADR-005)."
  }

  validation {
    condition     = !var.enable_cross_region_replication || try(var.replication_destination.region != var.region, false)
    error_message = "replication_destination is required when enable_cross_region_replication is true, and its region must differ from var.region."
  }
}

# --- RDS PostgreSQL (rds.tf). db_role = null creates no database.

variable "db_role" {
  description = "\"primary\" (active region), \"replica\" (cross-region read replica) or null for no database."
  type        = string
  default     = null

  validation {
    condition     = var.db_role == null || contains(["primary", "replica"], coalesce(var.db_role, "-"))
    error_message = "db_role must be \"primary\", \"replica\" or null."
  }
}

variable "db_source_db_arn" {
  description = "ARN of the primary DB instance; required iff db_role = \"replica\"."
  type        = string
  default     = null

  validation {
    condition     = var.db_source_db_arn == null || can(regex("^arn:aws[a-z-]*:rds:(eu-central-1|eu-west-3):[0-9]{12}:db:", var.db_source_db_arn))
    error_message = "db_source_db_arn must be an RDS DB instance ARN in an allowed EU region."
  }
}

variable "db_engine_version" {
  description = "PostgreSQL version; the major version selects the parameter group family."
  type        = string
  default     = "17"
}

variable "db_instance_class" {
  description = "DB instance class."
  type        = string
  default     = "db.m7g.large"
}

variable "db_allocated_storage" {
  description = "Initial gp3 storage in GiB (primary only; replicas inherit it)."
  type        = number
  default     = 100
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB."
  type        = number
  default     = 500

  validation {
    condition     = var.db_max_allocated_storage >= var.db_allocated_storage
    error_message = "db_max_allocated_storage must be >= db_allocated_storage."
  }
}

variable "db_backup_retention_days" {
  description = "Automated backup retention: 7-35 days (35 is the RDS limit); prod must use 35 (Global Constraints retention floor)."
  type        = number
  default     = 14

  validation {
    condition     = var.db_backup_retention_days >= (var.environment == "prod" ? 35 : 7) && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days must be 7-35, and 35 in prod."
  }
}

variable "db_vpc_id" {
  description = "VPC for the database security group."
  type        = string
  default     = null
}

variable "db_subnet_ids" {
  description = "Isolated subnet IDs (modules/network isolated tier), at least two AZs."
  type        = list(string)
  default     = []
}

variable "db_allowed_security_group_ids" {
  description = "Security groups allowed to reach PostgreSQL on 5432 (EKS nodes / pods)."
  type        = list(string)
  default     = []
}

variable "db_peer_cidr_blocks" {
  description = "Peer-region VPC CIDRs allowed on 5432 (via modules/network-peering)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.db_peer_cidr_blocks : can(cidrhost(c, 0)) && !startswith(c, "0.0.0.0")])
    error_message = "db_peer_cidr_blocks must be valid private CIDRs, never 0.0.0.0/x."
  }
}

variable "db_log_kms_key_arn" {
  description = "KMS key for the RDS CloudWatch log groups; its policy must allow logs.<region>.amazonaws.com (security module 'logs' key)."
  type        = string
  default     = null
}

variable "db_log_retention_days" {
  description = "Retention of RDS log exports; capped at 400 days (GDPR erasure bound for log personal data)."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400], var.db_log_retention_days)
    error_message = "db_log_retention_days must be a CloudWatch retention value <= 400."
  }
}

variable "enable_db_backup_replication" {
  description = "Replicate the primary's (db_source_db_arn) automated backups into this region for point-in-time restore after a region loss."
  type        = bool
  default     = false
}
