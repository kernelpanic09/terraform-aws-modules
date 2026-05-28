# ------------------------------------------------------------------------------
# Cluster
# ------------------------------------------------------------------------------

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_id" {
  description = "ID of the EKS cluster (same as cluster_name for EKS)."
  value       = aws_eks_cluster.this.id
}

output "cluster_endpoint" {
  description = "Endpoint URL for the EKS API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the cluster. Required by kubectl and the Kubernetes provider."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_platform_version" {
  description = "Platform version for the cluster (e.g. eks.5)."
  value       = aws_eks_cluster.this.platform_version
}

output "cluster_status" {
  description = "Status of the EKS cluster (ACTIVE, CREATING, DELETING, FAILED, UPDATING)."
  value       = aws_eks_cluster.this.status
}

# ------------------------------------------------------------------------------
# IAM
# ------------------------------------------------------------------------------

output "cluster_role_arn" {
  description = "ARN of the IAM role used by the EKS control plane."
  value       = aws_iam_role.cluster.arn
}

output "cluster_role_name" {
  description = "Name of the IAM role used by the EKS control plane."
  value       = aws_iam_role.cluster.name
}

output "node_role_arn" {
  description = "ARN of the IAM role used by managed node groups."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "Name of the IAM role used by managed node groups."
  value       = aws_iam_role.node.name
}

# ------------------------------------------------------------------------------
# OIDC provider (for IRSA)
# ------------------------------------------------------------------------------

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider. Required when creating IRSA roles outside this module."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC issuer (without https://). Used as the OIDC condition key prefix in IAM trust policies."
  value       = local.oidc_issuer_host
}

output "oidc_issuer_url" {
  description = "Full OIDC issuer URL including https://. As returned by the EKS API."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# ------------------------------------------------------------------------------
# Security groups
# ------------------------------------------------------------------------------

output "cluster_security_group_id" {
  description = "ID of the additional cluster security group created by this module. The EKS-managed cluster security group ID is available via cluster_primary_security_group_id."
  value       = aws_security_group.cluster_additional.id
}

output "cluster_primary_security_group_id" {
  description = "ID of the EKS-managed primary cluster security group (created automatically by EKS)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_security_group_id" {
  description = "ID of the security group attached to all managed node group instances."
  value       = aws_security_group.node.id
}

# ------------------------------------------------------------------------------
# KMS
# ------------------------------------------------------------------------------

output "kms_key_arn" {
  description = "ARN of the KMS key used for envelope encryption of Kubernetes secrets."
  value       = aws_kms_key.eks.arn
}

output "kms_key_id" {
  description = "ID of the KMS key used for envelope encryption of Kubernetes secrets."
  value       = aws_kms_key.eks.key_id
}

# ------------------------------------------------------------------------------
# CloudWatch
# ------------------------------------------------------------------------------

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group for EKS control plane logs."
  value       = aws_cloudwatch_log_group.eks.name
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group for EKS control plane logs."
  value       = aws_cloudwatch_log_group.eks.arn
}

# ------------------------------------------------------------------------------
# Node groups
# ------------------------------------------------------------------------------

output "node_group_arns" {
  description = "Map of node group key to ARN."
  value       = { for k, ng in aws_eks_node_group.this : k => ng.arn }
}

output "node_group_ids" {
  description = "Map of node group key to ID (cluster_name:node_group_name)."
  value       = { for k, ng in aws_eks_node_group.this : k => ng.id }
}

output "node_group_statuses" {
  description = "Map of node group key to current status."
  value       = { for k, ng in aws_eks_node_group.this : k => ng.status }
}

output "node_group_autoscaling_group_names" {
  description = "Map of node group key to the list of Auto Scaling Group names backing the node group."
  value       = { for k, ng in aws_eks_node_group.this : k => [for r in ng.resources : r.autoscaling_groups[*].name][0] }
}

# ------------------------------------------------------------------------------
# Add-ons
# ------------------------------------------------------------------------------

output "addon_arns" {
  description = "Map of add-on name to ARN."
  value       = { for k, a in aws_eks_addon.this : k => a.arn }
}

# ------------------------------------------------------------------------------
# IRSA - AWS Load Balancer Controller
# ------------------------------------------------------------------------------

output "lb_controller_role_arn" {
  description = "ARN of the IRSA role for the AWS Load Balancer Controller. Empty string when enable_lb_controller_irsa is false."
  value       = var.enable_lb_controller_irsa ? aws_iam_role.lb_controller[0].arn : ""
}

output "lb_controller_role_name" {
  description = "Name of the IRSA role for the AWS Load Balancer Controller. Empty string when enable_lb_controller_irsa is false."
  value       = var.enable_lb_controller_irsa ? aws_iam_role.lb_controller[0].name : ""
}

# ------------------------------------------------------------------------------
# IRSA - Cluster Autoscaler
# ------------------------------------------------------------------------------

output "cluster_autoscaler_role_arn" {
  description = "ARN of the IRSA role for the Cluster Autoscaler. Empty string when enable_cluster_autoscaler_irsa is false."
  value       = var.enable_cluster_autoscaler_irsa ? aws_iam_role.cluster_autoscaler[0].arn : ""
}

output "cluster_autoscaler_role_name" {
  description = "Name of the IRSA role for the Cluster Autoscaler. Empty string when enable_cluster_autoscaler_irsa is false."
  value       = var.enable_cluster_autoscaler_irsa ? aws_iam_role.cluster_autoscaler[0].name : ""
}
