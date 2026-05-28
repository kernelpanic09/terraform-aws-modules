# github-runner-fleet

Terraform module for an ephemeral, auto-scaling GitHub Actions self-hosted runner fleet on AWS ECS Fargate.

Runners are ephemeral: each container registers with GitHub, executes exactly one job, then exits. The ECS service scales up on `workflow_job` webhook events and scales back to zero (or to `min_runners`) as tasks complete naturally.

---

## Architecture

```
GitHub Org/Repo
       |
       | workflow_job webhook (HMAC-signed)
       v
API Gateway HTTP API  (POST /webhook)
       |
       v
Lambda (Python 3.12)
  - Verifies HMAC-SHA256 signature
  - Parses workflow_job action
  - On "queued": increments ECS desired_count (up to max_runners)
       |
       v
ECS Service (Fargate Spot 70% / On-Demand 30%)
  - Runner tasks register with GitHub
  - Execute one job each (EPHEMERAL=1)
  - Exit when job completes
  - ECS replaces tasks to maintain desired_count

Failed webhooks -> SQS Dead-Letter Queue (optional)
ECS task stop events -> EventBridge -> CloudWatch Logs
```

### Scaling model

**Scale-up:** Every `workflow_job queued` event causes the Lambda to increment `desired_count` by 1 (capped at `max_runners`). ECS starts a new Fargate task which self-registers as a runner, picks up the queued job, and exits.

**Scale-down:** Because runners exit after one job (`EPHEMERAL=1`), ECS task count naturally falls. No explicit scale-down logic is needed. The service settles at `min_runners` when the queue is empty.

---

## Prerequisites

1. A GitHub Personal Access Token stored in Secrets Manager:
   - Org-level runners: `admin:org` scope
   - Repo-level runners: `repo` scope
2. A random webhook secret string stored in a separate Secrets Manager secret.
3. A VPC with private subnets that have internet access via NAT Gateway.

---

## Usage

### Minimal (org-level runners)

```hcl
module "runner_fleet" {
  source = "path/to/module"

  name         = "my-runners"
  organization = "my-github-org"

  github_pat_secret_arn = aws_secretsmanager_secret.pat.arn
  webhook_secret_arn    = aws_secretsmanager_secret.webhook.arn

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
}
```

### With custom labels and scaling limits

```hcl
module "runner_fleet" {
  source = "path/to/module"

  name         = "build-runners"
  organization = "my-github-org"

  github_pat_secret_arn = aws_secretsmanager_secret.pat.arn
  webhook_secret_arn    = aws_secretsmanager_secret.webhook.arn

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  runner_image  = "myoung34/github-runner:2.317.0"
  runner_cpu    = 2048
  runner_memory = 4096
  runner_labels = ["fargate", "ubuntu-22.04", "build"]

  min_runners = 1
  max_runners = 50

  fargate_spot_weight     = 8
  fargate_ondemand_weight = 2

  log_retention_days = 30

  tags = {
    Team        = "platform"
    CostCenter  = "engineering"
  }
}
```

### Repo-level runners

```hcl
module "runner_fleet" {
  source = "path/to/module"

  name         = "api-runners"
  organization = "my-github-org"
  repos        = ["my-api-repo"]

  # ... other vars
}
```

---

## GitHub Webhook Setup

After `terraform apply`, configure the webhook in GitHub:

**Organization-level runners:**

1. Go to: `https://github.com/organizations/<org>/settings/hooks`
2. Click "Add webhook"
3. Set Payload URL to the `webhook_url` output value
4. Set Content type to `application/json`
5. Set Secret to the value stored in your `webhook_secret_arn` secret
6. Under "Which events would you like to trigger this webhook?", select "Let me select individual events"
7. Check "Workflow jobs" only
8. Click "Add webhook"

**Repo-level runners:** Same steps under `https://github.com/<org>/<repo>/settings/hooks`.

---

## Granting Runner Containers AWS Access

Runner containers use the ECS task role. Attach additional policies to grant access to AWS services:

```hcl
resource "aws_iam_role_policy" "runner_s3" {
  name = "runner-s3-access"
  role = module.runner_fleet.ecs_task_role_arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "arn:aws:s3:::my-artifacts-bucket/*"
    }]
  })
}
```

---

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| name | Base name prefix for all resources | `string` | - | yes |
| organization | GitHub organization name | `string` | - | yes |
| repos | Repository names for repo-level runners; empty = org-level | `list(string)` | `[]` | no |
| github_pat_secret_arn | Secrets Manager ARN holding the GitHub PAT | `string` | - | yes |
| webhook_secret_arn | Secrets Manager ARN holding the webhook HMAC secret | `string` | - | yes |
| vpc_id | VPC ID for runner ECS tasks | `string` | - | yes |
| subnet_ids | Private subnet IDs for runner tasks | `list(string)` | - | yes |
| runner_image | Docker image for runner containers | `string` | `"myoung34/github-runner:latest"` | no |
| runner_cpu | Fargate CPU units per runner (1024 = 1 vCPU) | `number` | `1024` | no |
| runner_memory | Fargate memory MiB per runner | `number` | `2048` | no |
| runner_labels | Additional runner labels | `list(string)` | `[]` | no |
| runner_group | GitHub runner group | `string` | `"Default"` | no |
| min_runners | Minimum desired runner tasks | `number` | `0` | no |
| max_runners | Maximum desired runner tasks | `number` | `20` | no |
| fargate_spot_weight | Spot capacity weight | `number` | `7` | no |
| fargate_ondemand_weight | On-Demand capacity weight | `number` | `3` | no |
| log_retention_days | CloudWatch Logs retention in days | `number` | `14` | no |
| enable_dlq | Create SQS dead-letter queue for failed webhooks | `bool` | `true` | no |
| tags | Tags applied to all resources | `map(string)` | `{}` | no |

---

## Outputs

| Name | Description |
|------|-------------|
| webhook_url | Configure this as the GitHub webhook Payload URL |
| ecs_cluster_name | ECS cluster name |
| ecs_cluster_arn | ECS cluster ARN |
| ecs_service_name | ECS service name |
| ecs_service_id | ECS service ARN |
| lambda_function_name | Webhook Lambda function name |
| lambda_function_arn | Webhook Lambda ARN |
| api_gateway_id | API Gateway HTTP API ID |
| runner_security_group_id | Runner task security group ID |
| runner_log_group_name | Runner CloudWatch Log Group name |
| lambda_log_group_name | Lambda CloudWatch Log Group name |
| dlq_url | SQS DLQ URL (empty string if enable_dlq = false) |
| dlq_arn | SQS DLQ ARN (empty string if enable_dlq = false) |
| ecs_task_role_arn | Task role ARN - attach extra policies here |
| ecs_task_execution_role_arn | Task execution role ARN |

---

## Security Notes

- The Lambda verifies the `X-Hub-Signature-256` header on every request before processing. Requests with invalid or missing signatures receive HTTP 401.
- The webhook secret is never logged or exposed in environment variables visible to runner containers.
- Runner tasks have no inbound security group rules. Outbound access is unrestricted (required to reach GitHub API and package registries).
- The GitHub PAT is injected into runner containers via ECS Secrets (pulled from Secrets Manager at task start). It is not logged.
- All IAM roles follow least-privilege: Lambda can only read the webhook secret, describe the ECS service, and update service desired_count.

---

## Cost Considerations

With `min_runners = 0`, you pay only for:
- Fargate task time while runners are executing jobs
- Lambda invocations per webhook delivery (effectively free at low volume)
- API Gateway invocations per webhook delivery
- NAT Gateway data transfer

With `fargate_spot_weight = 7` and `fargate_ondemand_weight = 3`, approximately 70% of tasks run on Fargate Spot (up to 70% cheaper). The `base = min_runners` on the On-Demand provider ensures the minimum baseline is always On-Demand (stable).

---

## Limitations and Known Considerations

- **Multi-repo scaling:** When `repos` contains multiple entries, only the first repo is used for runner registration in the current ECS task definition. For true per-repo fleet isolation, instantiate the module once per repository.
- **Rapid burst:** The Lambda increments desired_count by 1 per queued event. If 50 jobs queue simultaneously, GitHub fires 50 webhook deliveries and Lambda runs 50 times (concurrently). This is correct behavior but may cause minor ECS API throttling at extreme scale. Consider adding exponential backoff to the Lambda for fleets exceeding 100 runners.
- **Spot interruptions:** Fargate Spot tasks can be reclaimed with 2-minute notice. GitHub Actions handles runner disconnections gracefully by re-queuing the job (for self-hosted runners with the re-run-on-failure setting). Pin mission-critical jobs to On-Demand by setting `fargate_spot_weight = 0`.
- **Cold start:** New runner containers take 30-90 seconds to start and register with GitHub. Jobs queued during this window remain queued until a runner is available.

---

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| aws | >= 5.0.0 |
| archive | >= 2.4.0 |
