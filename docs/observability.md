# Observability

## Metrics

Each component comes from its own upstream chart, never an umbrella chart, and all run in the namespace `monitoring`:

- **Alloy** (`platform/alloy/`) is the only collector: a DaemonSet whose pod on each node scrapes what runs there, the kubelet, cAdvisor and every ServiceMonitor or PodMonitor target, and remote-writes it all to Prometheus. Every series carries a `node` label.
- **Prometheus** (`platform/prometheus/`) runs only its server, scrapes nothing itself and accepts remote writes. It keeps 7 days on a 10 Gi volume.
- **kube-state-metrics** and **node-exporter** ship ServiceMonitors that Alloy picks up. node-exporter's `drm` collector reports the GPU Node's GPU. The Prometheus-operator CRDs (`platform/prometheus-operator-crds/`) are only the ServiceMonitor and PodMonitor CRDs; no operator runs.
- **Grafana** (`platform/grafana/`) has Prometheus, Loki and Tempo as its datasources. Anyone can look; changing things takes the Lab login (see [Logging in](logging-in.md)). The password of its Break-glass login is new with every Lab: ESO generates it once into the Secret `grafana-admin` (a `Password` generator in its values), so it never goes in Git.

A chart that ships a ServiceMonitor or PodMonitor is scraped with no change to Alloy, as long as its targets are pods: a target with no pod behind it, such as the API server's endpoints, runs on no node, so no Alloy scrapes it. Alloy and node-exporter tolerate the GPU Node's taint, so its metrics start as soon as it joins.

Dashboards live in Git, in `platform/grafana-dashboards/`: one JSON file each, listed in its `kustomization.yaml`. Grafana loads them without any import. To add one, build it in Grafana, save its JSON (Export, with "Export for sharing externally" off) there with a fixed `uid`, and add the file to the `kustomization.yaml`. Grafana won't save changes to a dashboard from Git: change it by exporting it again over its file.

## Logs

Every pod's logs, on every node, can be searched in Grafana under Explore, with the Loki datasource.

- **Alloy** reads the logs of the pods on its own node from the node's `/var/log/pods` and pushes them to Loki. Each stream is labelled with its `namespace`, `pod`, `container` and `node`, so `{namespace="argocd"}` finds ArgoCD's logs. A Joined GPU Node's logs start as soon as it's Ready.
- **Loki** (`platform/loki/`) comes from the `grafana-community` chart; `grafana/loki` now serves only Enterprise Logs. It runs as one process, in Monolithic mode, and keeps 7 days of logs on a 10 Gi volume.

## Traces

A Workload sends its traces over OTLP to `alloy.monitoring.svc`: port 4317 for gRPC, 4318 for HTTP. They can be searched in Grafana under Explore, with the Tempo datasource, and each span links to its logs and its metrics.

- **Alloy** receives traces only from the pods on its own node: the Service `alloy` routes each pod to the Alloy there. It tags every span with the `k8s.namespace.name` and `k8s.pod.name` of the pod that sent it, found by the pod's IP, and forwards it to Tempo.
- **Tempo** (`platform/tempo/`) comes from the `grafana-community` chart. It runs as one process and keeps 7 days of traces on a 5 Gi volume. Its metrics generator turns every trace into a service graph (`traces_service_graph_*`) and span metrics (`traces_spanmetrics_*`, per `service` and `span_name`), which it remote-writes to Prometheus.
- **Grafana** links a span to its pod's logs in Loki, through those two tags, and to its service's span metrics in Prometheus. Its service graph shows who calls whom.
