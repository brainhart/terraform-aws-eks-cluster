locals {
  create_eks_service_role = local.enabled && var.create_eks_service_role

  eks_service_role_arn = local.create_eks_service_role ? one(aws_iam_role.default[*].arn) : var.eks_cluster_service_role_arn
}

data "aws_iam_policy_document" "assume_role" {
  count = local.create_eks_service_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"] # NOTE: auto mode requires TagSession (https://docs.aws.amazon.com/eks/latest/userguide/auto-cluster-iam-role.html)

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "default" {
  count = local.create_eks_service_role ? 1 : 0

  name                 = module.label.id
  assume_role_policy   = one(data.aws_iam_policy_document.assume_role[*].json)
  tags                 = module.label.tags
  permissions_boundary = var.permissions_boundary
}

resource "aws_iam_role_policy_attachment" "amazon_eks_cluster_policy" {
  count = local.create_eks_service_role ? 1 : 0

  policy_arn = format("arn:%s:iam::aws:policy/AmazonEKSClusterPolicy", one(data.aws_partition.current[*].partition))
  role       = one(aws_iam_role.default[*].name)
}

resource "aws_iam_role_policy_attachment" "amazon_eks_service_policy" {
  count = local.create_eks_service_role ? 1 : 0

  policy_arn = format("arn:%s:iam::aws:policy/AmazonEKSServicePolicy", one(data.aws_partition.current[*].partition))
  role       = one(aws_iam_role.default[*].name)
}

resource "aws_iam_role_policy_attachment" "amazon_eks_compute_policy" {
  count = local.create_eks_service_role && local.auto_mode_enabled ? 1 : 0

  policy_arn = format("arn:%s:iam::aws:policy/AmazonEKSComputePolicy", one(data.aws_partition.current[*].partition))
  role       = one(aws_iam_role.default[*].name)
}

resource "aws_iam_role_policy_attachment" "amazon_eks_block_storage_policy" {
  count = local.create_eks_service_role && local.auto_mode_enabled ? 1 : 0

  policy_arn = format("arn:%s:iam::aws:policy/AmazonEKSBlockStoragePolicy", one(data.aws_partition.current[*].partition))
  role       = one(aws_iam_role.default[*].name)
}

resource "aws_iam_role_policy_attachment" "amazon_eks_load_balancing_policy" {
  count = local.create_eks_service_role && local.auto_mode_enabled ? 1 : 0

  policy_arn = format("arn:%s:iam::aws:policy/AmazonEKSLoadBalancingPolicy", one(data.aws_partition.current[*].partition))
  role       = one(aws_iam_role.default[*].name)
}


resource "aws_iam_role_policy_attachment" "amazon_eks_networking_policy" {
  count = (local.create_eks_service_role && local.auto_mode_enabled) ? 1 : 0

  policy_arn = format("arn:%s:iam::aws:policy/AmazonEKSNetworkingPolicy", one(data.aws_partition.current[*].partition))
  role       = one(aws_iam_role.default[*].name)
}

# AmazonEKSClusterPolicy managed policy doesn't contain all necessary permissions to create
# ELB service-linked role required during LB provisioning by Kubernetes.
# Because of that, on a new AWS account (where load balancers have not been provisioned yet, `nginx-ingress` fails to provision a load balancer

data "aws_iam_policy_document" "cluster_elb_service_role" {
  count = local.create_eks_service_role ? 1 : 0

  statement {
    sid    = "AllowElasticLoadBalancer"
    effect = "Allow"
    #bridgecrew:skip=BC_AWS_IAM_57:There is no workable constraint to add to this policy
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeInternetGateways",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSubnets"
    ]
    resources = ["*"]
  }
  # Adding a policy to cluster IAM role that deny permissions to logs:CreateLogGroup
  # it is not needed since we create the log group elsewhere in this module, and it is causing trouble during "destroy"
  statement {
    sid    = "DenyCreateLogGroup"
    effect = "Deny"
    actions = [
      "logs:CreateLogGroup"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "cluster_elb_service_role" {
  count = local.create_eks_service_role ? 1 : 0

  name   = "${module.label.id}-ServiceRole"
  policy = one(data.aws_iam_policy_document.cluster_elb_service_role[*].json)

  tags = module.this.tags
}

resource "aws_iam_role_policy_attachment" "cluster_elb_service_role" {
  count = local.create_eks_service_role ? 1 : 0

  policy_arn = one(aws_iam_policy.cluster_elb_service_role[*].arn)
  role       = one(aws_iam_role.default[*].name)
}



################################################################################
# EKS Auto Node IAM Role
################################################################################
# https://docs.aws.amazon.com/eks/latest/userguide/auto-create-node-role.html#id_check_for_an_existing_node_role

locals {
  create_node_iam_role = local.create_eks_service_role && local.auto_mode_enabled
}

data "aws_iam_policy_document" "node_assume_role_policy" {
  count = local.create_eks_service_role ? 1 : 0

  statement {
    sid = "EKSAutoNodeAssumeRole"
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  count = local.create_eks_service_role ? 1 : 0

  name        = "${module.label.id}-eks-auto-role"

  assume_role_policy    = data.aws_iam_policy_document.node_assume_role_policy[0].json

  tags                 = module.label.tags
}

# Policies attached ref https://docs.aws.amazon.com/eks/latest/userguide/service_IAM_role.html
resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = { for k, v in {
    AmazonEKSWorkerNodeMinimalPolicy   = format("arn:%s:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy", one(data.aws_partition.current[*].partition))
    AmazonEC2ContainerRegistryPullOnly = format("arn:%s:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly", one(data.aws_partition.current[*].partition))
  } : k => v if local.create_eks_service_role }

  policy_arn = each.value
  role       = aws_iam_role.eks_node[0].name
}
