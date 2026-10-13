# GitOps

`just up` installs Cilium and ArgoCD with Helm, then applies one root Application. From then on ArgoCD manages the whole Lab, Cilium and itself included, from the branch `up` built it from (or the `REVISION` you gave it). A change pushed there is applied without running `up` again.

The root Application syncs two ApplicationSets from `gitops/`: **Platform**, one Application per folder in `platform/`, and **Workloads**, one per folder in `workloads/`. Adding a component means adding one folder, `<group>/<name>/`, holding:

- `component.yaml`: the upstream chart (`chart`, `repoURL`, a pinned `version`) and the `namespace` to install it in.
- `values.yaml`: the chart's values. For Cilium and ArgoCD, `just up` installs from the same file, so bootstrap and ArgoCD never disagree.

A component with no upstream chart, such as the Lab's own Gateway, leaves `chart`, `repoURL` and `version` out of `component.yaml`, and holds a `kustomization.yaml` instead of `values.yaml`.

Each ApplicationSet's Applications run in the ArgoCD project of the same name (`gitops/templates/appprojects.yaml`), and the root Application runs in `platform`. `platform` may install anything. `workloads` may only create namespaced resources, and not in a Platform namespace or Kubernetes' own: ArgoCD refuses the sync otherwise. Since the gitops chart can't read `component.yaml`, it lists the Platform's namespaces in `gitops/values.yaml`, and `just lint` fails until a new Platform namespace is added there. ArgoCD's `default` project allows nothing, so an Application that names no project fails rather than running unconfined.

The Platform also sets up each Workload's namespace: it's labelled `k3d-lab/group: workloads`, and `k3d-lab/isolation: strict` too if the Workload's `component.yaml` sets `isolation: strict`. A Workload never labels its own namespace. A Workload that sets `role: demo` in its `component.yaml` is a Demo: the Workloads ApplicationSet leaves it out unless the Lab was asked for its Demos. Unless it's `isolation: strict`, its Application also gets the baseline's same-namespace allow (see [Network policy for a Workload](networking.md#network-policy-for-a-workload)).

Every Application syncs automatically, with pruning and self-heal: a change made by hand with `kubectl` is undone. There are two exceptions, in every Application, because Argo Rollouts sets them during a canary (see [Progressive delivery](progressive-delivery.md)): the backend weights of an HTTPRoute, and the `rollouts-pod-template-hash` key of a Service's selector. ArgoCD neither reports nor reverts them. Applications sync in no particular order, Platform and Workloads alike. One that needs CRDs another component installs fails, and retries until they exist.

`just lint` renders every component with its pinned chart and values, or its kustomization, and its Application as the ApplicationSet generates it, and validates the output with `kubeconform`.
