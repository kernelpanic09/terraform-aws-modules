# terraform-aws-modules

Production-grade Terraform modules for AWS infrastructure. Each module is self-contained, tested against Terraform 1.5+ and AWS Provider 5.x, and designed for real-world use across staging and production environments.

## Modules

### Networking and Compute

| Module | Description | Key Features |
|--------|-------------|-------------|
| [vpc](modules/vpc/) | Multi-AZ VPC with public/private subnets | NAT gateway HA or single mode, VPC Flow Logs, restricted default SG |
| [eks-cluster](modules/eks-cluster/) | Production EKS cluster with managed node groups | OIDC/IRSA, KMS secret encryption, access entries, ALB controller + autoscaler IRSA |
| [ecs-fargate](modules/ecs-fargate/) | ECS Fargate service behind ALB | Autoscaling, SSM secrets, circuit breaker deploys, Container Insights |
| [s3-cloudfront](modules/s3-cloudfront/) | S3 static hosting with CloudFront CDN | OAC (not OAI), WAF with managed rules, security headers, SPA support |
| [route53-failover](modules/route53-failover/) | Multi-region active-passive DNS failover | Health checks from multiple regions, CloudWatch alarms, composite alarm escalation |

### Identity and Access

| Module | Description | Key Features |
|--------|-------------|-------------|
| [iam-roles](modules/iam-roles/) | Standard IAM role set with OIDC | GitHub Actions OIDC, MFA-gated admin, permission boundaries |
| [okta-aws-federation](modules/okta-aws-federation/) | Okta SAML federation to AWS | Multi-provider (Okta + AWS), group-to-role mapping, auto certificate rotation |
| [identity-center](modules/identity-center/) | AWS SSO programmatic management | Permission sets, groups, cross-account assignments as code |

### Foundation and Operations

| Module | Description | Key Features |
|--------|-------------|-------------|
| [landing-zone](modules/landing-zone/) | Multi-account foundation | S3/DynamoDB state backend, CloudTrail, Config, Organizations SCPs, budget alerts |
| [incident-response](modules/incident-response/) | Security operations pipeline | GuardDuty, Security Hub, EventBridge alerting, Lambda auto-remediation |
| [aws-backup](modules/aws-backup/) | Centralized backup with cross-region copy | KMS encryption, vault lock (GOVERNANCE/COMPLIANCE), restore testing, SNS alerts |
| [github-runner-fleet](modules/github-runner-fleet/) | Self-hosted GitHub Actions runners on Fargate | Ephemeral runners, Fargate Spot, webhook-driven autoscaling, HMAC verification |

### AI and Bedrock

| Module | Description | Key Features |
|--------|-------------|-------------|
| [bedrock-knowledge-base](modules/bedrock-knowledge-base/) | Full RAG infrastructure on AWS Bedrock | OpenSearch Serverless vector store, S3 data source, auto-ingestion Lambda, IAM with confused-deputy protection |
| [ai-gateway](modules/ai-gateway/) | Production Bedrock proxy with OpenAI-compatible API | Per-key budgets and rate limits, response caching, automatic model fallback, CloudWatch dashboard, optional WAF |
| [bedrock-guardrails](modules/bedrock-guardrails/) | Bedrock Guardrails as code for AI safety/compliance | Content filters, PII detection (BLOCK or ANONYMIZE), denied topics, regex filters, contextual grounding |

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

## Design Principles

**Secure by default.** Default security groups deny all traffic. S3 buckets block public access. IAM roles use permission boundaries. TLS is enforced everywhere. WAF rules are available on every public-facing resource.

**Cost-aware toggles.** Every expensive resource has a feature flag. Single NAT gateway for dev, HA for prod. Fargate Spot capacity. CloudFront price classes. DynamoDB on-demand vs provisioned.

**No hardcoded values.** All resource names, CIDRs, instance sizes, and feature flags are configurable through variables with validation blocks and sensible defaults.

**Composable.** Modules are designed to work together. The ECS example consumes VPC outputs directly. The landing zone creates the state backend that other modules use.

## Related Work

For general-purpose, community-maintained AWS modules covering common resources (VPC, EKS, RDS, EC2, etc.), see the [terraform-aws-modules](https://github.com/terraform-aws-modules) organization. This repo is intentionally opinionated and focuses on integrations and patterns (Okta federation, Identity Center, incident response, AI/Bedrock, GitHub runner fleets) that are not well-covered by the community modules.

## Requirements

| Dependency | Version | Used By |
|-----------|---------|---------|
| Terraform | >= 1.5 | All modules |
| AWS Provider | >= 5.0 | All modules (bedrock modules require >= 5.50) |
| Okta Provider | >= 4.0 | okta-aws-federation only |
| TLS Provider | >= 4.0 | eks-cluster only |
| Archive Provider | >= 2.0 | incident-response, github-runner-fleet, ai-gateway, bedrock-knowledge-base |
| Null Provider | >= 3.2 | bedrock-knowledge-base only |
| Random Provider | latest | ai-gateway only |

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
│   └── bedrock-guardrails/
├── LICENSE
└── README.md
```

## License

MIT
