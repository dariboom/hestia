terraform {
  # >= 1.9: variable validations reference other variables (prod => per-AZ NAT, flow-log retention).
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
