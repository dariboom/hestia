# modules/data

This module holds the regional data plane for one `live/<env>/<region>` stack:

- three S3 buckets (artifacts, logs, backups);
- Secrets Manager containers (no values);
- ARNs for SecureString parameters that are created out-of-band;
- optional cross-region replication of the backups bucket.

## Guarantees

- **Region lock:** `region` must be `eu-central-1` or `eu-west-3`. A `terraform_data` precondition rejects a provider region that differs from it.
- **Buckets** are built with `modules/s3-bucket`, so every bucket gets SSE-KMS with the customer key `kms_key_arn`, versioning, TLS-only access and a policy that only `bucket_admin_role_arns` may change. Names are `hestia-<env>-<rc>-<purpose>-<account>`; the account ID is read from the caller identity, never written down.

  | Bucket | Classification | Transition (day 30 by default) | Expiration | Noncurrent versions kept |
  |---|---|---|---|---|
  | artifacts | internal | STANDARD_IA | none by default | 30 days |
  | logs | personal | STANDARD_IA | ≤ 400 days, required | 1 day |
  | backups | personal | GLACIER_IR | ≤ 90 days, required | 7 days |

  The logs and backups caps are the GDPR erasure bound. A deletion reaches the last copy no later than expiration plus the noncurrent retention.
- **No secret values:** `aws_secretsmanager_secret.app` creates empty containers named `hestia/<env>/<rc>/app/<name>`. The external CI/CD secret store writes the values, and workloads read them at runtime through IRSA or task roles. Containers are encrypted with `secrets_kms_key_arn`, and the recovery window is 30 days in prod and 7 days elsewhere. Three checks enforce this:
  - `policies/secrets.rego` denies `aws_secretsmanager_secret_version` (as a resource or a data source) and SecureString parameters with a value, in HCL and plan modes;
  - `make secrets` runs gitleaks and a grep gate for the same patterns;
  - `policies/gdpr.rego` denies defaults on secret-like variables. Names ending in `_arn(s)` or `_name(s)` count as references and are allowed.
- **SecureString references:** `ssm_secure_parameter_names` takes names only, and each must start with `/hestia/<env>/`. The module returns their ARNs so consumers can be granted `ssm:GetParameter` on exact resources.
- **Replication** (`enable_cross_region_replication`, off by default):
  - Only the backups bucket is replicated, because it is the DR copy. Artifacts can be rebuilt, and logs stay in the region they came from.
  - Replicas are written as GLACIER_IR and encrypted with the destination region's key.
  - Delete markers are not replicated, so a deletion in the source cannot erase the DR copy. The destination's own lifecycle (≤ 90 days) still bounds erasure.
  - The role `hestia-<env>-<rc>-data-replication` has the `hestia-<env>-boundary` permissions boundary and is assumable only by S3 from this account. It can read replication data from the source bucket and replicate into the destination bucket's objects. `kms:Decrypt` and `kms:Encrypt` are each scoped by `kms:ViaService` and the S3 encryption context (bucket ARN, because bucket keys are enabled).
  - The destination must be in the other allowed region. A cross-variable validation enforces this; it runs at plan time, not in `terraform validate`.

## Example

```hcl
module "data" {
  source = "../../../modules/data"

  region                 = "eu-central-1"
  environment            = "prod"
  kms_key_arn            = module.kms_data.key_arn # modules/kms-key
  bucket_admin_role_arns = ["arn:aws:iam::<AWS_ACCOUNT_ID>:role/hestia-prod-tf-deploy"]

  secrets_kms_key_arn        = module.kms_secrets.key_arn
  app_secret_names           = ["app-api-key"]
  ssm_secure_parameter_names = ["<SSM_PARAMETER_NAME>"]

  enable_cross_region_replication = true
  replication_destination = {
    bucket_arn  = "arn:aws:s3:::hestia-prod-fr-backups-<AWS_ACCOUNT_ID>"
    kms_key_arn = "<FR_DATA_KMS_KEY_ARN>"
    region      = "eu-west-3"
  }
}
```

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `region` | string | required | `eu-central-1` or `eu-west-3`. |
| `environment` | string | required | `dev`, `staging` or `prod`. |
| `tags` | map(string) | `{}` | |
| `kms_key_arn` | string | required | Key ARN for the buckets; aliases are rejected. |
| `bucket_admin_role_arns` | list(string) | required | Must not be empty. |
| `bucket_lifecycle` | object | see table above | Per bucket `{transition_days, expiration_days}`. Transitions must be at least 30 days and expiration must come after the transition. |
| `secrets_kms_key_arn` | string | `null` | Required when `app_secret_names` is set. |
| `app_secret_names` | list(string) | `[]` | Lowercase kebab-case names, at most 63 characters. |
| `ssm_secure_parameter_names` | list(string) | `[]` | Each must start with `/hestia/<env>/`. |
| `enable_cross_region_replication` | bool | `false` | |
| `replication_destination` | object | `null` | `{bucket_arn, kms_key_arn, region}`; required when replication is on. |

## Outputs

| Name | Description |
|---|---|
| `bucket_arns` | Bucket ARNs keyed by `artifacts`, `logs` and `backups`. |
| `app_secret_arns` | Container ARNs keyed by app secret name. |
| `ssm_secure_parameter_arns` | Parameter ARNs keyed by name. |
| `replication_role_arn` | Replication role ARN, or `null` when replication is off. |

## Static checks

- checkov: `CKV2_AWS_57` is skipped inline on the secret containers. Rotation belongs to the external secret store, and Terraform holds no value to rotate. The `CKV_AWS_144` and `CKV_AWS_300` skips live in `modules/s3-bucket`.
- `terraform validate`: run against a scratch root, with the replication, secrets and invalid-lifecycle cases. The module has no `examples/` root.
- tflint: not run; it is not installed in this environment.
