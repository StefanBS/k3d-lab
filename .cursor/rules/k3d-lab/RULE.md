---
description: Working with this repo (k3d lab cluster + kubectl context "lab")
globs:
  - "**/*"
alwaysApply: true
---

## Repository intent

This repository deploys and manages a **k3d-based “lab” Kubernetes cluster** (a local k3s cluster in Docker). The k3d cluster name in this repo is **`my-lab-cluster`** (see `k3d-config.yaml`).

## Non-negotiable kubectl rule

Always run kubectl commands against the lab cluster using the explicit context flag:

- **Always**: `kubectl --context lab ...`
- **Never**: `kubectl ...` (no implicit current-context usage)

When writing docs/commands/snippets for this repo, include `--context lab` in every kubectl invocation.

## Kubeconfig / context expectations

The user’s kubeconfig must contain a context named **`lab`** pointing at the k3d cluster.

If the context is missing, prefer to **merge the existing cluster kubeconfig** and then **rename** the generated context to `lab`:

```bash
# Merge the existing k3d cluster kubeconfig into ~/.kube/config
k3d kubeconfig merge my-lab-cluster --kubeconfig "$HOME/.kube/config"

# If k3d created a context like "k3d-my-lab-cluster", rename it to "lab"
kubectl config get-contexts
kubectl config rename-context k3d-my-lab-cluster lab
```

After that, validation should always use the explicit context flag:

```bash
kubectl --context lab cluster-info
kubectl --context lab get nodes
```

## Cluster lifecycle policy (important)

- **Assume the k3d lab cluster is already deployed.**
- If it’s not currently running, **start it** (do not recreate).
- **Only deploy from scratch if the user explicitly asks** (e.g., “recreate the cluster”, “create from scratch”, “nuke and pave”).

Preferred “start if needed” flow:

```bash
k3d cluster list
k3d cluster start my-lab-cluster
```

Avoid running `k3d cluster create ...` unless the user explicitly requests a fresh deployment.


