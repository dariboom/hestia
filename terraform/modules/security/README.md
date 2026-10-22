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
- The Config role is added to `audit` automatically.
- The plan named three keys. This module has five, because the other modules expect separate `secrets` and `compute` keys.

## Home region and the other region

| | `home_region` | other region |
|---|---|---|
| Security Hub finding aggregator (links the other region) | yes | no |
| Config aggregator (both regions) | yes | no |
| Config records global types (IAM) | yes | no, so each item is recorded once |
| Security Hub alerts | own-region findings only | own-region findings only |

The Security Hub alert rule filters on `Region`. Without that filter, findings copied to `home_region` by the aggregator would alert a second time.

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

## Dependencies outside this module

- **Audit bucket:** the bucket `hestia-<env>-<rc>-audit-<account>` must exist before the Config delivery channel is created. It is created in Task 10.
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

## Outputs

| Name | Description |
|---|---|
| `kms_key_arns` | Key ARNs by name. |
| `security_alerts_topic_arn` | SNS topic for high-severity findings. |

## Static checks

- **checkov:** 55 passed, 0 failed, 4 inline skips, each justified in the code:
  - `CKV_AWS_111`, `CKV_AWS_356` (in `modules/kms-key`): a key policy's `Resource "*"` means that key only.
  - `CKV2_AWS_3`: no Organizations GuardDuty administrator.
  - `CKV2_AWS_48`: global Config types are recorded in `home_region` only.
- **conftest:** all policies pass. The managed `AWS_ConfigRole` attachment is the only non-inline policy.
- **gitleaks:** clean. The only account ID is the synthetic `000000000000` in scratch fixtures.
- **`terraform validate`:** run against scratch roots.
  - Valid FR (dev) and DE (prod) cases pass.
  - An invalid case is rejected with six variable errors: region `us-east-1`, environment `qa`, home region `eu-north-1`, key name `backups`, a full ruleset ARN as standard, and a parameter outside `/hestia/`.
- **tflint:** not run; it is not installed in this environment.
- No `terraform plan` or `apply` has been run against this module.
