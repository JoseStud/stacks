#!/usr/bin/env bash

set -euo pipefail

: "${EVENT_NAME:?EVENT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required but was not found in PATH."
  exit 1
fi

to_bool() {
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes) echo "true" ;;
    *) echo "false" ;;
  esac
}

normalize_csv() {
  local input="${1:-}"
  input="$(echo "${input}" | tr -d '\r')"
  if [[ -z "${input}" || "${input}" == "null" ]]; then
    echo ""
    return
  fi

  IFS=',' read -ra parts <<< "${input}"
  if [[ ${#parts[@]} -eq 0 ]]; then
    echo ""
    return
  fi

  printf '%s\n' "${parts[@]}" \
    | awk '{$1=$1; print}' \
    | awk 'NF > 0' \
    | awk '!seen[$0]++' \
    | sort \
    | paste -sd, -
}

if [[ ! -f stacks.yaml ]]; then
  echo "stacks.yaml not found. Run from stacks repo root."
  exit 1
fi

declare -A CHANGED_STACKS=()
declare -A CONFIG_STACKS=()
declare -A CHANGED_PATHS=()
declare -A COMPOSE_BY_STACK=()
declare -A STACK_DIR_BY_STACK=()

mapfile -t PORTAINER_STACKS < <(yq -r '.stacks | to_entries[] | select(.value.portainer_managed == true) | .key' stacks.yaml)
if [[ ${#PORTAINER_STACKS[@]} -eq 0 ]]; then
  echo "No portainer_managed stacks found in stacks.yaml."
  exit 1
fi

for stack in "${PORTAINER_STACKS[@]}"; do
  compose_path="$(yq -r ".stacks.\"${stack}\".compose_path" stacks.yaml)"
  COMPOSE_BY_STACK["${stack}"]="${compose_path}"
  STACK_DIR_BY_STACK["${stack}"]="$(dirname "${compose_path}")"
done

STRUCTURAL_CHANGE="false"
REASON=""
changed_stacks_csv=""
config_stacks_csv=""
changed_paths_csv=""

if [[ "${EVENT_NAME}" == "workflow_dispatch" ]]; then
  for stack in "${PORTAINER_STACKS[@]}"; do
    CHANGED_STACKS["${stack}"]=1
  done

  if [[ "$(to_bool "${INPUT_FORCE_PORTAINER_TF_REFRESH:-false}")" == "true" ]]; then
    STRUCTURAL_CHANGE="true"
    CHANGED_PATHS["stacks.yaml"]=1
    REASON="manual-refresh"
  else
    REASON="manual-dispatch"
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

    if [[ "${file}" == "stacks.yaml" ]]; then
      STRUCTURAL_CHANGE="true"
      CHANGED_PATHS["stacks.yaml"]=1
    fi

    for stack in "${PORTAINER_STACKS[@]}"; do
      compose_path="${COMPOSE_BY_STACK["${stack}"]}"
      stack_dir="${STACK_DIR_BY_STACK["${stack}"]}"
      if [[ "${file}" == "${stack_dir}/"* || "${file}" == "${compose_path}" ]]; then
        CHANGED_STACKS["${stack}"]=1
        CHANGED_PATHS["${file}"]=1

        if [[ "${stack}" == "auth" && "${file}" == "auth/config/"* ]]; then
          CONFIG_STACKS["auth"]=1
        fi
        if [[ "${stack}" == "observability" && "${file}" == "observability/config/"* ]]; then
          CONFIG_STACKS["observability"]=1
        fi
      fi
    done
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
        CHANGED_PATHS["stacks.yaml"]=1
      fi

      for stack in "${PORTAINER_STACKS[@]}"; do
        compose_path="${COMPOSE_BY_STACK["${stack}"]}"
        if [[ "${file}" == "${compose_path}" ]]; then
          STRUCTURAL_CHANGE="true"
          CHANGED_PATHS["${file}"]=1
        fi
      done
    done
  done <<< "${CHANGED_STATUS}"

  if [[ "${STRUCTURAL_CHANGE}" == "true" ]]; then
    REASON="structural-change"
  fi
fi

if [[ ${#CHANGED_STACKS[@]} -gt 0 ]]; then
  changed_stacks_csv="$(printf '%s\n' "${!CHANGED_STACKS[@]}" | sort | paste -sd, -)"
fi
if [[ ${#CONFIG_STACKS[@]} -gt 0 ]]; then
  config_stacks_csv="$(printf '%s\n' "${!CONFIG_STACKS[@]}" | sort | paste -sd, -)"
fi
if [[ ${#CHANGED_PATHS[@]} -gt 0 ]]; then
  changed_paths_csv="$(printf '%s\n' "${!CHANGED_PATHS[@]}" | sort | paste -sd, -)"
fi

changed_stacks_csv="$(normalize_csv "${changed_stacks_csv}")"
config_stacks_csv="$(normalize_csv "${config_stacks_csv}")"
changed_paths_csv="$(normalize_csv "${changed_paths_csv}")"

if [[ -n "${config_stacks_csv}" ]]; then
  changed_stacks_csv="$(normalize_csv "${changed_stacks_csv},${config_stacks_csv}")"
fi

if [[ -z "${REASON}" && -n "${changed_stacks_csv}" ]]; then
  REASON="content-change"
fi
if [[ -z "${REASON}" ]]; then
  REASON="no-op"
fi

SHOULD_DISPATCH="false"
if [[ -n "${changed_stacks_csv}" || "${STRUCTURAL_CHANGE}" == "true" ]]; then
  SHOULD_DISPATCH="true"
fi

{
  echo "schema_version=v2"
  echo "changed_stacks=${changed_stacks_csv}"
  echo "config_stacks=${config_stacks_csv}"
  echo "structural_change=${STRUCTURAL_CHANGE}"
  echo "reason=${REASON}"
  echo "changed_paths=${changed_paths_csv}"
  echo "should_dispatch=${SHOULD_DISPATCH}"
} >> "${GITHUB_OUTPUT}"

echo "Schema version: v2"
echo "Changed stacks: ${changed_stacks_csv:-<none>}"
echo "Config stacks: ${config_stacks_csv:-<none>}"
echo "Structural change: ${STRUCTURAL_CHANGE}"
echo "Reason: ${REASON}"
echo "Changed paths: ${changed_paths_csv:-<none>}"
echo "Should dispatch: ${SHOULD_DISPATCH}"
