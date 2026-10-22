package hestia.gdpr

import data.hestia.lib
import rego.v1

# Data-protection baseline (GDPR Art. 25/32): encryption at rest, no public data paths,
# bounded log retention, classification tags, and no secret values baked into defaults.

secret_name := `(?i)(password|secret|token|api_?key)`

# References (Secrets Manager ARNs, SSM parameter names) are the sanctioned way to point at secrets.
secret_ref := `(?i)_(arns?|names?)$`

secret_like(name) if {
	regex.match(secret_name, name)
	not regex.match(secret_ref, name)
}

after(rc) := rc.change.after

unknown(rc, attr) if rc.change.after_unknown[attr] == true

module_of(rc) := object.get(rc, "module_address", "")

# --- S3: buckets need SSE-KMS, versioning and a full public access block in the same module.
# shortcut: companions are matched per module, not per bucket; fine while every bucket comes from
# modules/s3-bucket (one bucket per module instance), revisit if a module ever creates several.

s3_kms(m) if {
	some c in lib.changes
	c.type == "aws_s3_bucket_server_side_encryption_configuration"
	module_of(c) == m
	some r in after(c).rule
	some d in r.apply_server_side_encryption_by_default
	d.sse_algorithm in {"aws:kms", "aws:kms:dsse"}
}

s3_versioned(m) if {
	some c in lib.changes
	c.type == "aws_s3_bucket_versioning"
	module_of(c) == m
	some v in after(c).versioning_configuration
	v.status == "Enabled"
}

s3_private(m) if {
	some c in lib.changes
	c.type == "aws_s3_bucket_public_access_block"
	module_of(c) == m
	a := after(c)
	a.block_public_acls
	a.block_public_policy
	a.ignore_public_acls
	a.restrict_public_buckets
}

deny contains msg if {
	some rc in lib.changes
	rc.type == "aws_s3_bucket"
	not s3_kms(module_of(rc))
	msg := sprintf("gdpr: %s has no SSE-KMS encryption configuration", [rc.address])
}

deny contains msg if {
	some rc in lib.changes
	rc.type == "aws_s3_bucket"
	not s3_versioned(module_of(rc))
	msg := sprintf("gdpr: %s has no enabled versioning", [rc.address])
}

deny contains msg if {
	some rc in lib.changes
	rc.type == "aws_s3_bucket"
	not s3_private(module_of(rc))
	msg := sprintf("gdpr: %s has no complete public access block", [rc.address])
}

# --- RDS

deny contains msg if {
	some rc in lib.changes
	rc.type in {"aws_db_instance", "aws_rds_cluster"}
	not after(rc).storage_encrypted == true
	not unknown(rc, "storage_encrypted")
	msg := sprintf("gdpr: %s must set storage_encrypted = true", [rc.address])
}

deny contains msg if {
	some rc in lib.changes
	rc.type in {"aws_db_instance", "aws_rds_cluster_instance"}
	after(rc).publicly_accessible == true
	msg := sprintf("gdpr: %s must not be publicly_accessible", [rc.address])
}

# --- EKS

deny contains msg if {
	some rc in lib.changes
	rc.type == "aws_eks_cluster"
	some vc in after(rc).vpc_config
	vc.endpoint_public_access == true
	msg := sprintf("gdpr: %s must not expose a public API endpoint", [rc.address])
}

# --- CloudWatch Logs

deny contains msg if {
	some rc in lib.changes
	rc.type == "aws_cloudwatch_log_group"
	object.get(after(rc), "kms_key_id", "") in {"", null}
	not unknown(rc, "kms_key_id")
	msg := sprintf("gdpr: %s must be encrypted with a KMS key", [rc.address])
}

deny contains msg if {
	some rc in lib.changes
	rc.type == "aws_cloudwatch_log_group"
	object.get(after(rc), "retention_in_days", 0) in {0, null}
	not unknown(rc, "retention_in_days")
	msg := sprintf("gdpr: %s must set a finite retention_in_days", [rc.address])
}

# --- Classification tag (tags_all includes provider default_tags)

deny contains msg if {
	some rc in lib.changes
	tags := after(rc).tags_all
	is_object(tags)
	not tags["hestia:data-classification"]
	msg := sprintf("gdpr: %s is missing tag hestia:data-classification", [rc.address])
}

# --- Secret-like variables must never carry a default

deny contains msg if {
	lib.plan_mode
	walk(input.configuration, [path, vars])
	count(path) > 0
	path[count(path) - 1] == "variables"
	some name, v in vars
	secret_like(name)
	"default" in object.keys(v)
	msg := sprintf("gdpr: variable %s looks secret and must not have a default", [name])
}

deny contains msg if {
	some v in lib.labeled("variable")
	secret_like(v.name)
	"default" in object.keys(v.body)
	msg := sprintf("gdpr: %s: variable %s looks secret and must not have a default", [v.path, v.name])
}

# --- Static HCL checks for literal violations (plan checks cover computed values)

deny contains msg if {
	some b in lib.blocks("resource")
	b.type == "aws_eks_cluster"
	some vc in lib.as_list(object.get(b.body, "vpc_config", []))
	vc.endpoint_public_access == true
	msg := sprintf("gdpr: %s: aws_eks_cluster.%s sets endpoint_public_access = true", [b.path, b.name])
}

deny contains msg if {
	some b in lib.blocks("resource")
	b.type in {"aws_db_instance", "aws_rds_cluster_instance"}
	b.body.publicly_accessible == true
	msg := sprintf("gdpr: %s: %s.%s sets publicly_accessible = true", [b.path, b.type, b.name])
}

deny contains msg if {
	some b in lib.blocks("resource")
	b.type in {"aws_db_instance", "aws_rds_cluster"}
	not b.body.storage_encrypted
	msg := sprintf("gdpr: %s: %s.%s must set storage_encrypted", [b.path, b.type, b.name])
}

deny contains msg if {
	some b in lib.blocks("resource")
	b.type == "aws_cloudwatch_log_group"
	some attr in ["kms_key_id", "retention_in_days"]
	not attr in object.keys(b.body)
	msg := sprintf("gdpr: %s: aws_cloudwatch_log_group.%s must set %s", [b.path, b.name, attr])
}

deny contains msg if {
	some b in lib.blocks("resource")
	b.type == "aws_s3_bucket_server_side_encryption_configuration"
	some r in lib.as_list(object.get(b.body, "rule", []))
	some d in lib.as_list(object.get(r, "apply_server_side_encryption_by_default", []))
	d.sse_algorithm == "AES256"
	msg := sprintf("gdpr: %s: %s.%s uses AES256 instead of SSE-KMS", [b.path, b.type, b.name])
}
