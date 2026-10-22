package hestia.audit

import data.hestia.lib
import rego.v1

# prod audit WORM needs COMPLIANCE mode and >= 10 years. The security module's validations enforce this only
# at plan time (cross-variable validation), so catch it statically as well.
deny contains msg if {
	some m in lib.labeled("module")
	contains(m.path, "live/prod/")
	m.body.object_lock_mode == "GOVERNANCE"
	msg := sprintf("audit: %s: module %s sets object_lock_mode = \"GOVERNANCE\"; prod requires COMPLIANCE", [m.path, m.name])
}

deny contains msg if {
	some m in lib.labeled("module")
	contains(m.path, "live/prod/")
	m.body.audit_retention_days < 3650
	msg := sprintf("audit: %s: module %s sets audit_retention_days below 3650; prod requires 10 years", [m.path, m.name])
}
