# ADR-002: Directory-based live environments, not Terraform workspaces

- **Status:** Accepted
- **Date:** 2026-10-22
- **Related:** ADR-004

## Context

Hestia needs `dev`, `staging` and `prod` in two regions (DE, FR), plus two cross-region stacks per environment (`peering`, `edge`). Each environment has its own AWS account.

Isolation goals:

- State is isolated by blast radius.
- Backends and credentials are separate per environment.
- Diffs between staging and prod are easy to review.
- No operator can apply a prod change while believing they are in dev.

## Decision

Use one **root module directory per environment and stack**:

```text
terraform/live/<env>/{de,fr,peering,edge}/
```

- Each root has its own `backend.tf`, state key, provider configuration, and `allowed_account_ids`.
- Roots are thin: they compose modules from `terraform/modules/` and hold only environment-specific values in `terraform.tfvars`.
- Account IDs are never committed. They are injected at run time as `TF_VAR_account_id` by the CI/CD system.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| **Workspaces** | One backend and one provider block shared by all environments. Workspace selection is invisible in code review, and a wrong `terraform workspace select` hits prod. Per-environment accounts and backends are awkward. Staging/prod differences hide in conditionals keyed on `terraform.workspace`. |
| **Terragrunt** | Reduces boilerplate but adds a tool and a DSL to the review and audit surface. Not justified for 4 stacks × 3 environments. |

## Consequences

- **Positive:**
  - `diff -r live/staging live/prod` shows exactly what differs.
  - Each state file has a minimal blast radius.
  - Per-environment IAM boundaries are straightforward.
- **Negative:** some duplication across `main.tf` files.
- **Mitigation:** roots stay thin, and the duplication is intentional (explicit beats DRY at the environment boundary). CI checks that staging and prod roots differ only in tfvars and backend keys.

## Compliance impact

- **NIS2 Art. 21 (access control, change management):** per-environment accounts and roles, reviewable diffs.
- **GDPR Art. 32:** prod personal data is never reachable from dev credentials.
