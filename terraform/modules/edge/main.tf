# Global DNS (ADR-005): Route 53 is a global service, so this stack is applied once per
# environment from DE. Records route to the regional ALBs; no personal data goes into names.

locals {
  name_prefix = "hestia-${var.environment}"
  region_code = { "eu-central-1" = "de", "eu-west-3" = "fr" }

  public_albs = var.enable_public_ingress ? var.regional_albs : {}
}

resource "aws_route53_zone" "private" {
  #checkov:skip=CKV2_AWS_39:Private zone; VPC DNS queries are logged by Route 53 Resolver query logging in each regional stack.
  #checkov:skip=CKV2_AWS_38:DNSSEC signing applies to public zones only.
  name    = var.internal_domain_name
  comment = "${local.name_prefix} internal names, shared by the DE and FR VPCs"

  dynamic "vpc" {
    for_each = var.vpc_associations

    content {
      vpc_id     = vpc.value.vpc_id
      vpc_region = vpc.value.region
    }
  }

  tags = var.tags
}

resource "aws_route53_zone" "public" {
  #checkov:skip=CKV2_AWS_39:Public query logging must target a us-east-1 log group, which ADR-005 does not allow.
  #checkov:skip=CKV2_AWS_38:DNSSEC needs an asymmetric KMS key in us-east-1, outside the ADR-005 exceptions.
  # CloudFront also needs it for the dashboard certificate and alias.
  count = var.enable_public_ingress || var.enable_cloudfront ? 1 : 0

  name    = var.domain_name
  comment = "${local.name_prefix} public names"
  tags    = var.tags
}

resource "aws_route53_health_check" "alb" {
  for_each = local.public_albs

  type              = "HTTPS"
  fqdn              = each.value.dns_name
  port              = 443
  resource_path     = var.health_check_path
  failure_threshold = 3
  request_interval  = 30
  tags              = merge(var.tags, { Name = "${local.name_prefix}-${local.region_code[each.key]}-alb" })
}

# portal: active-active reads, nearest healthy region wins.
resource "aws_route53_record" "portal" {
  #checkov:skip=CKV2_AWS_23:Alias target is a regional ALB from another stack (regional_albs input), which checkov cannot resolve.
  for_each = local.public_albs

  zone_id         = aws_route53_zone.public[0].zone_id
  name            = "portal.${var.domain_name}"
  type            = "A"
  set_identifier  = local.region_code[each.key]
  health_check_id = aws_route53_health_check.alb[each.key].id

  latency_routing_policy {
    region = each.key
  }

  alias {
    name                   = each.value.dns_name
    zone_id                = each.value.zone_id
    evaluate_target_health = true
  }
}

# api: writes go to the DE primary; FR takes over only when DE is unhealthy.
resource "aws_route53_record" "api" {
  #checkov:skip=CKV2_AWS_23:Alias target is a regional ALB from another stack (regional_albs input), which checkov cannot resolve.
  for_each = local.public_albs

  zone_id         = aws_route53_zone.public[0].zone_id
  name            = "api.${var.domain_name}"
  type            = "A"
  set_identifier  = local.region_code[each.key]
  health_check_id = aws_route53_health_check.alb[each.key].id

  failover_routing_policy {
    type = each.key == "eu-central-1" ? "PRIMARY" : "SECONDARY"
  }

  alias {
    name                   = each.value.dns_name
    zone_id                = each.value.zone_id
    evaluate_target_health = true
  }
}
