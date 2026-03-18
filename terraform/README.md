# EKS + Karpenter — Terraform

Deploys a VPC, EKS cluster, and Karpenter with **x86** and **arm64 (Graviton)** node pools. One `terraform apply` creates everything.

---

## Prerequisites

- Terraform >= 1.9
- AWS CLI v2 configured (`aws configure`)
- kubectl

---

## 1. Configure

Get your public IP and set it as the API endpoint allowlist:

```bash
curl -s https://checkip.amazonaws.com
```

```hcl
# terraform.tfvars
allowed_cidr_blocks = ["YOUR_IP/32"]
```

> If your IP changes, update this value and run `terraform apply` again.

---

## 2. Deploy

```bash
terraform init
terraform apply   # ~15 min
```

---

## 3. Connect kubectl

```bash
$(terraform output -raw update_kubeconfig_command)
```

Verify nodes are ready:

```bash
kubectl get nodes -L kubernetes.io/arch,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```

---

## 4. Developer demo — x86 and Graviton scheduling with RBAC

The `dev` namespace and a scoped `developer` RBAC role are deployed automatically. The demo below uses kubectl impersonation (`--as-group=developers`) to simulate a developer operating under that role — no second IAM user required.

### Verify the developer role exists

```bash
kubectl get clusterrole developer
kubectl describe rolebinding developer -n dev
```

### Deploy on x86 as a developer

```bash
kubectl run nginx-x86 --image=nginx -n dev \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"}}}' \
  --as=dev-user --as-group=developers
```

### Deploy on arm64 (Graviton) as a developer

```bash
kubectl run nginx-arm64 --image=nginx -n dev \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"arm64"}}}' \
  --as=dev-user --as-group=developers
```

### Deploy on On-Demand (workloads that cannot tolerate interruption)

For stateful or critical workloads that cannot be interrupted by Spot eviction:

```bash
kubectl run nginx-ondemand --image=nginx -n dev \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64","karpenter.sh/capacity-type":"on-demand"}}}' \
  --as=dev-user --as-group=developers
```

> Karpenter provisions a dedicated On-Demand node for this pod. It will never be evicted by AWS.

### Watch Karpenter provision the nodes

```bash
kubectl get nodes -w -L kubernetes.io/arch,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```

A new node appears within ~60 seconds. The `ARCH` and `CAPACITYTYPE` columns confirm architecture and whether it is Spot or On-Demand.

### Verify pods landed on the right architecture

```bash
kubectl get pods -n dev -o wide --as=dev-user --as-group=developers
```

Cross-reference the `NODE` column with `kubectl get nodes` to confirm placement.

---

## 5. Developer guardrails

The developer role is scoped to the `dev` namespace only. Attempting anything outside that scope is blocked:

```bash
# Allowed — workloads in dev namespace
kubectl auth can-i create deployments -n dev \
  --as=dev-user --as-group=developers
# yes

# Blocked — system namespace is off limits
kubectl auth can-i get pods -n kube-system \
  --as=dev-user --as-group=developers
# no

# Blocked — secrets are not in the developer role
kubectl auth can-i get secrets -n dev \
  --as=dev-user --as-group=developers
# no

# Blocked — cannot touch cluster infrastructure
kubectl auth can-i delete nodes \
  --as=dev-user --as-group=developers
# no
```

---

## 6. Grant a real developer access

To map an actual IAM identity to the developer role, add their ARN to `terraform.tfvars` and re-apply:

```hcl
developer_iam_arn = "arn:aws:iam::123456789012:role/developer-role"
```

```bash
terraform apply
```

The IAM principal is mapped to the `developers` Kubernetes group and inherits the scoped role automatically.

---

## Clean up

```bash
kubectl delete pod nginx-x86 nginx-arm64 nginx-ondemand -n dev --ignore-not-found
# Karpenter removes idle nodes automatically within ~1 min

terraform destroy
```

