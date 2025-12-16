# Grafana Alloy Setup

This document details the setup of [Grafana Alloy](https://grafana.com/docs/alloy/latest/) for log and metric collection (replacing Promtail).

## Installation

Alloy is deployed via ArgoCD using the official [Grafana Alloy Helm Chart](https://grafana.github.io/helm-charts).

### Configuration

- **Chart:** `alloy`
- **Version:** `1.5.0`
- **Namespace:** `monitoring`
- **Mode:** `DaemonSet` (Runs on every node to collect logs)

**Key Configuration (Alloy Config):**
The configuration reads log files directly from the host filesystem (which is more efficient and reliable than querying the API):
1.  **Volumes:** Host paths `/var/log` and `/var/lib/docker/containers` are mounted into the Alloy pod.
2.  **Discovery:** Finds all pods running on the node (`discovery.kubernetes`).
3.  **Relabeling:** Adds metadata (namespace, pod, app) AND constructs the `__path__` to the log file on the host (e.g., `/var/log/pods/*<pod-uid>/*.log`).
4.  **Collection:** Tails the files defined by `__path__` using `loki.source.file`.
5.  **Forwarding:** Sends logs to the internal Loki instance (`loki.write`).

### Deployment Manifest

The ArgoCD Application manifest is located at `infrastructure/alloy.yaml`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy
  namespace: argocd
spec:
  source:
    chart: alloy
    repoURL: https://grafana.github.io/helm-charts
    targetRevision: 1.5.0
    helm:
      values: |
        controller:
          type: daemonset
          volumes:
            - name: varlog
              hostPath:
                path: /var/log
            - name: varlibdockercontainers
              hostPath:
                path: /var/lib/docker/containers
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
        alloy:
          configMap:
            content: |
              # ... (discovery and relabeling rules) ...
              loki.source.file "pods" {
                targets    = discovery.relabel.pods.output
                forward_to = [loki.write.default.receiver]
              }
              loki.write "default" {
                endpoint {
                  url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
                }
              }
```

## Verifying Log Flow

1.  **Check Pods:** Ensure Alloy pods are running on all nodes:
    ```bash
    kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy
    ```
2.  **Check Grafana:**
    - Go to Grafana Explore.
    - Select **Loki** datasource.
    - Query `{app="logger"}` (if you deployed the test app) or `{namespace="monitoring"}`.
