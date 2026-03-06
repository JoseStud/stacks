#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLANNER="${ROOT_DIR}/.github/scripts/plan_redeploy_payload.sh"
VALIDATOR="${ROOT_DIR}/.github/scripts/validate_dispatch_payload_v4.sh"

if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not found."
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not found."
  exit 0
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not found."
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

init_fixture_repo() {
  local repo_dir="$1"

  mkdir -p "${repo_dir}"
  git -C "${repo_dir}" init -b main >/dev/null
  git -C "${repo_dir}" config user.name "Planner Test"
  git -C "${repo_dir}" config user.email "planner@example.com"

  mkdir -p \
    "${repo_dir}/gateway" \
    "${repo_dir}/auth/config" \
    "${repo_dir}/management" \
    "${repo_dir}/network" \
    "${repo_dir}/observability/config"

  cat > "${repo_dir}/stacks.yaml" <<'EOF_STACKS'
version: 1

stacks:
  management:
    compose_path: management/docker-compose.yml
    portainer_managed: false
    depends_on: []

  gateway:
    compose_path: gateway/docker-compose.yml
    portainer_managed: true
    depends_on: []

  auth:
    compose_path: auth/docker-compose.yml
    portainer_managed: true
    depends_on: [gateway]

  network:
    compose_path: network/docker-compose.yml
    portainer_managed: true
    depends_on: [gateway, auth]

  observability:
    compose_path: observability/docker-compose.yml
    portainer_managed: true
    depends_on: [gateway, auth]
EOF_STACKS

  cat > "${repo_dir}/infisical-agent.yaml" <<'EOF_AGENT'
infisical:
  templates:
    - source-path: "/opt/stacks/gateway/.env.tmpl"
      destination-path: "/opt/stacks/gateway/.env"
    - source-path: "/opt/stacks/auth/.env.tmpl"
      destination-path: "/opt/stacks/auth/.env"
    - source-path: "/opt/stacks/management/.env.tmpl"
      destination-path: "/opt/stacks/management/.env"
    - source-path: "/opt/stacks/network/.env.tmpl"
      destination-path: "/opt/stacks/network/.env"
    - source-path: "/opt/stacks/observability/.env.tmpl"
      destination-path: "/opt/stacks/observability/.env"
EOF_AGENT

  cat > "${repo_dir}/gateway/docker-compose.yml" <<'EOF_COMPOSE'
services:
  gateway:
    image: traefik:v3
EOF_COMPOSE

  cat > "${repo_dir}/auth/docker-compose.yml" <<'EOF_COMPOSE'
services:
  auth:
    image: authelia/authelia:latest
EOF_COMPOSE

  cat > "${repo_dir}/management/docker-compose.yml" <<'EOF_COMPOSE'
services:
  management:
    image: portainer/portainer-ce:lts
EOF_COMPOSE

  cat > "${repo_dir}/network/docker-compose.yml" <<'EOF_COMPOSE'
services:
  network:
    image: vaultwarden/server:latest
EOF_COMPOSE

  cat > "${repo_dir}/observability/docker-compose.yml" <<'EOF_COMPOSE'
services:
  observability:
    image: grafana/grafana:latest
EOF_COMPOSE

  cat > "${repo_dir}/gateway/.env.tmpl" <<'EOF_TMPL'
BASE_DOMAIN=example.com
EOF_TMPL

  cat > "${repo_dir}/auth/.env.tmpl" <<'EOF_TMPL'
AUTH_SECRET=value
EOF_TMPL

  cat > "${repo_dir}/management/.env.tmpl" <<'EOF_TMPL'
HOMARR_SECRET_KEY=value
EOF_TMPL

  cat > "${repo_dir}/network/.env.tmpl" <<'EOF_TMPL'
VW_DB_PASS=value
EOF_TMPL

  cat > "${repo_dir}/observability/.env.tmpl" <<'EOF_TMPL'
GF_OIDC_CLIENT_SECRET=value
EOF_TMPL

  cat > "${repo_dir}/auth/config/configuration.yml" <<'EOF_CFG'
server:
  address: tcp://0.0.0.0:9091
EOF_CFG

  cat > "${repo_dir}/observability/config/prometheus.yml" <<'EOF_CFG'
global:
  scrape_interval: 15s
EOF_CFG

  git -C "${repo_dir}" add .
  git -C "${repo_dir}" commit -m "base fixture" >/dev/null
}

run_push_case() {
  local case_name="$1"
  local mutate_fn="$2"
  local repo_dir="${TMP_DIR}/${case_name}"
  local output_file="${TMP_DIR}/${case_name}.out"
  local before_sha after_sha

  init_fixture_repo "${repo_dir}"
  before_sha="$(git -C "${repo_dir}" rev-parse HEAD)"
  "${mutate_fn}" "${repo_dir}"
  git -C "${repo_dir}" add .
  git -C "${repo_dir}" commit -m "${case_name}" >/dev/null
  after_sha="$(git -C "${repo_dir}" rev-parse HEAD)"

  (
    cd "${repo_dir}"
    export EVENT_NAME="push"
    export GITHUB_OUTPUT="${output_file}"
    export PUSH_BEFORE_SHA="${before_sha}"
    export PUSH_SHA="${after_sha}"
    "${PLANNER}"
  ) >/dev/null

  echo "${output_file}"
}

mutate_gateway_template() {
  local repo_dir="$1"
  printf 'BASE_DOMAIN=example.org\n' > "${repo_dir}/gateway/.env.tmpl"
}

mutate_management_template() {
  local repo_dir="$1"
  printf 'HOMARR_SECRET_KEY=next\n' > "${repo_dir}/management/.env.tmpl"
}

mutate_gateway_compose() {
  local repo_dir="$1"
  cat > "${repo_dir}/gateway/docker-compose.yml" <<'EOF_COMPOSE'
services:
  gateway:
    image: traefik:v3.1
EOF_COMPOSE
}

mutate_agent_config() {
  local repo_dir="$1"
  printf '\n# comment\n' >> "${repo_dir}/infisical-agent.yaml"
}

mutate_stacks_manifest() {
  local repo_dir="$1"
  printf '\n  cloud:\n    compose_path: cloud/docker-compose.yml\n    portainer_managed: true\n    depends_on: [gateway, auth]\n' >> "${repo_dir}/stacks.yaml"
}

mutate_auth_config() {
  local repo_dir="$1"
  printf 'server:\n  address: tcp://0.0.0.0:9191\n' > "${repo_dir}/auth/config/configuration.yml"
}

case1_out="$(run_push_case "gateway_template" mutate_gateway_template)"
assert_eq "gateway_template" "changed_stacks_json" "[]" "$(read_output "${case1_out}" "changed_stacks_json")"
assert_eq "gateway_template" "host_sync_stacks_json" "[\"gateway\"]" "$(read_output "${case1_out}" "host_sync_stacks_json")"

case2_out="$(run_push_case "management_template" mutate_management_template)"
assert_eq "management_template" "changed_stacks_json" "[]" "$(read_output "${case2_out}" "changed_stacks_json")"
assert_eq "management_template" "host_sync_stacks_json" "[\"management\"]" "$(read_output "${case2_out}" "host_sync_stacks_json")"

case3_out="$(run_push_case "gateway_compose" mutate_gateway_compose)"
assert_eq "gateway_compose" "changed_stacks_json" "[\"gateway\"]" "$(read_output "${case3_out}" "changed_stacks_json")"
assert_eq "gateway_compose" "host_sync_stacks_json" "[\"gateway\"]" "$(read_output "${case3_out}" "host_sync_stacks_json")"

case4_out="$(run_push_case "agent_config" mutate_agent_config)"
assert_eq "agent_config" "changed_stacks_json" "[]" "$(read_output "${case4_out}" "changed_stacks_json")"
assert_eq "agent_config" "host_sync_stacks_json" "[\"auth\",\"gateway\",\"management\",\"network\",\"observability\"]" "$(read_output "${case4_out}" "host_sync_stacks_json")"

case5_out="$(run_push_case "stacks_manifest" mutate_stacks_manifest)"
assert_eq "stacks_manifest" "changed_stacks_json" "[\"auth\",\"cloud\",\"gateway\",\"network\",\"observability\"]" "$(read_output "${case5_out}" "changed_stacks_json")"
assert_eq "stacks_manifest" "host_sync_stacks_json" "[\"auth\",\"cloud\",\"gateway\",\"network\",\"observability\"]" "$(read_output "${case5_out}" "host_sync_stacks_json")"
assert_eq "stacks_manifest" "structural_change" "true" "$(read_output "${case5_out}" "structural_change")"

case6_out="$(run_push_case "auth_config" mutate_auth_config)"
assert_eq "auth_config" "changed_stacks_json" "[\"auth\"]" "$(read_output "${case6_out}" "changed_stacks_json")"
assert_eq "auth_config" "config_stacks_json" "[\"auth\"]" "$(read_output "${case6_out}" "config_stacks_json")"
assert_eq "auth_config" "host_sync_stacks_json" "[]" "$(read_output "${case6_out}" "host_sync_stacks_json")"

valid_sha="$(printf 'a%.0s' $(seq 1 40))"
if (
  export PAYLOAD_SCHEMA_VERSION="v4"
  export PAYLOAD_STACKS_SHA="${valid_sha}"
  export PAYLOAD_SOURCE_SHA="${valid_sha}"
  export PAYLOAD_CHANGED_STACKS_JSON="[\"gateway\"]"
  export PAYLOAD_HOST_SYNC_STACKS_JSON="[\"gateway\"]"
  export PAYLOAD_CONFIG_STACKS_JSON="[]"
  export PAYLOAD_STRUCTURAL_CHANGE="false"
  export PAYLOAD_REASON="content-change"
  export PAYLOAD_CHANGED_PATHS_JSON="[\"gateway/.env.tmpl\"]"
  export PAYLOAD_SOURCE_REPO="example/stacks"
  export PAYLOAD_SOURCE_RUN_ID="12345"
  "${VALIDATOR}"
); then
  pass "dispatch_payload_v4_valid"
else
  fail "dispatch_payload_v4_valid"
fi

if (
  export PAYLOAD_SCHEMA_VERSION="v4"
  export PAYLOAD_STACKS_SHA="${valid_sha}"
  export PAYLOAD_SOURCE_SHA="${valid_sha}"
  export PAYLOAD_CHANGED_STACKS_JSON="[\"gateway\"]"
  unset PAYLOAD_HOST_SYNC_STACKS_JSON
  export PAYLOAD_CONFIG_STACKS_JSON="[]"
  export PAYLOAD_STRUCTURAL_CHANGE="false"
  export PAYLOAD_REASON="content-change"
  export PAYLOAD_CHANGED_PATHS_JSON="[\"gateway/.env.tmpl\"]"
  export PAYLOAD_SOURCE_REPO="example/stacks"
  export PAYLOAD_SOURCE_RUN_ID="12345"
  "${VALIDATOR}"
); then
  fail "dispatch_payload_v4_missing_host_sync: expected failure"
else
  pass "dispatch_payload_v4_missing_host_sync"
fi

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
