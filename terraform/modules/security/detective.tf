# Regional detective controls. Both regions detect; only home_region aggregates (no aggregator in the other).

locals {
  is_home      = var.region == var.home_region
  other_region = one([for r in ["eu-central-1", "eu-west-3"] : r if r != var.region])

  guardduty_features = {
    S3_DATA_EVENTS         = {}
    EKS_AUDIT_LOGS         = {}
    RDS_LOGIN_EVENTS       = {}
    EBS_MALWARE_PROTECTION = {}
    # GuardDuty manages the EKS runtime agent as an add-on; no agent on EC2 or Fargate outside EKS.
    RUNTIME_MONITORING = { EKS_ADDON_MANAGEMENT = "ENABLED" }
  }
}

data "aws_region" "current" {}

resource "aws_guardduty_detector" "this" {
  #checkov:skip=CKV2_AWS_3:Enabled per account in each allowed region by this module; there is no Organizations GuardDuty administrator (org/ holds SCPs only, Task 6).
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  tags                         = var.tags

  lifecycle {
    precondition {
      condition     = data.aws_region.current.region == var.region
      error_message = "var.region does not match the provider region."
    }
  }
}

resource "aws_guardduty_detector_feature" "this" {
  for_each = local.guardduty_features

  detector_id = aws_guardduty_detector.this.id
  name        = each.key
  status      = "ENABLED"

  dynamic "additional_configuration" {
    for_each = each.value
    content {
      name   = additional_configuration.key
      status = additional_configuration.value
    }
  }
}

resource "aws_securityhub_account" "this" {
  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = true
}

resource "aws_securityhub_standards_subscription" "this" {
  for_each = toset(var.securityhub_standards)

  standards_arn = "${local.arn_prefix}:securityhub:${var.region}::standards/${each.value}"
  depends_on    = [aws_securityhub_account.this]
}

resource "aws_securityhub_finding_aggregator" "this" {
  count = local.is_home ? 1 : 0

  linking_mode      = "SPECIFIED_REGIONS"
  specified_regions = [local.other_region]
  depends_on        = [aws_securityhub_account.this]
}

resource "aws_accessanalyzer_analyzer" "this" {
  analyzer_name = "${local.name_prefix}-access"
  type          = "ACCOUNT"
  tags          = var.tags
}
