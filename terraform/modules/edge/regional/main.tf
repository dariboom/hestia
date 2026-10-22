# Regional public ingress (ADR-005): an internet-facing ALB that only speaks TLS, with a
# DNS-validated regional ACM certificate and an IP target group the EKS LB Controller fills
# through a TargetGroupBinding.

data "aws_region" "current" {}

data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  region_code = { "eu-central-1" = "de", "eu-west-3" = "fr" }[var.region]
  name_prefix = "hestia-${var.environment}-${local.region_code}"
  alb_name    = "${local.name_prefix}-alb"
}

resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"
  tags                      = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.this.domain_validation_options : o.domain_name => o
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_security_group" "alb" {
  name        = local.alb_name
  description = "Public ingress to ${local.alb_name}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = local.alb_name })
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  #checkov:skip=CKV_AWS_260:Public ALB; 443 is the only content listener and sits behind WAF.
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  #checkov:skip=CKV_AWS_260:Port 80 only answers with a 301 to HTTPS; no content is served.
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet, redirected to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

# Targets are pod IPs inside the VPC, so egress never leaves it.
resource "aws_vpc_security_group_egress_rule" "targets" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS to pod targets in the VPC"
  cidr_ipv4         = data.aws_vpc.this.cidr_block
  ip_protocol       = "tcp"
  from_port         = var.target_port
  to_port           = var.target_port
}

resource "aws_lb" "this" {
  #checkov:skip=CKV_AWS_150:Deletion protection is on in prod (environment == "prod"); dev/staging stay disposable.
  name                       = local.alb_name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  enable_deletion_protection = var.environment == "prod"

  access_logs {
    enabled = true
    bucket  = var.access_log_bucket
    prefix  = local.alb_name
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = data.aws_region.current.region == var.region
      error_message = "var.region does not match the provider region; the ALB must stay in-region."
    }
  }
}

resource "aws_lb_target_group" "this" {
  name                 = "${local.name_prefix}-tg"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  protocol             = "HTTPS"
  protocol_version     = "HTTP1"
  port                 = var.target_port
  deregistration_delay = 30

  health_check {
    protocol = "HTTPS"
    path     = var.health_check_path
    matcher  = "200-399"
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = var.tags
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  tags = var.tags
}
