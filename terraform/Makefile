# Static validation only (ADR-007, docs/static-validation-checklist.md).
# No target runs plan/apply/destroy/import/state/refresh/test or contacts AWS.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

TF ?= terraform
# Every directory that holds .tf files, excluding provider caches.
TF_DIRS := $(shell find . -name '*.tf' -not -path '*/.terraform/*' -printf '%h\n' | sort -u)

FORBIDDEN := plan|apply|destroy|import|state|refresh|test|console|taint|untaint|force-unlock

.PHONY: all guard fmt validate lint checkov policy secrets python

all: guard fmt validate lint checkov policy secrets python

# Fails if anyone tries to smuggle a forbidden subcommand in via TF_CMD.
guard:
	@if [[ -n "$${TF_CMD:-}" ]] && grep -Eqw '$(FORBIDDEN)' <<<"$${TF_CMD}"; then \
	  echo "guard: forbidden terraform subcommand in TF_CMD='$${TF_CMD}'" >&2; exit 1; fi
	@echo "guard: ok"

fmt: guard
	$(TF) fmt -check -recursive -diff .

validate: guard
	@for d in $(TF_DIRS); do \
	  echo "== validate $$d"; \
	  $(TF) -chdir=$$d init -backend=false -input=false -no-color >/dev/null; \
	  $(TF) -chdir=$$d validate -no-color; \
	done

lint: guard
	tflint --init --config=$(CURDIR)/.tflint.hcl
	tflint --recursive --config=$(CURDIR)/.tflint.hcl

checkov: guard
	checkov --config-file .checkov.yaml -d .

# Only .rego files go to opa test: loading policies/ would also pull fixtures/ and data/ JSON into data.
# --combine gives rules the file path, which wildcard exceptions are keyed on (conftest.toml adds policies/data).
policy: guard
	opa check --strict policies/*.rego
	opa test policies/*.rego -v
	conftest test --combine --parser hcl2 $$(find modules live bootstrap org -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null)
	conftest test policies/fixtures/plan_compliant.json
	@# The violations fixture must be rejected; a pass here means a rule silently stopped firing.
	@if conftest test --no-color policies/fixtures/plan_violations.json >/dev/null; then \
	  echo "policy: plan_violations.json unexpectedly passed" >&2; exit 1; fi
	@echo "policy: plan_violations.json rejected as expected"

secrets: guard
	gitleaks detect --no-banner --config .gitleaks.toml --source .

python: guard
	@for d in $$(find modules -type d -path '*/src/*' -mindepth 3 -maxdepth 4 2>/dev/null); do \
	  echo "== unittest $$d"; python3 -m unittest discover -s $$d -v; \
	done
