#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="rbih-payments"

log() { echo "▶ $*"; }
die() { echo "✗ $*" >&2; exit 1; }

check_deps() {
  for cmd in docker kind kubectl curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed"
  done
  log "All dependencies present"
}

create_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log "Cluster '$CLUSTER_NAME' already exists"
    return
  fi

  log "Creating kind cluster '$CLUSTER_NAME'..."
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
}

deploy() {
  log "Deploying to Kubernetes..."

  kubectl apply -f k8s/base/namespace.yaml
  kubectl apply -f k8s/base/payment-gateway.yaml
  kubectl apply -f k8s/base/payment-processor.yaml
  kubectl apply -f k8s/base/reliability.yaml
  kubectl apply -f k8s/network-policy/network-policies.yaml
  kubectl apply -f k8s/monitoring/monitoring.yaml
}

wait_for_ready() {
  log "Waiting for deployments to be ready..."

  kubectl rollout status deployment/payment-gateway -n payments --timeout=120s
  kubectl rollout status deployment/payment-processor -n payments --timeout=120s

  log "All deployments ready"
}

smoke_test() {
  log "Running smoke test..."

  kubectl port-forward svc/payment-gateway 8080:8080 -n payments >/dev/null 2>&1 &
  PF_PID=$!

  sleep 5

  HEALTH=$(curl -sf http://localhost:8080/healthz | jq -r .status 2>/dev/null || echo "FAILED")

  if [ "$HEALTH" = "ok" ]; then
    log "Health check: PASSED"
  else
    echo "✗ Health check failed" >&2
  fi

  RESULT=$(curl -sf -X POST http://localhost:8080/pay \
    -H "Content-Type: application/json" \
    -d '{"amount":100.00,"currency":"INR","reference":"TEST-001"}' \
    | jq -r .status 2>/dev/null || echo "FAILED")

  if [ "$RESULT" = "approved" ]; then
    log "Payment flow: PASSED"
  else
    echo "✗ Payment flow failed (got: $RESULT)" >&2
  fi

  kill $PF_PID 2>/dev/null || true
}

main() {
  check_deps
  create_cluster
  deploy
  wait_for_ready
  smoke_test

  echo ""
  log "Setup complete! Use these commands to explore:"
  echo "  kubectl get pods -n payments"
  echo "  kubectl port-forward svc/payment-gateway 8080:8080 -n payments"
  echo "  kubectl port-forward svc/grafana 3000:3000 -n monitoring"
  echo "  curl -X POST http://localhost:8080/pay -H 'Content-Type: application/json' \\"
  echo "       -d '{\"amount\":500,\"currency\":\"INR\",\"reference\":\"txn-001\"}'"
}

main "$@"
