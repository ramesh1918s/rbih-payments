#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
#  RBIH Payments — Local Kind Setup Script
#  Usage: ./scripts/setup.sh
# ─────────────────────────────────────────────────────────

CLUSTER_NAME="rbih-payments"
NAMESPACE="payments"

# FIX 1: REGISTRY_NAME was used everywhere but never defined
REGISTRY_NAME="rbih-registry"
REGISTRY_PORT="5001"

log() { echo "▶ $*"; }
warn() { echo "⚠ $*"; }
die() { echo "✗ $*" >&2; exit 1; }

# ── Prereq check ──────────────────────────────────────────
check_deps() {
  for cmd in docker kind kubectl curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed"
  done
  log "All dependencies present"
}

# ── Local Docker registry ─────────────────────────────────
start_registry() {
  # FIX 2: was referencing $REGISTRY_NAME before it was defined — now defined above
  if docker inspect "$REGISTRY_NAME" &>/dev/null; then
    log "Local registry '$REGISTRY_NAME' already running"
    return
  fi
  log "Starting local Docker registry on port $REGISTRY_PORT..."
  docker run -d \
    --restart=always \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --network bridge \
    --name "$REGISTRY_NAME" \
    registry:2
  log "Registry started"
}

# ── Kind cluster ──────────────────────────────────────────
create_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log "Cluster '$CLUSTER_NAME' already exists — skipping creation"
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

  # Connect registry container to kind's internal network
  docker network connect "kind" "$REGISTRY_NAME" 2>/dev/null || true

  # Tell every kind node to use the local registry
  REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" mkdir -p "$REGISTRY_DIR"
    cat <<TOEOF | docker exec -i "$node" tee "${REGISTRY_DIR}/hosts.toml" >/dev/null
[host."http://${REGISTRY_NAME}:5000"]
TOEOF
  done

  log "Cluster '$CLUSTER_NAME' created"
}

# ── Build & push images to local registry ─────────────────
build_and_push() {
  log "Building payment-gateway..."
  docker build -t "localhost:${REGISTRY_PORT}/payment-gateway:1.0.0" \
    services/payment-gateway
  docker push "localhost:${REGISTRY_PORT}/payment-gateway:1.0.0"

  log "Building payment-processor..."
  docker build -t "localhost:${REGISTRY_PORT}/payment-processor:1.0.0" \
    services/payment-processor
  docker push "localhost:${REGISTRY_PORT}/payment-processor:1.0.0"

  log "Images built and pushed"
}

# ── Patch manifests to use local registry images ──────────
patch_images() {
  log "Patching image references in manifests..."

  # FIX 3: original sed pattern matched 'rbih-hiring/devopschallenge/...' which
  # doesn't exist in this repo — manifests already use shivaram1918/rbih-payment-*
  # Correct pattern replaces the DockerHub image with local registry image
  sed -i.bak \
    "s|image: shivaram1918/rbih-payment-gateway:.*|image: localhost:${REGISTRY_PORT}/payment-gateway:1.0.0|g" \
    k8s/base/payment-gateway.yaml

  sed -i.bak \
    "s|image: shivaram1918/rbih-payment-processor:.*|image: localhost:${REGISTRY_PORT}/payment-processor:1.0.0|g" \
    k8s/base/payment-processor.yaml

  log "Image references patched"
}

# ── Deploy all manifests ──────────────────────────────────
deploy() {
  log "Deploying to Kubernetes..."

  # FIX 4: namespace must exist before any namespaced resources are applied
  kubectl apply -f k8s/base/namespace.yaml

  # FIX 5: network-policies need the namespace to exist first
  kubectl apply -f k8s/network-policy/network-policies.yaml

  # FIX 6: processor must be deployed before gateway
  # (gateway tries to reach processor on startup — processor should be ready first)
  kubectl apply -f k8s/base/payment-processor.yaml -n ${NAMESPACE}
  kubectl apply -f k8s/base/payment-gateway.yaml   -n ${NAMESPACE}

  # FIX 7: reliability (PDB + HPA) must be applied in the correct namespace
  kubectl apply -f k8s/base/reliability.yaml -n ${NAMESPACE}

  # FIX 8: nodeport was never applied — required to reach the gateway
  kubectl apply -f k8s/base/nodeport.yaml -n ${NAMESPACE}

  # Monitoring: namespace + stack defined together in monitoring.yaml
  # apply once — namespace is created inside the file
  kubectl apply -f k8s/monitoring/monitoring.yaml

  log "All manifests applied"
}

# ── Wait for pods to be Ready ─────────────────────────────
wait_for_ready() {
  log "Waiting for payment-processor rollout..."
  kubectl rollout status deployment/payment-processor \
    -n ${NAMESPACE} --timeout=120s

  log "Waiting for payment-gateway rollout..."
  kubectl rollout status deployment/payment-gateway \
    -n ${NAMESPACE} --timeout=120s

  log "All deployments ready"
}

# ── Smoke test via port-forward ───────────────────────────
smoke_test() {
  log "Running smoke test..."

  # FIX 9: use trap so port-forward is always killed, even if curl fails
  kubectl port-forward svc/payment-gateway 8080:8080 \
    -n ${NAMESPACE} &>/dev/null &
  PF_PID=$!
  trap "kill ${PF_PID} 2>/dev/null; true" EXIT
  sleep 3

  # FIX 10: was hitting /healthz — correct endpoint is /health
  HEALTH=$(curl -sf http://localhost:8080/health \
    | jq -r '.status' 2>/dev/null || echo "FAILED")

  if [ "$HEALTH" = "ok" ]; then
    log "Health check: PASSED ✓"
  else
    warn "Health check: FAILED (got: '$HEALTH') — pods may still be starting"
  fi

  RESULT=$(curl -sf -X POST http://localhost:8080/pay \
    -H "Content-Type: application/json" \
    -d '{"amount":100.00,"currency":"INR","reference":"TEST-001"}' \
    | jq -r '.status' 2>/dev/null || echo "FAILED")

  if [ "$RESULT" = "approved" ]; then
    log "Payment flow: PASSED ✓"
  else
    warn "Payment flow: FAILED (got: '$RESULT')"
  fi

  kill "${PF_PID}" 2>/dev/null || true
  trap - EXIT
}

# ── Print usage info ──────────────────────────────────────
print_info() {
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  Setup complete!"
  echo ""
  echo "  Explore the cluster:"
  echo "    kubectl get pods -n payments"
  echo "    kubectl get pods -n monitoring"
  echo ""
  echo "  Test the gateway:"
  echo "    kubectl port-forward svc/payment-gateway 8080:8080 -n payments"
  echo "    curl http://localhost:8080/health"
  echo "    curl -X POST http://localhost:8080/pay \\"
  echo "         -H 'Content-Type: application/json' \\"
  echo "         -d '{\"amount\":500,\"currency\":\"INR\",\"reference\":\"txn-001\"}'"
  echo ""
  echo "  Grafana dashboard:"
  echo "    kubectl port-forward svc/grafana 3000:3000 -n monitoring"
  echo "    Open: http://localhost:3000  (admin / rbih@admin2026)"
  echo ""
  echo "  Teardown:"
  echo "    ./scripts/teardown.sh"
  echo "════════════════════════════════════════════════════════"
}

# ── Main ──────────────────────────────────────────────────
main() {
  check_deps
  start_registry
  create_cluster
  build_and_push
  patch_images
  deploy
  wait_for_ready
  smoke_test
  print_info
}

main "$@"