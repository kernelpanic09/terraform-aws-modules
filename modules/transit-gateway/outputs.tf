# ---------------------------------------------------------------------------
# Transit Gateway
# ---------------------------------------------------------------------------

output "transit_gateway_id" {
  description = "ID of the Transit Gateway."
  value       = aws_ec2_transit_gateway.this.id
}

output "transit_gateway_arn" {
  description = "ARN of the Transit Gateway."
  value       = aws_ec2_transit_gateway.this.arn
}

output "transit_gateway_owner_id" {
  description = "AWS account ID that owns the Transit Gateway."
  value       = aws_ec2_transit_gateway.this.owner_id
}

output "transit_gateway_association_default_route_table_id" {
  description = "ID of the default association route table. Not used when default_route_table_association = disable, but kept for reference."
  value       = aws_ec2_transit_gateway.this.association_default_route_table_id
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------

output "route_table_ids" {
  description = "Map of route table name to route table ID."
  value = {
    for name, rt in aws_ec2_transit_gateway_route_table.this : name => rt.id
  }
}

output "route_table_arns" {
  description = "Map of route table name to route table ARN."
  value = {
    for name, rt in aws_ec2_transit_gateway_route_table.this : name => rt.arn
  }
}

# ---------------------------------------------------------------------------
# VPC attachments
# ---------------------------------------------------------------------------

output "vpc_attachment_ids" {
  description = "Map of attachment name to attachment ID."
  value = {
    for name, att in aws_ec2_transit_gateway_vpc_attachment.this : name => att.id
  }
}

output "vpc_attachment_arns" {
  description = "Map of attachment name to attachment ARN."
  value = {
    for name, att in aws_ec2_transit_gateway_vpc_attachment.this : name => att.arn
  }
}

# ---------------------------------------------------------------------------
# RAM
# ---------------------------------------------------------------------------

output "ram_resource_share_arn" {
  description = "ARN of the RAM resource share. Null when enable_ram_sharing = false."
  value       = var.enable_ram_sharing ? aws_ram_resource_share.this[0].arn : null
}

# ---------------------------------------------------------------------------
# Flow logs
# ---------------------------------------------------------------------------

output "flow_log_id" {
  description = "ID of the Transit Gateway flow log. Null when enable_flow_logs = false."
  value       = var.enable_flow_logs ? aws_flow_log.tgw[0].id : null
}

# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------

output "alarm_sns_topic_arn" {
  description = "ARN of the SNS topic used for throughput alarms. Null when alarm_emails is empty."
  value       = local.create_alarms ? aws_sns_topic.alarms[0].arn : null
}

output "alarm_bytes_in_arn" {
  description = "ARN of the BytesIn CloudWatch alarm. Null when alarm_emails is empty."
  value       = local.create_alarms ? aws_cloudwatch_metric_alarm.bytes_in[0].arn : null
}

output "alarm_bytes_out_arn" {
  description = "ARN of the BytesOut CloudWatch alarm. Null when alarm_emails is empty."
  value       = local.create_alarms ? aws_cloudwatch_metric_alarm.bytes_out[0].arn : null
}
