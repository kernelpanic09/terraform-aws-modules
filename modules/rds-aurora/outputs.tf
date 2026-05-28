# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

output "cluster_id" {
  description = "The RDS cluster identifier."
  value       = aws_rds_cluster.this.id
}

output "cluster_arn" {
  description = "The ARN of the Aurora cluster."
  value       = aws_rds_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Writer endpoint for the cluster."
  value       = aws_rds_cluster.this.endpoint
}

output "cluster_reader_endpoint" {
  description = "Reader endpoint for the cluster (load-balanced across read replicas)."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "cluster_port" {
  description = "Port the cluster is listening on."
  value       = aws_rds_cluster.this.port
}

output "cluster_database_name" {
  description = "Name of the initial database in the cluster."
  value       = aws_rds_cluster.this.database_name
}

output "cluster_master_username" {
  description = "Master username for the cluster."
  value       = aws_rds_cluster.this.master_username
}

output "cluster_resource_id" {
  description = "RDS cluster resource ID (used for IAM auth policies)."
  value       = aws_rds_cluster.this.cluster_resource_id
}

# ---------------------------------------------------------------------------
# Instances
# ---------------------------------------------------------------------------

output "instance_ids" {
  description = "List of all DB instance identifiers."
  value       = aws_rds_cluster_instance.this[*].identifier
}

output "instance_arns" {
  description = "List of all DB instance ARNs."
  value       = aws_rds_cluster_instance.this[*].arn
}

output "instance_endpoints" {
  description = "Per-instance endpoints. Useful when you want to target a specific instance."
  value       = aws_rds_cluster_instance.this[*].endpoint
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

output "security_group_id" {
  description = "ID of the security group attached to the cluster."
  value       = aws_security_group.cluster.id
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group."
  value       = aws_db_subnet_group.this.name
}

# ---------------------------------------------------------------------------
# Parameter groups
# ---------------------------------------------------------------------------

output "cluster_parameter_group_name" {
  description = "Name of the cluster parameter group."
  value       = aws_rds_cluster_parameter_group.this.name
}

output "db_parameter_group_name" {
  description = "Name of the instance parameter group."
  value       = aws_db_parameter_group.this.name
}

# ---------------------------------------------------------------------------
# Secrets Manager
# ---------------------------------------------------------------------------

output "secret_arn" {
  description = "ARN of the Secrets Manager secret containing the master credentials. Empty if enable_secrets_manager = false."
  value       = var.enable_secrets_manager ? aws_secretsmanager_secret.master[0].arn : ""
}

output "secret_name" {
  description = "Name of the Secrets Manager secret. Empty if enable_secrets_manager = false."
  value       = var.enable_secrets_manager ? aws_secretsmanager_secret.master[0].name : ""
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

output "enhanced_monitoring_role_arn" {
  description = "ARN of the IAM role used for Enhanced Monitoring. Empty if monitoring is disabled."
  value       = var.enable_enhanced_monitoring && var.monitoring_interval > 0 ? aws_iam_role.enhanced_monitoring[0].arn : ""
}

# ---------------------------------------------------------------------------
# Alarms and SNS
# ---------------------------------------------------------------------------

output "sns_topic_arn" {
  description = "ARN of the SNS topic for CloudWatch alarms."
  value       = local.sns_topic_arn
}

# ---------------------------------------------------------------------------
# Cross-region replica
# ---------------------------------------------------------------------------

output "replica_cluster_id" {
  description = "Identifier of the cross-region replica cluster. Empty if not enabled."
  value       = var.enable_cross_region_replica ? aws_rds_cluster.replica[0].id : ""
}

output "replica_cluster_endpoint" {
  description = "Writer endpoint of the cross-region replica cluster. Empty if not enabled."
  value       = var.enable_cross_region_replica ? aws_rds_cluster.replica[0].endpoint : ""
}

output "replica_cluster_reader_endpoint" {
  description = "Reader endpoint of the cross-region replica cluster. Empty if not enabled."
  value       = var.enable_cross_region_replica ? aws_rds_cluster.replica[0].reader_endpoint : ""
}

output "replica_instance_ids" {
  description = "Instance identifiers in the cross-region replica cluster. Empty list if not enabled."
  value       = var.enable_cross_region_replica ? aws_rds_cluster_instance.replica[*].identifier : []
}
