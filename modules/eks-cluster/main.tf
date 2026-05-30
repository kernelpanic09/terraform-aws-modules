data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  dns_suffix  = data.aws_partition.current.dns_suffix
  region      = data.aws_region.current.name
  common_tags = merge(var.tags, { ManagedBy = "terraform", Module = "eks-cluster" })

  # OIDC issuer without the https:// prefix (used in IAM trust policies)
  oidc_issuer_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# ------------------------------------------------------------------------------
# KMS key for envelope encryption of Kubernetes secrets
# ------------------------------------------------------------------------------

resource "aws_kms_key" "eks" {
  description             = "EKS cluster ${var.cluster_name} secrets encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowEKSClusterRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.cluster.arn
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-secrets-key" })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

# ------------------------------------------------------------------------------
# CloudWatch Log Group for control plane logs
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-control-plane-logs" })
}

# ------------------------------------------------------------------------------
# IAM role for the EKS cluster control plane
# ------------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EKSClusterAssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.${local.dns_suffix}"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-cluster-role" })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

# ------------------------------------------------------------------------------
# Cluster security group (primary, managed by EKS). extra rules
# ------------------------------------------------------------------------------

# EKS creates a "cluster security group" automatically. We add rules for
# node-to-control-plane communication on top of what EKS manages by default.

resource "aws_security_group" "cluster_additional" {
  name        = "${var.cluster_name}-cluster-additional-sg"
  description = "Additional security group rules for the EKS cluster ${var.cluster_name} control plane"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-cluster-additional-sg" })
}

# Allow nodes to communicate with the control plane API server
resource "aws_security_group_rule" "nodes_to_cluster_api" {
  type                     = "ingress"
  description              = "Nodes to control plane API server"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.cluster_additional.id
}

# Allow control plane to send webhook traffic to nodes (e.g. for admission webhooks)
resource "aws_security_group_rule" "cluster_to_nodes_webhooks" {
  type                     = "egress"
  description              = "Control plane to nodes for webhooks and extension API servers"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.cluster_additional.id
}

resource "aws_security_group_rule" "cluster_to_nodes_kubelet" {
  type                     = "egress"
  description              = "Control plane to node kubelets for exec, logs, and port-forward"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.cluster_additional.id
}

# ------------------------------------------------------------------------------
# Node security group
# ------------------------------------------------------------------------------

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node-sg"
  description = "Security group for EKS managed node groups in cluster ${var.cluster_name}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name                                        = "${var.cluster_name}-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# Nodes need to talk to each other (pod-to-pod communication within VPC CNI)
resource "aws_security_group_rule" "nodes_internal" {
  type              = "ingress"
  description       = "Node to node communication"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.node.id
}

# Nodes receive traffic from the control plane (kubelet, metrics-server, etc.)
resource "aws_security_group_rule" "cluster_to_nodes_all" {
  type                     = "ingress"
  description              = "Control plane to nodes (all ports)"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.cluster_additional.id
  security_group_id        = aws_security_group.node.id
}

# Nodes need egress to pull images, call AWS APIs, reach the control plane, etc.
resource "aws_security_group_rule" "nodes_egress" {
  type              = "egress"
  description       = "All outbound traffic from nodes"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node.id
}

# ------------------------------------------------------------------------------
# EKS cluster
# ------------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  access_config {
    # Use API access entries instead of the legacy aws-auth ConfigMap.
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
    security_group_ids      = [aws_security_group.cluster_additional.id]
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  # Ensure CloudWatch log group is created before the cluster so that
  # the first control plane log events are not lost.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController,
    aws_cloudwatch_log_group.eks,
  ]

  tags = merge(local.common_tags, { Name = var.cluster_name })
}

# ------------------------------------------------------------------------------
# OIDC provider for IRSA (IAM Roles for Service Accounts)
# ------------------------------------------------------------------------------

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.${local.dns_suffix}"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-oidc-provider" })
}

# ------------------------------------------------------------------------------
# IAM role for managed node groups
# ------------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EKSNodeAssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.${local.dns_suffix}"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-node-role" })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

# Required for the EBS CSI driver add-on
resource "aws_iam_role_policy_attachment" "node_AmazonEBSCSIDriverPolicy" {
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.node.name
}

# ------------------------------------------------------------------------------
# Managed node groups
# ------------------------------------------------------------------------------

resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = length(each.value.subnet_ids) > 0 ? each.value.subnet_ids : var.subnet_ids

  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type
  ami_type       = each.value.ami_type
  disk_size      = each.value.disk_size

  scaling_config {
    min_size     = each.value.min_size
    max_size     = each.value.max_size
    desired_size = each.value.desired_size
  }

  # Graceful upgrade strategy: surge one node at a time, zero unavailable.
  update_config {
    max_unavailable = 1
  }

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  labels = each.value.labels

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-${each.value.name}"
    # Required for cluster-autoscaler auto-discovery via autodiscovery tags.
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  })

  lifecycle {
    # Cluster Autoscaler manages desired_size at runtime; ignore Terraform drift.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# ------------------------------------------------------------------------------
# EKS add-ons
# ------------------------------------------------------------------------------

resource "aws_eks_addon" "this" {
  for_each = var.addons

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.key

  addon_version               = each.value.version
  resolve_conflicts_on_create = each.value.resolve_conflicts_on_create
  resolve_conflicts_on_update = each.value.resolve_conflicts_on_update
  configuration_values        = each.value.configuration_values
  preserve                    = each.value.preserve_on_delete

  depends_on = [aws_eks_node_group.this]

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-addon-${each.key}" })
}

# ------------------------------------------------------------------------------
# EKS access entries (API-mode, replaces aws-auth ConfigMap)
# ------------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principals)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-access-entry-admin"
  })
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principals)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# ------------------------------------------------------------------------------
# IRSA: AWS Load Balancer Controller (optional)
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "lb_controller_assume" {
  count = var.enable_lb_controller_irsa ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.lb_controller_namespace}:${var.lb_controller_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.${local.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  count = var.enable_lb_controller_irsa ? 1 : 0

  name               = "${var.cluster_name}-lb-controller-irsa"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume[0].json

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-lb-controller-irsa" })
}

# Inline policy granting permissions required by the AWS Load Balancer Controller.
# Based on the official policy from https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
resource "aws_iam_role_policy" "lb_controller" {
  count = var.enable_lb_controller_irsa ? 1 : 0

  name = "${var.cluster_name}-lb-controller-policy"
  role = aws_iam_role.lb_controller[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2DescribeForALB"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowElasticLoadBalancingManagement"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCognito"
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowACM"
        Effect = "Allow"
        Action = [
          "acm:ListCertificates",
          "acm:DescribeCertificate",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowIAMServerCertificates"
        Effect = "Allow"
        Action = [
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowWAFv2"
        Effect = "Allow"
        Action = [
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowShieldAdvanced"
        Effect = "Allow"
        Action = [
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowEC2SecurityGroupMutations"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowEC2SecurityGroupTaggedDeletion"
        Effect = "Allow"
        Action = [
          "ec2:DeleteSecurityGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/elbv2.k8s.aws/cluster" = var.cluster_name
          }
        }
      },
      {
        Sid    = "AllowEC2TaggingForLoadBalancers"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags",
        ]
        Resource = "arn:${local.partition}:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
    ]
  })
}

# ------------------------------------------------------------------------------
# IRSA: Cluster Autoscaler (optional)
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_autoscaler_assume" {
  count = var.enable_cluster_autoscaler_irsa ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.cluster_autoscaler_namespace}:${var.cluster_autoscaler_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.${local.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  count = var.enable_cluster_autoscaler_irsa ? 1 : 0

  name               = "${var.cluster_name}-cluster-autoscaler-irsa"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume[0].json

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-cluster-autoscaler-irsa" })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  count = var.enable_cluster_autoscaler_irsa ? 1 : 0

  name = "${var.cluster_name}-cluster-autoscaler-policy"
  role = aws_iam_role.cluster_autoscaler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AutoscalerDescribe"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        # Autoscaler may only modify ASGs that belong to this cluster.
        Sid    = "AutoscalerMutateOwnedGroups"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"             = "true"
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
      },
    ]
  })
}
