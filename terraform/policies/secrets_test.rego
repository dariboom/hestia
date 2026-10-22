package hestia.secrets_test

import data.hestia.secrets
import rego.v1

# Synthetic inputs only; no real values.

hcl(kind, type, body) := [{"path": "modules/data/secrets.tf", "contents": {kind: {type: {"this": body}}}}]

test_hcl_secret_version_denied if {
	count(secrets.deny) == 1 with input as hcl("resource", "aws_secretsmanager_secret_version", {"secret_id": "${aws_secretsmanager_secret.this.id}"})
}

test_hcl_secret_version_data_source_denied if {
	count(secrets.deny) == 1 with input as hcl("data", "aws_secretsmanager_secret_version", {"secret_id": "x"})
}

test_hcl_secret_container_allowed if {
	count(secrets.deny) == 0 with input as hcl("resource", "aws_secretsmanager_secret", {"name": "hestia/dev/de/app/x"})
}

test_hcl_securestring_with_value_denied if {
	count(secrets.deny) == 1 with input as hcl("resource", "aws_ssm_parameter", {"type": "SecureString", "value": "${var.x}"})
}

test_hcl_securestring_with_write_only_value_denied if {
	count(secrets.deny) == 1 with input as hcl("resource", "aws_ssm_parameter", {"type": "SecureString", "value_wo": "${var.x}"})
}

test_hcl_string_parameter_allowed if {
	count(secrets.deny) == 0 with input as hcl("resource", "aws_ssm_parameter", {"type": "String", "value": "vpc-00000000000000000"})
}

rc(type, after) := {"address": sprintf("%s.this", [type]), "mode": "managed", "type": type, "change": {"actions": ["create"], "after": after}}

test_plan_secret_version_denied if {
	count(secrets.deny) == 1 with input as {"resource_changes": [rc("aws_secretsmanager_secret_version", {})]}
}

test_plan_securestring_denied if {
	count(secrets.deny) == 1 with input as {"resource_changes": [rc("aws_ssm_parameter", {"type": "SecureString"})]}
}

test_plan_string_parameter_allowed if {
	count(secrets.deny) == 0 with input as {"resource_changes": [rc("aws_ssm_parameter", {"type": "String"})]}
}
