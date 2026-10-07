# A Workload's database lives in a namespace of its own, provisioned by the Platform

A namespace holds one trust level (ADR 0008). A database is more sensitive than the Workload that uses it, so it can't share its namespace, or the same-namespace allow would open it to every pod there. Nothing can reliably tell that a pod is a database by looking at it, so this is enforced by how a database comes to exist, not by recognising one afterwards:

- Databases are a Platform capability: the Platform runs an operator (for example CloudNativePG), and a Workload asks for a database by declaring one.
- An ArgoCD AppProject, `data`, may only create the operator's database kinds, and only in `<workload>-data` namespaces. The `workloads` project may not create them at all. A database in the wrong place fails to sync.
- A `-data` namespace is `isolation: strict`. The claim names the Workloads that use the database, and the Platform generates the policy pair between them: egress from the Workload, ingress to the database on its port, and nothing else. The edge stays explicit, and the Workload writes nothing.
- Every namespace and pod carries a trust level, `k3d-lab/trust: app` or `data`. The namespace's comes from the Platform, and a ValidatingAdmissionPolicy rejects a pod whose trust level isn't its namespace's.

None of it is built until the first Workload needs a database: until then nothing would exercise it.

## Considered Options

- **Databases outside the Lab**, as managed services usually are in production: there's no managed database service on the Host, and the Lab exists to run things in Kubernetes.
- **Workloads deploy their own databases, with a label saying what they are**: a self-declared label is the only signal, and a database without one passes.
- **Detecting databases**, by image, port or a StatefulSet with a PVC: heuristics, with false positives either way. Worth running as a report, not as the enforcement.

## Consequences

- A Workload can't run a database in its own namespace, even a throwaway one: it asks the Platform.
- Each database is reachable only by the Workloads its claim names.
- The Platform takes on an operator and its upgrades.
