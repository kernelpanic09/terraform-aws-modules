# rds-aurora

Terraform module for an Amazon Aurora cluster (PostgreSQL or MySQL compatible) with encryption, monitoring, alarms, and optional cross-region replication.

## What it creates

**Always:**
- Aurora cluster with KMS encryption, deletion protection, configurable backup and maintenance windows, IAM auth, and CloudWatch log exports
- DB subnet group and security group (ingress from CIDR blocks and/or security group IDs)
- Custom cluster parameter group and instance parameter group with opinionated defaults (force SSL, slow query logging, pg_stat_statements for PostgreSQL)
- Writer instance plus N reader instances (configurable)
- CloudWatch alarms: CPU > 80%, FreeableMemory < 256 MB, FreeLocalStorage < 10 GB, DatabaseConnections > 800
- SNS topic for those alarms (or you can pass an existing topic ARN)

**Optional:**
- Enhanced Monitoring IAM role and attachment
- Performance Insights with KMS encryption
- Secrets Manager secret for the master password, with automatic rotation via Lambda
- Cross-region read replica with its own subnet group, parameter groups, and instances
- SNS email subscriptions for alarm notifications

## Usage

```hcl
module "aurora" {
  source = "../../module"

  name           = "myapp-prod"
  engine         = "aurora-postgresql"
  engine_version = "15.4"
  instance_class = "db.r6g.large"
  instance_count = 3

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  allowed_security_group_ids = [module.app.security_group_id]

  database_name   = "myapp"
  master_username = "dbadmin"

  enable_performance_insights         = true
  performance_insights_retention_days = 7
  enable_enhanced_monitoring          = true
  monitoring_interval                 = 60

  backup_retention_days = 7
  deletion_protection   = true
  skip_final_snapshot   = false

  enable_secrets_manager = true
  enable_rotation        = false

  alarm_emails = ["ops@example.com"]

  tags = {
    Environment = "production"
    Team        = "platform"
  }
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| aws | >= 5.0.0 |
| random | >= 3.5.0 |

## Providers

The module uses the default `aws` provider for the primary cluster and an `aws.replica` alias for cross-region replication. If you don't need cross-region replication, you still need to declare the alias in your root module. just point it at the same region.

```hcl
provider "aws" {
  region = "us-east-1"
}

# Required by the module even when cross-region replication is disabled.
provider "aws" {
  alias  = "replica"
  region = "us-east-1"
}
```

When `enable_cross_region_replica = true`, point `aws.replica` at the target region and supply `replica_subnet_ids`.

## Variables

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| name | Prefix for all resource names | string |. | yes |
| engine | aurora-postgresql or aurora-mysql | string | aurora-postgresql | no |
| engine_version | Aurora engine version, e.g. 15.4 | string |. | yes |
| instance_class | DB instance class | string | db.r6g.large | no |
| instance_count | Writer + readers | number | 2 | no |
| vpc_id | VPC for the cluster | string |. | yes |
| subnet_ids | Subnets for the DB subnet group | list(string) |. | yes |
| allowed_security_group_ids | SGs allowed to reach the cluster | list(string) | [] | no |
| allowed_cidr_blocks | CIDRs allowed to reach the cluster | list(string) | [] | no |
| database_name | Initial database name | string |. | yes |
| master_username | Master username | string | dbadmin | no |
| master_password | Master password. Generated if empty | string | "" | no |
| kms_key_id | KMS key ARN for encryption | string | "" | no |
| enable_iam_auth | Enable IAM database auth | bool | true | no |
| backup_retention_days | Days of automated backups (1-35) | number | 7 | no |
| preferred_backup_window | Daily backup window in UTC | string | 02:00-03:00 | no |
| preferred_maintenance_window | Weekly maintenance window | string | sun:05:00-sun:06:00 | no |
| deletion_protection | Protect cluster from deletion | bool | true | no |
| skip_final_snapshot | Skip final snapshot on destroy | bool | false | no |
| enable_performance_insights | Enable Performance Insights | bool | true | no |
| performance_insights_retention_days | PI retention: 7 or multiples of 31 up to 731 | number | 7 | no |
| enable_enhanced_monitoring | Enable Enhanced Monitoring | bool | true | no |
| monitoring_interval | Monitoring interval: 0,1,5,10,15,30,60 | number | 60 | no |
| cluster_parameters | Extra cluster parameters (merged with defaults) | map(object) | {} | no |
| db_parameters | Extra instance parameters | map(object) | {} | no |
| enable_cross_region_replica | Create a cross-region read replica | bool | false | no |
| replica_region | Target region for the replica | string | "" | no |
| replica_subnet_ids | Subnets in the replica region | list(string) | [] | no |
| replica_instance_count | Number of replica instances | number | 1 | no |
| replica_instance_class | Instance class for the replica | string | "" | no |
| cloudwatch_logs_exports | Log types to export (module sets defaults per engine) | list(string) | [] | no |
| alarm_emails | Emails subscribed to alarm SNS topic | list(string) | [] | no |
| existing_sns_topic_arn | Use an existing SNS topic instead of creating one | string | "" | no |
| enable_secrets_manager | Store master password in Secrets Manager | bool | true | no |
| enable_rotation | Rotate the Secrets Manager secret via Lambda | bool | false | no |
| rotation_days | Days between rotations | number | 30 | no |
| tags | Tags applied to all resources | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| cluster_id | Cluster identifier |
| cluster_arn | Cluster ARN |
| cluster_endpoint | Writer endpoint |
| cluster_reader_endpoint | Reader endpoint |
| cluster_port | Port |
| cluster_database_name | Initial database name |
| cluster_master_username | Master username |
| cluster_resource_id | Cluster resource ID (for IAM auth policies) |
| instance_ids | All instance identifiers |
| instance_arns | All instance ARNs |
| instance_endpoints | Per-instance endpoints |
| security_group_id | Security group ID |
| db_subnet_group_name | Subnet group name |
| cluster_parameter_group_name | Cluster parameter group name |
| db_parameter_group_name | Instance parameter group name |
| secret_arn | Secrets Manager secret ARN |
| secret_name | Secrets Manager secret name |
| enhanced_monitoring_role_arn | Enhanced Monitoring IAM role ARN |
| sns_topic_arn | SNS topic ARN for alarms |
| replica_cluster_id | Cross-region replica cluster ID |
| replica_cluster_endpoint | Cross-region replica writer endpoint |
| replica_cluster_reader_endpoint | Cross-region replica reader endpoint |
| replica_instance_ids | Cross-region replica instance IDs |

## Parameter group defaults

**PostgreSQL:**
- `log_statement = ddl`: logs DDL statements so you can audit schema changes without drowning in DML noise
- `log_min_duration_statement = 1000`: logs queries slower than 1 second
- `rds.force_ssl = 1`: rejects unencrypted connections
- `shared_preload_libraries = pg_stat_statements`: enables query statistics

**MySQL:**
- `slow_query_log = 1`: enables the slow query log
- `long_query_time = 1`: threshold for slow query logging (seconds)
- `log_output = FILE`: writes slow query log to a file for CloudWatch export
- `require_secure_transport = ON`: rejects unencrypted connections

You can override or extend any of these via `cluster_parameters` and `db_parameters`.

## Secret rotation

Setting `enable_rotation = true` creates a placeholder Lambda. For actual rotation, deploy the AWS-managed rotator from the Serverless Application Repository (SAR):

```
arn:aws:serverlessrepo:us-east-1:912272126732:applications/SecretsManagerRDSPostgreSQLRotationSingleUser
```

Then pass its ARN directly and skip the placeholder Lambda. The SAR application handles the VPC config, IAM permissions, and the actual rotation logic.

## Cross-region replication

When `enable_cross_region_replica = true`:
1. Configure the `aws.replica` provider to point at `replica_region`.
2. Provide `replica_subnet_ids` (subnets in the replica region).
3. The replica cluster uses the same engine version, parameter defaults, and Performance Insights settings as the primary.
4. A `replica-lag` CloudWatch alarm fires if replication lag exceeds 30 seconds.

The replica cluster's `kms_key_id` must exist in the replica region. If you're using a custom KMS key, create one in the replica region separately and pass its ARN.

## IAM authentication

When `enable_iam_auth = true`, grant an IAM role or user the `rds-db:connect` action:

```json
{
  "Effect": "Allow",
  "Action": "rds-db:connect",
  "Resource": "arn:aws:rds-db:<region>:<account>:dbuser/<cluster_resource_id>/<db_username>"
}
```

`cluster_resource_id` is available via the `cluster_resource_id` output.

## Destruction

1. Set `deletion_protection = false` and apply.
2. If `skip_final_snapshot = false` (the default), RDS takes a final snapshot before deletion. The snapshot name includes a timestamp.
3. Run `terraform destroy`.

Don't skip step 1. Terraform can't destroy a cluster with deletion protection enabled.
