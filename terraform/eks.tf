module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.36"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Public endpoint enables direct kubectl access from any machine with valid
  # AWS credentials. Locked to allowed_cidr_blocks (default: your IP only).
  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.allowed_cidr_blocks

  # Grant the Terraform caller cluster-admin during provisioning.
  enable_cluster_creator_admin_permissions = true

  # Control plane logs — every API call, authentication attempt, and audit
  # event is shipped to CloudWatch. Gives full visibility even with a public
  # endpoint: you can see who did what, when, and from which IAM identity.
  cluster_enabled_log_types = ["audit", "authenticator", "api"]

  # KMS envelope encryption for Kubernetes Secrets. The module creates a
  # customer-managed key automatically. Every secret decryption is logged in
  # CloudTrail and access can be revoked instantly by disabling the key.
  create_kms_key = true
  cluster_encryption_config = {
    resources = ["secrets"]
  }

  # Optional: map an IAM principal to the Kubernetes 'developers' group.
  # The developer ClusterRole + RoleBinding (rbac.tf) then scopes what they can do.
  access_entries = var.developer_iam_arn != "" ? {
    developer = {
      principal_arn     = var.developer_iam_arn
      kubernetes_groups = ["developers"]
    }
  } : {}

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns                = { most_recent = true }
    vpc-cni                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
  }

  # System node group — permanent on-demand nodes that run Karpenter and
  # core add-ons. Must exist before Karpenter can provision workload nodes.
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3a.medium", "t3.medium"]

      min_size     = 1
      max_size     = 3
      desired_size = 2

      labels = { role = "system" }

      # Prevent general workloads from landing on system nodes.
      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  # Karpenter discovers the node security group via this tag.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })
}

