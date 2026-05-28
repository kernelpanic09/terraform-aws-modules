variable "name" {
  description = "Name prefix applied to all resources."
  type        = string
}

variable "amazon_side_asn" {
  description = "Private ASN for the Amazon side of a BGP session. Must be in the 64512-65534 or 4200000000-4294967294 range."
  type        = number
  default     = 64512
}

variable "enable_multicast" {
  description = "Enable multicast support on the Transit Gateway."
  type        = bool
  default     = false
}

variable "auto_accept_shared_attachments" {
  description = "Accept cross-account attachment requests automatically."
  type        = bool
  default     = false
}

variable "route_tables" {
  description = <<-EOT
    List of route table definitions. Each route table is identified by name,
    which other variables reference. 'name' must be unique within the list.
  EOT
  type = list(object({
    name = string
    tags = optional(map(string), {})
  }))
  default = []
}

variable "vpc_attachments" {
  description = <<-EOT
    List of VPC attachments. Each entry creates one TGW VPC attachment and wires
    it to the route tables specified.

    Fields:
      name                      - unique label used in static_routes references
      vpc_id                    - the VPC to attach
      subnet_ids                - one subnet per AZ (TGW requirement)
      route_table_association   - name of the route table this VPC is associated with
                                  (controls what the VPC can reach)
      route_table_propagations  - list of route table names this VPC propagates its
                                  CIDR into (other VPCs in those RTs learn this CIDR)
      dns_support               - enable DNS resolution through the TGW (default true)
      ipv6_support              - enable IPv6 (default false)
      appliance_mode_support    - enable appliance mode for stateful appliances (default false)
      tags                      - additional tags for this attachment
  EOT
  type = list(object({
    name                     = string
    vpc_id                   = string
    subnet_ids               = list(string)
    route_table_association  = string
    route_table_propagations = list(string)
    dns_support              = optional(bool, true)
    ipv6_support             = optional(bool, false)
    appliance_mode_support   = optional(bool, false)
    tags                     = optional(map(string), {})
  }))
  default = []
}

variable "static_routes" {
  description = <<-EOT
    List of static routes to insert into a TGW route table.

    Fields:
      route_table_name        - name of the route table to insert the route into
      destination_cidr_block  - CIDR for the route
      attachment_name         - name of the vpc_attachment to forward traffic to.
                                Set to null (and blackhole = true) for blackhole routes.
      blackhole               - drop traffic matching this route instead of forwarding it
  EOT
  type = list(object({
    route_table_name       = string
    destination_cidr_block = string
    attachment_name        = optional(string, null)
    blackhole              = optional(bool, false)
  }))
  default = []
}

# ---------------------------------------------------------------------------
# RAM sharing
# ---------------------------------------------------------------------------

variable "enable_ram_sharing" {
  description = "Share the Transit Gateway via AWS Resource Access Manager."
  type        = bool
  default     = false
}

variable "share_with_organization" {
  description = <<-EOT
    Share with the entire AWS Organization. Requires Organizations integration
    to be enabled in RAM (one-time opt-in in the management account).
    Ignored when enable_ram_sharing = false.
  EOT
  type        = bool
  default     = false
}

variable "share_principals" {
  description = <<-EOT
    List of additional principals (account IDs, OU ARNs, or org ARN) to share
    the TGW with. Used alongside share_with_organization when you need to target
    specific accounts too.
    Ignored when enable_ram_sharing = false.
  EOT
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Flow logs
# ---------------------------------------------------------------------------

variable "enable_flow_logs" {
  description = "Enable Transit Gateway flow logs."
  type        = bool
  default     = false
}

variable "flow_logs_destination_type" {
  description = "Where to deliver flow logs. Valid values: 's3' or 'cloud-watch-logs'."
  type        = string
  default     = "cloud-watch-logs"

  validation {
    condition     = contains(["s3", "cloud-watch-logs"], var.flow_logs_destination_type)
    error_message = "flow_logs_destination_type must be 's3' or 'cloud-watch-logs'."
  }
}

variable "flow_logs_destination" {
  description = <<-EOT
    ARN of the destination for flow logs.
    S3: bucket or prefix ARN.
    CloudWatch: log group ARN.
    Ignored when enable_flow_logs = false.
  EOT
  type        = string
  default     = null
}

variable "flow_logs_iam_role_arn" {
  description = <<-EOT
    IAM role ARN that allows the flow logs service to publish to CloudWatch.
    Required when flow_logs_destination_type = 'cloud-watch-logs'.
    Not needed for S3.
  EOT
  type        = string
  default     = null
}

variable "flow_logs_traffic_type" {
  description = "Traffic to capture. Valid values: ACCEPT, REJECT, ALL."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_logs_traffic_type)
    error_message = "flow_logs_traffic_type must be ACCEPT, REJECT, or ALL."
  }
}

# ---------------------------------------------------------------------------
# CloudWatch alarms
# ---------------------------------------------------------------------------

variable "alarm_emails" {
  description = <<-EOT
    Email addresses to notify when BytesIn or BytesOut exceed the alarm threshold.
    An SNS topic is created when this list is non-empty.
  EOT
  type        = list(string)
  default     = []
}

variable "alarm_bytes_threshold" {
  description = "Bytes per 5-minute period that triggers the CloudWatch alarm."
  type        = number
  default     = 10737418240 # 10 GiB
}

variable "alarm_evaluation_periods" {
  description = "Number of consecutive periods the metric must breach before alarming."
  type        = number
  default     = 3
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Tags applied to every resource created by this module."
  type        = map(string)
  default     = {}
}
