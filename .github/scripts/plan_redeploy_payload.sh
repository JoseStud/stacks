#!/usr/bin/env bash

set -euo pipefail

: "${EVENT_NAME:?EVENT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required but was not found in PATH."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

to_bool() {
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes) echo "true" ;;
    *) echo "false" ;;
  esac
}

assoc_keys_to_json() {
  local -n assoc_ref="$1"
  if [[ ${#assoc_ref[@]} -eq 0 ]]; then
    echo "[]"
    return
  fi

  printf '%s\n' "${!assoc_ref[@]}" | sort | jq -R . | jq -s -c .
}

mark_all_portainer_stacks() {
  local stack
  for stack in "${PORTAINER_STACKS[@]}"; do
    CHANGED_STACKS["${stack}"]=1
    HOST_SYNC_STACKS["${stack}"]=1
  done
}

mark_agent_template_stacks() {
  local source_path relative_path stack_dir stack

  while IFS= read -r source_path; do
    [[ -z "${source_path}" ]] && continue
    relative_path="${source_path#/opt/stacks/}"
    stack_dir="$(dirname "${relative_path}")"
    stack="${STACK_NAME_BY_DIR["${stack_dir}"]:-}"
    if [[ -n "${stack}" ]]; then
      HOST_SYNC_STACKS["${stack}"]=1
    fi
  done < <(grep -E 'source-path:\s+"/opt/stacks/.+/.env\.tmpl"' infisical-agent.yaml | sed -E 's/.*source-path:\s+"([^"]+)".*/\1/')
}

if [[ ! -f stacks.yaml ]]; then
  echo "stacks.yaml not found. Run from stacks repo root."
  exit 1
fi

if [[ ! -f infisical-agent.yaml ]]; then
  echo "infisical-agent.yaml not found. Run from stacks repo root."
  exit 1
fi

declare -A CHANGED_STACKS=()
declare -A HOST_SYNC_STACKS=()
declare -A CONFIG_STACKS=()
declare -A CHANGED_PATHS=()
declare -A COMPOSE_BY_STACK=()
declare -A STACK_DIR_BY_STACK=()
declare -A STACK_NAME_BY_DIR=()
declare -A PORTAINER_MANAGED=()

mapfile -t ALL_STACKS < <(yq -r '.stacks | keys | .[]' stacks.yaml)
if [[ ${#ALL_STACKS[@]} -eq 0 ]]; then
  echo "No stacks found in stacks.yaml."
  exit 1
fi

mapfile -t PORTAINER_STACKS < <(yq -r '.stacks | to_entries[] | select(.value.portainer_managed == true) | .key' stacks.yaml)
if [[ ${#PORTAINER_STACKS[@]} -eq 0 ]]; then
  echo "No portainer_managed stacks found in stacks.yaml."
  exit 1
fi

for stack in "${ALL_STACKS[@]}"; do
  compose_path="$(yq -r ".stacks.\"${stack}\".compose_path" stacks.yaml)"
  stack_dir="$(dirname "${compose_path}")"

  COMPOSE_BY_STACK["${stack}"]="${compose_path}"
  STACK_DIR_BY_STACK["${stack}"]="${stack_dir}"
  STACK_NAME_BY_DIR["${stack_dir}"]="${stack}"

  if [[ "$(yq -r ".stacks.\"${stack}\".portainer_managed" stacks.yaml)" == "true" ]]; then
    PORTAINER_MANAGED["${stack}"]=1
  fi
done

STRUCTURAL_CHANGE="false"
REASON=""
changed_stacks_json="[]"
host_sync_stacks_json="[]"
config_stacks_json="[]"
changed_paths_json="[]"

if [[ "${EVENT_NAME}" == "workflow_dispatch" ]]; then
  mark_all_portainer_stacks

  if [[ "$(to_bool "${INPUT_FORCE_PORTAINER_TF_REFRESH:-false}")" == "true" ]]; then
    STRUCTURAL_CHANGE="true"
    CHANGED_PATHS["stacks.yaml"]=1
    REASON="manual-refresh"
  else
    REASON="content-change"
  fi
else
  BEFORE_SHA="${PUSH_BEFORE_SHA:-}"
  AFTER_SHA="${PUSH_SHA:-${GITHUB_SHA:-HEAD}}"

  if [[ "${BEFORE_SHA}" =~ ^0+$ || -z "${BEFORE_SHA}" ]]; then
    CHANGED_FILES="$(git show --name-only --pretty='' "${AFTER_SHA}" || true)"
    CHANGED_STATUS="$(git show --name-status --pretty='' "${AFTER_SHA}" || true)"
  else
    CHANGED_FILES="$(git diff --name-only "${BEFORE_SHA}" "${AFTER_SHA}" || true)"
    CHANGED_STATUS="$(git diff --name-status "${BEFORE_SHA}" "${AFTER_SHA}" || true)"
  fi

  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue

    case "${file}" in
      stacks.yaml)
        STRUCTURAL_CHANGE="true"
        CHANGED_PATHS["${file}"]=1
        mark_all_portainer_stacks
        continue
        ;;
      infisical-agent.yaml)
        CHANGED_PATHS["${file}"]=1
        mark_agent_template_stacks
        continue
        ;;
    esac

    for stack in "${ALL_STACKS[@]}"; do
      compose_path="${COMPOSE_BY_STACK["${stack}"]}"
      stack_dir="${STACK_DIR_BY_STACK["${stack}"]}"

      if [[ -n "${PORTAINER_MANAGED["${stack}"]:-}" && "${file}" == "${compose_path}" ]]; then
        CHANGED_STACKS["${stack}"]=1
        HOST_SYNC_STACKS["${stack}"]=1
        CHANGED_PATHS["${file}"]=1
        continue
      fi

      if [[ "${file}" == "${stack_dir}/.env.tmpl" ]]; then
        HOST_SYNC_STACKS["${stack}"]=1
        CHANGED_PATHS["${file}"]=1
        continue
      fi
    done

    if [[ "${file}" == auth/config/* ]]; then
      CHANGED_STACKS["auth"]=1
      CONFIG_STACKS["auth"]=1
      CHANGED_PATHS["${file}"]=1
      continue
    fi

    if [[ "${file}" == observability/config/* ]]; then
      CHANGED_STACKS["observability"]=1
      CONFIG_STACKS["observability"]=1
      CHANGED_PATHS["${file}"]=1
    fi
  done <<< "${CHANGED_FILES}"

  while IFS=$'\t' read -r status old_path new_path; do
    [[ -z "${status}" ]] && continue
    if [[ ! "${status}" =~ ^(A|D|R) ]]; then
      continue
    fi

    for file in "${old_path}" "${new_path}"; do
      [[ -z "${file}" ]] && continue

      if [[ "${file}" == "stacks.yaml" ]]; then
        STRUCTURAL_CHANGE="true"
        CHANGED_PATHS["${file}"]=1
        mark_all_portainer_stacks
        continue
      fi

      for stack in "${PORTAINER_STACKS[@]}"; do
        compose_path="${COMPOSE_BY_STACK["${stack}"]}"
        if [[ "${file}" == "${compose_path}" ]]; then
          STRUCTURAL_CHANGE="true"
          CHANGED_STACKS["${stack}"]=1
          HOST_SYNC_STACKS["${stack}"]=1
          CHANGED_PATHS["${file}"]=1
        fi
      done
    done
  done <<< "${CHANGED_STATUS}"

  if [[ "${STRUCTURAL_CHANGE}" == "true" ]]; then
    REASON="structural-change"
  fi
fi

changed_stacks_json="$(assoc_keys_to_json CHANGED_STACKS)"
host_sync_stacks_json="$(assoc_keys_to_json HOST_SYNC_STACKS)"
config_stacks_json="$(assoc_keys_to_json CONFIG_STACKS)"
changed_paths_json="$(assoc_keys_to_json CHANGED_PATHS)"

if [[ -z "${REASON}" && ("${changed_stacks_json}" != "[]" || "${host_sync_stacks_json}" != "[]" || "${config_stacks_json}" != "[]") ]]; then
  REASON="content-change"
fi
if [[ -z "${REASON}" ]]; then
  REASON="no-op"
fi

SHOULD_DISPATCH="false"
if [[ "${changed_stacks_json}" != "[]" || "${host_sync_stacks_json}" != "[]" || "${config_stacks_json}" != "[]" || "${STRUCTURAL_CHANGE}" == "true" ]]; then
  SHOULD_DISPATCH="true"
fi

{
  echo "schema_version=v4"
  echo "changed_stacks_json=${changed_stacks_json}"
  echo "host_sync_stacks_json=${host_sync_stacks_json}"
  echo "config_stacks_json=${config_stacks_json}"
  echo "structural_change=${STRUCTURAL_CHANGE}"
  echo "reason=${REASON}"
  echo "changed_paths_json=${changed_paths_json}"
  echo "should_dispatch=${SHOULD_DISPATCH}"
} >> "${GITHUB_OUTPUT}"

echo "Schema version: v4"
echo "Changed stacks JSON: ${changed_stacks_json}"
echo "Host sync stacks JSON: ${host_sync_stacks_json}"
echo "Config stacks JSON: ${config_stacks_json}"
echo "Structural change: ${STRUCTURAL_CHANGE}"
echo "Reason: ${REASON}"
echo "Changed paths JSON: ${changed_paths_json}"
echo "Should dispatch: ${SHOULD_DISPATCH}"
