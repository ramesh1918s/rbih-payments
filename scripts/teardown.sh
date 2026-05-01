#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="rbih-payments"
REGISTRY_NAME="rbih-registry"

log() { echo "▶ $*"; }

log "Deleting kind cluster '$CLUSTER_NAME'..."
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || log "Cluster not found, skipping"

log "Stopping local registry '$REGISTRY_NAME'..."
docker rm -f "$REGISTRY_NAME" 2>/dev/null || log "Registry not found, skipping"

log "Removing local images..."
docker rmi localhost:5001/payment-gateway:1.0.0  2>/dev/null || true
docker rmi localhost:5001/payment-processor:1.0.0 2>/dev/null || true

log "Teardown complete."
