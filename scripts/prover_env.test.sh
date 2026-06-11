#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=./prover_env.sh
source "$SCRIPT_DIR/prover_env.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "$message: expected '$expected', got '$actual'"
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    fail "$message"
  fi
}

echo "== prover env defaults =="
unset USE_REAL_PROVER USE_MOCK_PROVER
resolve_cdk_prover_env
assert_eq "true" "$USE_REAL_PROVER" "default USE_REAL_PROVER should be true"
assert_eq "false" "$USE_MOCK_PROVER" "default USE_MOCK_PROVER should be false"

echo "== prover env explicit true =="
USE_REAL_PROVER=true
unset USE_MOCK_PROVER
resolve_cdk_prover_env
assert_eq "true" "$USE_REAL_PROVER" "explicit true should stay true"
assert_eq "false" "$USE_MOCK_PROVER" "explicit true should disable mock prover"

echo "== prover env explicit false =="
USE_REAL_PROVER=false
unset USE_MOCK_PROVER
resolve_cdk_prover_env
assert_eq "false" "$USE_REAL_PROVER" "explicit false should stay false"
assert_eq "true" "$USE_MOCK_PROVER" "explicit false should enable mock prover"

echo "== prover env invalid values =="
USE_REAL_PROVER=TRUE
if resolve_cdk_prover_env 2>/dev/null; then
  fail "invalid USE_REAL_PROVER should fail"
fi

echo "== cdk_pipe state consistency hooks =="
CDK_PIPE="$REPO_ROOT/cdk_pipe.sh"
assert_file_contains "$CDK_PIPE" 'INPUT_USE_REAL_PROVER=' "cdk_pipe.sh should record USE_REAL_PROVER input"
assert_file_contains "$CDK_PIPE" 'check_input_env_consistency USE_REAL_PROVER' "cdk_pipe.sh should reject inconsistent USE_REAL_PROVER on resume"
assert_file_contains "$CDK_PIPE" 'resolve_cdk_prover_env' "cdk_pipe.sh should normalize USE_REAL_PROVER in the parent shell"

echo "== rendered params combinations =="
for value in true false; do
  USE_REAL_PROVER="$value"
  resolve_cdk_prover_env
  rendered="$(envsubst < "$SCRIPT_DIR/params.template.yml")"
  if [[ "$value" == "true" ]]; then
    [[ "$rendered" == *"zkevm_use_real_verifier: true"* ]] || fail "true mode should render real verifier true"
    [[ "$rendered" == *"zkevm_use_real_prover_client: false"* ]] || fail "true mode should keep real prover client false"
    [[ "$rendered" == *"zkevm_use_mock_prover_client: false"* ]] || fail "true mode should render mock prover false"
  else
    [[ "$rendered" == *"zkevm_use_real_verifier: false"* ]] || fail "false mode should render real verifier false"
    [[ "$rendered" == *"zkevm_use_real_prover_client: false"* ]] || fail "false mode should keep real prover client false"
    [[ "$rendered" == *"zkevm_use_mock_prover_client: true"* ]] || fail "false mode should render mock prover true"
  fi
done

echo "prover_env.test.sh passed"
