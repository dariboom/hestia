# Hestia Terraform platform

Infrastructure for Hestia in `eu-central-1` (DE, primary) and `eu-west-3` (FR, hot standby), for `dev`, `staging` and `prod`. Start with [`docs/architecture.md`](docs/architecture.md) and the decision records in [`docs/adr/`](docs/adr/).

> This README is expanded in a later task (T21) with the repo map and the new-environment walkthrough.

## Prerequisites

| Tool | Version | Used for |
|---|---|---|
| terraform | `>= 1.10` (S3-native state locking, ADR-004) | `fmt`, `init -backend=false`, `validate` |
| tflint | `>= 0.53` with `tflint-ruleset-aws 0.36.0` | lint |
| checkov | `>= 3.2` | IaC security scan |
| opa | `>= 0.68` | `opa test policies/` |
| conftest | `>= 0.55` | Rego checks on HCL |
| gitleaks | `>= 8.21` | secret scan |
| python3 | `>= 3.12` | Lambda unit tests |
| pre-commit | optional | runs the hooks in `.pre-commit-config.yaml` |

Install these yourself. Automated agents working on this repo don't install tools.

## Static validation

```bash
cd terraform
make all        # guard fmt validate lint checkov policy secrets python
make fmt        # terraform fmt -check -recursive
make validate   # terraform init -backend=false && terraform validate, per directory
```

No target runs `plan`, `apply` or anything else that contacts AWS or remote state. Plan and apply are human-only and four-eyes reviewed; see `docs/runbook.md`.
