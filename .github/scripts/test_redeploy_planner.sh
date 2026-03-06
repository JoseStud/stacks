#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLANNER="${ROOT_DIR}/.github/scripts/plan_redeploy_payload.sh"
VALIDATOR="${ROOT_DIR}/.github/scripts/validate_dispatch_payload.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not found."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  local message="$1"
  echo "[PASS] ${message}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  local message="$1"
  echo "[FAIL] ${message}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
  local case_name="$1"
  local key="$2"
  local expected="$3"
  local actual="$4"

  if [[ "${expected}" == "${actual}" ]]; then
    pass "${case_name}: ${key}=${expected}"
  else
    fail "${case_name}: ${key} expected='${expected}' actual='${actual}'"
  fi
}

read_output() {
  local file="$1"
  local key="$2"
  grep -E "^${key}=" "${file}" | tail -n1 | cut -d= -f2- || true
}

run_workflow_run_case() {
  local case_name="$1"
  local head_sha="$2"
  local source_repo="$3"
  local run_id="$4"
  local output_file="${TMP_DIR}/${case_name}.out"

  (
    cd "${ROOT_DIR}"
    export EVENT_NAME="workflow_run"
    export GITHUB_OUTPUT="${output_file}"
    export WORKFLOW_RUN_HEAD_SHA="${head_sha}"
    export WORKFLOW_RUN_REPOSITORY="${source_repo}"
    export WORKFLOW_RUN_ID="${run_id}"
    "${PLANNER}"
  ) >/dev/null

  echo "${output_file}"
}

valid_sha="$(printf 'a%.0s' $(seq 1 40))"
planner_out="$(run_workflow_run_case "workflow_run_payload" "${valid_sha}" "example/stacks" "12345")"
assert_eq "workflow_run_payload" "schema_version" "v5" "$(read_output "${planner_out}" "schema_version")"
assert_eq "workflow_run_payload" "stacks_sha" "${valid_sha}" "$(read_output "${planner_out}" "stacks_sha")"
assert_eq "workflow_run_payload" "source_sha" "${valid_sha}" "$(read_output "${planner_out}" "source_sha")"
assert_eq "workflow_run_payload" "reason" "full-reconcile" "$(read_output "${planner_out}" "reason")"
assert_eq "workflow_run_payload" "source_repo" "example/stacks" "$(read_output "${planner_out}" "source_repo")"
assert_eq "workflow_run_payload" "source_run_id" "12345" "$(read_output "${planner_out}" "source_run_id")"
assert_eq "workflow_run_payload" "should_dispatch" "true" "$(read_output "${planner_out}" "should_dispatch")"

valid_payload_json="$(
  jq -cn \
    --arg schema_version "v5" \
    --arg stacks_sha "${valid_sha}" \
    --arg source_sha "${valid_sha}" \
    --arg source_repo "example/stacks" \
    --argjson source_run_id 12345 \
    --arg reason "full-reconcile" \
    '{
      schema_version: $schema_version,
      stacks_sha: $stacks_sha,
      source_sha: $source_sha,
      source_repo: $source_repo,
      source_run_id: $source_run_id,
      reason: $reason
    }'
)"

if (
  export PAYLOAD_JSON="${valid_payload_json}"
  export PAYLOAD_SCHEMA_VERSION="v5"
  export PAYLOAD_STACKS_SHA="${valid_sha}"
  export PAYLOAD_SOURCE_SHA="${valid_sha}"
  export PAYLOAD_REASON="full-reconcile"
  export PAYLOAD_SOURCE_REPO="example/stacks"
  export PAYLOAD_SOURCE_RUN_ID="12345"
  "${VALIDATOR}"
); then
  pass "dispatch_payload_v5_valid"
else
  fail "dispatch_payload_v5_valid"
fi

if (
  export PAYLOAD_SCHEMA_VERSION="v4"
  export PAYLOAD_STACKS_SHA="${valid_sha}"
  export PAYLOAD_SOURCE_SHA="${valid_sha}"
  export PAYLOAD_REASON="full-reconcile"
  export PAYLOAD_SOURCE_REPO="example/stacks"
  export PAYLOAD_SOURCE_RUN_ID="12345"
  "${VALIDATOR}"
); then
  fail "dispatch_payload_v4_rejected: expected failure"
else
  pass "dispatch_payload_v4_rejected"
fi

if (
  export PAYLOAD_SCHEMA_VERSION="v5"
  export PAYLOAD_STACKS_SHA="${valid_sha}"
  export PAYLOAD_SOURCE_SHA="${valid_sha}"
  export PAYLOAD_REASON="full-reconcile"
  export PAYLOAD_SOURCE_REPO="example/stacks"
  export PAYLOAD_SOURCE_RUN_ID="12345"
  export PAYLOAD_CHANGED_STACKS_JSON="[\"gateway\"]"
  "${VALIDATOR}"
); then
  fail "dispatch_payload_removed_changed_stacks: expected failure"
else
  pass "dispatch_payload_removed_changed_stacks"
fi

if (
  export PAYLOAD_SCHEMA_VERSION="v5"
  export PAYLOAD_STACKS_SHA="${valid_sha}"
  export PAYLOAD_SOURCE_SHA="${valid_sha}"
  export PAYLOAD_REASON="full-reconcile"
  export PAYLOAD_SOURCE_REPO="example/stacks"
  export PAYLOAD_SOURCE_RUN_ID="12345"
  export PAYLOAD_HOST_SYNC_STACKS_JSON="[\"gateway\"]"
  "${VALIDATOR}"
); then
  fail "dispatch_payload_removed_host_sync_stacks: expected failure"
else
  pass "dispatch_payload_removed_host_sync_stacks"
fi

if (
  export PAYLOAD_SCHEMA_VERSION="v5"
  export PAYLOAD_STACKS_SHA="${valid_sha}"
  export PAYLOAD_SOURCE_SHA="${valid_sha}"
  export PAYLOAD_REASON="full-reconcile"
  export PAYLOAD_SOURCE_REPO="example/stacks"
  export PAYLOAD_SOURCE_RUN_ID="12345"
  export PAYLOAD_CONFIG_STACKS_JSON="[\"gateway\"]"
  "${VALIDATOR}"
); then
  fail "dispatch_payload_removed_config_stacks: expected failure"
else
  pass "dispatch_payload_removed_config_stacks"
fi

if (
  export PAYLOAD_SCHEMA_VERSION="v5"
  export PAYLOAD_STACKS_SHA="${valid_sha}"
  export PAYLOAD_SOURCE_SHA="${valid_sha}"
  export PAYLOAD_REASON="full-reconcile"
  export PAYLOAD_SOURCE_REPO="example/stacks"
  export PAYLOAD_SOURCE_RUN_ID="12345"
  export PAYLOAD_STRUCTURAL_CHANGE="true"
  "${VALIDATOR}"
); then
  fail "dispatch_payload_removed_structural_change: expected failure"
else
  pass "dispatch_payload_removed_structural_change"
fi

if (
  export PAYLOAD_SCHEMA_VERSION="v5"
  export PAYLOAD_STACKS_SHA="${valid_sha}"
  export PAYLOAD_SOURCE_SHA="${valid_sha}"
  export PAYLOAD_REASON="full-reconcile"
  export PAYLOAD_SOURCE_REPO="example/stacks"
  export PAYLOAD_SOURCE_RUN_ID="12345"
  export PAYLOAD_CHANGED_PATHS_JSON="[\"gateway/.env.tmpl\"]"
  "${VALIDATOR}"
); then
  fail "dispatch_payload_removed_changed_paths: expected failure"
else
  pass "dispatch_payload_removed_changed_paths"
fi

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
