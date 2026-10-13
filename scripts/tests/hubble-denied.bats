#!/usr/bin/env bats
# Whether Hubble holds a drop by policy (hubble_denied in verify/lib/checks.sh), with a
# kubectl that answers as the Lab's would. The check runs under pipefail, as here.

setup() {
  # A kubectl that prints one flow per line, pausing between them, as `kubectl exec`
  # does while Hubble Relay streams: a reader that stops at the first flow closes the
  # pipe before the second is written, and kubectl dies of that write, with 141.
  mkdir "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "config current-context") echo chainsaw ;;
  *"get service hubble-relay"*) echo 10.43.0.1:80 ;;
  *"hubble observe"*)
    while IFS= read -r flow; do
      echo "$flow" 2>/dev/null || exit 141
      sleep "${FLOW_PAUSE:-0.2}"
    done <"$FLOWS"
    ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  PATH=$BATS_TEST_TMPDIR/bin:$PATH
  export FLOWS=$BATS_TEST_TMPDIR/flows
  set -o pipefail
  # shellcheck source=../../verify/lib/checks.sh
  source "$BATS_TEST_DIRNAME/../../verify/lib/checks.sh"
  # Its retries wait 3s each.
  sleep() { :; }
}

# flow <drop reason>: a dropped flow as `hubble observe -o jsonpb` prints it, cut down.
flow() { echo "{\"flow\":{\"verdict\":\"DROPPED\",\"drop_reason_desc\":\"$1\"}}"; }

@test "three drops by policy, one per SYN: found, though the first is enough (#107)" {
  { flow POLICY_DENIED; flow POLICY_DENIED; flow POLICY_DENIED; } >"$FLOWS"
  run hubble_denied --from-pod strict/client
  [[ $status -eq 0 ]]
}

@test "a drop by a deny rule: found" {
  flow POLICY_DENY >"$FLOWS"
  run hubble_denied --from-pod guardrail/client
  [[ $status -eq 0 ]]
}

@test "DENIED_BY=POLICY_DENY, and only the default-deny dropped it: not found" {
  { flow POLICY_DENIED; flow POLICY_DENIED; } >"$FLOWS"
  FLOW_PAUSE=0 DENIED_BY=POLICY_DENY run hubble_denied --from-pod guardrail/client
  [[ $status -eq 1 ]]
}

@test "drops for another reason: not found" {
  { flow UNSUPPORTED_L3_PROTOCOL; flow STALE_OR_UNROUTABLE_IP; } >"$FLOWS"
  FLOW_PAUSE=0 run hubble_denied --from-pod strict/client
  [[ $status -eq 1 ]]
}

@test "no flows: not found" {
  : >"$FLOWS"
  run hubble_denied --from-pod strict/client
  [[ $status -eq 1 ]]
}
