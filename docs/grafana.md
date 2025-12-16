# Grafana Setup

This document details the setup of [Grafana](https://grafana.com/grafana/) for visualization.

## Installation

Grafana is deployed via ArgoCD using the official [Grafana Helm Chart](https://grafana.github.io/helm-charts).

### Configuration

- **Chart:** `grafana`
- **Version:** `10.3.1`
- **Namespace:** `monitoring`

**Key Settings:**
- **Persistence:** Disabled (for local lab simplicity).
- **Admin Password:** Set to `admin` (change in production!).
- **Datasources:** Automatically configured to connect to the internal Loki instance.

### Deployment Manifest

The ArgoCD Application manifest is located at `infrastructure/grafana.yaml`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grafana
  namespace: argocd
spec:
  source:
    chart: grafana
    repoURL: https://grafana.github.io/helm-charts
    targetRevision: 10.3.1
    helm:
      values: |
        persistence:
          enabled: false
        adminPassword: admin
        datasources:
          datasources.yaml:
            apiVersion: 1
            datasources:
            - name: Loki
              type: loki
              url: http://loki-gateway.monitoring.svc.cluster.local
              access: proxy
              isDefault: true
```

## Accessing Grafana

To access the Grafana UI:

1. **Port Forward:**
   ```bash
   kubectl port-forward svc/grafana -n monitoring 3000:80
   ```

2. **Login:**
   - URL: `http://localhost:3000`
   - User: `admin`
   - Password: `admin`

## Verifying Loki Datasource

1. Log in to Grafana.
2. Navigate to **Connections** -> **Data sources**.
3. You should see **Loki** listed as the default datasource.
4. Click on it and scroll down to click **Save & test**. You should see a green "Data source connected and labels found." message.
5. Go to **Explore**, select **Loki**, and try querying `{app="loki"}` (if self-monitoring is on) or just check for available labels.
