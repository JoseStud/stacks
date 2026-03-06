#!/usr/bin/env bash

set -euo pipefail

: "${EVENT_NAME:?EVENT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${WORKFLOW_RUN_HEAD_SHA:?WORKFLOW_RUN_HEAD_SHA is required}"
: "${WORKFLOW_RUN_REPOSITORY:?WORKFLOW_RUN_REPOSITORY is required}"
: "${WORKFLOW_RUN_ID:?WORKFLOW_RUN_ID is required}"

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

if [[ "${EVENT_NAME}" != "workflow_run" ]]; then
  echo "Unsupported EVENT_NAME '${EVENT_NAME}'. Expected 'workflow_run'."
  exit 1
fi

validate_sha "stacks_sha" "${WORKFLOW_RUN_HEAD_SHA}"
validate_source_repo "${WORKFLOW_RUN_REPOSITORY}"
validate_source_run_id "${WORKFLOW_RUN_ID}"

{
  echo "schema_version=v5"
  echo "stacks_sha=${WORKFLOW_RUN_HEAD_SHA}"
  echo "source_sha=${WORKFLOW_RUN_HEAD_SHA}"
  echo "reason=full-reconcile"
  echo "source_repo=${WORKFLOW_RUN_REPOSITORY}"
  echo "source_run_id=${WORKFLOW_RUN_ID}"
  echo "should_dispatch=true"
} >> "${GITHUB_OUTPUT}"

echo "Schema version: v5"
echo "Stacks SHA: ${WORKFLOW_RUN_HEAD_SHA}"
echo "Source SHA: ${WORKFLOW_RUN_HEAD_SHA}"
echo "Reason: full-reconcile"
echo "Source repo: ${WORKFLOW_RUN_REPOSITORY}"
echo "Source run id: ${WORKFLOW_RUN_ID}"
echo "Should dispatch: true"
