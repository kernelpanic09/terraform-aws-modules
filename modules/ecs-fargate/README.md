# terraform-aws-ecs-fargate

Terraform module for a complete ECS Fargate service behind an Application Load Balancer. Every resource is tagged, security-hardened, and structured for day-2 operations.

## Architecture

```
Internet
   |
   v
[ALB] (public subnets, ports 80/443)
   |  Security group: allows 0.0.0.0/0 on 80 and 443
   v
[Target Group] (target type: ip, health check on /health)
   |
   v
[ECS Service] (private subnets, awsvpc)
   |  Security group: allows container_port from ALB SG only
   |
   +-- [ECS Task] x desired_count
         |
         +-- [Container] (Fargate, awslogs driver -> CloudWatch Logs)
```

Optional add-ons:
- HTTPS listener with ACM certificate and HTTP-to-HTTPS redirect.
- Application Auto Scaling with target tracking on CPU and/or memory.
- AWS Cloud Map service discovery for VPC-internal DNS resolution.

## Features

- ECS cluster with Container Insights enabled.
- Fargate task definition with configurable CPU, memory, container image, port, plain-text environment variables, and SSM Parameter Store secrets.
- ECS service with desired count, deployment circuit breaker with automatic rollback, and rolling update configuration.
- ALB with HTTP and HTTPS listeners.
- ALB target group with fully configurable health check.
- Security groups: ALB accepts 80/443 from the internet; tasks accept the container port from the ALB only.
- CloudWatch Log Group with configurable retention.
- IAM task execution role (ECR, SSM, CloudWatch) and task role (application permissions, X-Ray, CloudWatch metrics).
- Application Auto Scaling with target tracking on CPU and/or memory (optional, via `enable_autoscaling`).
- Cloud Map service discovery (optional, via `enable_service_discovery`).

## Usage

```hcl
module "ecs" {
  source = "../../modules/ecs-fargate"

  name              = "api"
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.private_subnet_ids
  public_subnet_ids = module.vpc.public_subnet_ids

  container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/api:1.0.0"
  container_port  = 8080
  cpu             = 512
  memory          = 1024

  desired_count = 2

  environment_variables = {
    APP_ENV = "production"
    LOG_LEVEL = "info"
  }

  ssm_secrets = {
    DATABASE_URL = "arn:aws:ssm:us-east-1:123456789012:parameter/api/prod/database_url"
    API_KEY      = "arn:aws:ssm:us-east-1:123456789012:parameter/api/prod/api_key"
  }

  health_check_path = "/health"

  enable_https    = true
  certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abc-123"

  enable_autoscaling        = true
  min_count                 = 2
  max_count                 = 20
  autoscaling_cpu_target    = 70
  autoscaling_memory_target = 80

  tags = {
    Environment = "production"
    Team        = "platform"
  }
}
```

## Secrets Management

Secrets should be stored in AWS Systems Manager Parameter Store as `SecureString` parameters and referenced via `ssm_secrets`:

```hcl
ssm_secrets = {
  DATABASE_URL = "arn:aws:ssm:us-east-1:123456789012:parameter/api/prod/database_url"
}
```

The module automatically grants the task execution role `ssm:GetParameter` and `ssm:GetParameters` for each ARN listed. The values are injected as environment variables before the container starts and are never visible in the task definition JSON.

## Auto Scaling

When `enable_autoscaling = true` the module creates an Application Auto Scaling target and up to two target tracking policies.

| Variable | Default | Purpose |
|---|---|---|
| `min_count` | 2 | Floor for the scaler |
| `max_count` | 10 | Ceiling for the scaler |
| `autoscaling_cpu_target` | 70 | CPU % target. Set to `null` to disable. |
| `autoscaling_memory_target` | null | Memory % target. Set a value to enable. |
| `scale_in_cooldown` | 300 | Seconds to wait after a scale-in before the next one. |
| `scale_out_cooldown` | 60 | Seconds to wait after a scale-out before the next one. |

## HTTPS

Set `enable_https = true` and provide a valid `certificate_arn` (ACM). The module:

1. Adds an HTTPS listener on port 443 with the supplied certificate.
2. Converts the HTTP listener to issue a `301` redirect to HTTPS.

The `ssl_policy` variable defaults to `ELBSecurityPolicy-TLS13-1-2-2021-06`, which supports TLS 1.3 and 1.2 only (drops 1.0 and 1.1).

## Service Discovery

When `enable_service_discovery = true`, the ECS service is registered in an existing Cloud Map private DNS namespace. Callers must create the namespace separately and pass its ID via `service_discovery_namespace_id`. Once registered, other services in the VPC can reach this service at `<name>.<namespace-dns-name>`.

## IAM

The module creates two IAM roles.

**Execution role** (`<name>-ecs-execution-role`): used by the ECS agent (not the container). Receives `AmazonECSTaskExecutionRolePolicy` plus an inline policy for any SSM parameters listed in `ssm_secrets`.

**Task role** (`<name>-ecs-task-role`): assumed by the running container for AWS API calls. Starts with X-Ray write access and CloudWatch `PutMetricData`. Attach additional managed or inline policies to this role for application-specific AWS access.

```hcl
resource "aws_iam_role_policy_attachment" "app_s3" {
  role       = module.ecs.task_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Name prefix for all resources. |
| `vpc_id` | string | required | VPC ID. |
| `subnet_ids` | list(string) | required | Private subnet IDs for ECS tasks. |
| `public_subnet_ids` | list(string) | required | Public subnet IDs for the ALB (min 2). |
| `container_image` | string | required | Container image URI with tag. |
| `container_port` | number | 8080 | Port the container listens on. |
| `container_name` | string | null | Container name in the task definition. Defaults to `name`. |
| `cpu` | number | 512 | Fargate task CPU units. |
| `memory` | number | 1024 | Fargate task memory in MiB. |
| `environment_variables` | map(string) | {} | Plain-text env vars. |
| `ssm_secrets` | map(string) | {} | Map of env var name to SSM parameter ARN. |
| `desired_count` | number | 2 | Initial task count. |
| `deployment_minimum_healthy_percent` | number | 100 | Rolling deploy lower bound (%). |
| `deployment_maximum_percent` | number | 200 | Rolling deploy upper bound (%). |
| `health_check_path` | string | /health | ALB health check HTTP path. |
| `health_check_healthy_threshold` | number | 2 | Consecutive successes to mark healthy. |
| `health_check_unhealthy_threshold` | number | 3 | Consecutive failures to mark unhealthy. |
| `health_check_interval` | number | 30 | Seconds between health checks. |
| `health_check_timeout` | number | 5 | Seconds before health check request times out. |
| `health_check_matcher` | string | 200 | HTTP status codes that count as healthy. |
| `deregistration_delay` | number | 30 | Seconds before ALB stops sending traffic to deregistering targets. |
| `enable_https` | bool | false | Enable HTTPS listener and HTTP redirect. |
| `certificate_arn` | string | "" | ACM certificate ARN for HTTPS. |
| `ssl_policy` | string | ELBSecurityPolicy-TLS13-1-2-2021-06 | ALB SSL/TLS policy. |
| `enable_autoscaling` | bool | false | Enable Application Auto Scaling. |
| `min_count` | number | 2 | Autoscaling minimum task count. |
| `max_count` | number | 10 | Autoscaling maximum task count. |
| `autoscaling_cpu_target` | number | 70 | CPU utilization target %. Null to disable. |
| `autoscaling_memory_target` | number | null | Memory utilization target %. Null to disable. |
| `scale_in_cooldown` | number | 300 | Scale-in cooldown seconds. |
| `scale_out_cooldown` | number | 60 | Scale-out cooldown seconds. |
| `enable_service_discovery` | bool | false | Register in Cloud Map. |
| `service_discovery_namespace_id` | string | "" | Cloud Map namespace ID. |
| `service_discovery_dns_ttl` | number | 10 | Cloud Map DNS record TTL. |
| `log_retention_days` | number | 30 | CloudWatch Logs retention in days. |
| `tags` | map(string) | {} | Additional tags merged onto all resources. |

## Outputs

| Name | Description |
|---|---|
| `cluster_id` | ECS cluster ID. |
| `cluster_arn` | ECS cluster ARN. |
| `cluster_name` | ECS cluster name. |
| `service_id` | ECS service ARN. |
| `service_name` | ECS service name. |
| `task_definition_arn` | Active task definition ARN. |
| `task_definition_family` | Task definition family name. |
| `task_definition_revision` | Task definition revision number. |
| `execution_role_arn` | Task execution IAM role ARN. |
| `execution_role_name` | Task execution IAM role name. |
| `task_role_arn` | Task IAM role ARN. |
| `task_role_name` | Task IAM role name. |
| `alb_security_group_id` | ALB security group ID. |
| `tasks_security_group_id` | ECS tasks security group ID. |
| `alb_arn` | ALB ARN. |
| `alb_dns_name` | ALB DNS name (CNAME target). |
| `alb_zone_id` | ALB Route53 hosted zone ID (alias target). |
| `target_group_arn` | Target group ARN. |
| `http_listener_arn` | HTTP listener ARN. |
| `https_listener_arn` | HTTPS listener ARN. Empty string when disabled. |
| `log_group_name` | CloudWatch Log Group name. |
| `log_group_arn` | CloudWatch Log Group ARN. |
| `autoscaling_target_resource_id` | Auto Scaling resource ID. Empty string when disabled. |
| `service_discovery_service_arn` | Cloud Map service ARN. Empty string when disabled. |

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.5 |
| aws | >= 5.0 |
