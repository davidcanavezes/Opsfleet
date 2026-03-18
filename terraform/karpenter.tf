# =============================================================================
# Karpenter
#
# Deployment order:
#   1. module.karpenter  — IAM roles, SQS interruption queue, EventBridge rules
#   2. helm_release      — Karpenter controller (v1.9.0)
#   3. EC2NodeClass      — shared node template (AMI, subnets, SGs)
#   4. NodePool x86      — amd64 / Intel / AMD nodes
#   5. NodePool arm64    — Graviton nodes
# =============================================================================

# ── 1. IAM / SQS / EventBridge ───────────────────────────────────────────────

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.36"

  cluster_name = module.eks.cluster_name

  # EKS Pod Identity — no IRSA annotation needed on the service account.
  enable_pod_identity             = true
  create_pod_identity_association = true

  # SSM policy lets Karpenter-launched nodes be managed via Session Manager.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

# ── 2. Karpenter Helm release ─────────────────────────────────────────────────

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "kube-system"
  create_namespace = false

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.9.0"

  # Don't block Terraform waiting for pods to be ready — nodes may still be
  # joining when the chart is installed. Karpenter starts on its own schedule.
  wait    = false
  timeout = 300

  values = [yamlencode({
    serviceAccount = {
      name = module.karpenter.service_account
    }
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    tolerations = [{
      key      = "CriticalAddonsOnly"
      operator = "Exists"
    }]
    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{
            matchExpressions = [{
              key      = "role"
              operator = "In"
              values   = ["system"]
            }]
          }]
        }
      }
    }
  })]

  depends_on = [module.karpenter]
}

# ── 3. EC2NodeClass ───────────────────────────────────────────────────────────

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiSelectorTerms:
        - alias: al2023@latest
      role: ${module.karpenter.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      tags:
        Environment: ${var.environment}
  YAML

  depends_on = [helm_release.karpenter]
}

# ── 4. NodePool: x86 (amd64) ─────────────────────────────────────────────────

resource "kubectl_manifest" "karpenter_node_pool_x86" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: x86
    spec:
      template:
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: karpenter.k8s.aws/instance-family
              operator: In
              values: ["m5", "m5a", "m6i", "m6a", "c5", "c6i", "t3", "t3a"]
            - key: karpenter.k8s.aws/instance-size
              operator: NotIn
              values: ["nano", "micro", "small"]
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
      limits:
        cpu: "100"
        memory: 400Gi
  YAML

  depends_on = [kubectl_manifest.karpenter_node_class]
}

# ── 5. NodePool: arm64 (Graviton) ─────────────────────────────────────────────

resource "kubectl_manifest" "karpenter_node_pool_arm64" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: arm64
    spec:
      template:
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: karpenter.k8s.aws/instance-family
              operator: In
              values: ["m6g", "m7g", "c6g", "c7g", "r6g", "r7g", "t4g"]
            - key: karpenter.k8s.aws/instance-size
              operator: NotIn
              values: ["nano", "micro", "small"]
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
      limits:
        cpu: "100"
        memory: 400Gi
  YAML

  depends_on = [kubectl_manifest.karpenter_node_class]
}

