# High-severity findings to a KMS-encrypted SNS topic, per region. The recipient address lives in SSM, not in code.

locals {
  alert_rules = {
    guardduty = {
      source      = ["aws.guardduty"]
      detail-type = ["GuardDuty Finding"]
      detail      = { severity = [{ numeric = [">=", 7] }] }
    }
    # Region filter: home_region also receives the other region's findings via the aggregator; alert once, at source.
    securityhub = {
      source      = ["aws.securityhub"]
      detail-type = ["Security Hub Findings - Imported"]
      detail = {
        findings = {
          Region      = [var.region]
          Severity    = { Label = ["CRITICAL", "HIGH"] }
          Workflow    = { Status = ["NEW"] }
          RecordState = ["ACTIVE"]
        }
      }
    }
  }
}

data "aws_ssm_parameter" "alert_email" {
  name = var.alert_email_ssm_parameter_name
}

resource "aws_sns_topic" "security_alerts" {
  name              = "${local.name_prefix}-security-alerts"
  kms_master_key_id = module.kms["audit"].key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "security_alerts" {
  statement {
    sid       = "EventBridgeRules"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for r in aws_cloudwatch_event_rule.security_alerts : r.arn]
    }
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.security_alerts.json
}

resource "aws_sns_topic_subscription" "security_alerts_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = data.aws_ssm_parameter.alert_email.value
}

resource "aws_cloudwatch_event_rule" "security_alerts" {
  for_each = local.alert_rules

  name          = "${local.name_prefix}-${each.key}-alerts"
  description   = "High-severity ${each.key} findings to ${aws_sns_topic.security_alerts.name}"
  event_pattern = jsonencode(each.value)
  tags          = var.tags
}

resource "aws_cloudwatch_event_target" "security_alerts" {
  for_each = aws_cloudwatch_event_rule.security_alerts

  rule      = each.value.name
  target_id = "sns"
  arn       = aws_sns_topic.security_alerts.arn
}
