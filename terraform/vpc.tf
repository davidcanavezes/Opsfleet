module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  # Private /20 subnets — enough headroom for Karpenter to scale aggressively.
  # 10.0.0.0/20, 10.0.16.0/20, 10.0.32.0/20
  private_subnets = [for k, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]

  # Public /24 subnets — used by the ALB only.
  # 10.0.48.0/24, 10.0.49.0/24, 10.0.50.0/24
  public_subnets = [for k, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # Set false for production HA (one NAT GW per AZ).
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required by the AWS Load Balancer Controller to discover subnets.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter uses this tag to discover subnets when launching nodes.
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = local.tags
}

