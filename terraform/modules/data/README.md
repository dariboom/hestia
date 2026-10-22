# modules/data

This module holds the regional data plane for one `live/<env>/<region>` stack:

- three S3 buckets (artifacts, logs, backups);
- Secrets Manager containers (no values);
- ARNs for SecureString parameters that are created out-of-band;
- optional cross-region replication of the backups bucket;
- an optional PostgreSQL database: a primary in the active region, or a cross-region read replica in the passive one (ADR-003).

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
- **Database** (`db_role` = `"primary"` or `"replica"`; `null` creates none):
  - **No password in Terraform.** The primary sets `manage_master_user_password`, so RDS generates the master password and keeps it in a Secrets Manager secret encrypted with `secrets_kms_key_arn`. The module outputs only that secret's ARN. Applications connect with IAM database authentication. `policies/secrets.rego` denies `password`, `password_wo`, `master_password` and `master_password_wo` on `aws_db_instance` and `aws_rds_cluster`, in HCL and plan modes.
  - **Always on:** Multi-AZ, gp3 storage encrypted with `kms_key_arn`, `publicly_accessible = false`, the `rds-ca-rsa2048-g1` CA and minor-version upgrades. The parameter group sets `rds.force_ssl = 1`.
  - **Network:** the security group allows only 5432, from `db_allowed_security_group_ids` and `db_peer_cidr_blocks` (`0.0.0.0/x` is rejected). The subnet group uses the isolated subnets `db_subnet_ids`, at least two of them.
  - **Audit logging:** pgaudit (`ddl,role`), connections and disconnections, DDL statements, and statements slower than 1 s. `log_statement = all` is deliberately off, because statement text can contain personal data.
  - **Logs and monitoring:** the `postgresql` and `upgrade` logs go to log groups the module creates first, encrypted with `db_log_kms_key_arn` and kept for `db_log_retention_days` (≤ 400). Performance Insights is encrypted with `kms_key_arn`. Enhanced monitoring (60 s) uses a role with the `hestia-<env>-boundary` permissions boundary.
  - **Backups:** automated backups are kept 7–35 days (35 in prod, the retention floor in the Global Constraints). In prod, deletion protection is on and a final snapshot is required. In dev and staging, both are off.
  - **Replica:** a replica takes `db_source_db_arn` (the primary's `db_instance_arn` output) and inherits storage and credentials. `enable_db_backup_replication` also copies the primary's automated backups into the replica's region, encrypted with that region's `kms_key_arn`. A read replica follows logical corruption, so the backups are the point-in-time restore path after a region loss.
  - **Preconditions:** a replica needs `db_source_db_arn` and a primary must not set it. A primary needs `secrets_kms_key_arn`. Every database needs `db_vpc_id`, `db_log_kms_key_arn` and at least two subnets. These are checked at plan time.

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

  db_role                       = "primary"
  db_vpc_id                     = module.network.vpc_id
  db_subnet_ids                 = module.network.isolated_subnet_ids
  db_allowed_security_group_ids = ["<EKS_NODE_SECURITY_GROUP_ID>"]
  db_peer_cidr_blocks           = ["<FR_VPC_CIDR>"]
  db_log_kms_key_arn            = module.kms_logs.key_arn
}

# Passive region (live/prod/eu-west-3): a read replica plus a copy of the primary's backups.
module "data" {
  # ...buckets and secrets as above, with region = "eu-west-3"...
  db_role                      = "replica"
  db_source_db_arn             = "<DE_DB_INSTANCE_ARN>" # from the DE stack's db_instance_arn output
  enable_db_backup_replication = true
  # db_vpc_id, db_subnet_ids and db_log_kms_key_arn come from this region's modules.
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
| `db_role` | string | `null` | `primary`, `replica` or `null` (no database). |
| `db_source_db_arn` | string | `null` | ARN of the primary instance. Required for a replica and for backup replication. Must be in an allowed EU region. |
| `db_engine_version` | string | `"17"` | Its major version selects the parameter group family. |
| `db_instance_class` | string | `"db.m7g.large"` | |
| `db_allocated_storage` / `db_max_allocated_storage` | number | `100` / `500` | GiB. The maximum must be at least the allocated size. |
| `db_backup_retention_days` | number | `14` | 7–35 days; prod must set 35. |
| `db_vpc_id` | string | `null` | Required when a database is created. |
| `db_subnet_ids` | list(string) | `[]` | Isolated subnets; at least two. |
| `db_allowed_security_group_ids` | list(string) | `[]` | Allowed on 5432. |
| `db_peer_cidr_blocks` | list(string) | `[]` | Peer VPC CIDRs allowed on 5432; `0.0.0.0/x` is rejected. |
| `db_log_kms_key_arn` | string | `null` | Logs KMS key. Required when a database is created. |
| `db_log_retention_days` | number | `365` | A CloudWatch retention value of at most 400. |
| `enable_db_backup_replication` | bool | `false` | Copies the primary's automated backups into this region. |

## Outputs

| Name | Description |
|---|---|
| `bucket_arns` | Bucket ARNs keyed by `artifacts`, `logs` and `backups`. |
| `app_secret_arns` | Container ARNs keyed by app secret name. |
| `ssm_secure_parameter_arns` | Parameter ARNs keyed by name. |
| `replication_role_arn` | Replication role ARN, or `null` when replication is off. |
| `db_instance_arn` | DB instance ARN; a replica stack takes it as `db_source_db_arn`. |
| `db_endpoint` | `host:port`. |
| `master_user_secret_arn` | ARN of the RDS-managed master secret (primary only); never the value. |
| `db_security_group_id` | Database security group ID. |
| `db_backup_replication_arn` | ARN of the replicated automated backups, or `null`. |

## Static checks

- checkov: `CKV2_AWS_57` is skipped inline on the secret containers. Rotation belongs to the external secret store, and Terraform holds no value to rotate. The `CKV_AWS_144` and `CKV_AWS_300` skips live in `modules/s3-bucket`. Three more skips are inline on the database:
  - `CKV_AWS_293`: deletion protection is on only in prod.
  - `CKV2_AWS_30`: `log_statement = all` stays off, because statement text can contain personal data.
  - `CKV2_AWS_5`: checkov does not resolve the `count`-indexed security group attachment.
- `terraform validate`: run against a scratch root, with the replication, secrets, database primary, database replica (with backup replication) and invalid-lifecycle cases. The module has no `examples/` root.
- tflint: not run; it is not installed in this environment.
