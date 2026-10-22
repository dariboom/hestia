package hestia.secrets

import data.hestia.lib
import rego.v1

# Secret values never pass through Terraform: Secrets Manager secrets are empty containers and
# SecureString parameters are created out-of-band; both are populated by the external secret store.

# Any of these on a SecureString would put the value in code or state.
value_args := {"value", "insecure_value", "value_wo"}

deny contains msg if {
	some b in lib.blocks("resource")
	b.type == "aws_secretsmanager_secret_version"
	msg := sprintf("secrets: %s: resource %s.%s sets a secret value in Terraform; create the container only", [b.path, b.type, b.name])
}

# Reading a secret version stores its plaintext in state.
deny contains msg if {
	some b in lib.blocks("data")
	b.type == "aws_secretsmanager_secret_version"
	msg := sprintf("secrets: %s: data %s.%s copies a secret value into state; read it at runtime via IAM instead", [b.path, b.type, b.name])
}

deny contains msg if {
	some b in lib.blocks("resource")
	b.type == "aws_ssm_parameter"
	b.body.type == "SecureString"
	some arg in value_args
	arg in object.keys(b.body)
	msg := sprintf("secrets: %s: SecureString %s sets %s; SecureStrings are created out-of-band", [b.path, b.name, arg])
}

deny contains msg if {
	some rc in lib.changes
	rc.type == "aws_secretsmanager_secret_version"
	msg := sprintf("secrets: %s would store a secret value via Terraform", [rc.address])
}

deny contains msg if {
	some rc in lib.changes
	rc.type == "aws_ssm_parameter"
	rc.change.after.type == "SecureString"
	msg := sprintf("secrets: %s would create a SecureString with a Terraform-managed value", [rc.address])
}

# Database master passwords: RDS manages them (manage_master_user_password), so no password
# argument may appear on an instance or cluster, in code or in a plan.
db_types := {"aws_db_instance", "aws_rds_cluster"}

db_password_args := {"password", "password_wo", "master_password", "master_password_wo"}

deny contains msg if {
	some b in lib.blocks("resource")
	b.type in db_types
	some arg in db_password_args
	arg in object.keys(b.body)
	msg := sprintf("secrets: %s: %s.%s sets %s; use manage_master_user_password instead", [b.path, b.type, b.name, arg])
}

deny contains msg if {
	some rc in lib.changes
	rc.type in db_types
	some arg in db_password_args
	rc.change.after[arg] != null
	msg := sprintf("secrets: %s would set %s through Terraform; use manage_master_user_password instead", [rc.address, arg])
}
