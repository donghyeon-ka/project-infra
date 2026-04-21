#!/usr/bin/env bash
# Vault helper functions. Depends on lib/common.sh being sourced first.
#
# Environment contract:
#   VAULT_NAMESPACE     — k8s namespace where vault-0 runs (default: mnt)
#   VAULT_POD           — Vault pod name                  (default: vault-0)
#   VAULT_KEYS_FILE     — path to JSON file produced by vault operator init
#                          (default: $REPO_ROOT/vault-init-keys.json)

# shellcheck shell=bash
# shellcheck source=./common.sh
# (common.sh must be sourced by the caller.)

: "${VAULT_NAMESPACE:=mnt}"
: "${VAULT_POD:=vault-0}"

# vault_exec <args...> — exec vault CLI inside the Vault pod.
vault_exec() {
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault "$@"
}

# vault_exec_sh <script> — exec /bin/sh -c "$script" inside the Vault pod.
# Use when the vault CLI call needs shell features (heredocs, redirects).
vault_exec_sh() {
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- sh -c "$1"
}

# vault_status_json — echoes the JSON output of `vault status`, or empty on error.
vault_status_json() {
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    vault status -format=json 2>/dev/null || true
}

vault_is_initialized() {
  local json
  json="$(vault_status_json)"
  [[ -n "$json" ]] && echo "$json" | jq -e '.initialized == true' >/dev/null
}

vault_is_sealed() {
  local json
  json="$(vault_status_json)"
  [[ -n "$json" ]] && echo "$json" | jq -e '.sealed == true' >/dev/null
}

# vault_unseal_from_keyfile <keys_file>
vault_unseal_from_keyfile() {
  local keys_file="$1"
  [[ -f "$keys_file" ]] || die "unseal 키 파일이 없습니다: $keys_file"

  local threshold
  threshold="$(jq -r '.unseal_threshold' "$keys_file")"

  local i key
  for ((i = 0; i < threshold; i++)); do
    key="$(jq -r ".unseal_keys_b64[$i]" "$keys_file")"
    vault_exec operator unseal "$key" >/dev/null
  done
  log "Vault unseal 완료 (threshold=${threshold})"
}

# vault_login_root_from_keyfile <keys_file>
# Logs the vault CLI inside the pod using the root token. stdout is suppressed
# so the token never reaches terminals or logs.
vault_login_root_from_keyfile() {
  local keys_file="$1"
  local token
  token="$(jq -r '.root_token' "$keys_file")"
  printf '%s' "$token" | vault_exec_sh 'vault login -no-print -' >/dev/null
}

# vault_kv_exists <path>  — returns 0 if the KV v2 secret exists.
vault_kv_exists() {
  local path="$1"
  vault_exec kv get -format=json "$path" >/dev/null 2>&1
}

# vault_auth_method_enabled <mount>  — returns 0 if the auth method is enabled.
vault_auth_method_enabled() {
  local mount="$1"
  vault_exec auth list -format=json 2>/dev/null \
    | jq -e --arg m "${mount}/" '.[$m] // empty' >/dev/null
}

# vault_secrets_engine_enabled <mount>  — returns 0 if the secrets engine is enabled.
vault_secrets_engine_enabled() {
  local mount="$1"
  vault_exec secrets list -format=json 2>/dev/null \
    | jq -e --arg m "${mount}/" '.[$m] // empty' >/dev/null
}
