package hestia.lib

import rego.v1

# Two input shapes:
#   plan mode: `terraform show -json <plan>` produced by CI (never by agents)
#   hcl mode:  `conftest test --combine --parser hcl2` -> [{"path": ..., "contents": ...}]
hcl_mode if is_array(input)

plan_mode if not is_array(input)

# Resource changes that will exist after apply.
changes contains rc if {
	plan_mode
	some rc in input.resource_changes
	rc.mode == "managed"
	not rc.change.actions == ["delete"]
}

# Two-label HCL blocks (resource, data): {path, type, name, body}.
blocks(kind) := {b |
	hcl_mode
	some f in input
	some type, named in f.contents[kind]
	some name, bodies in named
	some body in bodies
	b := {"path": f.path, "type": type, "name": name, "body": body}
}

# One-label HCL blocks (provider, variable): {path, name, body}.
labeled(kind) := {b |
	hcl_mode
	some f in input
	some name, bodies in f.contents[kind]
	some body in bodies
	b := {"path": f.path, "name": name, "body": body}
}

as_list(x) := x if is_array(x)

as_list(x) := [x] if is_string(x)

# Literal string (not an interpolated expression) in hcl2json output.
literal(x) if {
	is_string(x)
	not contains(x, "${")
}
