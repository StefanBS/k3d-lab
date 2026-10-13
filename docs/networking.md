# Networking

Cilium is the Lab's network, and Hubble shows what travels over it. Hubble is part of Cilium (`platform/cilium/values.yaml`); `platform/hubble/` adds its UI's HTTPRoute and its ServiceMonitor.

- **Hubble UI**, at https://hubble.lab.localhost, behind the Lab login, shows every namespace's flows live, from Hubble Relay, which gathers them from the cilium-agent on every node, the GPU Node included while it's Joined.
- **Flow metrics**: every cilium-agent counts the flows it sees, forwarded and dropped, by namespace at both ends, and Alloy scrapes them like any other ServiceMonitor. The dashboard "Hubble network" shows drops by reason and by namespace. DNS and HTTP counts only cover the traffic that a network policy's DNS or HTTP rule sends through Cilium's proxies.

## Network policy for a Workload

Each Workload's namespace denies all traffic, in and out, except what a policy allows. The Platform writes most of that policy, in three tiers (ADR 0008):

- **The guardrails** (`platform/workload-network-policy/guardrails.yaml`): no Workload reaches the kube-apiserver or the cloud metadata address, whatever its own policy allows.
- **The baseline**, which every Workload gets without writing anything: DNS, through Cilium's DNS proxy; the Gateway to any port named `http`; Alloy to any port named `metrics`; and every pod in the namespace to every other. All but the last are cluster-wide policies in `platform/workload-network-policy/`, for every namespace labelled `k3d-lab/group: workloads`. The same-namespace allow is a `CiliumNetworkPolicy` named `same-namespace`, which the `workloads` ApplicationSet adds to the Workload's own namespace.
- **The Workload policy**, its own `network-policy.yaml`, only for what's its business: egress to the internet by FQDN, calls to another namespace, and L7 rules.

So a new Workload that names its ports `http` and `metrics` writes no policy until it calls the internet or another namespace. Naming the ports doesn't expose anything by itself: the Gateway only reaches a pod through an HTTPRoute, and Alloy through a PodMonitor or ServiceMonitor. The Platform's namespaces have no policies yet.

A Workload that sets `isolation: strict` in its `component.yaml` doesn't get the same-namespace allow: its pods only reach each other where its own policy says so.

A denied flow shows in Hubble UI, and in `hubble observe -n <namespace> --verdict DROPPED`, as `Policy denied`, or `Policy denied by denylist` for a guardrail. To find what a Workload needs, watch its flows in Hubble UI before writing its policy, then watch for drops after. Two things that Hubble shows and aren't obvious:

- The Gateway's Envoy has the `ingress` identity, so a rule for requests through the Gateway, such as an L7 one, says `fromEntities: [ingress]`.
- A pod calling a Workload through the Gateway, such as the demo's load generator, needs egress to the Workload's pods, not to the Gateway: Envoy checks the caller's policy against the backend, and answers 403 when it's denied. In the same namespace, the baseline already allows it.
