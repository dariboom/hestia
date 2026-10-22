# modules/edge/regional

This module holds the public ingress for one `live/<env>/<region>` stack (ADR-005):

- an internet-facing ALB `hestia-<env>-<rc>-alb` with a DNS-validated regional ACM certificate;
- an IP target group `hestia-<env>-<rc>-tg`, which the EKS AWS Load Balancer Controller fills through a `TargetGroupBinding`;
- a regional WAF ACL `hestia-<env>-<rc>-waf` on the ALB, with request logs in the region.

CloudFront is off by default (ADR-005). The global edge (`modules/edge`, T16) points Route 53 at `alb_dns_name` and `alb_zone_id`, which the live stack publishes to SSM.

## Guarantees

- **Region lock:** `region` must be `eu-central-1` or `eu-west-3`. A precondition on the ALB rejects a provider region that differs from it.
- **TLS only:**
  - The HTTPS listener uses `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.3, plus TLS 1.2 with forward-secret ciphers).
  - Port 80 serves no content. It only answers `301` to HTTPS.
  - The ALB drops requests with invalid header fields.
  - Traffic to targets is re-encrypted: the target group and its health check use HTTPS on `target_port`.
- **Certificate:** ACM, DNS-validated through records in `hosted_zone_id`. The listener waits for validation. No private key is handled by Terraform.
- **Security group:** ingress is 443 and 80 from anywhere, the only two public ports. Egress is only `target_port` to the VPC CIDR, because targets are pod IPs.
- **Deletion protection:** on when `environment = "prod"`. Dev and staging stay disposable.
- **WAF (REGIONAL), associated with the ALB:**
  - `waf_managed_rule_groups` run in list order, in their default block mode. The defaults are `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesKnownBadInputsRuleSet` (which includes Log4j), `AWSManagedRulesSQLiRuleSet` and `AWSManagedRulesAmazonIpReputationList`.
  - A last rule blocks a client IP that exceeds `rate_limit_per_5min` requests in 5 minutes.
  - Every rule emits CloudWatch metrics and sampled requests.
- **WAF logs stay in `region`:**
  - Logs go to the log group `aws-waf-logs-hestia-<env>-<rc>`. WAF accepts only the `aws-waf-logs-` prefix.
  - The group is encrypted with `log_kms_key_arn` and kept for `log_retention_days` (≤ 400, the GDPR erasure bound, because logs hold client IPs).
  - The `authorization` and `cookie` headers are redacted before logging, so bearer tokens and session cookies never reach the logs.
- **No IAM:** the module creates no roles or policies.

## Access-log bucket: an exception to customer-managed keys

ALB access-log delivery supports only SSE-S3 (`AES256`), not SSE-KMS. The bucket named by `access_log_bucket` therefore cannot use a customer-managed key. It also cannot be built with `modules/s3-bucket`, which always sets SSE-KMS. This is a documented exception to the "customer-managed KMS keys everywhere" constraint. It is limited to ALB access logs.

The bucket's owner (the security module or the live stack) must provide:

- default encryption SSE-S3, versioning, Block Public Access, and `BucketOwnerEnforced` ownership;
- a bucket policy that lets `logdelivery.elasticloadbalancing.amazonaws.com` `s3:PutObject` to `<bucket>/hestia-<env>-<rc>-alb/AWSLogs/<AWS_ACCOUNT_ID>/*`, with `aws:SourceAccount = <AWS_ACCOUNT_ID>`;
- a lifecycle that expires objects in ≤ 400 days, because logs hold client IPs;
- the bucket in the same region as the ALB.

## Key and log policies required

- `log_kms_key_arn`: the key policy must allow `logs.<region>.amazonaws.com`, with the `kms:EncryptionContext:aws:logs:arn` condition. This is the same "logs" key the compute module uses.
- WAF delivery to CloudWatch Logs needs an account-level log resource policy for `delivery.logs.amazonaws.com`. AWS creates it on the first logging configuration if the deploying principal may call `logs:PutResourcePolicy`. The module does not manage that account-wide policy.

## Example

```hcl
module "edge_regional" {
  source = "../../../modules/edge/regional"

  region            = "eu-central-1"
  environment       = "prod"
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  domain_name       = "api.example.eu"
  hosted_zone_id    = "<HOSTED_ZONE_ID>"
  access_log_bucket = "hestia-prod-de-alb-logs-<AWS_ACCOUNT_ID>"
  log_kms_key_arn   = module.kms_logs.key_arn # modules/kms-key

  rate_limit_per_5min = 2000
}
```

Bind workloads to the target group from Kubernetes, and admit `target_port` from `alb_security_group_id` on the pods' security group:

```yaml
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata: { name: api, namespace: hestia }
spec:
  serviceRef: { name: api, port: 8443 }
  targetGroupARN: <TARGET_GROUP_ARN> # module output target_group_arn
  targetType: ip
```

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `region` | string | required | `eu-central-1` or `eu-west-3`. |
| `environment` | string | required | `dev`, `staging` or `prod`. |
| `tags` | map(string) | `{}` | |
| `vpc_id` | string | required | From the network module. |
| `public_subnet_ids` | list(string) | required | At least two, from the public tier. |
| `domain_name` | string | required | Lower-case DNS name the certificate covers. |
| `hosted_zone_id` | string | required | Zone for the ACM validation records. |
| `access_log_bucket` | string | required | Existing SSE-S3 bucket name; see above. |
| `log_kms_key_arn` | string | required | Key ARN, not an alias, for the WAF log group. |
| `log_retention_days` | number | `365` | CloudWatch value ≤ 400. |
| `waf_managed_rule_groups` | list(string) | the four above | `AWSManagedRules*` names, non-empty. |
| `rate_limit_per_5min` | number | `2000` | 100 to 2 000 000 000. |
| `target_port` | number | `8443` | HTTPS pod port, 1024–65535. |
| `health_check_path` | string | `"/healthz"` | |

## Outputs

| Name | Description |
|---|---|
| `alb_arn` | ALB ARN. |
| `alb_dns_name` | ALB DNS name, published to SSM as `/hestia/<env>/<rc>/alb_dns`. |
| `alb_zone_id` | ALB hosted zone ID, published as `/hestia/<env>/<rc>/alb_zone_id`. |
| `target_group_arn` | IP target group for the `TargetGroupBinding`. |
| `alb_security_group_id` | ALB security group. |
| `web_acl_arn` | Regional WAF ACL. |

## Static checks

- checkov: three inline skips.
  - `CKV_AWS_260` (twice): public 443 and 80 ingress is the point of a public ALB. Port 80 only redirects.
  - `CKV_AWS_150`: deletion protection is conditional on `environment = "prod"`, which checkov does not evaluate.
- gitleaks: clean. ACM uses its default RSA-2048 key, because setting the P-256 elliptic-curve key algorithm explicitly matched the `generic-api-key` rule (a false positive on the algorithm name).
- `terraform validate`: run against a scratch root. The valid prod case passes. An invalid case is rejected: `rate_limit_per_5min = 50` and a non-`AWSManagedRules*` group. The module has no `examples/` root.
- tflint: not run; it is not installed in this environment.
