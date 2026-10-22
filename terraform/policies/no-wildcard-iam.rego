package hestia.iam

import data.hestia.lib
import rego.v1

# Exceptions live in policies/data/wildcard_exceptions.json. Each entry needs a justification and either
#   {path, address, sids}   for static HCL (address = "data.<type>.<name>"), or
#   {address_pattern, sids} for plan JSON (regex on the resource address).
default exceptions := []

exceptions := data.wildcard_exceptions

policy_types := {"aws_iam_policy", "aws_iam_role_policy", "aws_iam_user_policy", "aws_iam_group_policy"}

wild_action(a) if a == "*"

wild_action(a) if endswith(a, ":*")

# Deny statements may use wildcards; only Allow widens access.
allow(st) if lower(object.get(st, "Effect", "Allow")) == "allow"

problems(st) := (({"Action wildcard" |
	some a in lib.as_list(object.get(st, "Action", []))
	wild_action(a)
} | {"Resource \"*\"" | "*" in lib.as_list(object.get(st, "Resource", []))}) | {"NotAction" | st.NotAction}) | {"NotResource" | st.NotResource}

sid_listed(e, sid) if {
	some pattern in e.sids
	glob.match(pattern, null, sid)
}

justified(e) if trim_space(object.get(e, "justification", "")) != ""

plan_exempt(address, sid) if {
	some e in exceptions
	justified(e)
	regex.match(e.address_pattern, address)
	sid_listed(e, sid)
}

hcl_exempt(path, address, sid) if {
	some e in exceptions
	justified(e)
	endswith(path, e.path)
	e.address == address
	sid_listed(e, sid)
}

deny contains msg if {
	some rc in lib.changes
	rc.type in policy_types
	doc := json.unmarshal(rc.change.after.policy)
	some st in lib.as_list(doc.Statement)
	allow(st)
	some reason in problems(st)
	sid := object.get(st, "Sid", "")
	not plan_exempt(rc.address, sid)
	msg := sprintf("no-wildcard-iam: %s statement %q has %s without a justified exception", [rc.address, sid, reason])
}

# HCL statement keys are snake_case; normalise to the JSON policy shape.
hcl_statement(body) := {
	"Sid": object.get(body, "sid", ""),
	"Effect": object.get(body, "effect", "Allow"),
	"Action": object.get(body, "actions", []),
	"Resource": object.get(body, "resources", []),
	"NotAction": object.get(body, "not_actions", false) != false,
	"NotResource": object.get(body, "not_resources", false) != false,
}

hcl_statements(body) := array.concat(
	lib.as_list(object.get(body, "statement", [])),
	[c |
		some d in lib.as_list(object.get(object.get(body, "dynamic", {}), "statement", []))
		some c in lib.as_list(d.content)
	],
)

deny contains msg if {
	some b in lib.blocks("data")
	b.type == "aws_iam_policy_document"
	some raw in hcl_statements(b.body)
	st := hcl_statement(raw)
	allow(st)
	some reason in problems(st)
	address := sprintf("data.%s.%s", [b.type, b.name])
	not hcl_exempt(b.path, address, st.Sid)
	msg := sprintf("no-wildcard-iam: %s: %s statement %q has %s without a justified exception", [b.path, address, st.Sid, reason])
}
