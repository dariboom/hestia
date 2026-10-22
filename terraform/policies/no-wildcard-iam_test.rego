package hestia.iam_test

import data.hestia.iam
import rego.v1

# Synthetic inputs only; account IDs are 000000000000.

policy_plan(statements) := {"resource_changes": [{
	"address": "module.ci.aws_iam_policy.deploy",
	"mode": "managed",
	"type": "aws_iam_policy",
	"change": {"actions": ["create"], "after": {"policy": json.marshal({"Version": "2012-10-17", "Statement": statements})}},
}]}

scoped := {"Sid": "Read", "Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "arn:aws:s3:::hestia-dev-de-data/*"}

test_plan_scoped_policy_allowed if {
	count(iam.deny) == 0 with input as policy_plan([scoped])
}

test_plan_single_statement_object_allowed if {
	count(iam.deny) == 0 with input as policy_plan(scoped)
}

test_plan_action_star_denied if {
	count(iam.deny) == 1 with input as policy_plan([object.union(scoped, {"Action": "*"})])
}

test_plan_service_wildcard_denied if {
	count(iam.deny) == 1 with input as policy_plan([object.union(scoped, {"Action": ["s3:*"]})])
}

test_plan_resource_star_denied if {
	count(iam.deny) == 1 with input as policy_plan([object.union(scoped, {"Resource": "*"})])
}

test_plan_not_action_denied if {
	st := {"Sid": "X", "Effect": "Allow", "NotAction": ["iam:*"], "Resource": "arn:aws:s3:::b"}
	count(iam.deny) == 1 with input as policy_plan([st])
}

test_plan_deny_statement_with_wildcard_allowed if {
	st := {"Sid": "DenyAll", "Effect": "Deny", "Action": "*", "Resource": "*"}
	count(iam.deny) == 0 with input as policy_plan([st])
}

test_plan_justified_exception_allowed if {
	exc := [{"address_pattern": "^module\\.ci\\.aws_iam_policy\\.deploy$", "sids": ["Describe*"], "justification": "ec2:Describe* has no resource-level permissions"}]
	st := {"Sid": "DescribeAll", "Effect": "Allow", "Action": ["ec2:DescribeInstances"], "Resource": "*"}
	count(iam.deny) == 0 with input as policy_plan([st]) with data.wildcard_exceptions as exc
}

test_plan_exception_without_justification_denied if {
	exc := [{"address_pattern": ".*", "sids": ["*"], "justification": "  "}]
	count(iam.deny) == 1 with input as policy_plan([object.union(scoped, {"Resource": "*"})]) with data.wildcard_exceptions as exc
}

# conftest emits a single block as an object (not a one-element array), as here.
hcl_doc(path, body) := [{"path": path, "contents": {"data": {"aws_iam_policy_document": {"this": body}}}}]

kms_exc := [{
	"path": "modules/kms-key/main.tf",
	"address": "data.aws_iam_policy_document.this",
	"sids": ["KeyUsage", "Service*"],
	"justification": "Key policy Resource * means this key.",
}]

test_hcl_scoped_statement_allowed if {
	body := {"statement": [{"sid": "Read", "actions": ["s3:GetObject"], "resources": ["${aws_s3_bucket.this.arn}/*"]}]}
	count(iam.deny) == 0 with input as hcl_doc("modules/data/iam.tf", body)
}

test_hcl_resource_star_denied if {
	body := {"statement": {"sid": "Read", "actions": ["s3:GetObject"], "resources": ["*"]}}
	count(iam.deny) == 1 with input as hcl_doc("modules/data/iam.tf", body)
}

test_hcl_dynamic_statement_denied if {
	body := {"dynamic": {"statement": [{"for_each": "${var.x}", "content": {"sid": "Dyn", "actions": ["iam:*"], "resources": ["${var.arn}"]}}]}}
	count(iam.deny) == 1 with input as hcl_doc("modules/data/iam.tf", body)
}

test_hcl_listed_exception_allowed if {
	body := {"dynamic": {"statement": [{"content": [{"sid": "Service${statement.key}", "actions": ["kms:Decrypt"], "resources": ["*"]}]}]}}
	count(iam.deny) == 0 with input as hcl_doc("./modules/kms-key/main.tf", body) with data.wildcard_exceptions as kms_exc
}

test_hcl_exception_wrong_file_denied if {
	body := {"statement": [{"sid": "KeyUsage", "actions": ["kms:Decrypt"], "resources": ["*"]}]}
	count(iam.deny) == 1 with input as hcl_doc("modules/data/main.tf", body) with data.wildcard_exceptions as kms_exc
}

test_hcl_unlisted_sid_denied if {
	body := {"statement": [{"sid": "Sneaky", "actions": ["kms:Decrypt"], "resources": ["*"]}]}
	count(iam.deny) == 1 with input as hcl_doc("modules/kms-key/main.tf", body) with data.wildcard_exceptions as kms_exc
}
