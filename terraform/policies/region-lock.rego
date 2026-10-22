package hestia.region

import data.hestia.lib
import rego.v1

allowed := {"eu-central-1", "eu-west-3"}

# us-east-1 hosts only global-service control planes (ADR-005).
global_service(rc) if rc.type in {"aws_acm_certificate", "aws_acm_certificate_validation", "aws_bcmdataexports_export"}

global_service(rc) if startswith(rc.type, "aws_cloudfront_")

global_service(rc) if {
	rc.type == "aws_wafv2_web_acl"
	rc.change.after.scope == "CLOUDFRONT"
}

permitted(_, region) if region in allowed

permitted(rc, "us-east-1") if global_service(rc)

deny contains msg if {
	some rc in lib.changes
	region := rc.change.after.region
	is_string(region)
	not permitted(rc, region)
	msg := sprintf("region-lock: %s is planned in %s; only eu-central-1/eu-west-3 (us-east-1 for global services) are allowed", [rc.address, region])
}

# A us-east-1 provider is acceptable only as an explicit alias for global services.
provider_ok(region, _) if region in allowed

provider_ok("us-east-1", alias) if alias != ""

deny contains msg if {
	lib.plan_mode
	some key, p in input.configuration.provider_config
	p.name == "aws"
	region := p.expressions.region.constant_value
	not provider_ok(region, object.get(p, "alias", ""))
	msg := sprintf("region-lock: provider %s uses region %s", [key, region])
}

deny contains msg if {
	some p in lib.labeled("provider")
	p.name == "aws"
	lib.literal(p.body.region)
	not provider_ok(p.body.region, object.get(p.body, "alias", ""))
	msg := sprintf("region-lock: %s: aws provider uses region %s", [p.path, p.body.region])
}
