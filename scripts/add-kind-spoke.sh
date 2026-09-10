#!/usr/bin/env bash
# Create a local Kind spoke and register it with Argo CD in kind-hub.

set -euo pipefail

HUB_CLUSTER="hub"
ARGOCD_NAMESPACE="argocd"

log() { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok() { echo -e "\033[1;32m✔ $*\033[0m"; }
die() { echo -e "\033[1;31m✘ $*\033[0m" >&2; exit 1; }

usage() {
  echo "Usage: $0 <spoke-cluster-name>"
  echo "Example: $0 tenant-cluster-2"
}

[[ $# -eq 1 ]] || { usage; exit 1; }

SPOKE_CLUSTER="$1"
CONTEXT="kind-${SPOKE_CLUSTER}"
ENDPOINT="https://${SPOKE_CLUSTER}-control-plane:6443"

command -v argocd >/dev/null || die "argocd is required."
command -v docker >/dev/null || die "docker is required."
command -v kind >/dev/null || die "kind is required."
command -v kubectl >/dev/null || die "kubectl is required."

if ! kind get clusters | grep -qx "${HUB_CLUSTER}"; then
  die "Kind hub cluster '${HUB_CLUSTER}' does not exist. Run ./setup.sh first."
fi

if ! kind get clusters | grep -qx "${SPOKE_CLUSTER}"; then
  log "Creating Kind spoke '${SPOKE_CLUSTER}'..."
  kind create cluster --name "${SPOKE_CLUSTER}" --wait 60s
else
  log "Kind spoke '${SPOKE_CLUSTER}' already exists."
fi

kubectl config get-contexts -o name | grep -qx "${CONTEXT}" \
  || die "Kubeconfig context '${CONTEXT}' was not created."

log "Creating Argo CD credentials for '${CONTEXT}'..."
kubectl --context "${CONTEXT}" -n kube-system create serviceaccount argocd-manager \
  --dry-run=client -o yaml | kubectl --context "${CONTEXT}" apply -f - >/dev/null
kubectl --context "${CONTEXT}" create clusterrolebinding argocd-spoke-manager-cluster-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:argocd-manager \
  --dry-run=client -o yaml | kubectl --context "${CONTEXT}" apply -f - >/dev/null

TOKEN="$(kubectl --context "${CONTEXT}" -n kube-system create token argocd-manager --duration=8760h)"
CA_DATA="$(kubectl config view --raw --context "${CONTEXT}" \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
CLUSTER_SECRET="$(kubectl --context "kind-${HUB_CLUSTER}" -n "${ARGOCD_NAMESPACE}" get secrets \
  -l argocd.argoproj.io/secret-type=cluster \
  -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{index .data "name" | base64decode}}{{"\n"}}{{end}}' \
  | awk -v context="${CONTEXT}" '$2 == context { print $1 }')"
CLUSTER_SECRET="${CLUSTER_SECRET:-argocd-cluster-${SPOKE_CLUSTER}}"

log "Registering the hub-reachable endpoint for '${CONTEXT}'..."
kubectl --context "kind-${HUB_CLUSTER}" -n "${ARGOCD_NAMESPACE}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${CLUSTER_SECRET}
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${CONTEXT}
  server: ${ENDPOINT}
  config: '{"bearerToken":"${TOKEN}","tlsClientConfig":{"caData":"${CA_DATA}"}}'
EOF

docker exec "${HUB_CLUSTER}-control-plane" getent hosts "${SPOKE_CLUSTER}-control-plane" >/dev/null \
  || die "The hub cannot resolve ${SPOKE_CLUSTER}-control-plane on the Kind Docker network."

if ! argocd cluster list | awk -v endpoint="${ENDPOINT}" '$1 == endpoint { found = 1 } END { exit !found }'; then
  die "Argo CD does not list '${ENDPOINT}' after registration."
fi

ok "Spoke '${SPOKE_CLUSTER}' is registered at ${ENDPOINT}"
