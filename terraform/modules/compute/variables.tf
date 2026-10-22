variable "region" {
  description = "Region of this compute stack; must match the provider region."
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

variable "cluster_version" {
  description = "Kubernetes version of the EKS control plane."
  type        = string
  default     = "1.33"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.cluster_version))
    error_message = "cluster_version must look like 1.33."
  }
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (modules/network private tier) for the control plane ENIs and nodes, at least two AZs."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS needs private subnets in at least two AZs."
  }
}

variable "admin_principal_arns" {
  description = "IAM role ARNs granted AmazonEKSClusterAdminPolicy through EKS access entries."
  type        = list(string)

  validation {
    condition     = length(var.admin_principal_arns) > 0 && alltrue([for a in var.admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", a))])
    error_message = "admin_principal_arns needs at least one IAM role ARN (no users: humans come in through SSO roles)."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for Kubernetes Secrets envelope encryption and node EBS volumes (security module 'compute' key)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "log_kms_key_arn" {
  description = "KMS key for the control-plane log group; its policy must allow logs.<region>.amazonaws.com (security module 'logs' key)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.log_kms_key_arn))
    error_message = "log_kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "log_retention_days" {
  description = "Retention of control-plane logs; capped at 400 days (GDPR erasure bound for log personal data)."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch retention value <= 400."
  }
}
