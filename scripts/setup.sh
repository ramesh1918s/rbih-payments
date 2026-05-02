#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="rbih-payments"
REGISTRY_NAME="rbih-registry"
REGISTRY_PORT="5001"

log() { echo "▶ $*"; }
die() { echo "✗ $*" >&2; exit 1; }

check_deps() {
  for cmd in docker kind kubectl; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed"
  done
  log "All dependencies present"
}

start_registry() {
  if docker inspect "$REGISTRY_NAME" &>/dev/null; then
    log "Local registry already running"
    return
  fi
  log "Starting local Docker registry on port $REGISTRY_PORT..."
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --network bridge --name "$REGISTRY_NAME" registry:2
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
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REGISTRY_PORT}"]
      endpoint = ["http://${REGISTRY_NAME}:5000"]
EOF

  # Connect registry to cluster network
  docker network connect "kind" "$REGISTRY_NAME" 2>/dev/null || true

  # Configure nodes to use local registry
  REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" mkdir -p "$REGISTRY_DIR"
    cat <<TOEOF | docker exec -i "$node" tee "${REGISTRY_DIR}/hosts.toml" >/dev/null
[host."http://${REGISTRY_NAME}:5000"]
TOEOF
  done
}

build_and_push() {
  log "Building and pushing payment-gateway..."
  docker build -t "localhost:${REGISTRY_PORT}/payment-gateway:1.0.0" \
    services/payment-gateway
  docker push "localhost:${REGISTRY_PORT}/payment-gateway:1.0.0"

  log "Building and pushing payment-processor..."
  docker build -t "localhost:${REGISTRY_PORT}/payment-processor:1.0.0" \
    services/payment-processor
  docker push "localhost:${REGISTRY_PORT}/payment-processor:1.0.0"
}

patch_images() {
  # Patch deployment images to use local registry
  sed -i.bak \
    "s|rbih-hiring/devopschallenge/paymentgateway:1.0.0|localhost:${REGISTRY_PORT}/payment-gateway:1.0.0|g" \
    k8s/base/payment-gateway.yaml
  sed -i.bak \
    "s|rbih-hiring/devopschallenge/paymentprocessor:1.0.0|localhost:${REGISTRY_PORT}/payment-processor:1.0.0|g" \
    k8s/base/payment-processor.yaml
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
  kubectl port-forward svc/payment-gateway 8080:8080 -n payments &
  PF_PID=$!
  sleep 3

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
  start_registry
  create_cluster
  build_and_push
  patch_images
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
