# Optional CloudFront for the anonymized dashboard (ADR-005). Off by default: with
# enable_cloudfront = false nothing here exists and the us_east_1 provider is never used.
# CloudFront only accepts certificates and WAF ACLs from us-east-1; content, origin and logs
# stay in the EU, and only EU/EEA viewers are served.

locals {
  cloudfront     = var.enable_cloudfront ? 1 : 0
  dashboard_fqdn = "dashboard.${var.domain_name}"
}

# ADR-005 exception: CloudFront viewer certificates must live in us-east-1.
resource "aws_acm_certificate" "dashboard" {
  provider = aws.us_east_1
  count    = local.cloudfront

  domain_name       = local.dashboard_fqdn
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "dashboard_cert_validation" {
  for_each = {
    for o in flatten(aws_acm_certificate.dashboard[*].domain_validation_options) : o.domain_name => o
  }

  zone_id         = aws_route53_zone.public[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

# ADR-005 exception: validation of the us-east-1 certificate.
resource "aws_acm_certificate_validation" "dashboard" {
  provider = aws.us_east_1
  count    = local.cloudfront

  certificate_arn         = aws_acm_certificate.dashboard[0].arn
  validation_record_fqdns = [for r in aws_route53_record.dashboard_cert_validation : r.fqdn]
}

# ADR-005 exception: CLOUDFRONT-scope WAF ACLs exist only in us-east-1.
resource "aws_wafv2_web_acl" "dashboard" {
  #checkov:skip=CKV2_AWS_31:WAF logging would need a us-east-1 log destination, which ADR-005 does not allow; CloudFront standard logs in the DE bucket record every request instead.
  provider = aws.us_east_1
  count    = local.cloudfront

  name  = "${local.name_prefix}-dashboard-waf"
  scope = "CLOUDFRONT"
  tags  = var.tags

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = var.waf_rule_config.managed_rule_groups

    content {
      name     = rule.value
      priority = rule.key

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name_prefix}-dashboard-${rule.value}"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = length(var.waf_rule_config.managed_rule_groups)

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.waf_rule_config.rate_limit_per_5min
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-dashboard-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-dashboard-waf"
    sampled_requests_enabled   = true
  }
}

# ADR-005 exception: CloudFront control plane (global service, managed from us-east-1).
resource "aws_cloudfront_origin_access_control" "dashboard" {
  provider = aws.us_east_1
  count    = local.cloudfront

  name                              = "${local.name_prefix}-dashboard"
  description                       = "Signed S3 reads of the anonymized dashboard"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ADR-005 exception: AWS managed policies, looked up through the CloudFront control plane.
# CachingOptimized keys the cache on the URL only, so no cookie, query string or
# Authorization header ever reaches the origin.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  provider = aws.us_east_1
  count    = local.cloudfront

  name = "Managed-CachingOptimized"
}

# ADR-005 exception: see above.
data "aws_cloudfront_response_headers_policy" "security_headers" {
  provider = aws.us_east_1
  count    = local.cloudfront

  name = "Managed-SecurityHeadersPolicy"
}

# ADR-005 exception: CloudFront control plane (global service, managed from us-east-1).
resource "aws_cloudfront_distribution" "dashboard" {
  #checkov:skip=CKV2_AWS_47:The ACL adds AWSManagedRulesKnownBadInputsRuleSet (Log4j) by default through a dynamic block, which checkov does not expand.
  #checkov:skip=CKV_AWS_310:Single static S3 origin; S3 is already multi-AZ, and a failover origin in FR would duplicate the dashboard for no gain.
  provider = aws.us_east_1
  count    = local.cloudfront

  enabled             = true
  comment             = "${local.name_prefix} anonymized dashboard"
  aliases             = [local.dashboard_fqdn]
  price_class         = "PriceClass_100"
  http_version        = "http2and3"
  is_ipv6_enabled     = true
  default_root_object = trimprefix("${var.cloudfront_origin_paths[0]}/index.html", "/")
  web_acl_id          = aws_wafv2_web_acl.dashboard[0].arn
  tags                = var.tags

  origin {
    origin_id                = "dashboard-s3"
    domain_name              = var.dashboard_origin.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.dashboard[0].id
  }

  default_cache_behavior {
    target_origin_id           = "dashboard-s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized[0].id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = var.cloudfront_geo_allowlist
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.dashboard[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  logging_config {
    bucket          = "${var.cloudfront_log_bucket}.s3.amazonaws.com"
    prefix          = "${local.name_prefix}-dashboard/"
    include_cookies = false
  }
}

resource "aws_route53_record" "dashboard" {
  for_each = var.enable_cloudfront ? toset(["A", "AAAA"]) : toset([])

  zone_id = aws_route53_zone.public[0].zone_id
  name    = local.dashboard_fqdn
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.dashboard[0].domain_name
    zone_id                = aws_cloudfront_distribution.dashboard[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# Only this distribution may read the dashboard prefixes; the rest of the bucket stays private.
data "aws_iam_policy_document" "dashboard_origin" {
  count = local.cloudfront

  statement {
    sid       = "CloudFrontReadDashboard"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [for p in var.cloudfront_origin_paths : "${var.dashboard_origin.bucket_arn}${p}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.dashboard[0].arn]
    }
  }
}
