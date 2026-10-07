# Network policy for a Workload is tiered, and the Platform owns most of it

A Workload's namespace denies all traffic by default (#76). Most of what each Workload then had to allow was the Platform's business, not its own: DNS through Cilium's proxy, ingress from the Gateway and Alloy's scrape. So network policy for a Workload comes in three tiers:

- **Guardrails**, the Platform's, as `egressDeny` rules in a `CiliumClusterwideNetworkPolicy`: a Workload can't reach the kube-apiserver or the cloud metadata address. Cilium applies a deny over any allow, so a Workload's own policy can't undo them.
- **The baseline**, the Platform's: default-deny, DNS, the Gateway to a pod's port named `http`, Alloy to its port named `metrics`, and every pod in the namespace to every other. The first four are `CiliumClusterwideNetworkPolicy`s that select namespaces labelled `k3d-lab/group: workloads`. The same-namespace allow is a namespaced `CiliumNetworkPolicy` that the `workloads` ApplicationSet adds to each Workload's Application, because a cluster-wide policy can't say "the same namespace as this pod": there, `fromEndpoints: [{}]` means every pod in the cluster. All of it lives in `platform/workload-network-policy/`, the same-namespace allow in its `same-namespace/` folder.
- **The Workload's own** `CiliumNetworkPolicy`: egress by FQDN, calls to other namespaces and L7 rules.

The namespace is the trust boundary: it holds one Workload, with one owner and one trust level. Pods that share an owner, a pipeline and often credentials gain little from policy between them, while the paths that matter, out to the internet, to the kube-apiserver and across namespaces, stay closed by default. A Workload that wants least privilege inside its namespace too sets `isolation: strict` in its `component.yaml`, and then allows its pod-to-pod flows itself. A Workload's namespace labels, its project and its baseline are all set by the Platform from `component.yaml`, so a Workload never labels its own namespace.

The Gateway may reach a pod's `http` port in every Workload, but that doesn't expose anything by itself: the Gateway only sends a pod traffic when an HTTPRoute names its Service. The HTTPRoute and the PodMonitor stay the opt-ins.

Cross-namespace isolation comes from the default-deny, not from a guardrail. A deny would also block the explicit cross-namespace allows that Workloads need, such as the one to their database (ADR 0009).

## Considered Options

- **Explicit allows for every flow, inside the namespace too**, as after #76: least privilege everywhere, which the NSA/CISA hardening guidance and Cilium's docs lean toward. Kept as `isolation: strict`, not the default: inside one owner's namespace it costs every Workload policy for little gain.
- **Every Workload writes its own baseline**: each one copies the Platform's details, and a Platform change has to be made in every Workload.
- **A Kustomize Component the Platform ships, which each Workload includes**: visible in the Workload's folder, but one more line to forget, and an old copy can drift.
- **Opt-in pod labels such as `k3d-lab/expose: gateway`**: the HTTPRoute and the PodMonitor already say the same thing, and two places would have to agree.
- **Kyverno generating policies per namespace**: a new component for what the ApplicationSet already does.
- **Kubernetes' ClusterNetworkPolicy**, which replaced AdminNetworkPolicy and BaselineAdminNetworkPolicy: the Kubernetes API for these same tiers, and Cilium implements it since 1.20, which the Lab runs. But the API is still `v1alpha2`, behind a Cilium flag and a CRD of its own. Its Baseline tier only applies where no NetworkPolicy-tier policy selects the pod, so a Workload's first policy of its own, such as ComfyUI's FQDN egress, would drop the baseline's DNS and Gateway allows with it. And it has no DNS rule, which the FQDN rules need. Its Admin tier could hold the guardrails, but Cilium's `egressDeny` already wins over every allow. Worth revisiting once the API is beta.

## Consequences

- A new Workload that names its ports `http` and `metrics` writes no network policy until it calls the internet or another namespace.
- Reading a Workload's folder no longer shows everything its pods may do. The README's section on network policy and Hubble's dropped flows fill that gap.
- A Workload that ever needs the kube-apiserver needs the guardrail narrowed by the Platform, not an allow of its own.
- Workloads are in their own ArgoCD project, which can't create cluster-scoped resources or deploy into Platform namespaces. That keeps them from writing a `CiliumClusterwideNetworkPolicy` of their own.
- Nothing yet stops a Workload's own policy from allowing too much inside the tiers, for example `toEntities: [world]`. An admission policy would, once the Lab has more than one author.
