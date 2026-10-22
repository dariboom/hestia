package hestia.audit_test

import data.hestia.audit
import rego.v1

hcl_module(path, body) := [{"path": path, "contents": {"module": {"security": [body]}}}]

test_prod_governance_denied if {
	count(audit.deny) == 1 with input as hcl_module("live/prod/de/main.tf", {"object_lock_mode": "GOVERNANCE"})
}

test_prod_short_retention_denied if {
	count(audit.deny) == 1 with input as hcl_module("live/prod/fr/main.tf", {"audit_retention_days": 365})
}

test_prod_defaults_allowed if {
	count(audit.deny) == 0 with input as hcl_module("live/prod/de/main.tf", {"source": "../../../modules/security"})
}

test_dev_governance_allowed if {
	count(audit.deny) == 0 with input as hcl_module("live/dev/de/main.tf", {"object_lock_mode": "GOVERNANCE", "audit_retention_days": 400})
}
