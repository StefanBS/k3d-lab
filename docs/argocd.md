# ArgoCD Setup & GitOps

This document details the setup of [ArgoCD](https://argo-cd.readthedocs.io/) for GitOps deployment management.

## Installation

### 1. Install ArgoCD
We install ArgoCD into the `argocd` namespace using the official manifest.

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 2. Install ArgoCD CLI (Optional but Recommended)
Follow instructions [here](https://argo-cd.readthedocs.io/en/stable/cli_installation/) to install the CLI.

### 3. Access the UI
**Port Forwarding:**
To access the UI locally without an Ingress:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Access at: `https://localhost:8080`

**Login Credentials:**
- **Username:** `admin`
- **Password:** Get the initial password:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
  ```

## GitOps Structure

We use a standard directory structure for our GitOps state:

```
.
├── bootstrap/          # Initial setup manifests (ArgoCD itself, etc.)
├── infrastructure/     # Infrastructure charts (Envoy Gateway, Cert Manager, etc.)
└── apps/               # Application deployments
```

## Deploying Applications

We use the **App of Apps** pattern or individual **Application** manifests.

Example `Application` manifest:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: envoy-gateway
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.envoyproxy.io
    targetRevision: v0.0.0-latest
    chart: gateway-helm
  destination:
    server: https://kubernetes.default.svc
    namespace: envoy-gateway-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

