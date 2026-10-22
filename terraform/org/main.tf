# Guardrail SCPs for the Hestia OUs. SCPs only deny; access is still granted by IAM in each account.

data "aws_partition" "current" {}

locals {
  allowed_regions = ["eu-central-1", "eu-west-3"]
  break_glass_arn = "arn:${data.aws_partition.current.partition}:iam::*:role/${var.break_glass_role_name}"

  policies = {
    region-lock = {
      description = "Deny actions outside eu-central-1/eu-west-3, except global services (ADR-005)."
      statements = [
        {
          Sid    = "DenyOutsideAllowedRegions"
          Effect = "Deny"
          # Each exemption is a global service whose API is served from a single (usually us-east-1) endpoint, so
          # aws:RequestedRegion is not one of ours even for EU work.
          NotAction = [
            "iam:*",              # global identity
            "organizations:*",    # global; this root and account management
            "route53:*",          # global DNS
            "route53domains:*",   # domain registration, us-east-1 only
            "cloudfront:*",       # global CDN control plane
            "waf:*",              # classic WAF with CLOUDFRONT scope, us-east-1 only
            "wafv2:*",            # WAF CLOUDFRONT scope lives in us-east-1; region-capped below
            "acm:*",              # CloudFront certificates must be in us-east-1; region-capped below
            "sts:*",              # global STS endpoint used by SDKs and the OIDC deploy role
            "support:*",          # AWS Support, us-east-1 only
            "budgets:*",          # global
            "ce:*",               # Cost Explorer, us-east-1 only
            "cur:*",              # Cost and Usage Reports, us-east-1 only
            "bcm-data-exports:*", # carbon/cost data exports, us-east-1 only (ADR-005)
            "health:*",           # AWS Health, us-east-1 endpoint
            "trustedadvisor:*",   # Trusted Advisor, us-east-1 only
          ]
          Resource  = "*"
          Condition = { StringNotEquals = { "aws:RequestedRegion" = local.allowed_regions } }
        },
        {
          # ACM and WAF are exempt above only so CloudFront can use them in us-east-1; nowhere else.
          Sid       = "DenyAcmWafOutsideEuAndUsEast1"
          Effect    = "Deny"
          Action    = ["acm:*", "waf:*", "wafv2:*"]
          Resource  = "*"
          Condition = { StringNotEquals = { "aws:RequestedRegion" = concat(local.allowed_regions, ["us-east-1"]) } }
        },
      ]
    }

    protect-audit = {
      description = "Deny disabling or weakening CloudTrail, GuardDuty, Config, Security Hub, Object Lock and KMS keys."
      statements = [
        {
          Sid    = "DenyAuditControlChanges"
          Effect = "Deny"
          Action = [
            "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
            "guardduty:Delete*", "guardduty:Disassociate*",
            "config:Stop*", "config:Delete*",
            "securityhub:Disable*",
            "s3:PutBucketObjectLockConfiguration",
            "kms:ScheduleKeyDeletion",
          ]
          Resource = "*"
          # Break-glass only: incident response, and audit store changes the deploy role cannot make (README).
          Condition = { ArnNotLike = { "aws:PrincipalArn" = local.break_glass_arn } }
        },
      ]
    }

    no-leave-org = {
      description = "Deny member accounts leaving the organization."
      statements = [
        {
          Sid      = "DenyLeaveOrganization"
          Effect   = "Deny"
          Action   = "organizations:LeaveOrganization"
          Resource = "*"
        },
      ]
    }
  }

  attachments = {
    for pair in setproduct(keys(local.policies), var.target_ou_ids) : "${pair[0]}:${pair[1]}" => {
      policy = pair[0]
      target = pair[1]
    }
  }
}

resource "aws_organizations_policy" "this" {
  for_each = local.policies

  name        = "hestia-${each.key}"
  description = each.value.description
  type        = "SERVICE_CONTROL_POLICY"
  content     = jsonencode({ Version = "2012-10-17", Statement = each.value.statements })
}

resource "aws_organizations_policy_attachment" "this" {
  for_each = local.attachments

  policy_id = aws_organizations_policy.this[each.value.policy].id
  target_id = each.value.target
}
