# Admission policy

Kyverno (`platform/kyverno/`) checks every object as it's admitted against the Lab's policies in `platform/kyverno-policies/` (ADR 0010):

| Policy | What it checks | Mode |
|---|---|---|
| `gpu-workload-shape` | A pod template that requests `amd.com/gpu` is a DaemonSet's, selects `k3d-lab/gpu=amd` and tolerates the `amd.com/gpu` taint (ADR 0006). | Enforced |
| `httproute-on-lab-gateway` | An HTTPRoute's `parentRefs` is the `https` listener of the Gateway `lab` in `gateway`, and its hostnames are under `lab.localhost`. | Enforced |
| `images-pinned` | Every container's image has a tag other than `latest`, or a digest, as admitted, after Kustomize's `images` overrides. | Audit |

An enforced policy rejects a bad object, so its Application fails to sync with the policy named in the error. An Audit policy admits it, and records the violation in a PolicyReport in its namespace (`kubectl get policyreports -A`). The dashboard "Admission policy" shows both. Kyverno doesn't check `kube-system`, `argocd` or its own namespace, and while it's down, objects are admitted unchecked.

To add a policy, write a `ValidatingPolicy` (`policies.kyverno.io/v1`, in CEL) in `platform/kyverno-policies/`, list it in its `kustomization.yaml`, and start it with `validationActions: [Audit]`. Once the Lab has no PolicyReport failing it, switch it to `[Deny]`. Each policy has fixtures in `platform/kyverno-policies/tests/<policy>/`: good and bad objects, with the result each should get. Once it's enforced, `verify/policies-enforced/` applies one of its bad fixtures to the Lab. `just lint` runs them with the Kyverno CLI, and fails if one gets another result, or isn't matched at all. It also checks every component's render against the enforced policies, so a component that would fail its sync fails lint first. A policy on a kind beyond pods and their controllers needs that kind in the reports controller's role in `platform/kyverno/values.yaml`, or it never becomes Ready.
