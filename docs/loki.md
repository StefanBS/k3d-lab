# Loki Logging Setup

This document details the setup of [Loki](https://grafana.com/oss/loki/) for log aggregation.

## Installation

Loki is deployed via ArgoCD using the official [Grafana Loki Helm Chart](https://grafana.github.io/helm-charts).

### Configuration

We use the **Single Binary** deployment mode, which is suitable for local development and small-scale setups.

- **Chart:** `grafana/loki`
- **Version:** `6.27.0`
- **Namespace:** `monitoring`

**Key Settings:**
- **Deployment Mode:** `SingleBinary`
- **Replicas:** 1
- **Storage:** Filesystem (no object storage required for this lab configuration)
- **MinIO:** Disabled
- **Auth:** Disabled (for simplicity in lab)

### Deployment Manifest

The ArgoCD Application manifest is located at `infrastructure/loki.yaml`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd
spec:
  source:
    chart: loki
    repoURL: https://grafana.github.io/helm-charts
    targetRevision: 6.27.0
    helm:
      values: |
        loki:
          commonConfig:
            replication_factor: 1
          storage:
            type: 'filesystem'
          # ... (see full file for details)
        deploymentMode: SingleBinary
        singleBinary:
          replicas: 1
        read:
          replicas: 0
        write:
          replicas: 0
        backend:
          replicas: 0
```

## Accessing Loki

Loki exposes a gateway service that can be used to query logs.

**Service Name:** `loki-gateway`
**Namespace:** `monitoring`
**Port:** `80`

To query via `curl` (port-forward first):

```bash
kubectl port-forward svc/loki-gateway -n monitoring 3100:80
curl http://localhost:3100/loki/api/v1/ready
```

