provider "aws" {
  region = "us-east-1"
}

# ------------------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  name               = "production"
  vpc_cidr           = "10.0.0.0/16"
  az_count           = 3
  single_nat_gateway = false
  enable_flow_logs   = true

  tags = {
    Environment = "production"
    Project     = "platform"
  }
}

# ------------------------------------------------------------------------------
# EKS cluster
# ------------------------------------------------------------------------------

module "eks" {
  source = "../../modules/eks-cluster"

  cluster_name       = "production"
  kubernetes_version = "1.30"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  # Restrict the public API endpoint to known office CIDRs.
  # Replace with your actual egress IPs in production.
  endpoint_public_access  = true
  endpoint_private_access = true
  public_access_cidrs     = ["203.0.113.0/24"]

  # Retain control plane logs for 1 year.
  log_retention_days = 365

  # Two node groups:
  #   system    - On-Demand, dedicated to cluster-critical workloads (CoreDNS, kube-proxy, etc.)
  #   workloads - Spot pool with instance flexibility for cost-efficient application workloads

  node_groups = {
    system = {
      name           = "system"
      instance_types = ["m6i.large"]
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2_x86_64"
      disk_size      = 50
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      labels = {
        "node-role"                  = "system"
        "kubernetes.io/node-purpose" = "system"
      }
      # Prevent general workloads from landing on system nodes.
      taints = [
        {
          key    = "node-role"
          value  = "system"
          effect = "NO_SCHEDULE"
        }
      ]
    }

    workloads = {
      name = "workloads"
      # Multiple instance types increase Spot availability and reduce interruption rates.
      instance_types = ["m6i.large", "m6a.large", "m5.large", "m5a.large"]
      capacity_type  = "SPOT"
      ami_type       = "AL2_x86_64"
      disk_size      = 100
      min_size       = 0
      max_size       = 20
      desired_size   = 2
      labels = {
        "node-role"                  = "workload"
        "kubernetes.io/node-purpose" = "application"
      }
    }
  }

  # Pinned add-on versions. Check https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html
  # for the latest version compatible with your Kubernetes version before upgrading.
  addons = {
    vpc-cni = {
      version                     = "v1.18.1-eksbuild.1"
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns = {
      version                     = "v1.11.1-eksbuild.4"
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      version                     = "v1.30.0-eksbuild.3"
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      version                     = "v1.31.0-eksbuild.1"
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  # Replace with the IAM role or user ARNs that should have full cluster admin access.
  cluster_admin_principals = [
    "arn:aws:iam::123456789012:role/PlatformAdminRole",
    "arn:aws:iam::123456789012:role/GitHubActionsRole",
  ]

  # Create IRSA roles for the AWS Load Balancer Controller and Cluster Autoscaler.
  # After applying, annotate the corresponding Kubernetes service accounts with the
  # role ARN outputs (lb_controller_role_arn / cluster_autoscaler_role_arn).
  enable_lb_controller_irsa      = true
  enable_cluster_autoscaler_irsa = true

  tags = {
    Environment = "production"
    Project     = "platform"
  }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA data for kubeconfig"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version on the control plane"
  value       = module.eks.cluster_version
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for creating additional IRSA roles"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL without https://"
  value       = module.eks.oidc_provider_url
}

output "node_security_group_id" {
  description = "Security group ID shared by all node groups"
  value       = module.eks.node_security_group_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting Kubernetes secrets"
  value       = module.eks.kms_key_arn
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group for EKS control plane logs"
  value       = module.eks.cloudwatch_log_group_name
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN to annotate the AWS Load Balancer Controller service account with"
  value       = module.eks.lb_controller_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role ARN to annotate the Cluster Autoscaler service account with"
  value       = module.eks.cluster_autoscaler_role_arn
}

output "node_group_autoscaling_group_names" {
  description = "Auto Scaling Group names per node group (useful for Cluster Autoscaler node group discovery)"
  value       = module.eks.node_group_autoscaling_group_names
}

# Convenience: kubectl config command
output "configure_kubectl" {
  description = "Run this command to update your local kubeconfig"
  value       = "aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name}"
}
