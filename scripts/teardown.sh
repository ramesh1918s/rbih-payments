#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="rbih-payments"

log() { echo "▶ $*"; }

log "Deleting kind cluster '$CLUSTER_NAME'..."
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || log "Cluster not found, skipping"

eksctl delete cluster --name rbih-payments --region ap-south-1

log "Teardown complete."
