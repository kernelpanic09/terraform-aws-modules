locals {
  # Merge module-managed tags with caller-provided tags.
  # Caller tags take precedence so callers can override module defaults.
  base_tags = merge(
    {
      "module"    = "github-runner-fleet"
      "ManagedBy" = "terraform"
    },
    var.tags
  )

  # Build the comma-separated label string sent to the runner container.
  # Always include self-hosted and linux; append caller-provided extras.
  runner_labels_str = join(",", concat(["self-hosted", "linux"], var.runner_labels))

  # Determine the runner registration scope and target URL.
  # When repos is non-empty, register against the first repo listed.
  # For multi-repo isolation, instantiate this module once per repo.
  runner_scope = length(var.repos) == 0 ? "org" : "repo"
  repo_url = (
    length(var.repos) == 0
    ? "https://github.com/${var.organization}"
    : "https://github.com/${var.organization}/${var.repos[0]}"
  )
}

# ---------------------------------------------------------------------------
# Lambda source archive - references the Python file shipped with the module
# ---------------------------------------------------------------------------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/webhook_handler.py"
  output_path = "${path.module}/.build/webhook_handler.zip"
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "runners" {
  name              = "/ecs/${var.name}-runner"
  retention_in_days = var.log_retention_days
  tags              = local.base_tags
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}-webhook"
  retention_in_days = var.log_retention_days
  tags              = local.base_tags
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${var.name}-webhook"
  retention_in_days = var.log_retention_days
  tags              = local.base_tags
}

# ---------------------------------------------------------------------------
# SQS Dead-Letter Queue (optional)
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  count = var.enable_dlq ? 1 : 0

  name                      = "${var.name}-webhook-dlq"
  message_retention_seconds = 1209600 # 14 days
  tags                      = local.base_tags
}

resource "aws_sqs_queue_policy" "dlq" {
  count     = var.enable_dlq ? 1 : 0
  queue_url = aws_sqs_queue.dlq[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowLambdaSend"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.dlq[0].arn
        Condition = {
          ArnLike = { "aws:SourceArn" = aws_lambda_function.webhook.arn }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# IAM: Lambda execution role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-webhook-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.base_tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_permissions" {
  # Allow Lambda to read the webhook HMAC secret for signature verification
  statement {
    sid     = "ReadWebhookSecret"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      var.webhook_secret_arn,
    ]
  }

  # Allow Lambda to read the current desired_count and scale the ECS service
  statement {
    sid    = "ECSScaling"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = [
      "arn:aws:ecs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:service/${var.name}-runners/${var.name}-runners",
    ]
  }

  # Allow Lambda to send failed events to the DLQ when enabled
  dynamic "statement" {
    for_each = var.enable_dlq ? [1] : []
    content {
      sid       = "SendToDLQ"
      effect    = "Allow"
      actions   = ["sqs:SendMessage"]
      resources = [aws_sqs_queue.dlq[0].arn]
    }
  }
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "${var.name}-webhook-lambda-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

# ---------------------------------------------------------------------------
# IAM: ECS task execution role (pulls image, writes logs, reads secrets)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.name}-runner-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
  tags               = local.base_tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ecs_task_execution_secrets" {
  statement {
    sid     = "ReadRunnerSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      var.github_pat_secret_arn,
    ]
  }
}

resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  name   = "${var.name}-runner-secrets"
  role   = aws_iam_role.ecs_task_execution.id
  policy = data.aws_iam_policy_document.ecs_task_execution_secrets.json
}

# ECS task role - the identity assumed by the running container itself.
# Callers attach additional policies to this role to grant runners AWS access.
resource "aws_iam_role" "ecs_task" {
  name               = "${var.name}-runner-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
  tags               = local.base_tags
}

# ---------------------------------------------------------------------------
# Security Group: runner tasks (egress only - no inbound rules)
# ---------------------------------------------------------------------------

resource "aws_security_group" "runners" {
  name        = "${var.name}-runner-sg"
  description = "Egress-only security group for ${var.name} GitHub Actions runner ECS tasks"
  vpc_id      = var.vpc_id
  tags        = merge(local.base_tags, { Name = "${var.name}-runner-sg" })

  egress {
    description = "Allow all outbound traffic (runners reach GitHub API and package registries)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# ECS Cluster with Fargate and Fargate Spot capacity providers
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "runners" {
  name = "${var.name}-runners"
  tags = local.base_tags

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "runners" {
  cluster_name = aws_ecs_cluster.runners.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = var.fargate_spot_weight
    base              = 0
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = var.fargate_ondemand_weight
    # base ensures min_runners tasks always start On-Demand for stability
    base = var.min_runners
  }
}

# ---------------------------------------------------------------------------
# ECS Task Definition
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "runner" {
  family                   = "${var.name}-runner"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.runner_cpu
  memory                   = var.runner_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn
  tags                     = local.base_tags

  container_definitions = jsonencode([
    {
      name      = "runner"
      image     = var.runner_image
      essential = true

      environment = [
        { name = "RUNNER_SCOPE",        value = local.runner_scope },
        { name = "ORG_NAME",            value = var.organization },
        { name = "REPO_URL",            value = local.repo_url },
        { name = "RUNNER_LABELS",       value = local.runner_labels_str },
        { name = "RUNNER_GROUP",        value = var.runner_group },
        { name = "EPHEMERAL",           value = "1" },
        { name = "DISABLE_AUTO_UPDATE", value = "1" },
      ]

      # The GitHub PAT is injected via Secrets Manager - never stored in env vars
      secrets = [
        {
          name      = "ACCESS_TOKEN"
          valueFrom = var.github_pat_secret_arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.runners.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "runner"
        }
      }

      # Health check: verify the runner listener process is running.
      # startPeriod allows time for runner registration with GitHub.
      healthCheck = {
        command     = ["CMD-SHELL", "pgrep -f 'Runner.Listener' || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])
}

# ---------------------------------------------------------------------------
# ECS Service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "runners" {
  name            = "${var.name}-runners"
  cluster         = aws_ecs_cluster.runners.id
  task_definition = aws_ecs_task_definition.runner.arn
  desired_count   = var.min_runners

  # launch_type must be omitted when using capacity_provider_strategy
  launch_type             = null
  scheduling_strategy     = "REPLICA"
  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true
  tags                    = local.base_tags

  # Allow ECS to launch replacement tasks before draining old ones (scale-up).
  # Allow draining to 0 during scale-down (no minimum during low load).
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 0

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = var.fargate_spot_weight
    base              = 0
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = var.fargate_ondemand_weight
    base              = var.min_runners
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.runners.id]
    assign_public_ip = false
  }

  # Prevent Terraform from overwriting Lambda-driven scaling of desired_count
  # on subsequent plan/apply runs.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.runners,
    aws_iam_role_policy_attachment.ecs_task_execution_managed,
    aws_iam_role_policy.ecs_task_execution_secrets,
  ]
}

# ---------------------------------------------------------------------------
# Lambda Function
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "webhook" {
  function_name    = "${var.name}-webhook"
  description      = "Processes GitHub workflow_job webhooks and scales the ${var.name} ECS runner fleet"
  role             = aws_iam_role.lambda.arn
  handler          = "webhook_handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30
  memory_size      = 256
  tags             = local.base_tags

  environment {
    variables = {
      ECS_CLUSTER        = aws_ecs_cluster.runners.name
      ECS_SERVICE        = "${var.name}-runners"
      MAX_RUNNERS        = tostring(var.max_runners)
      MIN_RUNNERS        = tostring(var.min_runners)
      WEBHOOK_SECRET_ARN = var.webhook_secret_arn
    }
  }

  dynamic "dead_letter_config" {
    for_each = var.enable_dlq ? [1] : []
    content {
      target_arn = aws_sqs_queue.dlq[0].arn
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.lambda_permissions,
  ]
}

# Allow API Gateway to invoke the webhook Lambda
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.webhook.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# API Gateway HTTP API (v2)
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "webhook" {
  name          = "${var.name}-webhook"
  description   = "GitHub webhook receiver for the ${var.name} runner fleet"
  protocol_type = "HTTP"
  tags          = local.base_tags
}

resource "aws_apigatewayv2_stage" "webhook" {
  api_id      = aws_apigatewayv2_api.webhook.id
  name        = "$default"
  auto_deploy = true
  tags        = local.base_tags

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      errorMessage   = "$context.error.message"
    })
  }
}

resource "aws_apigatewayv2_integration" "webhook" {
  api_id                 = aws_apigatewayv2_api.webhook.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.webhook.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

resource "aws_apigatewayv2_route" "webhook_post" {
  api_id    = aws_apigatewayv2_api.webhook.id
  route_key = "POST /webhook"
  target    = "integrations/${aws_apigatewayv2_integration.webhook.id}"
}

# ---------------------------------------------------------------------------
# EventBridge: capture ECS task state changes for observability
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "runner_stopped" {
  name        = "${var.name}-runner-stopped"
  description = "Fires when a ${var.name} runner ECS task reaches STOPPED state"
  tags        = local.base_tags

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.runners.arn]
      lastStatus = ["STOPPED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "runner_stopped_log" {
  rule      = aws_cloudwatch_event_rule.runner_stopped.name
  target_id = "LogRunnerStopped"
  arn       = aws_cloudwatch_log_group.runners.arn
}

# Grant EventBridge permission to write to the runners CloudWatch Log Group
resource "aws_cloudwatch_log_resource_policy" "eventbridge_to_cw" {
  policy_name = "${var.name}-eb-cw-policy"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "delivery.logs.amazonaws.com"] }
        Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource  = "${aws_cloudwatch_log_group.runners.arn}:*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
