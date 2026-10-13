# Progressive delivery

**Argo Rollouts** (`platform/argo-rollouts/`) releases Workloads by canary, and its dashboard at https://rollouts.lab.localhost shows every Rollout, and promotes or aborts one, behind the Lab login. A canary's traffic is split for real, by weight, at the Lab's Gateway: Rollouts' Gateway API plugin sets the weights of the Rollout's HTTPRoute, which Cilium applies. ArgoCD leaves those weights alone, as it does the version that Rollouts adds to each of the Rollout's Services' selectors (see [GitOps](gitops.md)).

The demo Rollout (`workloads/rollouts-demo/`) is a Demo, so a Lab has it only when asked: build the Lab with `just up --demos`, or add it to a running one with `just demos on`. It's podinfo, at https://rollouts-demo.lab.localhost. A small load generator sends it 5 requests per second through the Gateway. A canary goes through these steps:

1. 20% of the traffic goes to the new version, then the analysis runs.
2. 50%, then the analysis.
3. 80%, then the analysis.
4. 100%: the new version becomes the stable one.

The analysis (`error-rate`, in `analysis.yaml`) asks Prometheus what share of the new version's requests failed (a 4xx or 5xx) over the last minute, from podinfo's own metrics, which Alloy scrapes every 10s. It measures 3 times, 30s apart, after waiting 1 minute for samples. More than one measurement at 5% or above, or with no requests to measure, aborts the canary: all traffic goes back to the stable version, and the Rollout is Degraded until Git changes again.

To try it, push a change to the branch the Lab tracks, and watch the dashboard, or the page itself, which shows the version that answered:

- **A canary that completes:** change `newTag` in `workloads/rollouts-demo/kustomization.yaml`.
- **A canary that's rolled back:** set `PODINFO_RANDOM_ERROR` to `"true"` in `rollout.yaml`, with or without a new tag. That alone is a new version, and about a fifth of its requests fail. Revert it to make the Rollout Healthy again.
