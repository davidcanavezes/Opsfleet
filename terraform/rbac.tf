# =============================================================================
# Developer RBAC
#
# Pattern: ClusterRole (permissions) + RoleBinding (scope to dev namespace)
# =============================================================================

resource "kubectl_manifest" "namespace_dev" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: dev
      labels:
        environment: ${var.environment}
  YAML
}

# What a developer can do — deploy and inspect workloads in dev namespace only.
resource "kubectl_manifest" "developer_cluster_role" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: developer
    rules:
      - apiGroups: [""]
        resources: ["pods", "pods/log", "pods/exec"]
        verbs: ["get", "list", "watch", "create", "delete"]
      - apiGroups: ["apps"]
        resources: ["deployments", "replicasets"]
        verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
      - apiGroups: [""]
        resources: ["services", "events", "configmaps"]
        verbs: ["get", "list", "watch"]
      - apiGroups: [""]
        resources: ["nodes"]
        verbs: ["get", "list", "watch"]
  YAML
}

# Bind to the 'developers' Kubernetes group — scoped to the dev namespace.
resource "kubectl_manifest" "developer_role_binding" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: developer
      namespace: dev
    subjects:
      - kind: Group
        name: developers
        apiGroup: rbac.authorization.k8s.io
    roleRef:
      kind: ClusterRole
      name: developer
      apiGroup: rbac.authorization.k8s.io
  YAML

  depends_on = [
    kubectl_manifest.namespace_dev,
    kubectl_manifest.developer_cluster_role,
  ]
}

