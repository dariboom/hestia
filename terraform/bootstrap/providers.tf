terraform {
  # >= 1.10: the live roots this bootstraps use S3-native lockfiles (ADR-004).
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state on first run, then migrated into the DE state bucket (README, "State migration").
}

locals {
  base_tags = {
    "hestia:environment"         = var.environment
    "hestia:owner"               = var.owner
    "hestia:cost-center"         = var.cost_center
    "hestia:data-classification" = "internal"
    "hestia:tenant"              = "shared"
    "hestia:workload"            = "terraform-bootstrap"
  }
}

# DE is the default provider: account-global resources (IAM, OIDC) live here.
provider "aws" {
  region              = "eu-central-1"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = merge(local.base_tags, { "hestia:region" = "eu-central-1" })
  }
}

provider "aws" {
  alias               = "fr"
  region              = "eu-west-3"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = merge(local.base_tags, { "hestia:region" = "eu-west-3" })
  }
}
