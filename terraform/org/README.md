# org

Optional root with guardrail service control policies (SCPs) for the Hestia OUs. Use it only when
Hestia accounts sit in an AWS Organization that you control. SCPs only deny: access is still granted
by IAM in each account.

Only humans run this root, from the organization **management account**, with an admin or
break-glass session. CI never has credentials for the management account.

> **Static validation only in this repository.** Agents and CI validation jobs never run
> `plan`/`apply`/`state` here. The commands below are the operator runbook for a human with
> authorised access to the management account.

| SCP | Effect |
|---|---|
| `hestia-region-lock` | Denies every action outside `eu-central-1` and `eu-west-3`, except global services (ADR-005). ACM and WAF are also allowed in `us-east-1` for CloudFront, nowhere else. |
| `hestia-protect-audit` | Denies stopping, deleting or updating CloudTrail; deleting or disassociating GuardDuty; stopping or deleting Config; disabling Security Hub; changing S3 Object Lock configuration; scheduling KMS key deletion. The `break_glass_role_name` role in any account is exempt. |
| `hestia-no-leave-org` | Denies `organizations:LeaveOrganization`. |

Each SCP is attached to every ID in `target_ou_ids` (OU `ou-...` or root `r-...`).

## Region-lock exemptions

These services are exempt because their API is global or served only from `us-east-1`. Each reason
is also commented in `main.tf`.

| Service | Why |
|---|---|
| `iam`, `organizations`, `sts` | Global identity and account management. SDKs and the OIDC deploy role use the global STS endpoint. |
| `route53`, `route53domains` | Global DNS; domain registration is `us-east-1` only. |
| `cloudfront`, `acm`, `waf`, `wafv2` | CloudFront certificates and WAF web ACLs with CLOUDFRONT scope live in `us-east-1`. |
| `budgets`, `ce`, `cur`, `bcm-data-exports` | Billing, Cost Explorer and carbon/cost data exports are `us-east-1` only (ADR-005). |
| `support`, `health`, `trustedadvisor` | `us-east-1` endpoints. |

## Rollout order

`hestia-protect-audit` also binds the `tf-deploy` role. With it attached, CI cannot:

- set Object Lock configuration on a new audit bucket (`s3:PutBucketObjectLockConfiguration`);
- change the trail (`cloudtrail:UpdateTrail`), for example its CloudWatch Logs settings.

So either:

1. apply the `live/<env>/<region>` security stacks first, then attach the SCPs; or
2. make later audit bucket and trail changes as the break-glass role.

## Usage

Prerequisites: Terraform >= 1.10, an authenticated admin session for the management account (from
your SSO or identity tooling, never from files), and a state bucket from `bootstrap/`.

```bash
export TF_VAR_management_account_id=<AWS_ACCOUNT_ID>
export TF_VAR_target_ou_ids='["ou-<ROOT_ID>-<OU_ID>"]'
export TF_VAR_owner=<OWNER_TEAM>
export TF_VAR_cost_center=<COST_CENTER>

terraform init \
  -backend-config="bucket=<STATE_BUCKET_NAME>" \
  -backend-config="key=org/terraform.tfstate" \
  -backend-config="region=eu-central-1" \
  -backend-config="use_lockfile=true"
terraform plan -out=org.tfplan   # review the SCP content and attachments
terraform apply org.tfplan
rm org.tfplan                    # plan files are never committed
```

`allowed_account_ids` on the provider stops a run in any account other than the management account.

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `management_account_id` | string | required | 12 digits; `TF_VAR_management_account_id` at run time, never committed. |
| `target_ou_ids` | list(string) | required | Non-empty; `ou-...` or `r-...` IDs. |
| `break_glass_role_name` | string | `hestia-break-glass` | Must match `hestia-*`. Exempt from `hestia-protect-audit`. |
| `owner` | string | required | `hestia:owner` tag. |
| `cost_center` | string | required | `hestia:cost-center` tag. |

## Outputs

| Name | Description |
|---|---|
| `scp_ids` | SCP IDs by name (`region-lock`, `protect-audit`, `no-leave-org`). |

## Limits

- `wafv2:*` in `us-east-1` cannot be limited to CLOUDFRONT scope by an SCP condition, so REGIONAL
  WAF resources there are not denied.
- SCPs are limited to 5120 characters. `jsonencode` output is minified; the largest policy is
  estimated well below the limit but has not been measured against AWS.
- The break-glass exemption matches the role name in every account. Keep that role's trust policy
  tight; it is created outside this repository.

## Static checks

- `terraform validate` passes. A scratch root with an invalid OU ID and a non-`hestia-*` break-glass
  name is rejected with two errors.
- checkov: 1 passed, 0 failed. conftest: all policies pass. gitleaks: clean.
- tflint: not run; it is not installed in this environment.
- No `terraform plan` or `apply` has been run against this root.
