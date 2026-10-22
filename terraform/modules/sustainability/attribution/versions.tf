terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
      # us_east_1 hosts only the BCM Data Exports control plane; the data lands in eu-central-1 (ADR-005).
      configuration_aliases = [aws.us_east_1]
    }
  }
}
