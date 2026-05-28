# eks-cluster

Production-grade EKS cluster with managed node groups, KMS secret encryption, control plane logging, OIDC-based IRSA, and API-mode access entries.

## Features

- **EKS cluster** with configurable Kubernetes version and API server endpoint access controls
- **KMS envelope encryption** for Kubernetes secrets with automatic key rotation
- **Control plane logging** to CloudWatch with configurable retention
- **OIDC provider** for IRSA (IAM Roles for Service Accounts), enabling pods to assume IAM roles without node-level credentials
- **Managed node groups** with full configurability: instance types, capacity type (ON_DEMAND/SPOT), scaling config, taints, labels, and per-group subnet override
- **EKS add-ons** with version pinning and conflict resolution policy (vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver, etc.)
- **IRSA role for AWS Load Balancer Controller** (optional)
- **IRSA role for Cluster Autoscaler** (optional, with ASG tag-scoped permissions)
- **Access entries** (API mode) for cluster admin principals, replacing the deprecated aws-auth ConfigMap
- **Security groups** for node-to-control-plane and intra-node communication

## Usage

```hcl
module "eks" {
  source = "github.com/kernelpanic09/terraform-aws-modules//modules/eks-cluster"

  cluster_name       = "production"
  kubernetes_version = "1.30"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids

  node_groups = {
    system = {
      name           = "system"
      instance_types = ["m6i.large"]
      capacity_type  = "ON_DEMAND"
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      labels = {
        "node-role" = "system"
      }
    }
    workloads = {
      name           = "workloads"
      instance_types = ["m6i.large", "m6a.large", "m5.large"]
      capacity_type  = "SPOT"
      min_size       = 0
      max_size       = 10
      desired_size   = 2
    }
  }

  addons = {
    vpc-cni = {
      version = "v1.18.1-eksbuild.1"
    }
    coredns = {
      version = "v1.11.1-eksbuild.4"
    }
    kube-proxy = {
      version = "v1.30.0-eksbuild.3"
    }
  }

  cluster_admin_principals       = ["arn:aws:iam::123456789012:role/MyPlatformRole"]
  enable_lb_controller_irsa      = true
  enable_cluster_autoscaler_irsa = true

  tags = {
    Environment = "production"
    Project     = "platform"
  }
}
```

## IRSA pattern

This module creates an OIDC provider for the cluster. Any IAM role that needs to be assumed by a Kubernetes service account should use the AssumeRoleWithWebIdentity trust policy pattern:

```hcl
data "aws_iam_policy_document" "my_app_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:my-namespace:my-service-account"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
```

The module outputs `oidc_provider_arn` and `oidc_provider_url` for use in downstream role definitions.

## Access entries

This module uses EKS API-mode access entries (`authentication_mode = "API"`) instead of the legacy aws-auth ConfigMap. Specify IAM role or user ARNs in `cluster_admin_principals` to grant `AmazonEKSClusterAdminPolicy` access.

The bootstrap creator admin permissions flag is set to `false` to avoid implicit access grants. All access is explicit and auditable via Terraform state.

## Cluster Autoscaler tagging

All managed node groups receive the following tags automatically:

```
k8s.io/cluster-autoscaler/enabled            = "true"
k8s.io/cluster-autoscaler/<cluster_name>     = "owned"
```

The Cluster Autoscaler IRSA policy restricts `SetDesiredCapacity` and `TerminateInstanceInAutoScalingGroup` to ASGs bearing these tags, so the Autoscaler cannot affect node groups from other clusters.

## Requirements

| Requirement | Version |
|-------------|---------|
| Terraform | >= 1.5 |
| AWS Provider | >= 5.0 |
| TLS Provider | >= 4.0 |

## Variables

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| cluster_name | Name of the EKS cluster | `string` | n/a | yes |
| kubernetes_version | Kubernetes version for the control plane | `string` | `"1.30"` | no |
| vpc_id | VPC ID for the cluster | `string` | n/a | yes |
| subnet_ids | Private subnet IDs for control plane and node groups | `list(string)` | n/a | yes |
| public_subnet_ids | Public subnet IDs (optional, not used by node groups) | `list(string)` | `[]` | no |
| endpoint_public_access | Enable public API server endpoint | `bool` | `true` | no |
| endpoint_private_access | Enable private API server endpoint | `bool` | `true` | no |
| public_access_cidrs | CIDRs allowed to reach the public endpoint | `list(string)` | `["0.0.0.0/0"]` | no |
| enabled_cluster_log_types | Control plane log types to enable | `list(string)` | all types | no |
| log_retention_days | CloudWatch log retention in days | `number` | `90` | no |
| node_groups | Map of managed node group configurations | `map(object)` | `{}` | no |
| addons | Map of EKS add-on configurations | `map(object)` | `{}` | no |
| cluster_admin_principals | IAM principal ARNs granted cluster admin access | `list(string)` | `[]` | no |
| enable_lb_controller_irsa | Create IRSA role for the AWS Load Balancer Controller | `bool` | `false` | no |
| lb_controller_namespace | Namespace for the LB Controller service account | `string` | `"kube-system"` | no |
| lb_controller_service_account | Service account name for the LB Controller | `string` | `"aws-load-balancer-controller"` | no |
| enable_cluster_autoscaler_irsa | Create IRSA role for the Cluster Autoscaler | `bool` | `false` | no |
| cluster_autoscaler_namespace | Namespace for the Cluster Autoscaler service account | `string` | `"kube-system"` | no |
| cluster_autoscaler_service_account | Service account name for the Cluster Autoscaler | `string` | `"cluster-autoscaler"` | no |
| tags | Additional tags to apply to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| cluster_name | Name of the EKS cluster |
| cluster_arn | ARN of the EKS cluster |
| cluster_endpoint | API server endpoint URL |
| cluster_certificate_authority_data | Base64-encoded CA data for kubectl |
| cluster_version | Kubernetes version on the control plane |
| cluster_role_arn | ARN of the cluster IAM role |
| node_role_arn | ARN of the node group IAM role |
| oidc_provider_arn | ARN of the IAM OIDC provider |
| oidc_provider_url | OIDC issuer URL without https:// |
| oidc_issuer_url | Full OIDC issuer URL |
| cluster_security_group_id | ID of the additional cluster security group |
| cluster_primary_security_group_id | ID of the EKS-managed cluster security group |
| node_security_group_id | ID of the node security group |
| kms_key_arn | ARN of the KMS secrets encryption key |
| cloudwatch_log_group_name | CloudWatch log group name for control plane logs |
| node_group_arns | Map of node group key to ARN |
| node_group_autoscaling_group_names | Map of node group key to ASG names |
| addon_arns | Map of add-on name to ARN |
| lb_controller_role_arn | IRSA role ARN for the AWS Load Balancer Controller |
| cluster_autoscaler_role_arn | IRSA role ARN for the Cluster Autoscaler |
