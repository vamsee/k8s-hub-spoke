#!/usr/bin/env bash
# teardown.sh — Remove kind clusters and clean up local state
#
# Usage:
#   ./teardown.sh          # prompts for confirmation
#   ./teardown.sh --yes    # skips confirmation prompt

set -euo pipefail

HUB_CLUSTER="hub"
PROJECT_CLUSTERS=()
CLEANUP_CLUSTERS=()

log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m✔ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }

add_unique() {
  local name="$1"
  local existing
  for existing in "${CLEANUP_CLUSTERS[@]}"; do
    [[ "${existing}" == "${name}" ]] && return
  done
  CLEANUP_CLUSTERS+=("${name}")
}

discover_project_clusters() {
  local name context

  while IFS= read -r name; do
    [[ "${name}" == "${HUB_CLUSTER}" || "${name}" == tenant-cluster-* ]] || continue
    PROJECT_CLUSTERS+=("${name}")
    add_unique "${name}"
  done < <(kind get clusters 2>/dev/null || true)

  # Also remove stale kubeconfig entries for project clusters deleted outside
  # this script.
  while IFS= read -r context; do
    [[ "${context}" == "kind-${HUB_CLUSTER}" || "${context}" == kind-tenant-cluster-* ]] || continue
    add_unique "${context#kind-}"
  done < <(kubectl config get-contexts -o name 2>/dev/null || true)
}

confirm() {
  if [[ "${1:-}" == "--yes" ]]; then
    return 0
  fi
  echo ""
  warn "This will delete the following kind clusters and all their data:"
  if [[ ${#PROJECT_CLUSTERS[@]} -eq 0 ]]; then
    echo "    (none found)"
  else
    local name
    for name in "${PROJECT_CLUSTERS[@]}"; do
      echo "    kind-${name}"
    done
  fi
  echo ""
  read -r -p "  Are you sure? [y/N] " response
  [[ "$response" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

delete_cluster() {
  local name="$1"
  log "Deleting kind cluster: ${name}..."
  kind delete cluster --name "$name"
  ok "Cluster '${name}' deleted."
}

stop_port_forward() {
  log "Stopping any ArgoCD port-forwards..."
  pkill -f "kubectl port-forward.*argocd-server" 2>/dev/null && ok "Port-forward stopped." || warn "No port-forward was running."
}

clean_kubeconfig() {
  log "Removing kind cluster contexts from kubeconfig..."
  local name
  for name in "${CLEANUP_CLUSTERS[@]}"; do
    kubectl config delete-context "kind-${name}" 2>/dev/null && ok "Removed context: kind-${name}" || true
    kubectl config delete-cluster "kind-${name}" 2>/dev/null || true
    kubectl config unset "users.kind-${name}" 2>/dev/null || true
  done
}

main() {
  discover_project_clusters
  confirm "${1:-}"
  stop_port_forward
  local name
  for name in "${PROJECT_CLUSTERS[@]}"; do
    delete_cluster "${name}"
  done
  clean_kubeconfig

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✅  Teardown complete. All project clusters removed."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

main "$@"
