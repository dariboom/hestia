# Validation harness: the module needs aliased providers, so it can only be
# validated from a root that passes aws.de/aws.fr. Never planned or applied.
# Real roots read these IDs from SSM (see the module README).

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  alias  = "de"
  region = "eu-central-1"
}

provider "aws" {
  alias  = "fr"
  region = "eu-west-3"
}

module "peering" {
  source = "../.."

  providers = {
    aws.de = aws.de
    aws.fr = aws.fr
  }

  environment        = "dev"
  de_vpc_id          = "vpc-00000000000000000"
  fr_vpc_id          = "vpc-00000000000000001"
  de_vpc_cidr        = "10.10.0.0/16"
  fr_vpc_cidr        = "10.11.0.0/16"
  de_route_table_ids = ["rtb-00000000000000000"]
  fr_route_table_ids = ["rtb-00000000000000001"]
}
