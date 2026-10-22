# CI identity (ADR-004): GitHub Actions OIDC, no long-lived keys.
#   hestia-<env>-tf-deploy    plan/apply from the GitHub environment <env> (human-approved)
#   hestia-<env>-tf-readonly  reads state only, from the GitHub environment <env>-readonly
# Both roles, and every role the deploy role creates, carry the hestia-<env>-boundary
# permissions boundary, so the deploy role cannot mint a role more powerful than itself.

data "aws_partition" "current" {}

locals {
  partition          = data.aws_partition.current.partition
  iam_arn_prefix     = "arn:${local.partition}:iam::${var.account_id}"
  boundary_name      = "hestia-${var.environment}-boundary"
  boundary_arn       = "${local.iam_arn_prefix}:policy/${local.boundary_name}"
  deploy_role_name   = "hestia-${var.environment}-tf-deploy"
  readonly_role_name = "hestia-${var.environment}-tf-readonly"
  github_subject     = "repo:${var.github_org}/${var.github_repo}:environment"

  # Services the platform modules manage. Kept explicit so a new service is a reviewed change.
  managed_services = [
    "access-analyzer", "acm", "application-autoscaling", "athena", "autoscaling", "bcm-data-exports",
    "budgets", "ce", "cloudfront", "cloudtrail", "cloudwatch", "config", "cur", "ec2", "ecr", "eks",
    "elasticloadbalancing", "events", "firehose", "glue", "guardduty", "kms", "lambda", "logs", "rds",
    "route53", "s3", "secretsmanager", "securityhub", "sns", "sqs", "ssm", "tag", "wafv2",
  ]

  audit_bucket_arns = [
    "arn:${local.partition}:s3:::hestia-${var.environment}-*audit*",
    "arn:${local.partition}:s3:::hestia-${var.environment}-*audit*/*",
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# --- Permissions boundary (also the deploy role's permission policy)

data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "ManageHestiaServices"
    actions   = [for s in local.managed_services : "${s}:*"]
    resources = ["*"]

    # us-east-1 is where global control planes (IAM, Route 53, CloudFront, ACM/WAF for CloudFront,
    # BCM) answer; region-lock.rego and the SCPs keep regional resources out of it (ADR-005).
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["eu-central-1", "eu-west-3", "us-east-1"]
    }
  }

  statement {
    sid     = "ManageHestiaIam"
    actions = ["iam:*"]
    resources = [
      "${local.iam_arn_prefix}:role/hestia-*",
      "${local.iam_arn_prefix}:policy/hestia-*",
      "${local.iam_arn_prefix}:instance-profile/hestia-*",
      "${local.iam_arn_prefix}:role/aws-service-role/*",
      "${local.iam_arn_prefix}:oidc-provider/oidc.eks.*",
    ]
  }

  statement {
    sid       = "RequireBoundaryOnNewRoles"
    effect    = "Deny"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid    = "ProtectBoundaryAndCiIdentity"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion", "iam:DeletePolicy",
      "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:DeleteRole", "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider",
    ]
    resources = [
      local.boundary_arn,
      "${local.iam_arn_prefix}:role/${local.deploy_role_name}",
      "${local.iam_arn_prefix}:role/${local.readonly_role_name}",
      aws_iam_openid_connect_provider.github.arn,
    ]
  }

  # Audit trail and WORM store are append-only for automation; changes go through break-glass.
  statement {
    sid    = "ProtectAuditControls"
    effect = "Deny"
    actions = [
      "cloudtrail:StopLogging", "cloudtrail:DeleteTrail",
      "guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount",
      "securityhub:DisableSecurityHub",
      "config:StopConfigurationRecorder", "config:DeleteConfigurationRecorder", "config:DeleteDeliveryChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ProtectAuditStore"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket", "s3:DeleteBucketPolicy", "s3:DeleteObjectVersion",
      "s3:BypassGovernanceRetention", "s3:PutLifecycleConfiguration",
    ]
    resources = local.audit_bucket_arns
  }

  statement {
    sid       = "ProtectAuditKeys"
    effect    = "Deny"
    actions   = ["kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:PutKeyPolicy"]
    resources = ["*"]

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = ["alias/hestia-${var.environment}-*-audit"]
    }
  }
}

resource "aws_iam_policy" "boundary" {
  name        = local.boundary_name
  description = "Permissions boundary for every hestia ${var.environment} role created by CI; also the tf-deploy permission policy."
  policy      = data.aws_iam_policy_document.boundary.json
}

# --- tf-deploy

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    sid     = "GitHubDeployEnvironment"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_subject}:${var.environment}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = local.deploy_role_name
  description          = "Terraform deploy role for hestia ${var.environment}, assumed only from GitHub environment ${var.environment}."
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.boundary.arn
}

# Secret values are set out-of-band; the pipeline never reads or writes them.
data "aws_iam_policy_document" "deploy_deny_secret_values" {
  statement {
    sid       = "DenySecretValues"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:RestoreSecret"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy_deny_secret_values" {
  name   = "deny-secret-values"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_deny_secret_values.json
}

# --- tf-readonly

data "aws_iam_policy_document" "readonly_trust" {
  statement {
    sid     = "GitHubReadonlyEnvironment"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_subject}:${var.environment}-readonly"]
    }
  }
}

resource "aws_iam_role" "readonly" {
  name                 = local.readonly_role_name
  description          = "Read-only access to hestia ${var.environment} Terraform state, from GitHub environment ${var.environment}-readonly."
  assume_role_policy   = data.aws_iam_policy_document.readonly_trust.json
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = 3600
}

data "aws_iam_policy_document" "readonly_state" {
  statement {
    sid       = "ListStateBuckets"
    actions   = ["s3:ListBucket"]
    resources = [module.state_bucket_de.arn, module.state_bucket_fr.arn]
  }

  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${module.state_bucket_de.arn}/*", "${module.state_bucket_fr.arn}/*"]
  }

  statement {
    sid       = "DecryptState"
    actions   = ["kms:Decrypt"]
    resources = [module.state_kms_de.key_arn, module.state_kms_fr.key_arn]
  }
}

resource "aws_iam_role_policy" "readonly_state" {
  name   = "read-state"
  role   = aws_iam_role.readonly.id
  policy = data.aws_iam_policy_document.readonly_state.json
}
