# RBIH Payments — DevOps Take-Home Challenge

> **Two Go microservices** (`payment-gateway` + `payment-processor`) deployed on **AWS EKS** with production-grade CI/CD, security hardening, observability, and reliability.

---

## 📋 Table of Contents

- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Quick Start — Local (kind)](#quick-start--local-kind)
- [Quick Start — AWS EKS](#quick-start--aws-eks)
- [Access the Application](#access-the-application)
- [CI/CD Pipeline (GitHub Actions)](#cicd-pipeline-github-actions)
- [Observability — Prometheus & Grafana](#observability--prometheus--grafana)
- [Security Design](#security-design)
- [Reliability Features](#reliability-features)
- [API Reference](#api-reference)
- [Troubleshooting](#troubleshooting)
- [Design Decisions](#design-decisions)

---

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │              payments namespace              │
                        │                                              │
  [Browser / curl]      │   ┌─────────────────┐                       │
  POST /pay    ──────────►  │ payment-gateway  │                       │
  GET  /healthz          │  │   :8080          │──► payment-processor  │
  GET  /metrics          │  │   (NodePort)     │        :8080          │
                        │  └─────────────────┘   (ClusterIP only)    │
                        │           │                    │             │
                        └───────────┼────────────────────┼─────────────┘
                                    │                    │
                        ┌───────────▼────────────────────▼─────────────┐
                        │           monitoring namespace                │
                        │                                              │
                        │   ┌─────────────┐    ┌──────────────┐        │
                        │   │  Prometheus │    │   Grafana    │        │
                        │   │  :9090      │───►│   :3000      │        │
                        │   │  NodePort   │    │   NodePort   │        │
                        │   └─────────────┘    └──────────────┘        │
                        └──────────────────────────────────────────────┘
```

- Services communicate **within the cluster only** via Kubernetes DNS (`http://payment-processor:8080`)
- **Network Policies** enforce zero-trust: processor is unreachable from anything except the gateway
- **Prometheus** scrapes metrics from both services every 15s
- **Grafana** auto-provisions dashboards from ConfigMaps

---

## Repository Structure

```
rbih-payments/
├── services/
│   ├── payment-gateway/
│   │   ├── main.py          # HTTP gateway — forwards POST /pay → processor
│   │   ├── requirements.txt
│   │   └── Dockerfile          # Multi-stage, scratch image, non-root UID 65534
│   └── payment-processor/
│       ├── main.py            # Processes payments, returns transaction ID
│       ├── requirements.txt
│       └── Dockerfile
│
├── k8s/
│   ├── base/
│   │   ├── namespace.yaml      # payments namespace
│   │   ├── payment-gateway.yaml    # Deployment + Service + ServiceAccount
│   │   ├── payment-processor.yaml
│   │   ├── reliability.yaml        # HPA + PodDisruptionBudgets
│   │   └── nodeport.yaml           # NodePort service for external access
│   ├── network-policy/
│   │   └── network-policies.yaml   # Default deny-all + explicit allow rules
│   └── monitoring/
│       └── monitoring.yaml         # Prometheus + Grafana + alert rules
│
├── .github/
│   └── workflows/
│       └── main.yaml         # Full CI/CD: Build → Scan → Approve → Deploy
│
├── scripts/
│   └── setup.sh               # Full local cluster setup (kind + registry)
└── README.md
```

---

## Prerequisites

### Local Development
| Tool | Version | Install |
|------|---------|---------|
| Docker | 20+ | [docs.docker.com](https://docs.docker.com/get-docker/) |
| kind | 0.20+ | `brew install kind` or [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| kubectl | 1.28+ | `brew install kubectl` |
| curl + jq | any | `brew install curl jq` |

### AWS EKS Deployment
| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | v2 | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| eksctl | 0.170+ | `brew tap weaveworks/tap && brew install eksctl` |
| kubectl | 1.28+ | `brew install kubectl` |

---
# 1. AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version

# 2. kubectl
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client

# 3. eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin/
eksctl version

# 4. Docker
sudo apt-get update
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
docker --version

---

aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region: ap-south-1
# Default output format: json

# Verify
aws sts get-caller-identity

---

 EKS Cluster Setup
Create EKS Cluster
eksctl create cluster \
  --name rbih-paymets \
  --region ap-south-1 \
  --nodegroup-name banking-nodes \
  --node-type t3.small \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 4 \
  --managed

# Takes ~15-20 minutes
# Automatically updates ~/.kube/config
Verify Cluster
kubectl get nodes
kubectl get nodes --show-labels
kubectl cluster-info

--
## Quick Start — Local (kind)

```bash
# 1. Clone the repo
git clone https://github.com/shivaram1918/rbih-payments.git
cd rbih-payments

# 2. Run the full local setup (creates kind cluster, builds images, deploys)
chmod +x scripts/setup.sh
./scripts/setup.sh
```

The script does the following automatically:
1. Starts a local Docker registry on port `5001`
2. Creates a 3-node kind cluster (1 control-plane + 2 workers)
3. Builds and pushes both service images to the local registry
4. Deploys all Kubernetes manifests in the correct order
5. Runs a smoke test to verify everything is working

### Verify locally

```bash
# Port-forward the gateway
kubectl port-forward svc/payment-gateway 8080:8080 -n payments

# Test a payment
curl -X POST http://localhost:8080/pay \
  -H "Content-Type: application/json" \
  -d '{"amount": 1500.00, "currency": "INR", "reference": "order-001"}'
```

---

## Quick Start — AWS EKS

### Step 1 — Configure AWS credentials

```bash
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region: ap-south-1
# Default output format: json
```

### Step 2 — Connect to the existing EKS cluster

```bash
aws eks update-kubeconfig \
  --region ap-south-1 \
  --name rbih-payments

# Verify connection
kubectl get nodes
```

### Step 3 — Deploy all manifests

```bash
# Apply in dependency order
kubectl apply -f k8s/base/namespace.yaml
kubectl apply -f k8s/network-policy/network-policies.yaml
kubectl apply -f k8s/monitoring/monitoring.yaml
kubectl apply -f k8s/base/payment-processor.yaml
kubectl apply -f k8s/base/payment-gateway.yaml
kubectl apply -f k8s/base/reliability.yaml
kubectl apply -f k8s/base/nodeport.yaml

# Wait for rollout
kubectl rollout status deployment/payment-processor -n payments --timeout=120s
kubectl rollout status deployment/payment-gateway   -n payments --timeout=120s
kubectl rollout status deployment/prometheus        -n monitoring --timeout=120s
kubectl rollout status deployment/grafana           -n monitoring --timeout=120s
```

### Step 4 — Verify all pods are running

```bash
kubectl get pods -n payments
kubectl get pods -n monitoring
```

Expected output:
```
NAMESPACE    NAME                                 READY   STATUS    RESTARTS
payments     payment-gateway-xxxxx-xxxxx          1/1     Running   0
payments     payment-processor-xxxxx-xxxxx        1/1     Running   0
monitoring   prometheus-xxxxx-xxxxx               1/1     Running   0
monitoring   grafana-xxxxx-xxxxx                  1/1     Running   0
```

---

## Access the Application

> **EC2 Node IP:** `43.205.91.169`

| Service | URL | Credentials |
|---------|-----|-------------|
| 🌐 Payment Gateway | http://43.205.91.169:30080 | — |
| ❤️ Health Check | http://43.205.91.169:30080/healthz | — |
| 📊 Metrics | http://43.205.91.169:30080/metrics | — |
| 📈 Grafana | http://43.205.91.169:32710 | `admin` / `rbih@admin2026` |
| 🔥 Prometheus | http://43.205.91.169:30091 | — |

### Workstation / EC2 Access on Port 8888

To access the app on port `8888` from your workstation or an EC2 instance:

```bash
# Option 1 — kubectl port-forward (no firewall changes needed)
kubectl port-forward svc/payment-gateway 8888:8080 -n payments --address 0.0.0.0

# Now accessible at:
# http://<your-workstation-ip>:8888
# http://43.205.91.169:8888  (from EC2)

# Option 2 — socat tunnel on the EC2 node (persistent)
sudo apt-get install -y socat
socat TCP-LISTEN:8888,fork TCP:43.205.91.169:30080 &

# Option 3 — kubectl port-forward in background (dev/test only)
nohup kubectl port-forward svc/payment-gateway 8888:8080 \
  -n payments --address 0.0.0.0 > /tmp/pf.log 2>&1 &
echo "App available at http://$(curl -s ifconfig.me):8888"


      echo ""
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  🌐 App URL    : http://${NODE_IP}:30080"
          echo "  🖥  Workstation: http://${NODE_IP}:8888  (port-forward)"
          echo "  ❤  Health    : http://${NODE_IP}:30080/healthz"
          echo "  📊 Metrics   : http://${NODE_IP}:30080/metrics"
          echo "  📈 Grafana   : http://${NODE_IP}:32710"
          echo "  🔥 Prometheus: http://${NODE_IP}:30091"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "| 🌐 App       | http://${NODE_IP}:30080 |"     >> $GITHUB_STEP_SUMMARY
          echo "| 🖥  Port 8888 | http://${NODE_IP}:8888  |"    >> $GITHUB_STEP_SUMMARY
          echo "| 📈 Grafana   | http://${NODE_IP}:32710 |"     >> $GITHUB_STEP_SUMMARY
          echo "| 🔥 Prometheus| http://${NODE_IP}:30091 |"     >> $GITHUB_STEP_SUMMARY

Prometheus → http://43.205.91.169:30091
Grafana → http://43.205.91.169:32710 (login: admin / rbih@admin2026)
```

> ⚠️ **AWS Security Group:** Make sure port `8888` is open for inbound TCP in your EC2 Security Group if accessing from outside the VPC.

### Test the payment endpoint

```bash
# Single payment
curl -X POST http://43.205.91.169:30080/pay \
  -H "Content-Type: application/json" \
  -d '{"amount": 1500.00, "currency": "INR", "reference": "order-001"}'

# Expected response
{
  "status": "approved",
  "reference": "order-001",
  "transaction_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "amount": 1500.00,
  "currency": "INR"
}

# Health check
curl http://43.205.91.169:30080/healthz
# → {"status":"ok"}
```

---

## CI/CD Pipeline (GitHub Actions)

The pipeline is defined in `.github/workflows/deploy.yaml` and has **5 stages**:

```
push to branch
      │
      ▼
┌─────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  1. Setup   │───►│  2. Build &  │───►│  3. Trivy    │───►│ 4. Approval  │───►│  5. Deploy   │
│  Env & Tag  │    │  Push Docker │    │  Scan        │    │  Gate        │    │  to EKS      │
└─────────────┘    └──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
```

### Triggers

| Trigger | Branch | Environment |
|---------|--------|-------------|
| `git push` | `main` | production |
| `git push` | `staging` | staging |
| `git push` | `develop` | dev |
| Manual (`workflow_dispatch`) | any | selectable |

### Manual deployment (workflow_dispatch)

Go to **GitHub → Actions → RBIH Payments — Build, Scan & Deploy to EKS → Run workflow**

| Input | Description | Default |
|-------|-------------|---------|
| `environment` | `dev` / `staging` / `production` | `dev` |
| `branch` | Branch to deploy | `main` |
| `image_tag` | Docker tag (empty = auto-increment) | auto |
| `skip_scan` | Skip Trivy security scan | `false` |

### Required GitHub Secrets

Set these in **GitHub → Settings → Secrets and variables → Actions**:

| Secret | Description |
|--------|-------------|
| `DOCKERHUB_USERNAME` | DockerHub username |
| `DOCKERHUB_TOKEN` | DockerHub access token |
| `AWS_ACCESS_KEY` | AWS IAM access key |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM secret key |

### Required GitHub Environments

The approval gate (`Job 4`) uses GitHub Environments for manual approval.
Create these in **GitHub → Settings → Environments**:

| Environment | Protection Rule |
|-------------|----------------|
| `dev` | (none — auto-approve) |
| `staging` | Required reviewers |
| `production` | Required reviewers |

### Auto image tagging

If `image_tag` is left empty, the pipeline auto-increments the semantic version from the latest git tag:
- First run → `1.0.0`
- Subsequent runs → `1.0.1`, `1.0.2`, etc.
- The tag is pushed to the repo automatically

---

## Observability — Prometheus & Grafana

### Grafana Dashboard

Open **http://43.205.91.169:32710** → login `admin` / `rbih@admin2026` → **Dashboards → Payments → RBIH Payments**

The auto-provisioned dashboard has 5 panels:

| Panel | Metric | Type |
|-------|--------|------|
| Request Rate | `http_requests_total` | Time series |
| P99 / P50 Latency | `http_request_duration_seconds` | Time series |
| Error Rate % | 5xx responses / total | Time series |
| Scrape Targets Up | `up{job=~"payment-*"}` | Stat |
| Total Requests | cumulative count | Stat |

### Prometheus Alerts

Open **http://43.205.91.169:30091/alerts** to see active alert rules.

| Alert | Condition | Severity |
|-------|-----------|----------|
| `HighErrorRate` | Error rate > 5% for 2m | 🔴 critical |
| `HighLatency` | P99 latency > 2s for 5m | 🟡 warning |
| `ProcessorDown` | Processor unreachable for 1m | 🔴 critical |
| `PodNotReady` | Any pod not ready for 2m | 🟡 warning |

### Metrics exposed by each service

| Metric | Description |
|--------|-------------|
| `http_requests_total` | Request counter by handler / method / status |
| `http_request_duration_seconds` | Latency histogram |
| `processor_calls_total` | Gateway → processor call outcomes |
| `payments_processed_total` | Processor-side results by currency |
| `payment_amount` | Histogram of payment amounts |

---

## Security Design

### Container Hardening

| Control | Detail |
|---------|--------|
| **Scratch base image** | No shell, no package manager — minimal attack surface |
| **Non-root user** | UID 65534 (`nobody`) enforced in Dockerfile AND pod spec |
| **Read-only root filesystem** | `readOnlyRootFilesystem: true` |
| **Drop all capabilities** | `capabilities: drop: [ALL]` |
| **seccomp** | `RuntimeDefault` profile applied |

### Network Isolation (Zero-Trust)

```
Internet ──► Gateway (port 8080) ──► Processor (port 8080, internal only)
               ↑                          ↑
        NetworkPolicy ALLOW         NetworkPolicy ALLOW
             from: *              from: payment-gateway only

Everything else → DENY (default-deny policy in payments namespace)
Prometheus scraping allowed from monitoring namespace only
```

### RBAC

Each service has its own `ServiceAccount`. Neither service account has any RBAC permissions — principle of least privilege.

---

## Reliability Features

| Feature | Configuration |
|---------|---------------|
| **Replicas** | 2 per service |
| **Rolling updates** | `maxUnavailable: 0` — zero-downtime deploys |
| **PodDisruptionBudget** | `minAvailable: 1` — survives node drains |
| **HPA** | Scales 2 → 10 replicas at 70% CPU |
| **TopologySpreadConstraints** | Pods spread across nodes |
| **Graceful shutdown** | 30s `terminationGracePeriodSeconds` |
| **Probes** | Liveness + readiness on `/healthz` |

---

## API Reference

### POST /pay

```bash
curl -X POST http://43.205.91.169:30080/pay \
  -H "Content-Type: application/json" \
  -d '{
    "amount": 1500.00,
    "currency": "INR",
    "reference": "order-789"
  }'
```

**Request body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `amount` | float | ✅ | Payment amount |
| `currency` | string | ✅ | ISO 4217 currency code (e.g. `INR`, `USD`) |
| `reference` | string | ✅ | Idempotency reference / order ID |

**Response `200 OK`:**

```json
{
  "status": "approved",
  "reference": "order-789",
  "transaction_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "amount": 1500.00,
  "currency": "INR"
}
```

### GET /healthz

```bash
curl http://43.205.91.169:30080/healthz
# → {"status":"ok"}
```

### GET /metrics

```bash
curl http://43.205.91.169:30080/metrics
# → Prometheus text format metrics
```

---

## Troubleshooting

### Pods not starting

```bash
# Check pod status and events
kubectl get pods -n payments -o wide
kubectl describe pod <pod-name> -n payments
kubectl logs <pod-name> -n payments
```

### Can't access Prometheus / Grafana

```bash
# Verify services are NodePort with correct ports
kubectl get svc -n monitoring

# If Prometheus is ClusterIP, patch it
kubectl patch svc prometheus -n monitoring \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},
       {"op":"add","path":"/spec/ports/0/nodePort","value":30091}]'

# If Grafana port is wrong
kubectl patch svc grafana -n monitoring \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":32710}]'
```

### AWS Security Group — open required ports

Ensure these inbound rules exist on your EC2 Security Group:

| Port | Protocol | Purpose |
|------|----------|---------|
| 30080 | TCP | Payment Gateway |
| 30091 | TCP | Prometheus |
| 32710 | TCP | Grafana |
| 8888 | TCP | Workstation access (port-forward) |

```bash
# Find your Security Group ID
aws ec2 describe-instances \
  --query "Reservations[*].Instances[*].[InstanceId,SecurityGroups]" \
  --output table

# Add inbound rule (replace sg-xxxxxxxx with your SG ID)
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp \
  --port 30091 \
  --cidr 0.0.0.0/0
```

### Rollout failed

```bash
# Check events
kubectl get events -n payments --sort-by='.lastTimestamp' | tail -20

# Check image pull status
kubectl describe pod -n payments -l app=payment-gateway | grep -A5 "Events:"

# Restart a deployment
kubectl rollout restart deployment/payment-gateway -n payments
```

### Kubeconfig / AWS auth issues

```bash
# Refresh kubeconfig
aws eks update-kubeconfig --region ap-south-1 --name rbih-payments

# Verify identity
aws sts get-caller-identity
```

---

## Design Decisions

**Why Go?** Fast startup, tiny binaries ideal for scratch images, excellent standard library for HTTP, very low memory overhead — all important for financial services.

**Why kind for local dev?** Creates a realistic multi-node topology (unlike minikube single-node), making `TopologySpreadConstraints` meaningful and CI-friendly.

**Why scratch image?** In a payment context, attack surface reduction is a priority. Scratch eliminates the entire OS layer — no shell to exec into, no package manager to exploit.

**Why separate `monitoring` namespace?** In production, observability infrastructure is managed by a platform team independently from application deployments. Separation enforces this boundary and allows different RBAC policies.

**Monitoring placement on NodePort:** Prometheus and Grafana are exposed on fixed NodePorts (`30091`, `32710`) so URLs are stable across pod restarts and deployments.

---

## What I Would Add With More Time

- **mTLS between services** via Istio or Linkerd — critical in production payment environments
- **Secrets management** — Vault or Kubernetes Sealed Secrets instead of plaintext env vars
- **Rate limiting** at the gateway — prevent burst abuse and DoS
- **Distributed tracing** — OpenTelemetry + Jaeger for end-to-end request visibility
- **Ingress + TLS** — NGINX ingress controller with cert-manager for HTTPS
- **Idempotency** — deduplicate payment requests by `reference` ID to prevent double-charges
- **Image signing** — cosign to verify image provenance before deployment
- **Resource quotas** on namespaces — prevent runaway resource consumption
- **Alertmanager** — route Prometheus alerts to Slack / PagerDuty

---

## Author

Ramesh | RBIH DevOps Take-Home Challenge
