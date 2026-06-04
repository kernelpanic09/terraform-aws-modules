# terraform-aws-modules

[![CI](https://github.com/kernelpanic09/terraform-aws-modules/actions/workflows/ci.yml/badge.svg)](https://github.com/kernelpanic09/terraform-aws-modules/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/kernelpanic09/terraform-aws-modules)](LICENSE)
[![Release](https://img.shields.io/github/v/release/kernelpanic09/terraform-aws-modules?include_prereleases&sort=semver)](https://github.com/kernelpanic09/terraform-aws-modules/releases)
[![Last commit](https://img.shields.io/github/last-commit/kernelpanic09/terraform-aws-modules)](https://github.com/kernelpanic09/terraform-aws-modules/commits)
[![Modules](https://img.shields.io/badge/modules-18-blue)](modules/)

A collection of opinionated Terraform modules for AWS, built around patterns I've used in real environments. These aren't generic wrappers around AWS resources. Each module captures a specific architecture (multi-region DNS failover, Okta-AWS SAML federation, ephemeral GitHub runner fleets, Bedrock-backed RAG, etc.) with the IAM, encryption, monitoring, and edge-case handling already wired in.

Built against Terraform 1.5+ and AWS Provider 5.x.

## Modules

### Networking and Compute

| Module | Description | Key Features |
|--------|-------------|-------------|
| [vpc](modules/vpc/) | Multi-AZ VPC with public and private subnets | HA or single NAT gateway, VPC Flow Logs, default SG locked down |
| [eks-cluster](modules/eks-cluster/) | EKS cluster with managed node groups | OIDC/IRSA, KMS secret encryption, access entries (no more aws-auth), ALB controller + autoscaler IRSA |
| [ecs-fargate](modules/ecs-fargate/) | ECS Fargate service behind an ALB | Autoscaling, SSM secrets, circuit breaker deploys, Container Insights |
| [s3-cloudfront](modules/s3-cloudfront/) | S3 static hosting fronted by CloudFront | OAC (not legacy OAI), WAF with managed rules, security headers, SPA routing |
| [route53-failover](modules/route53-failover/) | Active-passive DNS failover across regions | Health checks from multiple regions, CloudWatch alarms, composite alarm for total-outage escalation |
| [transit-gateway](modules/transit-gateway/) | Hub-and-spoke multi-VPC networking | Per-environment route tables, association vs propagation done right, RAM share with the org, flow logs |
| [fargate-cron](modules/fargate-cron/) | Scheduled Fargate tasks (cron jobs, not services) | EventBridge cron, DLQ for failed invocations, optional SNS alert when a task exits non-zero |

### Data

| Module | Description | Key Features |
|--------|-------------|-------------|
| [rds-aurora](modules/rds-aurora/) | Aurora cluster (Postgres or MySQL) with cross-region replica | Performance Insights, enhanced monitoring, Secrets Manager with optional rotation, CloudWatch alarms on CPU/memory/storage/connections |

### Identity and Access

| Module | Description | Key Features |
|--------|-------------|-------------|
| [iam-roles](modules/iam-roles/) | Standard role set: admin, dev, read-only, CI/CD | GitHub Actions OIDC, MFA-gated admin, permission boundaries on everything but admin |
| [okta-aws-federation](modules/okta-aws-federation/) | Okta SAML federation to AWS, end to end | Multi-provider (Okta + AWS), Okta groups mapped to IAM roles, SAML cert rotation handled automatically |
| [identity-center](modules/identity-center/) | AWS Identity Center (SSO) managed as code | Permission sets, groups, cross-account assignments. Stops people from clicking around the SSO console |

### Foundation and Operations

| Module | Description | Key Features |
|--------|-------------|-------------|
| [landing-zone](modules/landing-zone/) | Account foundation: state backend, audit, governance | S3 + DynamoDB for state, CloudTrail with KMS, AWS Config, Organizations SCPs, budget alerts |
| [incident-response](modules/incident-response/) | GuardDuty + Security Hub with auto-remediation | EventBridge filters by severity, Lambda revokes leaked credentials and locks down public S3 / open SGs |
| [aws-backup](modules/aws-backup/) | Centralized backup with cross-region copy | KMS encryption, vault lock (GOVERNANCE or COMPLIANCE), restore testing plans, SNS alerts on failures |
| [github-runner-fleet](modules/github-runner-fleet/) | Self-hosted GitHub Actions runners on Fargate | Ephemeral runners, Fargate Spot, webhook-driven autoscaling, HMAC signature verification |

### AI and Bedrock

| Module | Description | Key Features |
|--------|-------------|-------------|
| [bedrock-knowledge-base](modules/bedrock-knowledge-base/) | RAG infrastructure on AWS Bedrock, fully wired | OpenSearch Serverless vector store, S3 data source, Lambda auto-ingestion on upload, IAM with confused-deputy protection |
| [ai-gateway](modules/ai-gateway/) | OpenAI-compatible proxy in front of Bedrock | Per-key budgets and rate limits, response caching, model fallback on throttle, CloudWatch dashboard, optional WAF |
| [bedrock-guardrails](modules/bedrock-guardrails/) | Bedrock Guardrails as code | Content filters, PII detection (BLOCK or ANONYMIZE), denied topics, regex filters, contextual grounding thresholds |

## Quick Start

```hcl
module "vpc" {
  source = "github.com/kernelpanic09/terraform-aws-modules//modules/vpc"

  name               = "production"
  vpc_cidr           = "10.0.0.0/16"
  az_count           = 3
  single_nat_gateway = false
  enable_flow_logs   = true

  tags = {
    Environment = "production"
  }
}
```

Each module has its own README with full variable and output documentation. See [examples/](examples/) for complete, runnable configurations.

## Using these modules

Reference any module directly via git source. Replace `vpc` with whichever module you need.

**Pin to a release tag (recommended for production)**

```hcl
module "vpc" {
  source = "git::https://github.com/kernelpanic09/terraform-aws-modules.git//modules/vpc?ref=v1.0.0"

  name               = "production"
  vpc_cidr           = "10.0.0.0/16"
  az_count           = 3
  single_nat_gateway = false
}
```

**Pin to a specific commit SHA (most strict)**

```hcl
module "vpc" {
  source = "git::https://github.com/kernelpanic09/terraform-aws-modules.git//modules/vpc?ref=abc1234"

  # ...
}
```

**Track main (only for prototyping)**

```hcl
module "vpc" {
  source = "github.com/kernelpanic09/terraform-aws-modules//modules/vpc"

  # ...
}
```

Pinning to a tag or SHA matters in practice. Without it, `terraform init -upgrade` can pull in a changed module and produce a different plan than you ran yesterday. Tag-pinned sources give you the same reproducibility the Terraform Registry offers - you just manage the tags yourself.

### Why not the Terraform Registry?

The Terraform Registry requires each module to live in its own repo following the `terraform-<provider>-<name>` naming convention. Publishing 18 modules would mean 18 separate repos. For a collection like this - where the examples deliberately compose multiple modules together - splitting them up adds friction without adding much value. Keeping everything in one repo makes cross-module examples easier to maintain and easier to follow. The git source approach with tag pinning gives you the same version control story the Registry provides.

## Examples

| Example | Modules Used | Description |
|---------|-------------|-------------|
| [vpc-basic](examples/vpc-basic/) | vpc | 3-AZ VPC with HA NAT gateways |
| [eks-cluster](examples/eks-cluster/) | vpc, eks-cluster | 2-node-group EKS cluster with addons, IRSA, and access entries |
| [ecs-basic](examples/ecs-basic/) | vpc, ecs-fargate | Fargate service with ALB and autoscaling |
| [s3-static-site](examples/s3-static-site/) | s3-cloudfront | Static site with CloudFront and optional WAF |
| [iam-github-oidc](examples/iam-github-oidc/) | iam-roles | GitHub Actions OIDC federation |
| [landing-zone](examples/landing-zone/) | landing-zone | Multi-account bootstrap with state backend |
| [okta-federation](examples/okta-federation/) | okta-aws-federation | Okta SAML app with 3 AWS role mappings |
| [identity-center](examples/identity-center/) | identity-center | Multi-account SSO with 5 permission sets |
| [incident-response](examples/incident-response/) | incident-response | GuardDuty + Security Hub + auto-remediation |
| [github-runner-fleet](examples/github-runner-fleet/) | github-runner-fleet | Org-wide GitHub Actions runner pool on Fargate Spot |
| [aws-backup](examples/aws-backup/) | aws-backup | Daily + weekly plans with cross-region copy and PITR |
| [route53-failover](examples/route53-failover/) | route53-failover | Two-region ALB failover with HTTPS health checks |
| [bedrock-knowledge-base](examples/bedrock-knowledge-base/) | bedrock-knowledge-base | RAG setup with Titan embeddings and auto-ingestion |
| [ai-gateway](examples/ai-gateway/) | ai-gateway | OpenAI-compatible Bedrock proxy with 3 API keys (prod/staging/internal) |
| [bedrock-guardrails](examples/bedrock-guardrails/) | bedrock-guardrails | Production guardrails with PII, denied topics, contextual grounding |
| [rds-aurora](examples/rds-aurora/) | rds-aurora | 3-instance Postgres cluster (1 writer + 2 readers) with Performance Insights |
| [transit-gateway](examples/transit-gateway/) | transit-gateway | 3-VPC hub-and-spoke with centralized egress and org-wide RAM share |
| [fargate-cron](examples/fargate-cron/) | fargate-cron | Nightly backup job with SSM secrets, DLQ, and failure alerts |

## How These Are Built

A few things I try to be consistent about across modules:

- **Secure by default.** Default security groups are locked down. S3 buckets block public access. TLS is enforced on bucket policies. Default IAM trust policies use the right `aws:SourceAccount` / `aws:SourceArn` conditions to avoid confused deputy issues.
- **Cost toggles where it matters.** Single NAT vs HA NAT. Fargate Spot vs on-demand. CloudFront price classes. DynamoDB on-demand by default. You shouldn't need to fork a module to keep dev cheap.
- **Variable validation everywhere.** Account IDs are checked for the 12-digit format. CIDRs run through `can(cidrhost())`. Instance classes get regex'd. Cron expressions parsed. Better to fail at `plan` than at `apply`.
- **Composable.** Modules read each other's outputs cleanly. The ECS example pulls subnets from the VPC module. The EKS module gives back the OIDC issuer URL so you can build your own IRSA roles on top of it.

## Related Work

If you want general-purpose, community-maintained modules for common AWS resources (VPC, EKS, RDS, EC2, etc.), go check out the [terraform-aws-modules](https://github.com/terraform-aws-modules) organization. Those are excellent and you should use them as a starting point for most stacks.

This repo intentionally goes the other direction. It's opinionated and focuses on patterns and integrations that aren't well-covered elsewhere: Okta-AWS federation, Identity Center as code, GuardDuty auto-remediation, ephemeral GitHub runner fleets, Bedrock RAG, etc.

- [agents-platform](https://github.com/kernelpanic09/agents-platform) - an example of what gets built on top of these modules: an AI agent orchestration platform that uses `bedrock-knowledge-base` for RAG and `identity-center` for human access.
- [mcp-server-aws](https://github.com/kernelpanic09/mcp-server-aws) - pairs with the `iam-roles` module to give AI agents safe, scoped read access to AWS without handing them long-lived admin credentials.

## Requirements

| Dependency | Version | Used By |
|-----------|---------|---------|
| Terraform | >= 1.5 | All modules |
| AWS Provider | >= 5.0 | All modules (bedrock modules require >= 5.50) |
| Okta Provider | >= 4.0 | okta-aws-federation only |
| TLS Provider | >= 4.0 | eks-cluster only |
| Archive Provider | >= 2.0 | incident-response, github-runner-fleet, ai-gateway, bedrock-knowledge-base |
| Null Provider | >= 3.2 | bedrock-knowledge-base only |
| Random Provider | >= 3.5 | ai-gateway, rds-aurora |

## Repository Structure

```
terraform-aws-modules/
├── modules/
│   ├── vpc/                  # VPC, subnets, NAT, flow logs
│   ├── eks-cluster/          # EKS cluster, node groups, IRSA, addons, access entries
│   ├── ecs-fargate/          # ECS cluster, service, ALB, autoscaling
│   ├── s3-cloudfront/        # S3, CloudFront, WAF, OAC
│   ├── iam-roles/            # Admin, developer, read-only, CI/CD roles
│   ├── landing-zone/         # State backend, CloudTrail, Config, SCPs
│   ├── okta-aws-federation/  # Okta SAML app + AWS IAM IdP + role mapping
│   ├── identity-center/      # AWS SSO permission sets, groups, assignments
│   ├── incident-response/    # GuardDuty, Security Hub, EventBridge, Lambda
│   ├── github-runner-fleet/  # Self-hosted GitHub Actions runners on Fargate Spot
│   ├── aws-backup/           # AWS Backup vaults, plans, cross-region copy
│   ├── route53-failover/     # Multi-region DNS failover with health checks
│   ├── transit-gateway/      # Hub-and-spoke multi-VPC networking
│   ├── fargate-cron/         # Scheduled Fargate tasks via EventBridge
│   ├── rds-aurora/           # Aurora cluster with cross-region replica
│   ├── bedrock-knowledge-base/  # RAG: OpenSearch Serverless + S3 + Bedrock
│   ├── ai-gateway/           # OpenAI-compatible proxy to Bedrock with caching
│   └── bedrock-guardrails/   # Content filters, PII, denied topics, grounding
├── examples/
│   ├── vpc-basic/
│   ├── eks-cluster/
│   ├── ecs-basic/
│   ├── s3-static-site/
│   ├── iam-github-oidc/
│   ├── landing-zone/
│   ├── okta-federation/
│   ├── identity-center/
│   ├── incident-response/
│   ├── github-runner-fleet/
│   ├── aws-backup/
│   ├── route53-failover/
│   ├── bedrock-knowledge-base/
│   ├── ai-gateway/
│   ├── bedrock-guardrails/
│   ├── rds-aurora/
│   ├── transit-gateway/
│   └── fargate-cron/
├── LICENSE
└── README.md
```

## License

MIT
