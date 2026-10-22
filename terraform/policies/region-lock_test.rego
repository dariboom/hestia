package hestia.region_test

import data.hestia.region
import rego.v1

# Synthetic inputs only; account IDs are 000000000000.

rc(type, region, after) := {
	"address": sprintf("%s.this", [type]),
	"mode": "managed",
	"type": type,
	"change": {"actions": ["create"], "after": object.union({"region": region}, after)},
}

plan(rcs) := {"resource_changes": rcs, "configuration": {"provider_config": {}}}

test_resource_in_eu_allowed if {
	count(region.deny) == 0 with input as plan([rc("aws_s3_bucket", "eu-west-3", {})])
}

test_resource_outside_eu_denied if {
	count(region.deny) == 1 with input as plan([rc("aws_s3_bucket", "us-west-2", {})])
}

test_acm_in_us_east_1_allowed if {
	count(region.deny) == 0 with input as plan([rc("aws_acm_certificate", "us-east-1", {})])
}

test_cloudfront_waf_in_us_east_1_allowed if {
	count(region.deny) == 0 with input as plan([rc("aws_wafv2_web_acl", "us-east-1", {"scope": "CLOUDFRONT"})])
}

test_regional_waf_in_us_east_1_denied if {
	count(region.deny) == 1 with input as plan([rc("aws_wafv2_web_acl", "us-east-1", {"scope": "REGIONAL"})])
}

test_bucket_in_us_east_1_denied if {
	count(region.deny) == 1 with input as plan([rc("aws_s3_bucket", "us-east-1", {})])
}

test_deleted_resource_ignored if {
	gone := object.union(rc("aws_s3_bucket", "us-west-2", {}), {"change": {"actions": ["delete"], "after": null}})
	count(region.deny) == 0 with input as plan([gone])
}

provider_plan(region, alias) := {"resource_changes": [], "configuration": {"provider_config": {"aws": object.union(
	{"name": "aws", "expressions": {"region": {"constant_value": region}}},
	alias,
)}}}

test_plan_provider_eu_allowed if {
	count(region.deny) == 0 with input as provider_plan("eu-central-1", {})
}

test_plan_provider_us_east_1_alias_allowed if {
	count(region.deny) == 0 with input as provider_plan("us-east-1", {"alias": "us_east_1"})
}

test_plan_provider_us_east_1_default_denied if {
	count(region.deny) == 1 with input as provider_plan("us-east-1", {})
}

hcl_provider(body) := [{"path": "live/dev/de/providers.tf", "contents": {"provider": {"aws": [body]}}}]

test_hcl_provider_eu_allowed if {
	count(region.deny) == 0 with input as hcl_provider({"region": "eu-west-3"})
}

test_hcl_provider_variable_region_ignored if {
	count(region.deny) == 0 with input as hcl_provider({"region": "${var.region}"})
}

test_hcl_provider_outside_eu_denied if {
	count(region.deny) == 1 with input as hcl_provider({"region": "eu-north-1"})
}

test_hcl_provider_us_east_1_alias_allowed if {
	count(region.deny) == 0 with input as hcl_provider({"region": "us-east-1", "alias": "us_east_1"})
}
