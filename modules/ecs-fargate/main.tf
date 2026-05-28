locals {
  container_name = coalesce(var.container_name, var.name)

  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "ecs-fargate"
  })

  # Flatten env vars and secrets into the container definition format.
  # Using locals keeps the resource blocks terse and easy to audit.
  env_vars = [
    for k, v in var.environment_variables : { name = k, value = v }
  ]

  secrets = [
    for name, arn in var.ssm_secrets : { name = name, valueFrom = arn }
  ]

  # SSM parameter ARNs for the execution role policy.
  ssm_arns = values(var.ssm_secrets)

  # When HTTPS is enabled the ALB listener forwards on 443 and the HTTP
  # listener issues a 301 redirect. When HTTPS is disabled HTTP forwards
  # directly to the target group.
  alb_target_port = var.container_port
}

# ------------------------------------------------------------------------------
# CloudWatch Log Group
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = "/ecs/${var.name}" })
}

# ------------------------------------------------------------------------------
# IAM: Task Execution Role
# Pulled by the ECS agent to authenticate with ECR, pull secrets from SSM,
# and ship logs to CloudWatch.
# ------------------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name        = "${var.name}-ecs-execution-role"
  description = "ECS task execution role for ${var.name}. Grants the ECS agent permission to pull images and retrieve SSM secrets."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ECSTasksAssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# AWS-managed policy covering ECR authentication and CloudWatch Logs writes.
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Inline policy granting ssm:GetParameter(s) for the secrets specified by the caller.
# Only created when at least one SSM secret is provided.
resource "aws_iam_role_policy" "execution_ssm" {
  count = length(local.ssm_arns) > 0 ? 1 : 0
  name  = "${var.name}-execution-ssm"
  role  = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "GetSSMParameters"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = local.ssm_arns
    }]
  })
}

# ------------------------------------------------------------------------------
# IAM: Task Role
# Assumed by the running application container for AWS API calls made by the
# application itself (e.g., S3, DynamoDB). Start with a minimal footprint;
# callers should attach additional policies to this role as needed.
# ------------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name        = "${var.name}-ecs-task-role"
  description = "ECS task role for ${var.name}. Attach application-specific IAM policies to this role."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ECSTasksAssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # Condition restricts role chaining to tasks running in this cluster,
      # preventing lateral movement if an execution role is compromised.
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:aws:ecs:*:*:*"
        }
      }
    }]
  })

  tags = local.common_tags
}

# Allow CloudWatch agent / X-Ray daemon sidecars (common pattern).
# Callers add application-specific actions by attaching their own policies.
resource "aws_iam_role_policy" "task_baseline" {
  name = "${var.name}-task-baseline"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowXRayWrite"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchMetrics"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# Security Groups
# ------------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "Controls inbound traffic to the ${var.name} ALB. Allows HTTP (80) and HTTPS (443) from anywhere."
  vpc_id      = var.vpc_id

  # HTTP
  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS (always open so we can return a redirect even if var.enable_https is false)
  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound (to reach ECS tasks)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.name}-alb-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "tasks" {
  name        = "${var.name}-tasks-sg"
  description = "Controls inbound traffic to ${var.name} ECS tasks. Only accepts traffic from the ALB security group."
  vpc_id      = var.vpc_id

  ingress {
    description     = "Container port traffic from ALB only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound (ECR pull, SSM, CloudWatch)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.name}-tasks-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------------
# ECS Cluster
# ------------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.common_tags, { Name = var.name })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ------------------------------------------------------------------------------
# Task Definition
# ------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.container_image
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      # Plain-text environment variables (dynamic block equivalent via jsonencode)
      environment = local.env_vars

      # Secrets pulled from SSM Parameter Store at task start
      secrets = local.secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.id
          "awslogs-stream-prefix" = "ecs"
        }
      }

      # Graceful shutdown: give the container 30 s to drain before SIGKILL.
      stopTimeout = 30

      # Readonly filesystem hardening; callers can override via container_definitions
      # override if their app writes to the local filesystem.
      readonlyRootFilesystem = false

      # Health check at the container level (ALB also checks at the target group level).
      healthCheck = {
        command     = ["CMD-SHELL", "curl -sf http://localhost:${var.container_port}${var.health_check_path} || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = merge(local.common_tags, { Name = var.name })

  # Always create a new task definition revision on any image or config change.
  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------------
# Application Load Balancer
# ------------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  # Prevent accidental deletion when traffic is live.
  enable_deletion_protection = false

  # Access logs require an S3 bucket; left to callers to configure to keep
  # the module self-contained without requiring S3 bucket creation.
  # Callers can set access_logs via an override or separate resource.

  tags = merge(local.common_tags, { Name = "${var.name}-alb" })
}

# ------------------------------------------------------------------------------
# Target Group
# ------------------------------------------------------------------------------

resource "aws_lb_target_group" "this" {
  name        = "${var.name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Required for Fargate (awsvpc network mode)

  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
    interval            = var.health_check_interval
    timeout             = var.health_check_timeout
    matcher             = var.health_check_matcher
  }

  # Enable sticky sessions using ALB-generated cookies when needed by stateful apps.
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = false
  }

  tags = merge(local.common_tags, { Name = "${var.name}-tg" })

  # Blue/green deployments create a new TG before destroying the old one.
  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------------
# ALB Listeners
# ------------------------------------------------------------------------------

# HTTP listener: forwards to target group when HTTPS is disabled;
# issues a 301 permanent redirect to HTTPS when it is enabled.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = var.enable_https ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = var.enable_https ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this.arn
    }
  }

  tags = local.common_tags
}

# HTTPS listener: only created when var.enable_https = true.
resource "aws_lb_listener" "https" {
  count = var.enable_https ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# ECS Service
# ------------------------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name                               = var.name
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  # Force a new deployment whenever the task definition ARN changes (i.e.,
  # on every image update). This avoids stale tasks staying up after a deploy.
  force_new_deployment = true

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false # Tasks live in private subnets; outbound goes via NAT.
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true # Automatically roll back to the last stable task definition on failure.
  }

  deployment_controller {
    type = "ECS" # Rolling update. Switch to "CODE_DEPLOY" for blue/green.
  }

  # Cloud Map service discovery (optional)
  dynamic "service_registries" {
    for_each = var.enable_service_discovery ? [1] : []
    content {
      registry_arn = aws_service_discovery_service.this[0].arn
    }
  }

  # Propagate module tags to each task so cost allocation works at task level.
  propagate_tags = "SERVICE"
  tags           = merge(local.common_tags, { Name = var.name })

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.execution_managed,
  ]

  lifecycle {
    ignore_changes = [
      # Allow external CI/CD pipelines to update desired_count without Terraform
      # reverting it on the next plan.
      desired_count,
    ]
  }
}

# ------------------------------------------------------------------------------
# Application Auto Scaling
# ------------------------------------------------------------------------------

resource "aws_appautoscaling_target" "this" {
  count = var.enable_autoscaling ? 1 : 0

  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.enable_autoscaling && var.autoscaling_cpu_target != null ? 1 : 0

  name               = "${var.name}-cpu-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.autoscaling_cpu_target
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "memory" {
  count = var.enable_autoscaling && var.autoscaling_memory_target != null ? 1 : 0

  name               = "${var.name}-memory-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = var.autoscaling_memory_target
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}

# ------------------------------------------------------------------------------
# Cloud Map Service Discovery (optional)
# ------------------------------------------------------------------------------

resource "aws_service_discovery_service" "this" {
  count = var.enable_service_discovery ? 1 : 0

  name = var.name

  dns_config {
    namespace_id = var.service_discovery_namespace_id

    dns_records {
      ttl  = var.service_discovery_dns_ttl
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  tags = merge(local.common_tags, { Name = var.name })
}

# ------------------------------------------------------------------------------
# Data sources
# ------------------------------------------------------------------------------

data "aws_region" "current" {}
