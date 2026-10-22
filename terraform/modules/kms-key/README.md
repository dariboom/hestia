# modules/kms-key

This module creates a customer-managed KMS key and its alias. Every Hestia storage resource is encrypted with a key from this module.

## Guarantees

- `enable_key_rotation = true` is always set and cannot be turned off.
- The key policy never grants `kms:*` and never allows `Principal: "*"`.
- **Administration and use are separate.**
  - Administrators, including the account root, get an explicit list of administrative actions. Encrypt and Decrypt are not in it.
  - Usage roles get crypto actions only. They are gated by `aws:PrincipalAccount ∈ allowed_account_ids`. They can create grants only when the grant is for an AWS resource.
- **The root statement exists for recovery.** It keeps the key manageable if all admin roles are deleted. In prod, `kms:ScheduleKeyDeletion` is additionally denied by SCP (ADR-007).
- **Service principals** are always scoped by `aws:SourceAccount`. They can optionally be scoped further by `aws:SourceArn`, or by `kms:EncryptionContext:aws:logs:arn` for CloudWatch Logs.
- **Region lock:** a precondition rejects any region other than `eu-central-1` or `eu-west-3`.
- **`Resource: "*"`** in a key policy refers to the key itself. Its statement IDs are registered in `policies/data/wildcard_exceptions.json`.

## Example

```hcl
module "data_key" {
  source              = "../../modules/kms-key"
  alias               = "hestia-dev-de-data"
  description         = "Hestia dev DE data at rest"
  allowed_account_ids = [var.account_id] # injected as TF_VAR_account_id, never committed
  usage_role_arns     = [module.compute.node_role_arn]
  service_principals = [
    { service = "logs.eu-central-1.amazonaws.com",
      source_arn_like = "arn:aws:logs:eu-central-1:<AWS_ACCOUNT_ID>:log-group:*",
      source_arn_condition_key = "kms:EncryptionContext:aws:logs:arn" },
  ]
}
```

## Inputs

| Name | Type | Default |
|---|---|---|
| `alias` | string | required |
| `description` | string | required |
| `allowed_account_ids` | list(string) | required |
| `tags` | map(string) | `{}` |
| `admin_role_arns` | list(string) | `[]` |
| `usage_role_arns` | list(string) | `[]` |
| `service_principals` | list(object) | `[]` |
| `deletion_window_in_days` | number (7–30) | `30` |

## Outputs

`key_arn`, `key_id`, `alias_arn`.
