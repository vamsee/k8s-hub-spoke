#!/usr/bin/env bash
# setup.sh — Bootstrap kind clusters and ArgoCD for local multi-tenant GitOps testing
#
# Usage:
#   ./setup.sh                        # uses current directory as repo root
#   REPO_URL=https://github.com/... ./setup.sh   # override git repo URL
#
# Prerequisites: docker, kind, kubectl, argocd CLI

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
HUB_CLUSTER="hub"
SPOKE_CLUSTER="tenant-cluster-1"
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="stable" # pin to a specific tag like "v2.11.0" for reproducibility
ARGOCD_PORT="8080"

# If REPO_URL is not set, remind the user but continue (useful for dry runs)
# REPO_URL="${REPO_URL:-}"
REPO_URL="https://github.com/vamsee/k8s-hub-spoke"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok() { echo -e "\033[1;32m✔ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }
die() {
  echo -e "\033[1;31m✘ $*\033[0m"
  exit 1
}

check_prereqs() {
  log "Checking prerequisites..."
  local missing=()
  for cmd in docker kind kubectl argocd; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}\n  Install with: brew install ${missing[*]}"
  fi

  if ! docker info &>/dev/null; then
    die "Docker is not running. Start Docker Desktop and retry."
  fi

  ok "All prerequisites found."
}

create_cluster() {
  local name="$1"
  if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
    warn "Cluster '${name}' already exists — skipping creation."
  else
    log "Creating kind cluster: ${name}..."
    kind create cluster --name "$name" --wait 60s
    ok "Cluster '${name}' ready."
  fi
}

install_argocd() {
  log "Installing ArgoCD on hub cluster (${HUB_CLUSTER})..."
  kubectl config use-context "kind-${HUB_CLUSTER}"

  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # Use server-side apply to avoid the 262144-byte annotation limit on ArgoCD CRDs
  kubectl apply -n "$ARGOCD_NAMESPACE" --server-side \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

  log "Waiting for ArgoCD server to become ready (up to 3 minutes)..."
  kubectl wait --for=condition=available --timeout=180s \
    deployment/argocd-server -n "$ARGOCD_NAMESPACE"

  ok "ArgoCD installed."
}

login_argocd() {
  log "Starting port-forward for ArgoCD UI on localhost:${ARGOCD_PORT}..."

  # Kill any existing port-forward on that port
  pkill -f "kubectl port-forward.*argocd-server" 2>/dev/null || true

  kubectl port-forward svc/argocd-server \
    -n "$ARGOCD_NAMESPACE" "${ARGOCD_PORT}:443" &>/dev/null &

  sleep 3 # give port-forward a moment to bind

  local password
  password=$(argocd admin initial-password -n "$ARGOCD_NAMESPACE" 2>/dev/null | head -1)

  log "Logging into ArgoCD CLI..."
  argocd login "localhost:${ARGOCD_PORT}" \
    --username admin \
    --password "$password" \
    --insecure

  ok "ArgoCD login successful."
  echo ""
  echo "  🌐 ArgoCD UI → https://localhost:${ARGOCD_PORT}"
  echo "  👤 Username  → admin"
  echo "  🔑 Password  → ${password}"
  echo "  (change this password after first login)"
}

register_spoke() {
  log "Creating and registering spoke cluster (${SPOKE_CLUSTER})..."
  ./scripts/add-kind-spoke.sh "${SPOKE_CLUSTER}"
}

apply_applicationset() {
  if [[ -z "$REPO_URL" ]]; then
    warn "REPO_URL is not set. Skipping ApplicationSet apply."
    warn "To apply later, run:"
    warn "  REPO_URL=https://github.com/your-org/your-repo ./setup.sh --apply-only"
    return
  fi

  log "Patching ApplicationSet with REPO_URL: ${REPO_URL}..."

  local appset_file="argocd/applicationset.yaml"
  if [[ ! -f "$appset_file" ]]; then
    die "Cannot find ${appset_file}. Run this script from the repo root."
  fi

  # Substitute placeholder URL and apply
  sed "s|https://github.com/YOUR_ORG/YOUR_REPO.git|${REPO_URL}|g" "$appset_file" |
    kubectl apply -n "$ARGOCD_NAMESPACE" -f -

  ok "ApplicationSet applied. ArgoCD will sync tenants shortly."
}

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✅  Setup complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  Clusters:"
  echo "    kind-${HUB_CLUSTER}      → ArgoCD hub"
  echo "    kind-${SPOKE_CLUSTER}  → tenant workloads"
  echo ""
  echo "  ArgoCD UI  → https://localhost:${ARGOCD_PORT}"
  echo ""
  echo "  Useful commands:"
  echo "    argocd app list"
  echo "    kubectl --context kind-${SPOKE_CLUSTER} get pods -n tenant-a"
  echo "    kubectl --context kind-${SPOKE_CLUSTER} get pods -n tenant-b"
  echo ""
  echo "  To add a second spoke:"
  echo "    ./scripts/add-kind-spoke.sh tenant-cluster-2"
  echo "  Then follow README.md to add tenant-c to that spoke."
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  check_prereqs
  create_cluster "$HUB_CLUSTER"
  install_argocd
  login_argocd
  register_spoke
  apply_applicationset
  print_summary
}

main "$@"
