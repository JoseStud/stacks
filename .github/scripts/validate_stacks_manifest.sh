#!/usr/bin/env bash

set -euo pipefail

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required but was not found in PATH."
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required but was not found in PATH."
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin is required but is unavailable."
  exit 1
fi

if [[ ! -f stacks.yaml ]]; then
  echo "stacks.yaml not found. Run from repository root."
  exit 1
fi

if ! yq -e '.stacks | type == "!!map"' stacks.yaml >/dev/null; then
  echo "stacks.yaml must contain a top-level map at .stacks."
  exit 1
fi

mapfile -t STACKS < <(yq -r '.stacks | keys | .[]' stacks.yaml)
if [[ ${#STACKS[@]} -eq 0 ]]; then
  echo "No stacks defined in stacks.yaml."
  exit 1
fi

declare -A STACK_SET=()
for stack in "${STACKS[@]}"; do
  STACK_SET["${stack}"]=1
done

errors=0
error() {
  echo "::error::$1"
  errors=$((errors + 1))
}

for stack in "${STACKS[@]}"; do
  if ! yq -e ".stacks.\"${stack}\".compose_path | type == \"!!str\"" stacks.yaml >/dev/null; then
    error "Stack '${stack}' must define compose_path as a string."
    continue
  fi

  compose_path="$(yq -r ".stacks.\"${stack}\".compose_path" stacks.yaml)"
  if [[ -z "${compose_path}" || "${compose_path}" == "null" ]]; then
    error "Stack '${stack}' has an empty compose_path."
    continue
  fi

  if ! yq -e ".stacks.\"${stack}\".portainer_managed | type == \"!!bool\"" stacks.yaml >/dev/null; then
    error "Stack '${stack}' must define portainer_managed as a boolean."
  fi

  if ! yq -e ".stacks.\"${stack}\".depends_on | type == \"!!seq\"" stacks.yaml >/dev/null; then
    error "Stack '${stack}' must define depends_on as an array."
  fi

  if [[ ! -f "${compose_path}" ]]; then
    error "Stack '${stack}' compose_path '${compose_path}' does not exist."
    continue
  fi

  if ! yq eval '.' "${compose_path}" >/dev/null; then
    error "Compose file '${compose_path}' is not valid YAML."
    continue
  fi

  if ! yq -e '.services | type == "!!map" and length > 0' "${compose_path}" >/dev/null; then
    error "Compose file '${compose_path}' must define a non-empty services map."
  fi

  if ! docker compose -f "${compose_path}" config --no-interpolate -q >/dev/null 2>&1; then
    error "Compose validation failed for '${compose_path}'."
  fi
done

for stack in "${STACKS[@]}"; do
  mapfile -t dependencies < <(yq -r ".stacks.\"${stack}\".depends_on[]?" stacks.yaml)
  for dependency in "${dependencies[@]}"; do
    if [[ -z "${STACK_SET[${dependency}]:-}" ]]; then
      error "Stack '${stack}' depends_on unknown stack '${dependency}'."
    fi
  done
done

if (( errors > 0 )); then
  echo "Stack manifest validation failed with ${errors} error(s)."
  exit 1
fi

echo "Stack manifest and compose validation passed."
