# modules/edge

This module holds the global edge of one environment (ADR-005). Route 53 is a global service, so `live/<env>/global` applies this module once, with a DE (`eu-central-1`) default provider. It creates:

- a private zone `internal_domain_name`, associated with the DE and FR VPCs;
- when `enable_public_ingress` is set, a public zone `domain_name` with:
  - `portal.<domain>`: latency routing across DE and FR, with health checks (active-active reads);
  - `api.<domain>`: failover routing, PRIMARY = DE, SECONDARY = FR;
- when `enable_cloudfront` is set, an anonymized dashboard at `dashboard.<domain>` behind CloudFront.

The regional ALBs come from `modules/edge/regional` (T15). The live stack reads their `alb_dns_name` and `alb_zone_id` from SSM (`/hestia/<env>/<rc>/alb_dns`, `/hestia/<env>/<rc>/alb_zone_id`) and passes them as `regional_albs`. It never uses `terraform_remote_state`.

## Providers

The module needs two AWS providers:

- `aws`: eu-central-1. Route 53 and the IAM policy document use it.
- `aws.us_east_1`: declared through `configuration_aliases`. Only the CloudFront resources use it. With `enable_cloudfront = false` the module creates nothing in us-east-1 and makes no us-east-1 API calls, but the caller must still pass the alias.

## Two-pass ordering

The regional certificates validate in the public zone, and the global records point at the regional ALBs. To avoid a cycle:

1. Apply the global stack with `enable_public_ingress = true` and `regional_albs = {}`. This creates the zones only.
2. Apply the regional stacks. Their certificates validate in `public_zone_id`, and each stack publishes its ALB to SSM.
3. Apply the global stack again with `regional_albs` read from SSM. `regional_albs` must then include `eu-central-1`, because DE is the api PRIMARY.

## Guarantees

- **Region lock:** each `vpc_associations` region and each `regional_albs` key must be `eu-central-1` or `eu-west-3`.
- **Routing:**
  - `portal` uses latency records, one per region (`set_identifier` = `de` or `fr`).
  - `api` uses failover records. FR answers only when DE is unhealthy.
  - Every record has an HTTPS Route 53 health check on the ALB (`health_check_path`, port 443, 3 failures at a 30 s interval), and evaluates target health.
- **No personal data in DNS:** record names are fixed (`portal`, `api`, `dashboard`).
- **CloudFront (optional, off by default):**
  - It serves only the S3 prefixes in `cloudfront_origin_paths` of `dashboard_origin`. The `dashboard_origin_policy_json` output grants `s3:GetObject` on those prefixes to this distribution alone (`AWS:SourceArn`). The rest of the bucket stays private.
  - The origin is read through Origin Access Control (SigV4, always signed). There is no public bucket.
  - `PriceClass_100` keeps edge locations to Europe and North America. A geo allowlist serves only `cloudfront_geo_allowlist`, which defaults to the EU27 plus IS, LI and NO.
  - Viewers must use HTTPS: HTTP is redirected, the floor is `TLSv1.2_2021` and SNI is required.
  - The managed `CachingOptimized` cache policy forwards no cookies, no query strings and no `Authorization` header. The managed `SecurityHeadersPolicy` adds HSTS, `X-Content-Type-Options`, frame and referrer headers.
  - A CLOUDFRONT-scope WAF runs `waf_rule_config.managed_rule_groups` in order (default: Common, KnownBadInputs including Log4j, AmazonIpReputationList), then blocks a client IP above `waf_rule_config.rate_limit_per_5min` requests in 5 minutes.
  - Standard logs go to `cloudfront_log_bucket` in DE, without cookies.
- **No IAM:** the module creates no roles or policies. It only renders a bucket policy document for the caller.

## ADR-005 exceptions

Every us-east-1 resource and data source in `cloudfront.tf` carries the comment `# ADR-005 exception`. All of them exist only when `enable_cloudfront = true`.

| Resource | Why us-east-1 |
|---|---|
| `aws_acm_certificate.dashboard`, `aws_acm_certificate_validation.dashboard` | CloudFront accepts viewer certificates only from us-east-1. |
| `aws_wafv2_web_acl.dashboard` (scope `CLOUDFRONT`) | CLOUDFRONT-scope ACLs exist only in us-east-1. |
| `aws_cloudfront_origin_access_control`, `aws_cloudfront_distribution`, managed-policy data sources | CloudFront's control plane is global and is managed through us-east-1. |

What does not leave the EU: the dashboard content (S3 in DE or FR), the access logs (DE bucket) and the DNS zones' data. Only control-plane metadata (certificate, ACL, distribution config) is stored in us-east-1.

## Known gaps

- **No CloudFront WAF logs.** WAF logging needs a destination in the ACL's region (us-east-1), which `policies/region-lock.rego` denies. CloudFront standard logs in DE record every request instead, and WAF metrics and sampled requests stay on.
- **No public DNS query logging, no DNSSEC.** Both need us-east-1 resources (a log group, an asymmetric KMS key) outside the ADR-005 exceptions.
- **Route 53 health checkers run worldwide.** They probe the ALB from AWS checker regions, some outside the EU. They send no personal data, only a GET to `health_check_path`.
- **Cross-variable checks run at plan time.** `terraform validate` does not evaluate "`dashboard_origin` and `cloudfront_log_bucket` are required when `enable_cloudfront`". `terraform plan` does.

## Buckets and keys required

The module does not create the buckets. Their owner must provide:

- **`dashboard_origin`:** a `modules/s3-bucket` bucket in eu-central-1 or eu-west-3, holding only anonymized aggregates under `cloudfront_origin_paths`. Pass `dashboard_origin_policy_json` in its `additional_policy_statements`. The bucket's KMS key policy must allow `cloudfront.amazonaws.com` `kms:Decrypt`, with `AWS:SourceArn` = the distribution ARN, because OAC reads SSE-KMS objects.
- **`cloudfront_log_bucket`:** a bucket in eu-central-1. CloudFront standard logging writes through object ACLs, so the bucket needs `BucketOwnerPreferred` ownership with ACLs enabled (CloudFront grants itself `FULL_CONTROL` through the `awslogsdelivery` account). The bucket also needs Block Public Access and a lifecycle that expires objects in ≤ 400 days, because the logs hold client IPs. With SSE-KMS, the key policy must allow `delivery.logs.amazonaws.com`.

## Example

```hcl
provider "aws" {
  region = "eu-central-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1" # ADR-005 exception: CloudFront certificate and WAF only
}

data "aws_ssm_parameter" "alb_dns" {
  for_each = { "eu-central-1" = "de", "eu-west-3" = "fr" }
  name     = "/hestia/prod/${each.value}/alb_dns"
}

data "aws_ssm_parameter" "alb_zone_id" {
  for_each = { "eu-central-1" = "de", "eu-west-3" = "fr" }
  name     = "/hestia/prod/${each.value}/alb_zone_id"
}

module "edge" {
  source    = "../../../modules/edge"
  providers = { aws = aws, aws.us_east_1 = aws.us_east_1 }

  environment          = "prod"
  domain_name          = "example.eu"
  internal_domain_name = "prod.hestia.internal"
  vpc_associations = [
    { vpc_id = "<DE_VPC_ID>", region = "eu-central-1" },
    { vpc_id = "<FR_VPC_ID>", region = "eu-west-3" },
  ]

  enable_public_ingress = true
  regional_albs = {
    for r, p in data.aws_ssm_parameter.alb_dns :
    r => { dns_name = p.value, zone_id = data.aws_ssm_parameter.alb_zone_id[r].value }
  }

  enable_cloudfront = true
  dashboard_origin = {
    bucket_arn                  = module.dashboard_bucket.arn
    bucket_regional_domain_name = module.dashboard_bucket.domain_name
  }
  cloudfront_log_bucket = "hestia-prod-de-cf-logs-<AWS_ACCOUNT_ID>"
}
```

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `environment` | string | required | `dev`, `staging` or `prod`. |
| `tags` | map(string) | `{}` | |
| `domain_name` | string | required | Public zone, lower-case DNS name. |
| `internal_domain_name` | string | required | Private zone shared by the VPCs. |
| `vpc_associations` | list(object{vpc_id, region}) | required | At least one, allowed regions only. |
| `enable_public_ingress` | bool | `false` | Creates the public zone and the `portal`/`api` records. |
| `regional_albs` | map(object{dns_name, zone_id}) | `{}` | Keyed by region. Empty on the first pass, otherwise must include `eu-central-1`. |
| `health_check_path` | string | `"/healthz"` | |
| `enable_cloudfront` | bool | `false` | The only switch that creates us-east-1 resources. Also creates the public zone. |
| `dashboard_origin` | object{bucket_arn, bucket_regional_domain_name} | `null` | Required with CloudFront. Bucket in DE or FR. |
| `cloudfront_origin_paths` | list(string) | `["/dashboard"]` | S3 prefixes CloudFront may read. The first holds `index.html`. |
| `cloudfront_log_bucket` | string | `null` | Required with CloudFront. DE bucket name. |
| `cloudfront_geo_allowlist` | list(string) | EU27 + IS, LI, NO | Upper-case ISO country codes. |
| `waf_rule_config` | object{managed_rule_groups, rate_limit_per_5min} | `{}` | Defaults: the three groups above, `2000`. Rate 100 to 2 000 000 000. |

## Outputs

| Name | Description |
|---|---|
| `private_zone_id` | Private zone shared by the regional VPCs. |
| `public_zone_id` | Public zone, the regional certificates' `hosted_zone_id`. Null without public ingress or CloudFront. |
| `cloudfront_distribution_id` | Dashboard distribution, or null. |
| `dashboard_origin_policy_json` | Bucket policy statement for `dashboard_origin`, or null. |

## Static checks

- checkov: inline skips, each with a justification in the code.
  - `CKV2_AWS_39`, `CKV2_AWS_38` on both zones: query logging and DNSSEC (see Known gaps; the private zone is logged by Resolver query logging and cannot be signed).
  - `CKV2_AWS_23` on `portal` and `api`: the alias targets come from another stack.
  - `CKV2_AWS_31` on the CloudFront WAF: no in-EU log destination is possible.
  - `CKV2_AWS_47` on the distribution: the Log4j rule group is added through a dynamic block that checkov does not expand.
  - `CKV_AWS_310` on the distribution: a single static S3 origin needs no failover origin.
- conftest: `region-lock` passes; the us-east-1 provider is an alias and only global-service resources use it.
- gitleaks: clean. No account IDs except the synthetic `000000000000` in scratch fixtures.
- `terraform validate`: run against scratch roots.
  - Passes: both ALBs with public ingress and CloudFront, and a minimal dev case with everything off.
  - Rejected: a us-east-1 VPC, `regional_albs` without DE, a lower-case country code, a wildcard origin path and a rate limit of 50.
  - The module has no `examples/` root.
- tflint: not run; it is not installed in this environment.
