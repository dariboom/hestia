package hestia.network

import data.hestia.lib
import rego.v1

# prod needs AZ-independent egress. The module's nat_mode validation enforces this only at
# plan time (cross-variable validation), so catch it statically as well.
deny contains msg if {
	some m in lib.labeled("module")
	contains(m.path, "live/prod/")
	m.body.nat_mode == "single"
	msg := sprintf("network: %s: module %s sets nat_mode = \"single\"; prod requires per_az", [m.path, m.name])
}
