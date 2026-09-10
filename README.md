# Multi-tenant GitOps with Kind and Argo CD

A local demo of a hub-and-spoke GitOps setup:

- **Hub**: `kind-hub` runs Argo CD only.
- **Spoke 1**: `kind-tenant-cluster-1` runs `tenant-a` and `tenant-b`.
- **Spoke 2**: added later with one command; it runs `tenant-c`.

Argo CD reads each tenant's configuration from Git and deploys its Kustomize
overlay to the selected spoke cluster.

## Prerequisites

```bash
brew install kind kubectl helm argocd
brew install --cask docker
```

Start Docker Desktop, then push this repository to a remote Git repository.
Argo CD must be able to read that repository.

```bash
git remote add origin https://github.com/YOUR_ORG/YOUR_REPO.git
git push -u origin main
```

## 1. Bootstrap the hub and first spoke

```bash
REPO_URL=https://github.com/YOUR_ORG/YOUR_REPO.git ./setup.sh
```

The script creates the hub, installs and logs in to Argo CD, creates spoke 1,
and registers it with the hub. It also applies the ApplicationSet, so
`tenant-a` and `tenant-b` deploy to spoke 1 automatically.

Open Argo CD at <https://localhost:8080>. The bootstrap output prints the
initial admin password.

## 2. Verify the first spoke

```bash
argocd cluster list
argocd app list

kubectl --context kind-tenant-cluster-1 get pods -n tenant-a
kubectl --context kind-tenant-cluster-1 get pods -n tenant-b
```

The applications should target:

```
https://tenant-cluster-1-control-plane:6443
```

The hub does not run tenant workloads.

## 3. Add the second spoke

Keep the Argo CD port-forward and CLI login created by `setup.sh` running,
then run:

```bash
./scripts/add-kind-spoke.sh tenant-cluster-2
```

The helper creates the Kind cluster when needed, creates the Argo CD service
account and RBAC, and registers the Docker-network API endpoint that is
reachable from the hub. Re-running it is safe.

## 4. Put tenant-c on the second spoke

```bash
mkdir -p tenants/tenant-c overlays/tenant-c
cp tenants/tenant-a/config.json tenants/tenant-c/config.json
cp overlays/tenant-a/kustomization.yaml overlays/tenant-c/kustomization.yaml
```

Edit `tenants/tenant-c/config.json`:

```json
{
  "tenant": "tenant-c",
  "namespace": "tenant-c",
  "clusterURL": "https://tenant-cluster-2-control-plane:6443",
  "clusterName": "kind-tenant-cluster-2",
  "imageTag": "1.26.0",
  "replicas": "1"
}
```

Edit `overlays/tenant-c/kustomization.yaml` so its namespace, labels, and
resource names use `tenant-c`; set the desired image tag and replica count.
Then commit and push:

```bash
git add tenants/tenant-c overlays/tenant-c
git commit -m "add tenant-c on spoke 2"
git push
```

Argo CD creates the `tenant-c` Application and deploys it to spoke 2.

```bash
argocd app get tenant-c
kubectl --context kind-tenant-cluster-2 get pods -n tenant-c
```

## Useful commands

```bash
# Render a tenant overlay locally
kubectl kustomize overlays/tenant-a

# Trigger a sync without waiting for the Git poll
argocd app sync tenant-c

# Remove the hub and every project spoke (`tenant-cluster-*`)
./teardown.sh --yes
```

## Local Kind networking

Kind writes `127.0.0.1:<port>` into your local kubeconfig. That address works
from your Mac, but not from Argo CD running inside the hub cluster. The helper
uses `https://<spoke>-control-plane:6443`, the shared Docker-network address,
instead. This is specific to the local Kind demo; production clusters should
use their normal reachable API endpoints.
