# ADR-004: Remote state in per-region S3 buckets with S3-native locking

- **Status:** Accepted
- **Date:** 2026-10-22
- **Related:** ADR-002, ADR-003

## Context

State files contain resource identifiers and sometimes sensitive attributes. They must be:

- EU-resident and encrypted;
- versioned so they can be recovered;
- locked against concurrent writes;
- available during a regional outage of the region they do *not* describe. In particular, FR must be operable when DE is down.

Terraform ≥ 1.10 supports lock files stored in S3 (`use_lockfile = true`). DynamoDB-based locking is deprecated.

## Decision

- **Backend:** `s3` with `encrypt = true`, a customer-managed `kms_key_id`, and `use_lockfile = true`. No DynamoDB table.
- **One state bucket per account per region**, created by `terraform/bootstrap/`:

  | Root | State bucket region |
  |---|---|
  | `live/<env>/de` | `eu-central-1` |
  | `live/<env>/fr` | `eu-west-3` |
  | `live/<env>/peering`, `live/<env>/edge` | `eu-central-1` (cross-region and global; not on the DR critical path) |

- **State buckets** use the hardened bucket module: versioning, SSE-KMS, public access block, TLS-only, noncurrent versions kept 90 days. They have **no Object Lock**, because lock files must be deletable.
- **Key layout:** `<env>/<stack>/terraform.tfstate`.
- **Access:** only `hestia-<env>-tf-deploy` can write state; `hestia-<env>-tf-readonly` can read it for validation jobs. Application roles have no access.
- **No `terraform_remote_state`.** Cross-stack values are published as non-secret SSM `String` parameters under `/hestia/<env>/<region_code>/...`, so consumers never need read access to a whole state file.
- **Required Terraform version:** `>= 1.10`.
- **Bootstrap:** `terraform/bootstrap` starts with local state and is migrated into its own bucket afterwards (runbook). Local bootstrap state is never committed (`.gitignore`).

## Alternatives considered

| Option | Why not chosen |
|---|---|
| S3 + DynamoDB lock table | Deprecated pattern, and one more resource per region. |
| A single state bucket in DE with CRR to FR | FR operations would depend on DE (or on a failover dance on the replica). Per-region buckets are simpler. |
| Terraform Cloud / HCP | State held by a US-headquartered SaaS. Avoided for sovereignty (ADR-005). |

## Consequences

- Operators need Terraform ≥ 1.10. The repository's toolchain section pins this.
- Losing DE never blocks changes to `fr`.

## Compliance impact

- **GDPR Art. 32:** state is encrypted at rest and in transit and access-controlled.
- **NIS2:** state access is auditable through CloudTrail data events on the state buckets.
