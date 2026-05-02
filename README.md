# RBIH DevOps Take-Home Challenge

## Overview

Two Go microservices (`payment-gateway` and `payment-processor`) deployed on a local Kubernetes cluster with production-grade security, reliability, and observability.

---

## Architecture

```
[Client]
    │  POST /pay
    ▼
[payment-gateway]  ─────► [payment-processor]
  :8080                         :8080
    │                               │
    └───────────[Prometheus]────────┘
                    │
                [Grafana]
```

Services communicate **within the cluster only** via Kubernetes DNS (`http://payment-processor:8080`). Network Policies enforce zero-trust: the processor is unreachable from anything except the gateway.

---

## Repository Structure

```
rbih-devops/
├── services/
│   ├── payment-gateway/
│   │   ├── main.go          # HTTP gateway, forwards POST /pay → processor
│   │   ├── go.mod
│   │   └── Dockerfile       # Multi-stage, scratch image, non-root UID 65534
│   └── payment-processor/
│       ├── main.go          # Processes payments, returns transaction ID
│       ├── go.mod
│       └── Dockerfile
├── k8s/
│   ├── base/
│   │   ├── namespace.yaml
│   │   ├── payment-gateway.yaml   # Deployment + Service + ServiceAccount
│   │   ├── payment-processor.yaml
│   │   └── reliability.yaml       # HPA + PodDisruptionBudgets
│   ├── network-policy/
│   │   └── network-policies.yaml  # Default deny-all + explicit allow rules
│   └── monitoring/
│       └── monitoring.yaml        # Prometheus + Grafana + alert rules
├── scripts/
│   └── setup.sh             # Full local cluster setup (kind + registry)
└── README.md
```

---

## Prerequisites

- Docker (running)
- [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- `kubectl`
- `curl` + `jq` (for smoke test)

---

## Quick Start

```bash
git clone <repo-url>
cd rbih-devops
chmod +x scripts/setup.sh
./scripts/setup.sh
```

The script:
1. Starts a local Docker registry on port 5001
2. Creates a 3-node kind cluster (1 control-plane, 2 workers)
3. Builds and pushes both service images
4. Deploys all Kubernetes manifests
5. Runs a smoke test

---

## Endpoints

| Service | Endpoint | Description |
|---|---|---|
| payment-gateway | `POST /pay` | Accept payment JSON |
| both | `GET /healthz` | Health check |
| both | `GET /metrics` | Prometheus metrics |
| payment-processor | `POST /process` | Internal only (not exposed externally) |

### Example payment request

```bash
kubectl port-forward svc/payment-gateway 8080:8080 -n payments

curl -X POST http://localhost:8080/pay \
  -H "Content-Type: application/json" \
  -d '{"amount": 1500.00, "currency": "INR", "reference": "order-789"}'
```

Expected response:
```json
{
  "status": "approved",
  "reference": "order-789",
  "transaction_id": "f47ac10b-58cc-...",
  "amount": 1500.00,
  "currency": "INR"
}
```

---

## Observability

Access Grafana:
```bash
Prometheus → http://43.205.91.169:30091
Grafana → http://43.205.91.169:32710 (login: admin / rbih@admin2026)

```

Prometheus metrics exposed by both services:
- `http_requests_total` — total requests by handler/method/status
- `http_request_duration_seconds` — request latency histogram
- `processor_calls_total` — gateway→processor call outcomes
- `payments_processed_total` — processor-side payment outcomes by currency
- `payment_amount` — histogram of payment amounts

### Alerting rules configured
- `HighErrorRate` — error rate > 5% for 2 minutes → critical
- `HighLatency` — P99 latency > 2s for 5 minutes → warning
- `ProcessorDown` — processor unreachable for 1 minute → critical
- `PodNotReady` — any pod not ready for 2 minutes → warning

---

## Security Design

### Container hardening
- **Scratch base image** — no shell, no package manager, minimal attack surface
- **Non-root user** (UID 65534 / `nobody`) enforced at both Dockerfile and pod spec level
- **Read-only root filesystem**
- **All Linux capabilities dropped**
- **seccomp RuntimeDefault** applied

### Network isolation (zero-trust)
- Default-deny NetworkPolicy in `payments` namespace
- Only `payment-gateway` accepts external traffic on port 8080
- `payment-processor` only accepts connections from `payment-gateway` pods
- `payment-processor` has no outbound internet access
- Prometheus scraping allowed from `monitoring` namespace only

### RBAC
- Each service has its own ServiceAccount
- Neither service account has any RBAC permissions (principle of least privilege)

---

## Reliability

- **2 replicas** for each service by default
- **`maxUnavailable: 0`** in rolling updates (zero-downtime deployments)
- **PodDisruptionBudgets** — at least 1 pod always available during node drains
- **HPA** — scales 2→10 replicas at 70% CPU utilisation
- **TopologySpreadConstraints** — pods spread across nodes
- **Graceful shutdown** — 30s termination grace period, drains in-flight requests
- **Liveness + readiness probes** — automatic pod recovery and traffic shaping

---

## What I Would Add With More Time

- **mTLS between services** via a service mesh (Istio or Linkerd) — important in a real payment environment where network-level encryption between services matters
- **Secrets management** — any real credentials (DB passwords, signing keys) should use Vault or Kubernetes sealed secrets, not env vars
- **Rate limiting** at the gateway — prevent burst abuse
- **Distributed tracing** (OpenTelemetry + Jaeger) for end-to-end request visibility
- **Ingress + TLS termination** — currently services are port-forwarded; production needs a proper ingress controller with TLS
- **Idempotency** — payment requests should be idempotent by reference ID to avoid double-charges on retries
- **CI/CD pipeline** — GitHub Actions to build, test, scan (Trivy), and push images on merge
- **Image signing** — cosign to verify image provenance before deployment
- **Resource quotas** on the namespace — prevent runaway resource consumption

---

## Design Trade-offs

**Why Go?** Fast startup, tiny binaries (suitable for scratch images), good standard library for HTTP servers, low memory overhead — all desirable for financial services.

**Why kind over minikube?** kind creates a more realistic multi-node topology and is more CI-friendly. The setup script creates 2 worker nodes so topology spread constraints are meaningful.

**Why scratch image?** In a payment context, reducing attack surface is a priority. A scratch image eliminates the OS layer entirely, meaning no shell to exec into, no package manager to exploit.

**Monitoring placement:** Prometheus and Grafana are deployed in a separate `monitoring` namespace. This is intentional — in production, observability infrastructure is typically separate from application infrastructure and managed by a platform team.
