# Envoy Gateway Setup

This document details the setup of [Envoy Gateway](https://gateway.envoyproxy.io/) as the implementation of the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/).

## Prerequisites

- A running Kubernetes cluster (k3d/k3s).
- `kubectl` installed and configured.

## Installation

We use the official installation manifest which includes the necessary CRDs and the Envoy Gateway controller.

### 1. Install Envoy Gateway

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.2.0 -n envoy-gateway-system --create-namespace
```

*Note: Alternatively, you can install using the static manifest:*

```bash
kubectl apply --server-side -f https://github.com/envoyproxy/gateway/releases/download/v1.2.0/install.yaml
```

### 2. Verify Installation

Wait for the Envoy Gateway controller to be ready:

```bash
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
```

## Configuration

### 1. Create GatewayClass

The `GatewayClass` defines the controller that will manage the Gateways.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

### 2. Create Gateway

The `Gateway` resource triggers the creation of the Envoy Proxy infrastructure (Deployment, Service, etc.).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
```

Once applied, Envoy Gateway will provision a Service of type `LoadBalancer` (managed by k3d) to expose port 80.

### 3. Testing (HTTPRoute)

To route traffic to a service, define an `HTTPRoute`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-app-1
  namespace: default
spec:
  parentRefs:
    - name: my-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /get
      backendRefs:
        - name: httpbin
          port: 80
```

