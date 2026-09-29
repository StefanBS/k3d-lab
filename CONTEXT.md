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
