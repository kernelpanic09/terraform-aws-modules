# ------------------------------------------------------------------------------
# Cluster
# ------------------------------------------------------------------------------

output "cluster_id" {
  description = "ID of the ECS cluster."
  value       = aws_ecs_cluster.this.id
}

output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.this.name
}

# ------------------------------------------------------------------------------
# Service
# ------------------------------------------------------------------------------

output "service_id" {
  description = "Full ARN of the ECS service."
  value       = aws_ecs_service.this.id
}

output "service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.this.name
}

# ------------------------------------------------------------------------------
# Task Definition
# ------------------------------------------------------------------------------

output "task_definition_arn" {
  description = "Full ARN of the active task definition revision."
  value       = aws_ecs_task_definition.this.arn
}

output "task_definition_family" {
  description = "Task definition family name."
  value       = aws_ecs_task_definition.this.family
}

output "task_definition_revision" {
  description = "Task definition revision number currently registered."
  value       = aws_ecs_task_definition.this.revision
}

# ------------------------------------------------------------------------------
# IAM Roles
# ------------------------------------------------------------------------------

output "execution_role_arn" {
  description = "ARN of the ECS task execution IAM role. Attach additional policies here to grant the ECS agent extra permissions (e.g., KMS decryption for encrypted SSM parameters)."
  value       = aws_iam_role.execution.arn
}

output "execution_role_name" {
  description = "Name of the ECS task execution IAM role."
  value       = aws_iam_role.execution.name
}

output "task_role_arn" {
  description = "ARN of the ECS task IAM role. Attach application-specific policies (S3, DynamoDB, etc.) to this role."
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Name of the ECS task IAM role."
  value       = aws_iam_role.task.name
}

# ------------------------------------------------------------------------------
# Security Groups
# ------------------------------------------------------------------------------

output "alb_security_group_id" {
  description = "ID of the ALB security group. Reference this to allow other resources to receive traffic from the ALB."
  value       = aws_security_group.alb.id
}

output "tasks_security_group_id" {
  description = "ID of the ECS tasks security group. Reference this in RDS, ElastiCache, or other downstream security groups to allow traffic from ECS tasks."
  value       = aws_security_group.tasks.id
}

# ------------------------------------------------------------------------------
# Load Balancer
# ------------------------------------------------------------------------------

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer. Create a CNAME or alias record pointing to this value."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Route53 canonical hosted zone ID of the ALB. Use with aws_route53_record alias records."
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  description = "ARN of the ALB target group."
  value       = aws_lb_target_group.this.arn
}

output "http_listener_arn" {
  description = "ARN of the HTTP (port 80) ALB listener."
  value       = aws_lb_listener.http.arn
}

output "https_listener_arn" {
  description = "ARN of the HTTPS (port 443) ALB listener. Empty string when enable_https = false."
  value       = var.enable_https ? aws_lb_listener.https[0].arn : ""
}

# ------------------------------------------------------------------------------
# CloudWatch Logs
# ------------------------------------------------------------------------------

output "log_group_name" {
  description = "Name of the CloudWatch Log Group where container logs are written."
  value       = aws_cloudwatch_log_group.app.name
}

output "log_group_arn" {
  description = "ARN of the CloudWatch Log Group."
  value       = aws_cloudwatch_log_group.app.arn
}

# ------------------------------------------------------------------------------
# Auto Scaling
# ------------------------------------------------------------------------------

output "autoscaling_target_resource_id" {
  description = "Application Auto Scaling target resource ID. Empty string when enable_autoscaling = false."
  value       = var.enable_autoscaling ? aws_appautoscaling_target.this[0].resource_id : ""
}

# ------------------------------------------------------------------------------
# Service Discovery
# ------------------------------------------------------------------------------

output "service_discovery_service_arn" {
  description = "ARN of the Cloud Map service registry entry. Empty string when enable_service_discovery = false."
  value       = var.enable_service_discovery ? aws_service_discovery_service.this[0].arn : ""
}
