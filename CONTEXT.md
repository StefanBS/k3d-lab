# k3d-lab

A disposable Kubernetes lab on a single workstation, managed with GitOps, for experimenting with networking, progressive delivery, observability and GPU scheduling.

## Language

### Machines

**Host**:
The workstation that runs the Lab's k3d Nodes.
_Avoid_: laptop, local machine, server

**k3d Node**:
A Kubernetes node that runs as a container on the Host.
_Avoid_: container node, docker node

**GPU Node**:
The physical machine on the LAN that joins the Lab as an Agent, so GPU Workloads can be scheduled on it.
_Avoid_: physical node, GPU box, worker

**Joined**:
The GPU Node's state when it's registered with the current Lab and lending its GPU to it. A Joined GPU Node may be powered off; it's then unreachable, not Left.
_Avoid_: online, active, attached

**Left**:
The GPU Node's state when it's not registered with the current Lab, so its GPU belongs entirely to its owner. It's the state after every reboot, until the next join.
_Avoid_: offline, detached, removed

**Stale install**:
A k3s install on the GPU Node that belongs to an earlier Lab, which no longer exists. The GPU Node is Left; the next join cleans the install up before joining.
_Avoid_: old install, leftover node

**Server**:
A node running the k3s control plane. The Lab has exactly one, and it is a k3d Node.
_Avoid_: master, control-plane node

**Agent**:
A node that only runs pods and is joined to the Server. It can be a k3d Node or the GPU Node.
_Avoid_: worker

### What runs in the Lab

**Lab**:
The whole environment: the cluster, its Platform, its Workloads and any joined GPU Node.
_Avoid_: cluster (when the whole environment is meant), environment

**Platform**:
The infrastructure components the Lab provides to Workloads, such as networking, GitOps, progressive delivery, observability and GPU enablement.
_Avoid_: infra, system apps, add-ons

**Secret Store**:
The vault on the Host that holds the secrets Workloads need. It lives outside the Lab, so it survives tearing the Lab down.
_Avoid_: vault (on its own), secrets manager

**Lab CA**:
The certificate authority on the Host that signs every TLS certificate the Lab and the Secret Store serve. The Host trusts it once, and it survives tearing the Lab down.
_Avoid_: self-signed cert, root cert

**Workload**:
Something deployed into the Lab as an experiment, running on top of the Platform.
_Avoid_: application, app (clashes with ArgoCD's `Application`)

**Demo**:
A Workload that exists to show a Platform component working, not to be used. A Lab has its Demos only when asked for.
_Avoid_: example, sample app

**GPU Workload**:
A Workload that requests the GPU Node's GPU (`amd.com/gpu`) and tolerates its taint, so it runs only on the GPU Node, and only while it's Joined.
_Avoid_: GPU job, GPU app

**Paused**:
A Workload's or Platform component's state while ArgoCD neither syncs nor self-heals its Application (`just pause`), so changes made by hand to it stay until `just resume` puts Git back.
_Avoid_: frozen, suspended, detached

### Network policy

**Guardrails**:
The Platform's deny rules for every Workload, which a Workload's own policy can't undo: no egress to the kube-apiserver or the cloud metadata address.
_Avoid_: deny list, hard limits

**Baseline**:
What the Platform allows every Workload without a policy of its own: DNS, the Gateway to a port named `http`, Alloy to a port named `metrics`, and every pod in its namespace to every other. Everything else is denied.
_Avoid_: default policy, defaults

**Workload policy**:
The `CiliumNetworkPolicy` in a Workload's own folder, for what only the Workload knows: egress by FQDN, calls to another namespace, and L7 rules.
_Avoid_: app policy, custom policy

**Strict isolation**:
A Workload's opt-out of the Baseline's same-namespace allow, set with `isolation: strict` in its `component.yaml`, so its pods only reach each other where its Workload policy says so.
_Avoid_: zero trust, locked down
