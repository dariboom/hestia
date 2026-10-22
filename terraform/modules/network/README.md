# modules/network

This module creates one regional Hestia VPC: three AZs, three subnet tiers, NAT, VPC endpoints and flow logs. Each `live/<env>/<region>` stack instantiates it once.

## Guarantees

- **Region lock:** `region` must be `eu-central-1` or `eu-west-3`. A VPC precondition also rejects any other region.
- **Subnet tiers** (one subnet per AZ in each tier):
  - **public:** ALB and NAT gateways only. `map_public_ip_on_launch = false`.
  - **private:** EKS nodes and Lambda. The default route goes through NAT.
  - **isolated:** RDS. There is no internet route in any direction.
- **NAT:** `per_az` (the default) runs one NAT gateway per AZ, so egress survives an AZ outage. `single` runs one shared gateway, to save cost in dev and staging. prod must use `per_az`, which is enforced twice:
  - by the variable validation, at plan time (it is a cross-variable check, so `terraform validate` does not evaluate it);
  - by `policies/network.rego`, statically, for any module block under `live/prod/`.
- **Default security group:** locked down with no rules. Nothing can silently fall back to it.
- **Isolated NACL:** allows traffic only to and from `vpc_cidr` and, once peering exists, `peer_vpc_cidr`. This blocks the S3 gateway endpoint from the isolated tier by design, because S3 prefix-list IPs are not in the allowed CIDRs. RDS does not need S3 from inside the VPC.
- **S3 gateway endpoint:** on the private and isolated route tables. Its policy allows only buckets owned by this account (`aws:ResourceAccount`), plus the AWS-owned ECR layer bucket. This blocks exfiltration to foreign buckets.
- **Interface endpoints:** in the private subnets, with private DNS. Their security group allows 443 from `vpc_cidr` only. AWS API calls stay off NAT.
- **Flow logs:** ALL traffic is written to a bucket created with `modules/s3-bucket`.
  - Format: Parquet, Hive-compatible hourly partitions, 600-second aggregation.
  - Objects expire after `flow_log_retention_days`, which must be at least 90 in prod. This is also the GDPR erasure bound for IP metadata.
  - The KMS key policy must allow `delivery.logs.amazonaws.com` to use the key (the security module's `logs` key does). Without it, delivery fails silently.

## CIDR plan

Each environment/region pair gets its own /16. None of them overlap, so any pair can be peered later.

| Environment | eu-central-1 (DE) | eu-west-3 (FR) |
|---|---|---|
| dev | `10.10.0.0/16` | `10.11.0.0/16` |
| staging | `10.20.0.0/16` | `10.21.0.0/16` |
| prod | `10.30.0.0/16` | `10.31.0.0/16` |

Subnet layout inside each /16, using dev DE as the example (substitute the second octet):

| Tier | Size | AZ a | AZ b | AZ c |
|---|---|---|---|---|
| public | /24 | `10.10.0.0/24` | `10.10.1.0/24` | `10.10.2.0/24` |
| private | /20 | `10.10.16.0/20` | `10.10.32.0/20` | `10.10.48.0/20` |
| isolated | /24 | `10.10.64.0/24` | `10.10.65.0/24` | `10.10.66.0/24` |

The private subnets are /20 because EKS (VPC CNI) gives every pod a VPC IP. `10.10.128.0/17` is kept free for future tiers.

## Example

```hcl
module "network" {
  source = "../../../modules/network"

  region                = "eu-central-1"
  environment           = "dev"
  tags                  = local.tags
  vpc_cidr              = "10.10.0.0/16"
  public_subnet_cidrs   = ["10.10.0.0/24", "10.10.1.0/24", "10.10.2.0/24"]
  private_subnet_cidrs  = ["10.10.16.0/20", "10.10.32.0/20", "10.10.48.0/20"]
  isolated_subnet_cidrs = ["10.10.64.0/24", "10.10.65.0/24", "10.10.66.0/24"]
  nat_mode              = "single"
  peer_vpc_cidr         = "10.11.0.0/16"

  flow_log_retention_days         = 30
  flow_log_bucket_kms_key_arn     = module.security.logs_key_arn
  flow_log_bucket_admin_role_arns = ["arn:aws:iam::<AWS_ACCOUNT_ID>:role/hestia-dev-admin"]
}
```

## Inputs

| Name | Type | Default |
|---|---|---|
| `region` | string, `eu-central-1` or `eu-west-3` | required |
| `environment` | string, `dev`, `staging` or `prod` | required |
| `tags` | map(string) | `{}` |
| `vpc_cidr` | string, a /16 | required |
| `public_subnet_cidrs` | list(string), exactly 3 | required |
| `private_subnet_cidrs` | list(string), exactly 3 | required |
| `isolated_subnet_cidrs` | list(string), exactly 3 | required |
| `nat_mode` | `per_az` or `single`; prod must be `per_az` | `per_az` |
| `peer_vpc_cidr` | string or null | `null` |
| `interface_endpoints` | list(string) | ecr.api, ecr.dkr, sts, logs, kms, secretsmanager, ssm, ec2, elasticloadbalancing, eks, firehose |
| `flow_log_retention_days` | number, 1–400; at least 90 in prod | required |
| `flow_log_bucket_kms_key_arn` | string, a KMS key ARN (not an alias) | required |
| `flow_log_bucket_admin_role_arns` | list(string), at least 1 | required |

## Outputs

`vpc_id`, `vpc_cidr`, `public_subnet_ids`, `private_subnet_ids`, `isolated_subnet_ids`, `private_route_table_ids`, `isolated_route_table_ids`, `endpoint_security_group_id`, `flow_log_bucket_arn`.

## Static checks

- checkov: `CKV2_AWS_1` is skipped inline on the isolated NACL. It is attached through `subnet_ids`, but checkov does not resolve the splat reference.
- tflint: not run; it is not installed in this environment.
