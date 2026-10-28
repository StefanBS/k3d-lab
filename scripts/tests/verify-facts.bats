#!/usr/bin/env bats
# What verify's checks read from Git instead of copying it (scripts/lib/verify-facts.sh),
# from a repo of fixtures rather than the Lab's own: what verify.sh exports to them, and
# what lint reports of the copies they still hold, and of the Demos' unlabelled checks.

setup() {
  for module in platform-facts components nodes verify-facts; do
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib/$module.sh"
  done
  load lab
  LAB_ROOT=$BATS_TEST_TMPDIR/repo
  mkdir -p "$LAB_ROOT/platform/web" "$LAB_ROOT/platform/db" "$LAB_ROOT/verify/web-healthy" "$LAB_ROOT/verify/lib"
  printf 'host: web.lab.localhost\nurl: https://ui.lab.localhost\n' >"$LAB_ROOT/platform/web/values.yaml"
  printf 'namespace: web\n' >"$LAB_ROOT/platform/web/component.yaml"
  printf 'namespace: data\n' >"$LAB_ROOT/platform/db/component.yaml"
  mkdir -p "$LAB_ROOT/workloads/shop"
  printf 'namespace: shop\nrole: demo\n' >"$LAB_ROOT/workloads/shop/component.yaml"
  PLATFORM_FACTS=(
    [web.host]='platform/web/values.yaml|.host'
    [ui.url]='platform/web/values.yaml|.url'
  )
  VERIFY_NAMESPACES=([web]=platform/web [db]=platform/db)
  # A check as it should be: it reads every fact and namespace from verify.sh.
  check web-healthy <<'YAML'
metadata:
  name: web-healthy
  labels:
    k3d-lab/gpu: amd
spec:
  steps:
    - try:
        - assert:
            resource:
              metadata:
                namespace: (env('VERIFY_NS_WEB'))
        - script:
            content: curl "https://$PLATFORM_FACT_WEB_HOST/" && kubectl -n "$VERIFY_NS_DB" get pods
YAML
}

# check <name> < <chainsaw-test.yaml>
check() {
  mkdir -p "$LAB_ROOT/verify/$1"
  cat >"$LAB_ROOT/verify/$1/chainsaw-test.yaml"
}

@test "every fact and namespace read from verify.sh, labelled as it selects: no problems" {
  run verify_copies_problems
  [[ $status -eq 0 && -z $output ]]
}

@test "a fact's value, a URL's without its scheme: names the file, line and fact" {
  printf '#!/bin/sh\ncurl https://web.lab.localhost/\n' >"$LAB_ROOT/verify/lib/web.sh"
  printf 'host=ui.lab.localhost\n' >>"$LAB_ROOT/verify/lib/web.sh"
  run verify_copies_problems
  [[ $status -eq 0 ]]
  [[ $output == "verify/lib/web.sh:2 copies the Platform fact web.host (web.lab.localhost); read \$PLATFORM_FACT_WEB_HOST
verify/lib/web.sh:3 copies the Platform fact ui.url (ui.lab.localhost); read \$PLATFORM_FACT_UI_URL" ]]
}

@test "a namespace verify.sh exports, as kubectl, YAML, a URL or a Service's name takes it: names the file, line and variable" {
  cat >"$LAB_ROOT/verify/lib/db.sh" <<'SH'
kubectl -n data get pods
kubectl --namespace=web get pods
kubectl get --raw /api/v1/namespaces/data/services/db:http/proxy/
wget http://db.data.svc:5432/
x_k8s_get($client, 'v1', 'Pod', 'web', 'db')
# The namespace web is the one the check reads.
kubectl -n database get pods
kubectl -n webapp get pods
SH
  printf 'metadata:\n  namespace: data\n' >"$LAB_ROOT/verify/lib/db.yaml"
  run verify_copies_problems
  [[ $status -eq 0 ]]
  [[ $output == "verify/lib/db.sh:1 names the namespace data; read \$VERIFY_NS_DB
verify/lib/db.sh:2 names the namespace web; read \$VERIFY_NS_WEB
verify/lib/db.sh:3 names the namespace data; read \$VERIFY_NS_DB
verify/lib/db.sh:4 names the namespace data; read \$VERIFY_NS_DB
verify/lib/db.sh:5 names the namespace web; read \$VERIFY_NS_WEB
verify/lib/db.sh:6 names the namespace web; read \$VERIFY_NS_WEB
verify/lib/db.yaml:2 names the namespace data; read \$VERIFY_NS_DB" ]]
}

@test "a check labelled other than as verify.sh selects: names the file and label" {
  check web-healthy <<'YAML'
metadata:
  name: web-healthy
  labels:
    k3d-lab/gpu: nvidia
    k3d-lab/demos: web
    k3d-lab/demo: web
YAML
  run verify_copies_problems
  [[ $status -eq 0 ]]
  [[ $output == "verify/web-healthy/chainsaw-test.yaml:4 is labelled k3d-lab/gpu=nvidia, which verify.sh doesn't select by: label it k3d-lab/gpu=amd or k3d-lab/demo
verify/web-healthy/chainsaw-test.yaml:5 is labelled k3d-lab/demos=web, which verify.sh doesn't select by: label it k3d-lab/gpu=amd or k3d-lab/demo" ]]
}

@test "the GPU Node's label key outside a check's labels: names the file and line" {
  printf 'spec:\n  nodeSelector: {k3d-lab/gpu: amd}\n' >"$LAB_ROOT/verify/lib/gpu.yaml"
  run verify_copies_problems
  [[ $status -eq 0 ]]
  [[ $output == "verify/lib/gpu.yaml:2 copies the GPU Node's label key k3d-lab/gpu; read \$VERIFY_GPU_NODE_LABEL_KEY" ]]
}

@test "verify_export: every fact, namespace and the GPU Node's label, as the checks read them" {
  verify_export
  [[ $PLATFORM_FACT_WEB_HOST == web.lab.localhost && $PLATFORM_FACT_UI_URL == https://ui.lab.localhost ]]
  [[ $VERIFY_NS_WEB == web && $VERIFY_NS_DB == data ]]
  [[ $VERIFY_GPU_NODE_LABEL_KEY == k3d-lab/gpu && $VERIFY_GPU_NODE_LABEL_VALUE == amd ]]
  [[ $(env | grep -c '^PLATFORM_FACT_\|^VERIFY_') == 6 ]]
}

@test "verify_export: a fact that doesn't resolve fails, saying which" {
  PLATFORM_FACTS[web.port]='platform/web/values.yaml|.port'
  run verify_export
  [[ $status -eq 1 && $output == "error: Platform fact 'web.port' doesn't resolve: no .port in platform/web/values.yaml" ]]
}

@test "a variable verify.sh doesn't export, such as a renamed fact's: names the file, line and variable" {
  cat >"$LAB_ROOT/verify/lib/web.sh" <<'SH'
curl "https://$PLATFORM_FACT_WEB_URL/" "$PLATFORM_FACT_UI_URL"
kubectl -n "${VERIFY_NS_CACHE}" get pods
SH
  printf "nodeSelector: (env('VERIFY_GPU_NODE_LABEL'))\n" >"$LAB_ROOT/verify/lib/gpu.yaml"
  run verify_copies_problems
  [[ $status -eq 0 ]]
  [[ $output == "verify/lib/gpu.yaml:1 reads VERIFY_GPU_NODE_LABEL, which verify.sh doesn't export
verify/lib/web.sh:1 reads PLATFORM_FACT_WEB_URL, which verify.sh doesn't export
verify/lib/web.sh:2 reads VERIFY_NS_CACHE, which verify.sh doesn't export" ]]
}

@test "a check that names a Demo's namespace, unlabelled: names the check and namespace" {
  check orders-healthy <<'YAML'
metadata:
  name: orders-healthy
spec:
  steps:
    - try:
        - script:
            content: kubectl -n shop get pods
YAML
  run demo_checks_problems
  [[ $status -eq 0 ]]
  [[ $output == "verify/orders-healthy/chainsaw-test.yaml names the Demo's namespace shop, but isn't labelled k3d-lab/demo" ]]
}

@test "a check that names a Demo's namespace only in a verify/lib/ script it runs, unlabelled: names the check" {
  printf 'kubectl -n shop get pods\n' >"$LAB_ROOT/verify/lib/orders.sh"
  check orders-healthy <<'YAML'
metadata:
  name: orders-healthy
spec:
  steps:
    - try:
        - script:
            content: ../lib/orders.sh
YAML
  run demo_checks_problems
  [[ $status -eq 0 ]]
  [[ $output == "verify/orders-healthy/chainsaw-test.yaml names the Demo's namespace shop, but isn't labelled k3d-lab/demo" ]]
}

@test "a check that names a Demo's namespace, labelled as a Demo's, and one that names none: no problems" {
  check orders-healthy <<'YAML'
metadata:
  name: orders-healthy
  labels:
    k3d-lab/demo: shop
spec:
  steps:
    - try:
        - script:
            content: kubectl -n shop get pods
YAML
  run demo_checks_problems
  [[ $status -eq 0 && -z $output ]]
}
