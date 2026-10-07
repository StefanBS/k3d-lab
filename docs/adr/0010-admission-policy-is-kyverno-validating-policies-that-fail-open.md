# Admission policy is Kyverno ValidatingPolicies that fail open

The Lab's rules, such as "a GPU Workload is a DaemonSet" (ADR 0006) and "an HTTPRoute attaches to the `https` listener of `gateway/lab`", lived in prose and reviews. A Workload that broke one only failed later, as a Pending pod or an unreachable UI (#73). Kyverno (`platform/kyverno/`) now checks them at admission, with policies in `platform/kyverno-policies/`.

- **The policies are `ValidatingPolicy` (`policies.kyverno.io/v1`), written in CEL**, not `ClusterPolicy`. Kyverno 1.19 marks `kyverno.io/v1` `ClusterPolicy` deprecated and due for removal, so a new Lab starts on its replacement. `validationActions: [Audit]` is the old `validationFailureAction: Audit`; `[Deny]` is `Enforce`.
- **They fail open**: each policy is `failurePolicy: Ignore`, so while Kyverno is down, or slow, objects are admitted unchecked rather than not at all. Kyverno's webhooks also skip `kube-system`, `argocd` and `kyverno`, so nothing the Lab needs to come up, or ArgoCD to keep syncing, waits on Kyverno.
- **A policy starts in Audit**, and moves to Deny once the Lab passes it. `gpu-workload-shape` and `httproute-on-lab-gateway` are enforced. `images-pinned` stays in Audit: the Platform's charts pick their own images, and an unpinned one after a chart update should show up in a PolicyReport, not stop that component.

## Considered Options

- **`ClusterPolicy`**, as #73 first described: pattern-based and familiar, but deprecated in the version the Lab installs.
- **`failurePolicy: Fail`**: an enforced policy can't be skipped while Kyverno is down. No deadlock, since Kyverno's own namespace is skipped, but every pod in a checked namespace would wait on Kyverno after a restart of the Host. The policies catch mistakes, not attackers, and verify checks them whenever Kyverno is up.
- **Kubernetes' own ValidatingAdmissionPolicy**: no extra component, and the same CEL. But no PolicyReports, so no Audit to try a policy out against the running Lab first, and no metrics for Grafana.

## Consequences

- A Workload that breaks an enforced policy fails its ArgoCD sync, with the policy named in the error, instead of failing later on a node.
- While Kyverno is down, an object that breaks a policy can get in. The next background scan reports it in its namespace's PolicyReport.
- A policy on a kind that Kubernetes' `view` role doesn't cover, such as HTTPRoutes, needs that kind added to the reports controller's role in `platform/kyverno/values.yaml`, or it never becomes Ready.
