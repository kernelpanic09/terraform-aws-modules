# fargate-cron

Run containerized cron jobs on Fargate without keeping a service alive 24/7. This module wires together an ECS task definition, EventBridge schedule rule, IAM roles, and CloudWatch logging so you can go from "I need to run this container nightly" to working infrastructure in about 20 lines of Terraform.

The regular `ecs-fargate` module assumes you have a long-running service. This module is for the opposite case: a task that wakes up, does its thing, and exits.

## How it works

EventBridge fires on your cron schedule and calls `ecs:RunTask` via a dedicated IAM role. The task runs on Fargate (no EC2 to manage), writes logs to CloudWatch, and exits. If it fails, you can get an email notification and inspect the DLQ to see whether EventBridge even got the invocation off.

```
EventBridge rule
  |
  v (ecs:RunTask via events IAM role)
ECS cluster (existing, you provide the ARN)
  |
  v
Fargate task (your container, awsvpc networking)
  |
  v
CloudWatch Logs (/fargate-cron/<name>)
```

## Usage

```hcl
module "nightly_backup" {
  source = "path/to/module"

  name        = "nightly-db-backup"
  cluster_arn = data.aws_ecs_cluster.shared.arn

  container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/backup:latest"
  cpu             = 512
  memory          = 1024

  ssm_secrets = {
    DATABASE_URL = "arn:aws:ssm:us-east-1:123456789012:parameter/myapp/db-url"
  }

  schedule_expression = "cron(0 2 * * ? *)"  # 2am UTC daily

  vpc_id     = data.aws_vpc.main.id
  subnet_ids = data.aws_subnets.private.ids

  enable_failure_notifications = true
  notification_emails          = ["oncall@example.com"]

  log_retention_days = 30
}
```

See the `../example/` directory for a full working example.

## Cluster

This module does NOT create an ECS cluster. Pass in `cluster_arn` for an existing one. Reusing the cluster from your `ecs-fargate` module is fine, or you can create a dedicated cluster for cron jobs. Either way, there's no cost for an empty ECS cluster, so the choice is mostly about organization.

## Networking

Tasks run in `awsvpc` mode with public IP disabled. Pass private subnets that have outbound internet access via a NAT gateway if your container needs to reach the internet or AWS endpoints. The security group is egress-only by default. Inbound traffic isn't needed since cron tasks don't receive connections.

## Secrets

Use `ssm_secrets` to inject sensitive values. ECS fetches them at task launch time using the execution role, so they never show up in the task definition or log output. The execution role gets `ssm:GetParameters` scoped to the exact ARNs you provide.

```hcl
ssm_secrets = {
  DATABASE_URL = "arn:aws:ssm:us-east-1:123456789012:parameter/myapp/prod/db-url"
  API_KEY      = "arn:aws:ssm:us-east-1:123456789012:parameter/myapp/prod/api-key"
}
```

## IAM

Three IAM roles are created:

| Role | Purpose |
|------|---------|
| `<name>-execution` | ECS agent pulls the image, fetches SSM secrets, writes to CloudWatch |
| `<name>-task` | Your container code. Attach policies via `task_role_policy_arns` |
| `<name>-events` | EventBridge calls `ecs:RunTask` and passes the other two roles |

The events role policy scopes `ecs:RunTask` to the task definition family (all revisions, but only this task). It also has `iam:PassRole` for the execution and task roles. This follows least-privilege: EventBridge can only run this specific task on the cluster you specified.

## Schedule format

EventBridge uses a 6-field cron format that's slightly different from standard cron. Notably, you can't specify both day-of-month and day-of-week; use `?` for the one you don't want.

```
cron(minute hour day-of-month month day-of-week year)

cron(0 2 * * ? *)       - 2am UTC every day
cron(0 9 ? * MON-FRI *) - 9am UTC every weekday
cron(0 4 1 * ? *)       - 4am UTC on the 1st of every month
cron(30 18 ? * FRI *)   - 6:30pm UTC every Friday
rate(1 hour)            - every hour
rate(7 days)            - every 7 days
```

All times in cron expressions are UTC. The `schedule_timezone` variable is stored for documentation purposes but EventBridge classic rules always use UTC. If you need timezone-aware scheduling, use EventBridge Scheduler (a separate AWS service) instead.

## Task definition revisions

Every `terraform apply` that changes the container image or any other task definition attribute creates a new revision. The EventBridge target uses `lifecycle { ignore_changes = [ecs_target[0].task_definition_arn] }` so the target isn't updated on every apply. EventBridge will still run whatever revision it last saw. To force EventBridge to pick up a new revision, taint the target or update it manually.

If you want EventBridge to always run the latest revision, you can remove the `ignore_changes` block, but be aware that will cause the EventBridge target to be replaced on every apply that bumps the task definition.

## Failure notifications

When `enable_failure_notifications = true`, the module creates:

1. An SNS topic with email subscriptions for each address in `notification_emails`.
2. An EventBridge rule that matches ECS task state change events for tasks in this family that stop with a non-zero exit code.
3. The CloudWatch alarm on `FailedInvocations` also routes to the SNS topic.

This covers two failure modes:
- EventBridge couldn't invoke the task at all (FailedInvocations alarm).
- The task ran but the container exited non-zero (task state change rule).

Note: SNS email subscriptions require confirmation. Each email address will get a confirmation email when the subscription is created. The subscription won't deliver notifications until it's confirmed.

## Dead letter queue

When `enable_dlq = true`, an SQS queue is created and attached to the EventBridge target. If EventBridge can't invoke the task after exhausting retries, the event lands in the DLQ. This is different from task failures - the DLQ captures cases where EventBridge couldn't even start the task (e.g., ECS is temporarily unavailable, the cluster doesn't exist, IAM permissions issue).

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| aws | >= 5.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| name | Name prefix for all resources | `string` | | yes |
| cluster_arn | ARN of an existing ECS cluster | `string` | | yes |
| container_image | Docker image to run | `string` | | yes |
| container_command | Command override (list) | `list(string)` | `[]` | no |
| cpu | CPU units (valid Fargate values) | `number` | `256` | no |
| memory | Memory in MiB | `number` | `512` | no |
| environment_variables | Plain-text env vars | `map(string)` | `{}` | no |
| ssm_secrets | Map of env var name to SSM ARN | `map(string)` | `{}` | no |
| schedule_expression | cron(...) or rate(...) | `string` | | yes |
| schedule_timezone | IANA timezone (documentation only for classic rules) | `string` | `"UTC"` | no |
| max_retry_attempts | EventBridge retry count (0-185) | `number` | `0` | no |
| vpc_id | VPC ID for the security group | `string` | | yes |
| subnet_ids | Subnet IDs for task networking | `list(string)` | | yes |
| additional_egress_rules | Extra egress SG rules | `list(object)` | `[]` | no |
| task_role_policy_arns | Policy ARNs attached to the task role | `list(string)` | `[]` | no |
| execution_role_policy_arns | Extra policy ARNs for the execution role | `list(string)` | `[]` | no |
| log_retention_days | CloudWatch log retention | `number` | `30` | no |
| enable_dlq | Create an SQS DLQ | `bool` | `false` | no |
| dlq_message_retention_seconds | DLQ message retention | `number` | `604800` | no |
| enable_failure_notifications | Create SNS failure alerts | `bool` | `false` | no |
| notification_emails | Email addresses for failure alerts | `list(string)` | `[]` | no |
| tags | Tags for all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| task_definition_arn | Full task definition ARN including revision |
| task_definition_family | Task definition family name |
| task_role_arn | Task IAM role ARN |
| task_role_name | Task IAM role name |
| execution_role_arn | Execution IAM role ARN |
| execution_role_name | Execution IAM role name |
| events_role_arn | EventBridge IAM role ARN |
| security_group_id | Task security group ID |
| event_rule_arn | EventBridge schedule rule ARN |
| event_rule_name | EventBridge schedule rule name |
| log_group_name | CloudWatch log group name |
| log_group_arn | CloudWatch log group ARN |
| dlq_url | SQS DLQ URL (empty if DLQ disabled) |
| dlq_arn | SQS DLQ ARN (empty if DLQ disabled) |
| failure_sns_topic_arn | Failure SNS topic ARN (empty if notifications disabled) |
| failed_invocations_alarm_arn | CloudWatch alarm ARN |
