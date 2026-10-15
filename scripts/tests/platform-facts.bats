#!/usr/bin/env bats
# Platform facts (scripts/lib/platform-facts.sh), from a table and values files of
# fixtures rather than the Lab's own: reading one, and what lint reports of them all.

setup() {
  # shellcheck source=../lib/platform-facts.sh
  source "$BATS_TEST_DIRNAME/../lib/platform-facts.sh"
  load lab
  LAB_ROOT=$BATS_TEST_TMPDIR/repo
  mkdir -p "$LAB_ROOT/platform/web"
  printf 'host: web.lab.localhost\nip: 172.28.0.2\nempty: null\n' >"$LAB_ROOT/platform/web/values.yaml"
  LAB_SERVER_IP=172.28.0.2
  PLATFORM_FACTS=(
    [web.host]='platform/web/values.yaml|.host'
    [web.ip]='platform/web/values.yaml|.ip'
  )
  PLATFORM_PINNED_FACTS=([web.ip]=LAB_SERVER_IP)
}

@test "a fact: its value" {
  run platform_fact web.host
  [[ $status -eq 0 && $output == web.lab.localhost ]]
}

@test "no such fact, or one that finds null: fails, saying which" {
  run platform_fact web.port
  [[ $status -eq 1 && $output == "error: no Platform fact named 'web.port'" ]]
  PLATFORM_FACTS[web.empty]='platform/web/values.yaml|.empty'
  run platform_fact web.empty
  [[ $status -eq 1 && $output == "error: Platform fact 'web.empty' doesn't resolve: no .empty in platform/web/values.yaml" ]]
}

@test "every fact resolves, and the pinned one is its constant: no problems" {
  run platform_facts_problems
  [[ $status -eq 0 && -z $output ]]
}

@test "a fact that doesn't resolve, and a pinned one that isn't its constant: names each" {
  PLATFORM_FACTS[web.port]='platform/web/values.yaml|.port'
  LAB_SERVER_IP=172.28.0.9
  run platform_facts_problems
  [[ $status -eq 0 ]]
  [[ $output == "Platform fact 'web.ip' is '172.28.0.2', not LAB_SERVER_IP (172.28.0.9)
Platform fact 'web.port' doesn't resolve: no .port in platform/web/values.yaml" ]]
}
