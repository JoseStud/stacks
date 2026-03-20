#!/usr/bin/env bash

set -euo pipefail

: "${EVENT_NAME:?EVENT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${WORKFLOW_RUN_HEAD_SHA:?WORKFLOW_RUN_HEAD_SHA is required}"
: "${WORKFLOW_RUN_REPOSITORY:?WORKFLOW_RUN_REPOSITORY is required}"
: "${WORKFLOW_RUN_ID:?WORKFLOW_RUN_ID is required}"

CHANGED_PATHS_JSON="${CHANGED_PATHS_JSON:-[]}"

validate_sha() {
  local field_name="$1"
  local sha="${2:-}"

  if ! [[ "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Invalid ${field_name}: '${sha}' (must be 40-char lowercase hex)."
    exit 1
  fi
}

validate_source_repo() {
  local value="${1:-}"

  if ! [[ "${value}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Invalid source_repo '${value}'. Expected 'owner/repo'."
    exit 1
  fi
}

validate_source_run_id() {
  local value="${1:-}"

  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "Invalid source_run_id '${value}'. Expected numeric run id."
    exit 1
  fi
}

validate_changed_paths_json() {
  local value="${1:-}"

  if ! jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null <<<"${value}"; then
    echo "CHANGED_PATHS_JSON must be a JSON array of strings."
    exit 1
  fi
}

is_functional_path() {
  local path="${1}"

  if [[ "${path}" == "stacks.yaml" ]]; then
    return 0
  fi
  if [[ "${path}" == "infisical-agent.yaml" ]]; then
    return 0
  fi
  if [[ "${path}" == auth/config/* ]]; then
    return 0
  fi
  if [[ "${path}" == observability/config/* ]]; then
    return 0
  fi
  if [[ "${path}" == */docker-compose.yml ]]; then
    return 0
  fi
  if [[ "${path}" == */.env.tmpl ]]; then
    return 0
  fi

  return 1
}

classify_dispatch_decision() {
  local changed_json="${1}"
  local -a changed_paths=()
  local changed_path
  local functional_count=0

  mapfile -t changed_paths < <(jq -r '.[]' <<<"${changed_json}")

  if (( ${#changed_paths[@]} == 0 )); then
    echo "true|no-paths-provided"
    return 0
  fi

  for changed_path in "${changed_paths[@]}"; do
    if is_functional_path "${changed_path}"; then
      functional_count=$((functional_count + 1))
    fi
  done

  if (( functional_count > 0 )); then
    echo "true|functional-path-change"
  else
    echo "false|non-functional-change-only"
  fi
}

if [[ "${EVENT_NAME}" != "workflow_run" ]]; then
  echo "Unsupported EVENT_NAME '${EVENT_NAME}'. Expected 'workflow_run'."
  exit 1
fi

validate_sha "stacks_sha" "${WORKFLOW_RUN_HEAD_SHA}"
validate_source_repo "${WORKFLOW_RUN_REPOSITORY}"
validate_source_run_id "${WORKFLOW_RUN_ID}"
validate_changed_paths_json "${CHANGED_PATHS_JSON}"

decision="$(classify_dispatch_decision "${CHANGED_PATHS_JSON}")"
should_dispatch="${decision%%|*}"
dispatch_decision_reason="${decision##*|}"

{
  echo "schema_version=v5"
  echo "stacks_sha=${WORKFLOW_RUN_HEAD_SHA}"
  echo "source_sha=${WORKFLOW_RUN_HEAD_SHA}"
  echo "reason=full-reconcile"
  echo "source_repo=${WORKFLOW_RUN_REPOSITORY}"
  echo "source_run_id=${WORKFLOW_RUN_ID}"
  echo "should_dispatch=${should_dispatch}"
  echo "dispatch_decision_reason=${dispatch_decision_reason}"
} >> "${GITHUB_OUTPUT}"

echo "Schema version: v5"
echo "Stacks SHA: ${WORKFLOW_RUN_HEAD_SHA}"
echo "Source SHA: ${WORKFLOW_RUN_HEAD_SHA}"
echo "Reason: full-reconcile"
echo "Source repo: ${WORKFLOW_RUN_REPOSITORY}"
echo "Source run id: ${WORKFLOW_RUN_ID}"
echo "Changed paths: ${CHANGED_PATHS_JSON}"
echo "Should dispatch: ${should_dispatch}"
echo "Dispatch decision reason: ${dispatch_decision_reason}"
