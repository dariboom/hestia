package hestia.gdpr_test

import data.hestia.gdpr
import rego.v1

# Synthetic inputs only; account IDs are 000000000000.

tags := {"hestia:data-classification": "personal"}

rc(address, type, after) := {
	"address": address,
	"mode": "managed",
	"type": type,
	"module_address": "module.audit",
	"change": {"actions": ["create"], "after": object.union({"tags_all": tags}, after), "after_unknown": {}},
}

plan(changes) := {"resource_changes": changes}

bucket := rc("module.audit.aws_s3_bucket.this", "aws_s3_bucket", {})

sse(alg) := rc("module.audit.aws_s3_bucket_server_side_encryption_configuration.this", "aws_s3_bucket_server_side_encryption_configuration", {"rule": [{"apply_server_side_encryption_by_default": [{"sse_algorithm": alg}]}]})

versioning(status) := rc("module.audit.aws_s3_bucket_versioning.this", "aws_s3_bucket_versioning", {"versioning_configuration": [{"status": status}]})

pab(flag) := rc("module.audit.aws_s3_bucket_public_access_block.this", "aws_s3_bucket_public_access_block", {
	"block_public_acls": true,
	"block_public_policy": true,
	"ignore_public_acls": true,
	"restrict_public_buckets": flag,
})

test_s3_compliant_bucket_allowed if {
	count(gdpr.deny) == 0 with input as plan([bucket, sse("aws:kms"), versioning("Enabled"), pab(true)])
}

test_s3_aes256_denied if {
	count(gdpr.deny) == 1 with input as plan([bucket, sse("AES256"), versioning("Enabled"), pab(true)])
}

test_s3_versioning_suspended_denied if {
	count(gdpr.deny) == 1 with input as plan([bucket, sse("aws:kms"), versioning("Suspended"), pab(true)])
}

test_s3_partial_public_access_block_denied if {
	count(gdpr.deny) == 1 with input as plan([bucket, sse("aws:kms"), versioning("Enabled"), pab(false)])
}

test_s3_bare_bucket_denied_three_times if {
	count(gdpr.deny) == 3 with input as plan([bucket])
}

test_rds_encrypted_private_allowed if {
	db := rc("aws_db_instance.main", "aws_db_instance", {"storage_encrypted": true, "publicly_accessible": false})
	count(gdpr.deny) == 0 with input as plan([db])
}

test_rds_unencrypted_denied if {
	db := rc("aws_db_instance.main", "aws_db_instance", {"storage_encrypted": false})
	count(gdpr.deny) == 1 with input as plan([db])
}

test_rds_public_instance_denied if {
	db := rc("aws_rds_cluster_instance.a", "aws_rds_cluster_instance", {"publicly_accessible": true})
	count(gdpr.deny) == 1 with input as plan([db])
}

test_eks_private_endpoint_allowed if {
	eks := rc("aws_eks_cluster.this", "aws_eks_cluster", {"vpc_config": [{"endpoint_public_access": false}]})
	count(gdpr.deny) == 0 with input as plan([eks])
}

test_eks_public_endpoint_denied if {
	eks := rc("aws_eks_cluster.this", "aws_eks_cluster", {"vpc_config": [{"endpoint_public_access": true}]})
	count(gdpr.deny) == 1 with input as plan([eks])
}

test_log_group_compliant_allowed if {
	lg := rc("aws_cloudwatch_log_group.app", "aws_cloudwatch_log_group", {"kms_key_id": "arn:aws:kms:eu-central-1:000000000000:key/x", "retention_in_days": 365})
	count(gdpr.deny) == 0 with input as plan([lg])
}

test_log_group_unknown_kms_allowed if {
	lg := json.patch(
		rc("aws_cloudwatch_log_group.app", "aws_cloudwatch_log_group", {"retention_in_days": 30}),
		[{"op": "add", "path": "/change/after_unknown/kms_key_id", "value": true}],
	)
	count(gdpr.deny) == 0 with input as plan([lg])
}

test_log_group_unencrypted_infinite_denied_twice if {
	lg := rc("aws_cloudwatch_log_group.app", "aws_cloudwatch_log_group", {"retention_in_days": 0})
	count(gdpr.deny) == 2 with input as plan([lg])
}

test_missing_classification_tag_denied if {
	lg := json.patch(
		rc("aws_cloudwatch_log_group.app", "aws_cloudwatch_log_group", {"kms_key_id": "k", "retention_in_days": 7}),
		[{"op": "replace", "path": "/change/after/tags_all", "value": {"hestia:owner": "x"}}],
	)
	count(gdpr.deny) == 1 with input as plan([lg])
}

test_plan_secret_variable_default_denied if {
	cfg := {"resource_changes": [], "configuration": {"root_module": {"module_calls": {"db": {"module": {"variables": {"db_password": {"default": "x", "sensitive": true}}}}}}}}
	count(gdpr.deny) == 1 with input as cfg
}

test_plan_secret_variable_without_default_allowed if {
	cfg := {"resource_changes": [], "configuration": {"root_module": {"variables": {"app_api_key": {"sensitive": true}}}}}
	count(gdpr.deny) == 0 with input as cfg
}

# conftest emits a single block as an object (not a one-element array), as here.
hcl(path, contents) := [{"path": path, "contents": contents}]

res(type, name, body) := {"resource": {type: {name: body}}}

test_hcl_secret_variable_default_denied if {
	count(gdpr.deny) == 1 with input as hcl("live/dev/variables.tf", {"variable": {"api_token": {"default": "", "sensitive": true}}})
}

test_hcl_secret_reference_variable_default_allowed if {
	count(gdpr.deny) == 0 with input as hcl("modules/data/variables.tf", {"variable": {"app_secret_names": {"default": []}, "secrets_kms_key_arn": {"default": null}}})
}

test_hcl_non_secret_variable_default_allowed if {
	count(gdpr.deny) == 0 with input as hcl("live/dev/variables.tf", {"variable": {"retention_days": {"default": 30}}})
}

test_hcl_eks_public_endpoint_denied if {
	count(gdpr.deny) == 1 with input as hcl("modules/compute/eks.tf", res("aws_eks_cluster", "this", {"vpc_config": {"endpoint_public_access": true}}))
}

test_hcl_eks_private_endpoint_allowed if {
	count(gdpr.deny) == 0 with input as hcl("modules/compute/eks.tf", res("aws_eks_cluster", "this", {"vpc_config": {"endpoint_public_access": false}}))
}

test_hcl_rds_public_denied if {
	count(gdpr.deny) == 1 with input as hcl("modules/data/rds.tf", res("aws_db_instance", "main", {"storage_encrypted": true, "publicly_accessible": true}))
}

test_hcl_rds_unencrypted_denied if {
	count(gdpr.deny) == 1 with input as hcl("modules/data/rds.tf", res("aws_db_instance", "main", {"publicly_accessible": false}))
}

test_hcl_log_group_missing_attrs_denied_twice if {
	count(gdpr.deny) == 2 with input as hcl("modules/x/logs.tf", res("aws_cloudwatch_log_group", "app", {"name": "x"}))
}

test_hcl_sse_aes256_denied if {
	body := {"bucket": "${aws_s3_bucket.this.id}", "rule": {"apply_server_side_encryption_by_default": {"sse_algorithm": "AES256"}}}
	count(gdpr.deny) == 1 with input as hcl("modules/x/s3.tf", res("aws_s3_bucket_server_side_encryption_configuration", "this", body))
}
