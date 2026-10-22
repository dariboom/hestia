# modules/s3-bucket

This module creates a hardened S3 bucket. Every Hestia bucket is created through it: state, audit, data lake, carbon reports and access logs.

## Guarantees

- **Access:** ACLs are disabled (`BucketOwnerEnforced`) and all four public-access-block flags are on.
- **Encryption and versioning:** versioning is always enabled. Encryption is SSE-KMS with a customer-managed key, with bucket keys on.
- **Bucket policy baseline.** It always contains these statements:
  - `DenyInsecureTransport`
  - `DenyPolicyAndAclChangesExceptAdmins`, which allows only `policy_admin_role_arns` to change the policy or ACLs
  - `DenyWrongEncryption` and `DenyWrongKmsKey`, which reject uploads that use a different algorithm or key

  Extra statements, passed through `additional_policy_statements`, are merged into the baseline. They cannot replace it.
- **Lifecycle:** at least one lifecycle rule is required. Every rule aborts incomplete multipart uploads after 7 days. Noncurrent versions expire after 90 days by default.
- **Object Lock:** it is optional and can only be set at creation. Audit buckets use `COMPLIANCE` in prod and `GOVERNANCE` elsewhere (ADR-007).
- **`force_destroy`:** it defaults to `false`. A precondition rejects it when `tags["hestia:environment"] == "prod"`.
- **Region lock:** a precondition rejects any region other than `eu-central-1` or `eu-west-3`.

## Example

```hcl
module "audit_bucket" {
  source                 = "../../modules/s3-bucket"
  name                   = "hestia-dev-de-audit-<suffix>"
  kms_key_arn            = module.audit_key.key_arn
  tags                   = local.tags
  policy_admin_role_arns = ["arn:aws:iam::<AWS_ACCOUNT_ID>:role/hestia-dev-admin"]
  object_lock            = { mode = "GOVERNANCE", days = 365 }
  lifecycle_rules = [{
    id          = "archive"
    transitions = [{ days = 90, storage_class = "GLACIER_IR" }]
  }]
}
```

## Inputs

| Name | Type | Default |
|---|---|---|
| `name` | string | required |
| `kms_key_arn` | string | required |
| `tags` | map(string), must include `hestia:environment` | required |
| `lifecycle_rules` | list(object), at least 1 | required |
| `policy_admin_role_arns` | list(string), at least 1 | required |
| `object_lock` | object({mode, days}) | `null` |
| `additional_policy_statements` | list(string) (JSON) | `[]` |
| `access_log_bucket` | string | `null` |
| `force_destroy` | bool | `false` |

## Outputs

`id`, `arn`, `domain_name`.
