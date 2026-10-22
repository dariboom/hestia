# ADR-007: Four-layer policy-as-code enforcement

- **Status:** Accepted
- **Date:** 2026-10-22
- **Related:** ADR-005

## Context

These constraints must be enforced **by code**, not only described:

- region lock;
- no wildcard IAM without documented justification;
- encryption, public-access blocking and data-classification tagging (GDPR);
- no secret values in configuration.

No single mechanism catches everything. Variable validation only sees module inputs. Static analysis can't evaluate computed values. Only the AWS control plane is authoritative at run time.

## Decision

Enforce the constraints in four layers, each catching what the previous one misses.

| # | Layer | Where | Catches | When |
|---|---|---|---|---|
| 1 | **Variable validation and `precondition`s** | Every module | Disallowed region, prod without per-AZ NAT, retention below floors, Object Lock mode, public route tables in peering | `validate`, and plan (by humans) |
| 2 | **Provider guards** | Every live root | Wrong account (`allowed_account_ids`), missing mandatory tags (`default_tags`) | Plan (by humans) |
| 3 | **OPA/Rego via conftest** | `terraform/policies/` | Region lock (with the closed `us-east-1` exception list from ADR-005), wildcard IAM not listed in `policies/data/wildcard_exceptions.json`, GDPR controls, sensitive variables with defaults | CI on HCL (`conftest --parser hcl2`, static). Plan JSON is checked by the human-run plan gate before any apply. |
| 4 | **AWS Organizations SCPs** | `terraform/org/` (management account) | Any API call outside the allowed regions (except global-service NotActions). Disabling CloudTrail, GuardDuty, Config or Security Hub. Changing Object Lock. Scheduling KMS key deletion. Leaving the Organization. | AWS run time, always |

**Wildcard exception register.** `policies/data/wildcard_exceptions.json` lists each allowed wildcard as `{resource_address, statement_sid, field, justification}`. A wildcard not in the register fails CI.

**Local tooling** runs only static checks: `terraform fmt -check`, `terraform validate` (with `-backend=false`), `tflint`, `checkov`, `opa test`, `conftest`, `gitleaks`. Agents and CI never run `plan` or `apply` (see `docs/static-validation-checklist.md`).

## Alternatives considered

| Option | Why not chosen |
|---|---|
| Sentinel | Requires HCP Terraform / Enterprise (ADR-004 avoids it). |
| checkov alone | Good baseline scanner, but hard to express Hestia-specific rules: the exception register, the closed `us-east-1` list, data-classification tags. Kept as an *additional* scanner. |
| SCPs alone | Only enforced at AWS run time, so feedback is late, and they can't check tagging or encryption settings comprehensively. |

## Consequences

- The SCP layer requires access to the Organization's management account. It is mandatory for prod. That is an open point, `hestia-89g.23` item 3.
- Rego rules need tests with synthetic fixtures (account ID `000000000000`, labelled `SYNTHETIC FIXTURE`). They never use real plan output.

## Compliance impact

- **GDPR Art. 25 (data protection by design):** controls are executable.
- **NIS2 Art. 21:** guardrails against disabling detection and logging.
- **EU data residency:** enforced at three layers (1, 3, 4).
