terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial config: bucket, key and region are passed at init (-backend-config), e.g. bucket=<STATE_BUCKET_NAME>.
  backend "s3" {}
}

# Organizations is a global service; the management account's home region is used for the provider.
provider "aws" {
  region              = "eu-central-1"
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      "hestia:environment"         = "shared"
      "hestia:owner"               = var.owner
      "hestia:cost-center"         = var.cost_center
      "hestia:data-classification" = "internal"
      "hestia:tenant"              = "shared"
      "hestia:workload"            = "org-guardrails"
      "hestia:region"              = "global"
    }
  }
}
