# ---------------------------------------------------------------------------
# locals
# ---------------------------------------------------------------------------

locals {
  # Pull the cluster name out of the ARN for resource naming and policy scoping.
  # ARN format: arn:aws:ecs:region:account:cluster/name
  cluster_name = element(split("/", var.cluster_arn), length(split("/", var.cluster_arn)) - 1)

  # Build the secrets block for the container definition.
  secrets = [
    for env_name, ssm_arn in var.ssm_secrets : {
      name      = env_name
      valueFrom = ssm_arn
    }
  ]

  # Build the environment block for the container definition.
  environment = [
    for k, v in var.environment_variables : {
      name  = k
      value = v
    }
  ]

  # Collect all SSM ARNs so we can grant ssm:GetParameters on each one.
  ssm_arns = values(var.ssm_secrets)

  log_group_name = "/fargate-cron/${var.name}"
}

# ---------------------------------------------------------------------------
# CloudWatch log group
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# IAM: execution role (used by ECS agent to pull image + get secrets)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "execution_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.execution_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# CloudWatch Logs permissions for the execution role (needed for awslogs driver)
data "aws_iam_policy_document" "execution_inline" {
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  dynamic "statement" {
    for_each = length(local.ssm_arns) > 0 ? [1] : []
    content {
      sid    = "SSMGetParameters"
      effect = "Allow"
      actions = [
        "ssm:GetParameters",
        "ssm:GetParameter",
      ]
      resources = local.ssm_arns
    }
  }
}

resource "aws_iam_role_policy" "execution_inline" {
  name   = "${var.name}-execution-inline"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_inline.json
}

resource "aws_iam_role_policy_attachment" "execution_extra" {
  for_each   = toset(var.execution_role_policy_arns)
  role       = aws_iam_role.execution.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# IAM: task role (used by the application running inside the container)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "task_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "task_extra" {
  for_each   = toset(var.task_role_policy_arns)
  role       = aws_iam_role.task.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# IAM: EventBridge role (used by EventBridge to call ecs:RunTask)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "events_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  name               = "${var.name}-events"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "events_inline" {
  statement {
    sid    = "RunECSTask"
    effect = "Allow"
    actions = [
      "ecs:RunTask",
    ]
    # Scope to the task definition family (all revisions of this specific task).
    resources = ["arn:aws:ecs:*:*:task-definition/${var.name}:*"]

    condition {
      test     = "ArnLike"
      variable = "ecs:cluster"
      values   = [var.cluster_arn]
    }
  }

  statement {
    sid    = "PassRoleToTask"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      aws_iam_role.execution.arn,
      aws_iam_role.task.arn,
    ]
  }
}

resource "aws_iam_role_policy" "events_inline" {
  name   = "${var.name}-events-inline"
  role   = aws_iam_role.events.id
  policy = data.aws_iam_policy_document.events_inline.json
}

# ---------------------------------------------------------------------------
# ECS task definition
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  tags                     = var.tags

  container_definitions = jsonencode([
    {
      name    = var.name
      image   = var.container_image
      command = length(var.container_command) > 0 ? var.container_command : null

      environment = local.environment
      secrets     = local.secrets

      essential = true

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "task"
        }
      }
    }
  ])
}

data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Security group (egress-only by default)
# ---------------------------------------------------------------------------

resource "aws_security_group" "task" {
  name        = "${var.name}-fargate-cron"
  description = "Security group for ${var.name} Fargate cron tasks. Egress only."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-fargate-cron" })
}

resource "aws_vpc_security_group_egress_rule" "default" {
  security_group_id = aws_security_group.task.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "additional" {
  for_each = {
    for idx, rule in var.additional_egress_rules :
    "${rule.protocol}-${rule.from_port}-${rule.to_port}-${idx}" => rule
  }

  security_group_id = aws_security_group.task.id
  description       = each.value.description
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  ip_protocol       = each.value.protocol
  cidr_ipv4         = length(each.value.cidr_blocks) > 0 ? each.value.cidr_blocks[0] : null
}

# ---------------------------------------------------------------------------
# EventBridge rule (schedule)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = var.name
  description         = "Trigger ${var.name} Fargate cron task on schedule: ${var.schedule_expression}"
  schedule_expression = var.schedule_expression
  state               = "ENABLED"
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Dead letter queue (optional)
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  count = var.enable_dlq ? 1 : 0

  name                      = "${var.name}-cron-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds
  tags                      = var.tags
}

# Allow EventBridge to send messages to the DLQ.
resource "aws_sqs_queue_policy" "dlq" {
  count     = var.enable_dlq ? 1 : 0
  queue_url = aws_sqs_queue.dlq[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgeDLQ"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.dlq[0].arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.schedule.arn
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# EventBridge target
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_target" "ecs" {
  rule     = aws_cloudwatch_event_rule.schedule.name
  arn      = var.cluster_arn
  role_arn = aws_iam_role.events.arn

  # Retry policy
  retry_policy {
    maximum_retry_attempts       = var.max_retry_attempts
    maximum_event_age_in_seconds = 60
  }

  # Optional DLQ
  dynamic "dead_letter_config" {
    for_each = var.enable_dlq ? [1] : []
    content {
      arn = aws_sqs_queue.dlq[0].arn
    }
  }

  ecs_target {
    task_count          = 1
    task_definition_arn = aws_ecs_task_definition.this.arn
    launch_type         = "FARGATE"
    platform_version    = "LATEST"

    network_configuration {
      subnets          = var.subnet_ids
      security_groups  = [aws_security_group.task.id]
      assign_public_ip = false
    }
  }

  # Task definition ARN includes a revision number that increments on every
  # apply. Ignoring changes here prevents EventBridge from being updated every
  # time the task definition revision bumps, which would be noisy and
  # disruptive. The target always pulls the latest revision at invocation time
  # via the family ARN.
  lifecycle {
    ignore_changes = [ecs_target[0].task_definition_arn]
  }
}

# ---------------------------------------------------------------------------
# CloudWatch alarm: EventBridge FailedInvocations
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "failed_invocations" {
  alarm_name          = "${var.name}-failed-invocations"
  alarm_description   = "EventBridge failed to invoke the ${var.name} ECS task"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "FailedInvocations"
  namespace           = "AWS/Events"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    RuleName = aws_cloudwatch_event_rule.schedule.name
  }

  alarm_actions = var.enable_failure_notifications ? [aws_sns_topic.failure[0].arn] : []

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Failure notifications (optional)
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "failure" {
  count = var.enable_failure_notifications ? 1 : 0
  name  = "${var.name}-task-failure"
  tags  = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each = var.enable_failure_notifications ? toset(var.notification_emails) : toset([])

  topic_arn = aws_sns_topic.failure[0].arn
  protocol  = "email"
  endpoint  = each.value
}

# EventBridge rule that fires when an ECS task in this family stops with a
# non-zero exit code.
resource "aws_cloudwatch_event_rule" "task_failure" {
  count = var.enable_failure_notifications ? 1 : 0

  name        = "${var.name}-task-failure"
  description = "Detect ${var.name} task failures (non-zero exit code)"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      lastStatus    = ["STOPPED"]
      stoppedReason = [{ prefix = "Essential container in task exited" }]
      taskDefinitionArn = [{ prefix = "arn:aws:ecs" }]
      # Filter to tasks from this task definition family.
      group = [{ prefix = "family:${var.name}" }]
      containers = {
        exitCode = [{ anything-but = 0 }]
      }
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "task_failure_sns" {
  count = var.enable_failure_notifications ? 1 : 0

  rule = aws_cloudwatch_event_rule.task_failure[0].name
  arn  = aws_sns_topic.failure[0].arn

  input_transformer {
    input_paths = {
      task_arn       = "$.detail.taskArn"
      stopped_reason = "$.detail.stoppedReason"
      cluster        = "$.detail.clusterArn"
    }
    input_template = <<-EOT
      "ECS task FAILED: ${var.name}"
      "Task ARN: <task_arn>"
      "Cluster: <cluster>"
      "Reason: <stopped_reason>"
    EOT
  }
}

# Allow EventBridge to publish to the SNS topic.
resource "aws_sns_topic_policy" "failure" {
  count = var.enable_failure_notifications ? 1 : 0
  arn   = aws_sns_topic.failure[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.failure[0].arn
      }
    ]
  })
}
