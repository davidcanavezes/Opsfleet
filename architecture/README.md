# Innovate Inc. — Cloud Architecture

**Stack:** React SPA · Python/Flask REST API · PostgreSQL
**Platform:** AWS · EKS · CloudFront · Aurora PostgreSQL Serverless v2

---

## Assignment coverage

| Question | Section |
|---|---|
| Optimal number of AWS accounts | §1 |
| Isolation, billing, management | §1 |
| VPC architecture | §2 |
| How the network is secured | §2 |
| Kubernetes deployment and management | §3 |
| Node groups, scaling, resource allocation | §3 |
| Containerisation — build, registry, deploy | §4 |
| PostgreSQL service recommendation | §5 |
| Backups, HA, and disaster recovery | §5 |
| High-level diagram | §6 |

---

## The architecture in one paragraph

The React frontend is a static SPA — it lives on S3 and is delivered globally through CloudFront. The Flask API runs on EKS, accessed through an Application Load Balancer. The database is Aurora PostgreSQL Serverless v2, sitting in isolated subnets with no internet route. GitHub Actions builds and scans container images, ArgoCD deploys them to the cluster. Karpenter automatically provisions the right nodes — including Graviton and Spot instances — as demand grows.

---

## 1. Account structure

**4 AWS accounts via AWS Organizations.**

```
Management / Shared Services   billing, ECR, SSO, audit logs
Development                    dev workloads, engineer sandboxes
Staging                        production mirror — QA and load testing
Production                     live customer traffic — most restricted
```

**Why not one account?** A bug or misconfiguration in dev cannot touch production data. Costs are visible per environment. Strict security policies (SCPs) can be applied to production without blocking developer work. 4 accounts is the right balance for a small team — enough isolation without the overhead of managing more.

**Access:**
- AWS IAM Identity Center (SSO) — no shared passwords, no long-lived access keys
- CI/CD uses OIDC federation — GitHub Actions assumes an IAM role directly, no stored secrets
- SCPs block `iam:CreateUser` and enforce MFA organisation-wide

---

## 2. Network design

### VPC layout

One VPC per environment. Three tiers with hard network boundaries:

```
VPC  10.0.0.0/16  (eu-central-1, 3 AZs)

  Public subnets   /24 × 3    ALB, NAT Gateway        internet-facing
  Private subnets  /20 × 3    EKS worker nodes         no direct internet
  Isolated subnets /24 × 3    Aurora PostgreSQL         zero internet route
```

### How requests flow

```
Frontend:
  User → Route 53 → WAF → CloudFront → S3  (React SPA assets)

API:
  User → Route 53 → ALB → Flask pods → Aurora PostgreSQL
```

The React SPA is loaded by the user's browser from CloudFront/S3. Once loaded, it makes API calls directly to the ALB. These are two completely separate paths.

### Network security

Layered controls:

| Layer | Control |
|---|---|
| Edge | CloudFront enforces HTTPS. WAF blocks DDoS, bots, and bad actors before they reach infrastructure. |
| Load Balancer | ALB only accepts HTTPS (443). WAF is also attached here for API-level protection. |
| Security Groups | Flask pods only accept traffic from the ALB. Aurora only accepts TCP 5432 from the Flask pod security group. Nothing else. |
| Kubernetes Network Policies | Default-deny-all in every namespace. Only explicitly permitted flows are allowed — see below. |
| Isolated subnets | Aurora's route table has no `0.0.0.0/0` entry. Unreachable from the internet by design. |
| NAT Gateway | Private subnets can make outbound calls (ECR pulls, AWS APIs) but nothing can reach in. |

### Kubernetes Network Policies — default-deny model

Every namespace starts with a policy that denies all ingress and egress. Explicit allow rules are then added only for what is needed:

| Allowed flow | Reason |
|---|---|
| ALB → Flask pods :8000 | Serve API requests |
| Flask pods → Aurora :5432 | Database queries |
| Flask pods → DNS :53 | Name resolution |
| Flask pods → Secrets Manager (AWS API, via Pod Identity) | Secret fetching — outbound via NAT Gateway or VPC endpoint |
| Prometheus scrape → app pods | Metrics collection |

A compromised pod cannot make arbitrary network calls. It is contained at the pod level, independent of VPC controls.

---

## 3. Kubernetes platform

### Why EKS?

EKS is a managed Kubernetes service. AWS operates the control plane — no etcd to manage, no API server to patch. The team only manages what runs inside the cluster.

### Cluster design

| Component | Choice | Why |
|---|---|---|
| Kubernetes | Latest stable EKS version | Managed control plane, always patched |
| Node provisioner | Karpenter | Provisions capacity quickly, prefers Spot, consolidates underused nodes |
| System nodes | On-demand `t3a.medium`, tainted | Always available for Karpenter, CoreDNS, ArgoCD — app pods cannot land here |
| Workload nodes | Karpenter-provisioned | Right-sized per workload; Spot-preferred (40–70% cheaper) |
| Architectures | amd64 + arm64 (Graviton) | Graviton offers ~20–30% better price-performance |

### Scaling

- HPA scales Flask pods horizontally when CPU hits 60%
- Karpenter provisions a new node if no capacity exists — typically within about a minute
- Consolidation — Karpenter removes underused nodes continuously, keeping costs tight
- Aurora Serverless v2 scales database capacity automatically — no manual resize

### Namespace layout

| Namespace | What runs there |
|---|---|
| `kube-system` | Karpenter, CoreDNS, AWS Load Balancer Controller |
| `platform` | External Secrets Operator, cert-manager, ExternalDNS |
| `argocd` | ArgoCD |
| `monitoring` | CloudWatch agent (day one) → Prometheus + Grafana (when scale justifies it) |
| `app` | Flask API pods |

### Resource allocation

| Component | CPU request | CPU limit | Memory request | Memory limit |
|---|---|---|---|---|
| Flask API pod | 100m | 500m | 128Mi | 512Mi |
| System components | Set by upstream Helm charts | — | — | — |

Requests are what Kubernetes uses for scheduling decisions. Limits cap what a pod can actually consume — a runaway pod cannot starve its neighbours. PodDisruptionBudgets ensure at least one Flask pod remains available during node drains.

**RBAC:** `cluster-admin` for the platform team only. `developer` role scoped to deploy and view logs in their own namespace. All RBAC is managed via Terraform — no ad-hoc permissions.

---

## 4. Containerisation and CI/CD

### How images are built

Multi-stage Dockerfile — keeps the runtime image lean (no build tools, no pip cache):

```dockerfile
FROM python:3.12-slim AS builder
RUN pip install --prefix=/install -r requirements.txt

FROM python:3.12-slim AS runtime
COPY --from=builder /install /usr/local
COPY src/ .
USER nonroot
ENTRYPOINT ["gunicorn", "-w", "4", "-b", "0:8000", "app:app"]
```

Multi-arch build so the same image runs on both x86 and Graviton nodes:

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  --tag $ECR_URI/backend:$GIT_SHA --push .
```

### Registry — Amazon ECR

- One repo per service in the Shared Services account
- Lifecycle policy: keep last 30 images, delete untagged after 1 day
- Amazon Inspector scans every push — CI fails on HIGH/CRITICAL CVEs
- Production always uses immutable Git SHA tags — never `latest`

### CI/CD pipeline

```
Pull Request   →  lint → unit tests → build (multi-arch) → scan → push to ECR
Merge to main  →  all above → integration tests → update image reference in GitOps repo
                                      ↓
                              ArgoCD detects change → rolling deploy in ~2 min
```

No `kubectl` in CI. Rollback = revert the GitOps config commit. ArgoCD reconciles within 2 minutes.

---

## 5. Database

### Recommendation: Aurora PostgreSQL Serverless v2

Aurora Serverless v2 balances operational simplicity with autoscaling:

| Factor | Aurora Serverless v2 | Standard RDS PostgreSQL |
|---|---|---|
| Failover | ~30 s, automatic | ~60–120 s |
| Scaling | Instant, 0.5–128 ACU, zero downtime | Manual resize with downtime |
| Idle cost | ~$0.06/hr at 0.5 ACU | ~$0.02/hr (db.t4g.micro) |
| Ops overhead | Near-zero | Low |

**Why Serverless v2 for this startup:** traffic is unpredictable and the team is small. Serverless v2 handles sudden spikes automatically and costs almost nothing when idle.

**Key configuration:**
- Writer in AZ-a, Reader in AZ-b — automatic failover, reader promoted in ~30 s
- Isolated subnets only — no internet route
- IAM database authentication — pods get short-lived tokens, no passwords in environment variables
- Connection pooling via SQLAlchemy; RDS Proxy added if concurrency exceeds ~100 connections

### Backups

| What | How | Retention |
|---|---|---|
| Database | Aurora continuous backup (point-in-time restore) | 35 days |
| Cross-region DR | Nightly snapshot copy to eu-west-1 | 7 days |
| Kubernetes state | Velero daily snapshots to S3 | 30 days |
| Frontend assets | S3 versioning | Last 10 versions |


### Architecture
<img width="1623" height="803" alt="innovate_inc_arch drawio" src="https://github.com/user-attachments/assets/d57084d6-46f8-43fa-bf11-216b5e4ec042" />



### HA and DR

| Failure scenario | RPO | RTO | How |
|---|---|---|---|
| Pod crash | 0 | < 1 min | Kubernetes restarts automatically |
| Node failure | 0 | < 5 min | Karpenter replaces; PDB keeps service alive |
| AZ failure | 0 | < 5 min | Multi-AZ nodes + Aurora reader in separate AZ |
| Full region failure | ≤ 5 min | < 1 hr | Route 53 failover + Aurora cross-region restore |

**Region DR in brief:** flip Route 53 → `terraform apply` in DR region → restore Aurora from snapshot → ArgoCD syncs workloads → smoke tests.

---

## Security at a glance

Security is layered — no single failure exposes the system:

| Layer | Controls applied |
|---|---|
| Edge | CloudFront + WAF — HTTPS enforcement, rate limiting, DDoS protection |
| Network | VPC security groups, isolated subnets, NAT Gateway (outbound-only) |
| Kubernetes | Network Policies (default-deny), Pod Security Standards (no root), PodDisruptionBudgets |
| Identity | EKS Pod Identity for AWS API access, OIDC for CI/CD, no long-lived credentials |
| Secrets | Secrets Manager + External Secrets Operator — nothing in manifests or CI logs |
| Data | TLS 1.2+ everywhere, KMS CMK for Aurora storage, EKS etcd encryption, S3 SSE |
| CI/CD | CVE scanning on every push, immutable SHA tags, no manual `kubectl` in pipelines |

---

## 6. Architecture diagram

<img width="1623" height="803" alt="innovate_inc_arch_updated drawio" src="https://github.com/user-attachments/assets/38cf4e62-9a0f-4954-95ea-be72a5ba2891" />

