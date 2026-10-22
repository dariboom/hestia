# modules/security

This module holds the per-region security baseline for one `live/<env>/<region>` stack. Every region runs it; the `home_region` (default `eu-central-1`) also holds the aggregators. It creates:

- **Keys:** five customer-managed KMS keys `alias/hestia-<env>-<rc>-<name>`, built with `modules/kms-key`.
- **Detection:**
  - GuardDuty with S3, EKS audit logs, EKS runtime (managed add-on), RDS login and EBS malware protection.
  - Security Hub with consolidated control findings and the standards listed in `securityhub_standards`.
  - An IAM Access Analyzer for the account.
- **AWS Config:**
  - a recorder of all supported resource types;
  - delivery to the audit bucket, encrypted with the audit key;
  - in `home_region`, an account aggregator over both regions.
- **Audit store:** a WORM bucket `hestia-<env>-<rc>-audit-<account>` in every region, optionally replicated to the peer region's audit bucket.
- **CloudTrail:** in `home_region` only, one multi-region trail `hestia-<env>-<rc>-trail` into the audit bucket, with a copy in CloudWatch Logs.
- **Alerting:**
  - GuardDuty findings of severity 7 or higher, and Security Hub CRITICAL/HIGH findings, go through EventBridge to the SNS topic `hestia-<env>-<rc>-security-alerts`;
  - the topic is encrypted with the audit key and has an email subscription.

## Keys

| Name | For | Service principals in the key policy |
|---|---|---|
| `data` | RDS and data buckets | none |
| `logs` | CloudWatch Logs, VPC flow logs, WAF logs | `logs.<region>` (condition `kms:EncryptionContext:aws:logs:arn`), `delivery.logs` |
| `audit` | CloudTrail, Config delivery, alerts topic | `cloudtrail` (trails `hestia-<env>-*`), `events` (rules `hestia-<env>-<rc>-*`) |
| `secrets` | Secrets Manager and SSM SecureString | none |
| `compute` | EKS secrets, EBS, Lambda environment, schedules | `scheduler` (schedules `hestia-<env>-<rc>-*`) |

- Every service statement is limited to `aws:SourceAccount` in `allowed_account_ids`.
- Other modules take key ARNs from `kms_key_arns` and never edit a key policy. A principal they need is added here, as each module's README lists.
- Roles that use a key come in through `key_usage_role_arns`, by key name.
- The Config role and, when replication is on, the audit replication role are added to `audit` automatically.
- The plan named three keys. This module has five, because the other modules expect separate `secrets` and `compute` keys.

## Home region and the other region

| | `home_region` | other region |
|---|---|---|
| Security Hub finding aggregator (links the other region) | yes | no |
| Config aggregator (both regions) | yes | no |
| Config records global types (IAM) | yes | no, so each item is recorded once |
| CloudTrail trail (multi-region, global service events) | yes | no; the home trail records it |
| Audit bucket | yes | yes |
| Security Hub alerts | own-region findings only | own-region findings only |

The Security Hub alert rule filters on `Region`. Without that filter, findings copied to `home_region` by the aggregator would alert a second time.

## Audit store and CloudTrail

- **Audit bucket** (`modules/s3-bucket`):
  - Encrypted with the audit key.
  - Object Lock for `audit_retention_days` (default 3650) in `object_lock_mode`. prod requires COMPLIANCE and at least 3650 days; dev and staging may use GOVERNANCE.
  - Moves to Glacier Instant Retrieval after 90 days and to Deep Archive after 365. Objects expire when their retention ends.
  - Only `audit_bucket_admin_role_arns` may change its policy or ACLs.
  - Records hold only pseudonymous IDs, so Object Lock does not conflict with GDPR erasure.
- **Trail** (`home_region` only):
  - Multi-region, with global service events and log file validation, encrypted with the audit key.
  - Records management events, object reads and writes on `cloudtrail_data_event_bucket_arns`, and object reads on the audit bucket. Writes to the audit bucket are not recorded, because they are the trail's own deliveries.
  - The bucket grants CloudTrail `GetBucketAcl` and `PutObject` under `AWSLogs/<account>/` only for this trail's ARN (`aws:SourceArn`).
  - A copy goes to the CloudWatch log group `/aws/cloudtrail/hestia-<env>-<rc>-trail`, encrypted with the logs key and kept for `cloudtrail_log_retention_days`. The delivery role may only write log streams in that group.
- **Replication** (`audit_replication_destination`, off when `null`):
  - The role `hestia-<env>-<rc>-audit-replication` has the boundary and is assumable only by S3 from this account.
  - It reads object versions with their Object Lock retention and legal hold, and replicates them into the destination bucket.
  - `kms:Decrypt` on the audit key and `kms:Encrypt` on the destination key are each scoped by `kms:ViaService` and the S3 encryption context.
  - Delete markers are not replicated. Replicas are stored as Glacier Instant Retrieval.

## Guarantees

- **Region lock:** `region` and `home_region` must be `eu-central-1` or `eu-west-3`. A precondition on the GuardDuty detector rejects a provider region that differs from `region`.
- **No secret in Terraform:**
  - Account IDs come from `allowed_account_ids` (`TF_VAR_*` at run time) and from `aws_caller_identity`.
  - The alert email address is read from an SSM String parameter, so no address is committed.
  - The address is personal data, not a secret. It is stored in state, which is encrypted.
- **Config role:**
  - It carries the `hestia-<env>-boundary` permissions boundary.
  - It has the AWS managed `AWS_ConfigRole`.
  - Its inline policy only allows writes under `AWSLogs/<account>/Config/` in the audit bucket. It may use the audit key only through S3.
- **Alerts topic:** only the two EventBridge rules of this stack may publish to it (`aws:SourceArn`).
- **prod audit floors:** the variable validations that compare with `environment` run at plan time only; `terraform validate` skips them. `policies/audit.rego` rejects GOVERNANCE or retention below 3650 days in `live/prod/` statically.

## Dependencies outside this module

- **Peer audit bucket:** with replication on, the peer region's stack must list `arn:aws:iam::<AWS_ACCOUNT_ID>:role/hestia-<env>-<rc>-audit-replication` in its `key_usage_role_arns["audit"]`. Without it, the destination key rejects the replicas.
- **Access logs:** `audit_access_log_bucket` must be an SSE-S3 bucket, because S3 server access logs cannot be delivered to an SSE-KMS bucket.
- **Alert email:** the SSM String parameter named by `alert_email_ssm_parameter_name` must exist. It is created out-of-band (`docs/secrets-handling.md`).
- **Email confirmation:** the email subscription stays pending until the recipient confirms it.
- **Organizations:** none. GuardDuty and Security Hub are enabled per account in each region, and `org/` holds SCPs only (Task 6).

## Example

```hcl
module "security" {
  source = "../../../modules/security"

  region                         = "eu-central-1"
  environment                    = "prod"
  allowed_account_ids            = [var.account_id] # TF_VAR_account_id, e.g. <AWS_ACCOUNT_ID>
  alert_email_ssm_parameter_name = "<SSM_PARAMETER_NAME>" # e.g. /hestia/prod/de/security/alert-email
  key_admin_role_arns            = ["arn:aws:iam::<AWS_ACCOUNT_ID>:role/hestia-prod-kms-admin"]
  key_usage_role_arns = {
    compute = [module.eks.cluster_role_arn]
    audit   = ["arn:aws:iam::<AWS_ACCOUNT_ID>:role/hestia-prod-fr-audit-replication"] # the peer's replication role
  }

  audit_bucket_admin_role_arns      = ["arn:aws:iam::<AWS_ACCOUNT_ID>:role/hestia-prod-admin"]
  cloudtrail_data_event_bucket_arns = ["arn:aws:s3:::hestia-prod-de-backups-<AWS_ACCOUNT_ID>"]
  audit_replication_destination = {
    bucket_arn  = "arn:aws:s3:::hestia-prod-fr-audit-<AWS_ACCOUNT_ID>"
    kms_key_arn = "arn:aws:kms:eu-west-3:<AWS_ACCOUNT_ID>:key/<KEY_ID>"
    region      = "eu-west-3"
  }
}
```

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `region` | string | required | `eu-central-1` or `eu-west-3`. |
| `environment` | string | required | `dev`, `staging` or `prod`. |
| `tags` | map(string) | `{}` | Mandatory `hestia:*` tags normally come from provider `default_tags`. |
| `home_region` | string | `eu-central-1` | Holds the aggregators and records global Config types. |
| `securityhub_standards` | list(string) | FSBP 1.0.0, CIS 3.0.0 | Short form `<name>/v/<version>`. |
| `allowed_account_ids` | list(string) | required | Supplied at run time; never committed. |
| `alert_email_ssm_parameter_name` | string | required | SSM String under `/hestia/`. |
| `key_admin_role_arns` | list(string) | `[]` | Administer every key; cannot use them. |
| `key_usage_role_arns` | map(list(string)) | `{}` | Keys: `data`, `logs`, `audit`, `secrets`, `compute`. |
| `audit_bucket_admin_role_arns` | list(string) | required | Only these may change the audit bucket policy or ACLs. |
| `audit_access_log_bucket` | string | `null` | SSE-S3 bucket for server access logs. |
| `audit_retention_days` | number | `3650` | Above 365; at least 3650 in prod. |
| `object_lock_mode` | string | `COMPLIANCE` | `COMPLIANCE` or `GOVERNANCE`; `COMPLIANCE` in prod. |
| `cloudtrail_data_event_bucket_arns` | list(string) | `[]` | S3 bucket ARNs whose object reads and writes are recorded. |
| `cloudtrail_log_retention_days` | number | `365` | CloudWatch retention value, at most 400. |
| `audit_replication_destination` | object | `null` | `{bucket_arn, kms_key_arn, region}`; key ARN, not alias; region in the allowlist and different from `region`. |

## Outputs

| Name | Description |
|---|---|
| `kms_key_arns` | Key ARNs by name. |
| `security_alerts_topic_arn` | SNS topic for high-severity findings. |
| `audit_bucket_arn` | This region's audit bucket. |
| `cloudtrail_arn` | Trail ARN in `home_region`; `null` in the other region. |

## Static checks

- **checkov:** 116 passed, 0 failed, 8 inline skips, each justified in the code:
  - `CKV_AWS_111`, `CKV_AWS_356` (in `modules/kms-key`): a key policy's `Resource "*"` means that key only.
  - `CKV_AWS_144`, `CKV2_AWS_62`, `CKV_AWS_300` (in `modules/s3-bucket`): replication is set by the caller (here, `audit_replication_destination`), notifications by consumers, and every lifecycle rule aborts incomplete uploads.
  - `CKV2_AWS_3`: no Organizations GuardDuty administrator.
  - `CKV2_AWS_48`: global Config types are recorded in `home_region` only.
  - `CKV_AWS_252`: the trail has no SNS delivery topic; high-severity findings alert through EventBridge.
- **conftest:** all policies pass, including `policies/audit.rego` (4 unit tests). The managed `AWS_ConfigRole` attachment is the only non-inline policy.
- **gitleaks:** clean. The only account ID is the synthetic `000000000000` in scratch fixtures.
- **`terraform validate`:** run against scratch roots.
  - Valid FR (dev) and DE (prod) cases pass.
  - An invalid case is rejected with eight variable errors: region `us-east-1`, environment `qa`, home region `eu-north-1`, key name `backups`, a full ruleset ARN as standard, a parameter outside `/hestia/`, a bucket name instead of an ARN for data events, and a log retention of 3650.
  - A valid FR case with a bucket name and a key alias as replication destination is rejected.
- **tflint:** not run; it is not installed in this environment.
- No `terraform plan` or `apply` has been run against this module.
