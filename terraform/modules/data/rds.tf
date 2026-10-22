# PostgreSQL: a primary in the active region, a cross-region read replica in the passive one (ADR-003).
# The master password is RDS-managed (manage_master_user_password) and lives in a KMS-encrypted
# Secrets Manager secret; Terraform never sees it. Applications use IAM DB auth.

locals {
  db_enabled    = var.db_role != null
  db_primary    = var.db_role == "primary"
  db_identifier = "${local.name_prefix}-db"
  db_family     = "postgres${split(".", var.db_engine_version)[0]}"
  db_log_types  = ["postgresql", "upgrade"]
}

resource "aws_security_group" "db" {
  #checkov:skip=CKV2_AWS_5:Attached to aws_db_instance.db via vpc_security_group_ids (count-indexed, not resolved by checkov).
  count = local.db_enabled ? 1 : 0

  name        = local.db_identifier
  description = "Hestia ${var.environment} PostgreSQL: 5432 from app security groups and the peer VPC only."
  vpc_id      = var.db_vpc_id
  tags        = merge(var.tags, { Name = local.db_identifier })
}

resource "aws_vpc_security_group_ingress_rule" "db_from_sg" {
  for_each = local.db_enabled ? toset(var.db_allowed_security_group_ids) : toset([])

  security_group_id            = aws_security_group.db[0].id
  description                  = "PostgreSQL from app security group"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = each.key
}

resource "aws_vpc_security_group_ingress_rule" "db_from_peer" {
  for_each = local.db_enabled ? toset(var.db_peer_cidr_blocks) : toset([])

  security_group_id = aws_security_group.db[0].id
  description       = "PostgreSQL from peer region VPC (replication, DR failover clients)"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.key
}

resource "aws_db_subnet_group" "db" {
  count = local.db_enabled ? 1 : 0

  name       = local.db_identifier
  subnet_ids = var.db_subnet_ids
  tags       = var.tags
}

resource "aws_db_parameter_group" "db" {
  count = local.db_enabled ? 1 : 0

  name   = "${local.db_identifier}-${local.db_family}"
  family = local.db_family
  tags   = var.tags

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pgaudit,pg_stat_statements"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "pgaudit.log"
    value = "ddl,role"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  # Statement text can contain personal data; only slow statements are logged.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Created up front so the exports land in KMS-encrypted, retention-bounded groups.
resource "aws_cloudwatch_log_group" "db" {
  for_each = local.db_enabled ? toset(local.db_log_types) : toset([])

  name              = "/aws/rds/instance/${local.db_identifier}/${each.key}"
  retention_in_days = var.db_log_retention_days
  kms_key_id        = var.db_log_kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "db_monitoring_assume" {
  count = local.db_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "db_monitoring" {
  count = local.db_enabled ? 1 : 0

  name                 = "${local.db_identifier}-monitoring"
  assume_role_policy   = data.aws_iam_policy_document.db_monitoring_assume[0].json
  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:policy/hestia-${var.environment}-boundary"
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "db_monitoring" {
  count = local.db_enabled ? 1 : 0

  role       = aws_iam_role.db_monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "db" {
  #checkov:skip=CKV_AWS_293:Deletion protection is on in prod; dev/staging databases are disposable.
  #checkov:skip=CKV2_AWS_30:log_statement=all would copy personal data into logs (GDPR); pgaudit ddl/role plus slow statements are logged instead.
  count = local.db_enabled ? 1 : 0

  identifier     = local.db_identifier
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  # Replicas inherit storage, credentials and database settings from the source.
  replicate_source_db           = local.db_primary ? null : var.db_source_db_arn
  allocated_storage             = local.db_primary ? var.db_allocated_storage : null
  max_allocated_storage         = var.db_max_allocated_storage
  storage_type                  = "gp3"
  storage_encrypted             = true
  kms_key_id                    = var.kms_key_arn
  username                      = local.db_primary ? "hestia_admin" : null
  manage_master_user_password   = local.db_primary ? true : null
  master_user_secret_kms_key_id = local.db_primary ? var.secrets_kms_key_arn : null

  db_subnet_group_name                = aws_db_subnet_group.db[0].name
  vpc_security_group_ids              = [aws_security_group.db[0].id]
  parameter_group_name                = aws_db_parameter_group.db[0].name
  multi_az                            = true
  publicly_accessible                 = false
  iam_database_authentication_enabled = true
  ca_cert_identifier                  = "rds-ca-rsa2048-g1"

  backup_retention_period    = var.db_backup_retention_days
  copy_tags_to_snapshot      = true
  deletion_protection        = var.environment == "prod"
  skip_final_snapshot        = var.environment != "prod"
  final_snapshot_identifier  = "${local.db_identifier}-final"
  auto_minor_version_upgrade = true

  enabled_cloudwatch_logs_exports       = local.db_log_types
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.db_monitoring[0].arn

  tags = merge(var.tags, {
    "hestia:environment"         = var.environment
    "hestia:data-classification" = "personal"
  })

  depends_on = [aws_cloudwatch_log_group.db, aws_iam_role_policy_attachment.db_monitoring]

  lifecycle {
    precondition {
      condition     = local.db_primary == (var.db_source_db_arn == null)
      error_message = "db_source_db_arn is required for db_role = \"replica\" and must be null for \"primary\"."
    }

    precondition {
      condition     = !local.db_primary || var.secrets_kms_key_arn != null
      error_message = "secrets_kms_key_arn is required for a primary: it encrypts the RDS-managed master user secret."
    }

    precondition {
      condition     = length(var.db_subnet_ids) >= 2 && var.db_vpc_id != null && var.db_log_kms_key_arn != null
      error_message = "A database needs db_vpc_id, db_log_kms_key_arn and at least two isolated db_subnet_ids."
    }
  }
}
