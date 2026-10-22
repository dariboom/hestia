terraform {
  # Modules use no 1.10-only features; live roots pin >= 1.10 for S3 lockfiles (ADR-004).
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
