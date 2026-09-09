#!/usr/bin/env bash
# teardown.sh — Remove kind clusters and clean up local state
#
# Usage:
#   ./teardown.sh          # prompts for confirmation
#   ./teardown.sh --yes    # skips confirmation prompt

set -euo pipefail

HUB_CLUSTER="hub"
SPOKE_CLUSTER="tenant-cluster-1"

log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m✔ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }

confirm() {
  if [[ "${1:-}" == "--yes" ]]; then
    return 0
  fi
  echo ""
  warn "This will delete the following kind clusters and all their data:"
  echo "    kind-${HUB_CLUSTER}"
  echo "    kind-${SPOKE_CLUSTER}"
  echo ""
  read -r -p "  Are you sure? [y/N] " response
  [[ "$response" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

delete_cluster() {
  local name="$1"
  if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
    log "Deleting kind cluster: ${name}..."
    kind delete cluster --name "$name"
    ok "Cluster '${name}' deleted."
  else
    warn "Cluster '${name}' not found — skipping."
  fi
}

stop_port_forward() {
  log "Stopping any ArgoCD port-forwards..."
  pkill -f "kubectl port-forward.*argocd-server" 2>/dev/null && ok "Port-forward stopped." || warn "No port-forward was running."
}

clean_kubeconfig() {
  log "Removing kind cluster contexts from kubeconfig..."
  for name in "$HUB_CLUSTER" "$SPOKE_CLUSTER"; do
    kubectl config delete-context "kind-${name}" 2>/dev/null && ok "Removed context: kind-${name}" || true
    kubectl config delete-cluster "kind-${name}" 2>/dev/null || true
    kubectl config unset "users.kind-${name}" 2>/dev/null || true
  done
}

main() {
  confirm "${1:-}"
  stop_port_forward
  delete_cluster "$HUB_CLUSTER"
  delete_cluster "$SPOKE_CLUSTER"
  clean_kubeconfig

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✅  Teardown complete. All clusters removed."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

main "$@"
