# Local Kubernetes Lab Stack

## Overview

This document outlines the infrastructure stack used for the local Kubernetes lab environment.

## Components

### Kubernetes Distribution
- **Distribution:** [K3s](https://k3s.io/)
- **Version:** `v1.34.2+k3s1` (Image: `rancher/k3s:v1.34.2-k3s1`)
- **Manager:** [k3d](https://k3d.io/) (Runs K3s in Docker)

### Deployment Management (GitOps)
- **Tool:** [ArgoCD](https://argo-cd.readthedocs.io/)
- **Setup:** [docs/argocd.md](./argocd.md)
- **Method:** GitOps (Pull-based deployment)

### Ingress & Networking
- **Gateway API:** [Envoy Gateway](https://gateway.envoyproxy.io/)
  - Implements the Kubernetes Gateway API.
  - Managed via ArgoCD.
  - Setup details: [docs/gateway.md](./gateway.md)

### Observability
- **Logging:** [Loki](https://grafana.com/oss/loki/)
  - Installed via official Helm chart.
  - Deployment Mode: Single Binary.
  - Setup details: [docs/loki.md](./loki.md)
- **Visualization:** [Grafana](https://grafana.com/)
  - Installed via official Helm chart.
  - Pre-configured with Loki datasource.
  - Setup details: [docs/grafana.md](./grafana.md)
- **Collector:** [Grafana Alloy](https://grafana.com/docs/alloy/latest/)
  - Installed via official Helm chart (DaemonSet).
  - Collects logs and metrics (replacing Promtail).
  - Setup details: [docs/alloy.md](./alloy.md)

### Cluster Configuration
The cluster is defined in `k3d-config.yaml` and consists of:

- **Topology:**
  - 1 Server Node (Control Plane)
  - 2 Agent Nodes (Workers)
- **Networking:**
  - API Server exposed on port `6443`
  - Host port `8080` mapped to container port `80` (LoadBalancer)
- **Ingress:**
  - Default **Traefik** ingress controller is **DISABLED** (to allow custom ingress setup).

## Setup Instructions

### Prerequisites
- Docker
- k3d
- kubectl

### 1. Create Cluster
To spin up the cluster using the configuration file:

```bash
k3d cluster create --config k3d-config.yaml
```

### 2. Install ArgoCD
Bootstrap the cluster with ArgoCD:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 3. Deploy Stack
Apply the ArgoCD Application manifests to deploy infrastructure and apps.

### Teardown
To delete the cluster:

```bash
k3d cluster delete my-lab-cluster
```
