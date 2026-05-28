# ---------------------------------------------------------------------------
# locals
# ---------------------------------------------------------------------------

locals {
  is_postgres = var.engine == "aurora-postgresql"
  port        = local.is_postgres ? 5432 : 3306

  # Determine the parameter group family from the engine and version.
  # Aurora PostgreSQL: "aurora-postgresql15", Aurora MySQL: "aurora-mysql8.0"
  pg_family = local.is_postgres ? "aurora-postgresql${split(".", var.engine_version)[0]}" : "aurora-mysql${join(".", slice(split(".", var.engine_version), 0, 2))}"

  # Default log exports per engine.
  default_logs = local.is_postgres ? ["postgresql", "upgrade"] : ["audit", "error", "general", "slowquery"]
  logs_exports = length(var.cloudwatch_logs_exports) > 0 ? var.cloudwatch_logs_exports : local.default_logs

  # Use the caller-supplied KMS key or fall back to the default RDS key (empty string = default).
  kms_key_id = var.kms_key_id != "" ? var.kms_key_id : null

  # Instance list (writer at index 0, readers at 1..N).
  instance_ids = [for i in range(var.instance_count) : format("%s-%s", var.name, i == 0 ? "writer" : "reader-${i}")]

  # Replica instance class: fall back to primary instance class.
  replica_instance_class = var.replica_instance_class != "" ? var.replica_instance_class : var.instance_class

  # Use an existing SNS topic or the one this module creates.
  sns_topic_arn = var.existing_sns_topic_arn != "" ? var.existing_sns_topic_arn : aws_sns_topic.alarms[0].arn

  # Default cluster parameters per engine.
  default_cluster_params_pg = {
    log_statement = {
      value        = "ddl"
      apply_method = "immediate"
    }
    log_min_duration_statement = {
      value        = "1000" # log queries slower than 1 s
      apply_method = "immediate"
    }
    rds.force_ssl = {
      value        = "1"
      apply_method = "immediate"
    }
    shared_preload_libraries = {
      value        = "pg_stat_statements"
      apply_method = "pending-reboot"
    }
  }

  default_cluster_params_mysql = {
    slow_query_log = {
      value        = "1"
      apply_method = "immediate"
    }
    long_query_time = {
      value        = "1"
      apply_method = "immediate"
    }
    log_output = {
      value        = "FILE"
      apply_method = "immediate"
    }
    require_secure_transport = {
      value        = "ON"
      apply_method = "immediate"
    }
  }

  # Merge module defaults with caller-supplied overrides. Caller wins on conflict.
  effective_cluster_params = merge(
    local.is_postgres ? local.default_cluster_params_pg : local.default_cluster_params_mysql,
    var.cluster_parameters
  )
}

# ---------------------------------------------------------------------------
# Master password
# ---------------------------------------------------------------------------

resource "random_password" "master" {
  count = var.master_password == "" ? 1 : 0

  length           = 32
  special          = true
  override_special = "!#$%^&*()-_=+[]{}|;:,.<>?"
  # Aurora doesn't allow @ / in passwords.
}

locals {
  master_password = var.master_password != "" ? var.master_password : random_password.master[0].result
}

# ---------------------------------------------------------------------------
# Secrets Manager
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "master" {
  count = var.enable_secrets_manager ? 1 : 0

  name        = "${var.name}/aurora/master"
  description = "Master credentials for Aurora cluster ${var.name}."
  kms_key_id  = local.kms_key_id

  tags = merge(var.tags, { Name = "${var.name}-aurora-master-secret" })
}

resource "aws_secretsmanager_secret_version" "master" {
  count = var.enable_secrets_manager ? 1 : 0

  secret_id = aws_secretsmanager_secret.master[0].id
  secret_string = jsonencode({
    username = var.master_username
    password = local.master_password
    engine   = var.engine
    host     = aws_rds_cluster.this.endpoint
    port     = local.port
    dbname   = var.database_name
  })
}

resource "aws_secretsmanager_secret_rotation" "master" {
  count = var.enable_secrets_manager && var.enable_rotation ? 1 : 0

  secret_id           = aws_secretsmanager_secret.master[0].id
  rotation_lambda_arn = aws_lambda_function.rotation[0].arn

  rotation_rules {
    automatically_after_days = var.rotation_days
  }

  depends_on = [aws_lambda_permission.rotation_allow_sm]
}

# ---------------------------------------------------------------------------
# Rotation Lambda
# ---------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# The rotation Lambda uses the AWS-provided SAR application for Aurora.
# For simplicity this module creates a minimal inline function that can be
# replaced with the full SecretsManager-provided rotator if needed.

data "archive_file" "rotation_lambda" {
  count = var.enable_secrets_manager && var.enable_rotation ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/rotation_lambda.zip"

  source {
    content  = <<-PYTHON
      import boto3, json, os

      def handler(event, context):
          """
          Minimal rotation shim. Replace with the full AWS Secrets Manager
          RDS rotator (arn:aws:serverlessrepo:us-east-1:912272126732:applications/SecretsManagerRDSPostgreSQLRotationSingleUser)
          for production use.
          """
          raise NotImplementedError(
              "Deploy the full AWS SecretsManager rotator SAR application and "
              "set its Lambda ARN via the rotation_lambda_arn variable."
          )
      PYTHON
    filename = "handler.py"
  }
}

resource "aws_iam_role" "rotation_lambda" {
  count = var.enable_secrets_manager && var.enable_rotation ? 1 : 0

  name               = "${var.name}-aurora-rotation-lambda"
  assume_role_policy = data.aws_iam_policy_document.rotation_assume[0].json

  tags = merge(var.tags, { Name = "${var.name}-aurora-rotation-lambda" })
}

data "aws_iam_policy_document" "rotation_assume" {
  count = var.enable_secrets_manager && var.enable_rotation ? 1 : 0

  statement {
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role_policy_attachment" "rotation_lambda_basic" {
  count = var.enable_secrets_manager && var.enable_rotation ? 1 : 0

  role       = aws_iam_role.rotation_lambda[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "rotation_lambda_vpc" {
  count = var.enable_secrets_manager && var.enable_rotation ? 1 : 0

  role       = aws_iam_role.rotation_lambda[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "rotation" {
  count = var.enable_secrets_manager && var.enable_rotation ? 1 : 0

  function_name    = "${var.name}-aurora-rotation"
  role             = aws_iam_role.rotation_lambda[0].arn
  filename         = data.archive_file.rotation_lambda[0].output_path
  source_code_hash = data.archive_file.rotation_lambda[0].output_base64sha256
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      SECRETS_MANAGER_ENDPOINT = "https://secretsmanager.${data.aws_region.current.name}.amazonaws.com"
    }
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.cluster.id]
  }

  tags = merge(var.tags, { Name = "${var.name}-aurora-rotation" })
}

resource "aws_lambda_permission" "rotation_allow_sm" {
  count = var.enable_secrets_manager && var.enable_rotation ? 1 : 0

  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation[0].function_name
  principal     = "secretsmanager.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name        = "${var.name}-aurora"
  subnet_ids  = var.subnet_ids
  description = "Subnet group for Aurora cluster ${var.name}."

  tags = merge(var.tags, { Name = "${var.name}-aurora-subnet-group" })
}

resource "aws_security_group" "cluster" {
  name        = "${var.name}-aurora"
  description = "Controls access to the ${var.name} Aurora cluster."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-aurora-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "from_sg" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = each.value
  from_port                    = local.port
  to_port                      = local.port
  ip_protocol                  = "tcp"
  description                  = "Allow inbound from SG ${each.value}."

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "from_cidr" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = each.value
  from_port         = local.port
  to_port           = local.port
  ip_protocol       = "tcp"
  description       = "Allow inbound from ${each.value}."

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound (required for parameter group downloads and monitoring)."

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Parameter groups
# ---------------------------------------------------------------------------

resource "aws_rds_cluster_parameter_group" "this" {
  name        = "${var.name}-aurora-cluster"
  family      = local.pg_family
  description = "Cluster parameter group for ${var.name}."

  dynamic "parameter" {
    for_each = local.effective_cluster_params
    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-aurora-cluster-pg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name}-aurora-instance"
  family      = local.pg_family
  description = "Instance parameter group for ${var.name}."

  dynamic "parameter" {
    for_each = var.db_parameters
    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-aurora-instance-pg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Enhanced monitoring IAM role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "enhanced_monitoring" {
  count = var.enable_enhanced_monitoring && var.monitoring_interval > 0 ? 1 : 0

  name               = "${var.name}-aurora-enhanced-monitoring"
  assume_role_policy = data.aws_iam_policy_document.enhanced_monitoring_assume[0].json

  tags = merge(var.tags, { Name = "${var.name}-aurora-enhanced-monitoring" })
}

data "aws_iam_policy_document" "enhanced_monitoring_assume" {
  count = var.enable_enhanced_monitoring && var.monitoring_interval > 0 ? 1 : 0

  statement {
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role_policy_attachment" "enhanced_monitoring" {
  count = var.enable_enhanced_monitoring && var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.enhanced_monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------------------------------------------------------------------------
# Aurora cluster
# ---------------------------------------------------------------------------

resource "aws_rds_cluster" "this" {
  cluster_identifier = var.name
  engine             = var.engine
  engine_version     = var.engine_version

  database_name   = var.database_name
  master_username = var.master_username
  master_password = local.master_password

  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.cluster.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name

  storage_encrypted = true
  kms_key_id        = local.kms_key_id

  iam_database_authentication_enabled = var.enable_iam_auth

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = var.preferred_backup_window
  preferred_maintenance_window = var.preferred_maintenance_window

  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final-${formatdate("YYYYMMDD-HHmmss", timestamp())}"

  enabled_cloudwatch_logs_exports = local.logs_exports

  apply_immediately = false

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    # Prevent destroy if deletion_protection is on.
    # The password is managed via Secrets Manager; ignore changes to avoid
    # Terraform treating a rotation as drift.
    ignore_changes = [master_password, final_snapshot_identifier]
  }
}

# ---------------------------------------------------------------------------
# Cluster instances
# ---------------------------------------------------------------------------

resource "aws_rds_cluster_instance" "this" {
  count = var.instance_count

  identifier         = local.instance_ids[count.index]
  cluster_identifier = aws_rds_cluster.this.id
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version

  db_parameter_group_name = aws_db_parameter_group.this.name
  db_subnet_group_name    = aws_db_subnet_group.this.name

  monitoring_role_arn = var.enable_enhanced_monitoring && var.monitoring_interval > 0 ? aws_iam_role.enhanced_monitoring[0].arn : null
  monitoring_interval = var.enable_enhanced_monitoring ? var.monitoring_interval : 0

  performance_insights_enabled          = var.enable_performance_insights
  performance_insights_kms_key_id       = var.enable_performance_insights ? local.kms_key_id : null
  performance_insights_retention_period = var.enable_performance_insights ? var.performance_insights_retention_days : null

  apply_immediately            = false
  auto_minor_version_upgrade   = true
  copy_tags_to_snapshot        = true
  publicly_accessible          = false

  tags = merge(var.tags, {
    Name = local.instance_ids[count.index]
    Role = count.index == 0 ? "writer" : "reader"
  })

  depends_on = [aws_iam_role_policy_attachment.enhanced_monitoring]
}

# ---------------------------------------------------------------------------
# Cross-region read replica
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "replica" {
  count    = var.enable_cross_region_replica ? 1 : 0
  provider = aws.replica

  name        = "${var.name}-aurora-replica"
  subnet_ids  = var.replica_subnet_ids
  description = "Subnet group for cross-region replica of Aurora cluster ${var.name}."

  tags = merge(var.tags, { Name = "${var.name}-aurora-replica-subnet-group" })
}

resource "aws_rds_cluster_parameter_group" "replica" {
  count    = var.enable_cross_region_replica ? 1 : 0
  provider = aws.replica

  name        = "${var.name}-aurora-cluster-replica"
  family      = local.pg_family
  description = "Cluster parameter group for ${var.name} cross-region replica."

  dynamic "parameter" {
    for_each = local.effective_cluster_params
    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-aurora-cluster-pg-replica" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_parameter_group" "replica" {
  count    = var.enable_cross_region_replica ? 1 : 0
  provider = aws.replica

  name        = "${var.name}-aurora-instance-replica"
  family      = local.pg_family
  description = "Instance parameter group for ${var.name} cross-region replica."

  dynamic "parameter" {
    for_each = var.db_parameters
    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-aurora-instance-pg-replica" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_rds_cluster" "replica" {
  count    = var.enable_cross_region_replica ? 1 : 0
  provider = aws.replica

  cluster_identifier = "${var.name}-replica"
  engine             = var.engine
  engine_version     = var.engine_version

  # Replicate from the primary cluster.
  replication_source_identifier = aws_rds_cluster.this.arn

  db_subnet_group_name            = aws_db_subnet_group.replica[0].name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.replica[0].name

  storage_encrypted = true
  kms_key_id        = local.kms_key_id

  deletion_protection  = var.deletion_protection
  skip_final_snapshot  = var.skip_final_snapshot

  enabled_cloudwatch_logs_exports = local.logs_exports

  apply_immediately = false

  # Replica clusters don't set master credentials; they inherit from the source.
  lifecycle {
    ignore_changes = [replication_source_identifier]
  }

  tags = merge(var.tags, { Name = "${var.name}-replica" })
}

resource "aws_rds_cluster_instance" "replica" {
  count    = var.enable_cross_region_replica ? var.replica_instance_count : 0
  provider = aws.replica

  identifier         = "${var.name}-replica-${count.index}"
  cluster_identifier = aws_rds_cluster.replica[0].id
  instance_class     = local.replica_instance_class
  engine             = var.engine
  engine_version     = var.engine_version

  db_parameter_group_name = aws_db_parameter_group.replica[0].name
  db_subnet_group_name    = aws_db_subnet_group.replica[0].name

  performance_insights_enabled          = var.enable_performance_insights
  performance_insights_kms_key_id       = var.enable_performance_insights ? local.kms_key_id : null
  performance_insights_retention_period = var.enable_performance_insights ? var.performance_insights_retention_days : null

  apply_immediately          = false
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  publicly_accessible        = false

  tags = merge(var.tags, {
    Name = "${var.name}-replica-${count.index}"
    Role = "replica-reader"
  })
}

# ---------------------------------------------------------------------------
# SNS topic for CloudWatch alarms
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  count = var.existing_sns_topic_arn == "" ? 1 : 0

  name              = "${var.name}-aurora-alarms"
  kms_master_key_id = local.kms_key_id

  tags = merge(var.tags, { Name = "${var.name}-aurora-alarms" })
}

resource "aws_sns_topic_subscription" "alarm_email" {
  for_each = var.existing_sns_topic_arn == "" ? toset(var.alarm_emails) : toset([])

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = each.value
}

# ---------------------------------------------------------------------------
# CloudWatch alarms
# ---------------------------------------------------------------------------

# CPU utilization. fired when any instance exceeds 80% for 2 consecutive minutes.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count = var.instance_count

  alarm_name          = "${local.instance_ids[count.index]}-cpu-high"
  alarm_description   = "CPU utilization for ${local.instance_ids[count.index]} exceeds 80%."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    DBInstanceIdentifier = local.instance_ids[count.index]
  }

  alarm_actions = [local.sns_topic_arn]
  ok_actions    = [local.sns_topic_arn]

  treat_missing_data = "breaching"
  tags               = var.tags

  depends_on = [aws_rds_cluster_instance.this]
}

# Freeable memory. fired when any instance drops below 256 MB.
resource "aws_cloudwatch_metric_alarm" "freeable_memory_low" {
  count = var.instance_count

  alarm_name          = "${local.instance_ids[count.index]}-freeable-memory-low"
  alarm_description   = "Freeable memory on ${local.instance_ids[count.index]} is below 256 MB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 268435456 # 256 MB in bytes
  comparison_operator = "LessThanThreshold"

  dimensions = {
    DBInstanceIdentifier = local.instance_ids[count.index]
  }

  alarm_actions = [local.sns_topic_arn]
  ok_actions    = [local.sns_topic_arn]

  treat_missing_data = "breaching"
  tags               = var.tags

  depends_on = [aws_rds_cluster_instance.this]
}

# Free local storage. fired when any instance drops below 10 GB.
resource "aws_cloudwatch_metric_alarm" "free_storage_low" {
  count = var.instance_count

  alarm_name          = "${local.instance_ids[count.index]}-free-storage-low"
  alarm_description   = "Free local storage on ${local.instance_ids[count.index]} is below 10 GB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeLocalStorage"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 10737418240 # 10 GB in bytes
  comparison_operator = "LessThanThreshold"

  dimensions = {
    DBInstanceIdentifier = local.instance_ids[count.index]
  }

  alarm_actions = [local.sns_topic_arn]
  ok_actions    = [local.sns_topic_arn]

  treat_missing_data = "breaching"
  tags               = var.tags

  depends_on = [aws_rds_cluster_instance.this]
}

# Database connections. fired when connections exceed 80% of the instance
# max_connections. We alarm on the raw count at 800 as a sensible baseline;
# tune max_connections via the parameter group to match your instance class.
resource "aws_cloudwatch_metric_alarm" "db_connections_high" {
  count = var.instance_count

  alarm_name          = "${local.instance_ids[count.index]}-db-connections-high"
  alarm_description   = "Database connection count on ${local.instance_ids[count.index]} is high."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 800
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    DBInstanceIdentifier = local.instance_ids[count.index]
  }

  alarm_actions = [local.sns_topic_arn]
  ok_actions    = [local.sns_topic_arn]

  treat_missing_data = "notBreaching"
  tags               = var.tags

  depends_on = [aws_rds_cluster_instance.this]
}

# Replica lag. only meaningful when cross-region replication is enabled.
resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  count = var.enable_cross_region_replica ? var.replica_instance_count : 0

  alarm_name          = "${var.name}-replica-${count.index}-replica-lag"
  alarm_description   = "Aurora replica lag for ${var.name}-replica-${count.index} exceeds 30 seconds."
  namespace           = "AWS/RDS"
  metric_name         = "AuroraGlobalDBReplicationLag"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 30000 # milliseconds
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    DBClusterIdentifier = "${var.name}-replica"
  }

  alarm_actions = [local.sns_topic_arn]
  ok_actions    = [local.sns_topic_arn]

  treat_missing_data = "notBreaching"
  tags               = var.tags

  depends_on = [aws_rds_cluster_instance.replica]
}
