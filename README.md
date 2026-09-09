# Multi-Tenant GitOps Demo

Local proof-of-concept for managing multiple microservice versions across tenants using
**kind** + **ArgoCD ApplicationSets** + **Kustomize overlays**.

## Repo structure

```
.
├── base/                          # Shared Kubernetes manifests
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
│
├── overlays/                      # Per-tenant version pins
│   ├── tenant-a/
│   │   └── kustomization.yaml     # nginx:1.25.0, 1 replica
│   └── tenant-b/
│       └── kustomization.yaml     # nginx:1.25.3, 2 replicas
│
├── tenants/                       # ApplicationSet generator source of truth
│   ├── tenant-a/config.json
│   └── tenant-b/config.json
│
├── argocd/
│   └── applicationset.yaml        # Auto-generates one ArgoCD App per tenant
│
├── setup.sh                       # Bootstrap clusters + ArgoCD
└── teardown.sh                    # Clean up everything
```

## Prerequisites

```bash
brew install kind kubectl helm argocd
brew install --cask docker    # if not installed
```

Ensure Docker Desktop is running before proceeding.

## Quick start

### 1. Push this repo to GitHub

ArgoCD needs a remote git URL to poll for changes.

```bash
git init
git add .
git commit -m "initial multi-tenant gitops setup"
git remote add origin https://github.com/YOUR_ORG/YOUR_REPO.git
git push -u origin main
```

### 2. Run setup

```bash
REPO_URL=https://github.com/YOUR_ORG/YOUR_REPO.git ./setup.sh
```

This will:
- Create two kind clusters: `hub` and `tenant-cluster-1`
- Install ArgoCD on the hub
- Register the spoke cluster with ArgoCD
- Apply the ApplicationSet (if `REPO_URL` is set)

Setup takes ~3–4 minutes depending on your internet connection.

### 3. Open the ArgoCD UI

```bash
# Port-forward is started automatically by setup.sh, but you can restart it:
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open **https://localhost:8080** in your browser.  
The initial credentials are printed at the end of `setup.sh`.

### 4. Watch tenants sync

```bash
# List all ArgoCD applications
argocd app list

# Check pods for each tenant
kubectl config use-context kind-hub
kubectl get pods -n tenant-a
kubectl get pods -n tenant-b
```

You should see `tenant-a` running `nginx:1.25.0` and `tenant-b` running `nginx:1.25.3`.

## Verify the overlay diff

You can preview what Kustomize will render for each tenant without applying anything:

```bash
kubectl kustomize overlays/tenant-a
kubectl kustomize overlays/tenant-b
```

## Upgrade a tenant's version

1. Edit `overlays/tenant-b/kustomization.yaml` and change the `newTag`
2. Commit and push
3. ArgoCD auto-syncs within ~3 minutes (or click **Sync** in the UI)

```bash
# Trigger a manual sync immediately
argocd app sync tenant-b
```

## Add a new tenant

```bash
# 1. Create the config
mkdir -p tenants/tenant-c overlays/tenant-c

cat > tenants/tenant-c/config.json <<EOF
{
  "tenant": "tenant-c",
  "namespace": "tenant-c",
  "clusterURL": "https://kubernetes.default.svc",
  "imageTag": "1.26.0",
  "replicas": "1"
}
EOF

# 2. Create the overlay
cp overlays/tenant-a/kustomization.yaml overlays/tenant-c/kustomization.yaml
# Edit overlays/tenant-c/kustomization.yaml to set namespace: tenant-c and desired imageTag

# 3. Push — ArgoCD does the rest
git add .
git commit -m "add tenant-c"
git push
```

## Tear down

```bash
./teardown.sh          # prompts for confirmation
./teardown.sh --yes    # skips prompt
```

## Translating to EKS

| Local (kind)               | Production (EKS)                              |
|----------------------------|-----------------------------------------------|
| `kind create cluster`      | `eksctl create cluster` / Terraform           |
| `kind-hub`                 | Dedicated EKS cluster for ArgoCD              |
| `kind-tenant-cluster-1`    | Per-region or per-tenant EKS cluster          |
| `https://kubernetes.default.svc` | EKS API server endpoint (from kubeconfig) |
| `argocd cluster add`       | Same command, pointing at EKS context         |

Everything else — the overlays, ApplicationSet, and tenant config structure — is identical.
