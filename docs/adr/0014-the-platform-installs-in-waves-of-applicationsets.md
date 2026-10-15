# The Platform installs in Waves of ApplicationSets

A new Lab synced every Application at once. One that needed another's CRDs or webhook, such as an `ExternalSecret` before ESO or a `Certificate` before cert-manager, failed and retried until they were up. That worked, but a new Lab's first minutes were mostly failed syncs, and nothing said what a component needed first. The Platform now installs in Waves: a component that others need first sets `wave` in its `component.yaml`, and `gitops/values.yaml` lists the Waves in order.

- **One ApplicationSet per Wave, ordered by the root Application's sync waves.** `platform-crds` is sync wave 0, `platform-controllers` 1, `platform` (every component that sets no Wave) 2, and `workloads` 3. The root Application's sync applies each only once the one before is Healthy.
- **An ApplicationSet is Healthy once every Application it generated is** (a health check in `platform/argocd/values.yaml`). ArgoCD's own check says Healthy once the Applications exist, which would order nothing.
- **Progressive Syncs are enabled, but no ApplicationSet uses them.** With the flag on, an Application's change of health requeues its ApplicationSet, so its status says so within seconds. With it off, that waits for the next refresh, three minutes later, and so would every Wave.
- **A sync times out after 15 minutes** (`controller.sync.timeout.seconds`), twice the 8 minutes a new Lab's root sync took. It applies to every sync, since ArgoCD has no timeout per Application. A root sync behind a Wave that never gets Healthy would otherwise run forever, and the root couldn't sync another revision.

## Considered Options

- **RollingSync**, the ApplicationSet's own ordering by label, with one ApplicationSet. It turns every generated Application's automated sync off, and syncs one itself only when it's OutOfSync. Self-heal would go with it, and with it the Lab's rule that a change made by hand is undone.
- **Sync waves on the generated Applications.** ArgoCD orders resources within one Application's sync. The Applications belong to the ApplicationSet controller, not to the root Application's sync, so their sync waves order nothing.
- **Keep retrying, unordered.** It already works. But the order lived nowhere but in the retries, and a new Lab spent its first minutes on syncs bound to fail.

## Consequences

- Only a new Lab, or a root sync, waits on the Waves. Once the ApplicationSets exist, each Application syncs a new commit by itself. A component that starts needing new CRDs still retries until they're up.
- `just track` waits for the root Application to be Settled, which now takes until every Application is Healthy.
- A component in a Wave can't serve a UI through the Gateway: ArgoCD calls its HTTPRoute Progressing until the Gateway, installed after the Waves, accepts it, so its Wave would never be Healthy. Lint fails on one. That's why ArgoCD and Argo Rollouts, whose CRDs nothing in the Platform uses, are in no Wave.
- Components installed together, in a Wave or after them, still race. An admission policy on a Platform component's kind, such as Argo Rollouts' `Rollout`, gets the reports controller's read rule in `platform/kyverno/values.yaml`: Kyverno found it couldn't read Rollouts before Argo Rollouts added them to `view`, and the policy stayed not Ready.
- A Wave that lists no component would never be Healthy, so lint fails on one. So does a `wave` that `gitops/values.yaml` doesn't list, which no ApplicationSet would select.
- `up` waits up to 15 minutes, not 5, for the ApplicationSets to exist: the last appears near the end of the Platform's install.
