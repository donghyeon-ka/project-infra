#!/usr/bin/env bash
# Initialize Vault (Shamir 5-of-3) and bootstrap the Kubernetes auth method,
# KV v2 secrets engine, and the vault-secrets-operator policy/role.
#
# Idempotent: 이미 초기화된 Vault 에서는 init 을 skip 하지만 unseal 과
# post-init 구성은 매번 재적용해서 bootstrap.sh 에서 여러 번 호출되어도 안전.
#
# Required env:
#   REPO_ROOT   — repository root
#
# Optional env:
#   VAULT_NAMESPACE / VAULT_POD / VAULT_KEYS_FILE — see lib/vault.sh
#   ENV_NAME    — dev|staging|prod (bootstrap.sh 가 주입). prod 일 때 기본 경로
#                 (repo working tree) 사용을 차단한다 — VAULT_KEYS_FILE 를 명시
#                 해서 repo 바깥의 안전한 경로로 써야 한다.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/vault.sh
. "$SCRIPT_DIR/../lib/vault.sh"

KEY_SHARES=5
KEY_THRESHOLD=3

resolve_keys_file() {
  DEFAULT_KEYS_FILE="$REPO_ROOT/vault-init-keys.json"
  KEYS_FILE="${VAULT_KEYS_FILE:-$DEFAULT_KEYS_FILE}"
  # prod 에서 repo 내부 평문 저장 차단 — root token / unseal key 가 repo
  # working tree 에 남으면 accidental commit / backup / IDE 인덱싱 경로로 유출.
  if [[ "${ENV_NAME:-}" == "prod" && "$KEYS_FILE" == "$DEFAULT_KEYS_FILE" ]]; then
    die "env=prod 에서는 VAULT_KEYS_FILE 를 repo 바깥 경로로 반드시 지정해야 합니다. (예: VAULT_KEYS_FILE=/run/secrets/vault-keys.json 또는 sops age 로 암호화)"
  fi
}

initialize_if_needed() {
  if vault_is_initialized; then
    log "Vault 는 이미 초기화되어 있습니다. 초기화 단계를 건너뜁니다."
    return 0
  fi
  log "Vault 초기화 중 (shares=${KEY_SHARES}, threshold=${KEY_THRESHOLD})..."
  local tmp_out
  tmp_out="$(mktemp)"
  trap_cleanup_path "$tmp_out"

  vault_exec operator init \
    -key-shares="$KEY_SHARES" \
    -key-threshold="$KEY_THRESHOLD" \
    -format=json > "$tmp_out"

  chmod 600 "$tmp_out"
  mv "$tmp_out" "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
  log "unseal keys + root token 저장: $KEYS_FILE (권한 0600)"
}

unseal_if_needed() {
  if vault_is_sealed; then
    log "Vault sealed 상태, unseal 진행"
    vault_unseal_from_keyfile "$KEYS_FILE"
  else
    log "Vault unsealed 상태"
  fi
}

enable_kv_v2() {
  if vault_secrets_engine_enabled "secret"; then
    log "secrets engine 'secret/' 이미 활성화됨"
    return 0
  fi
  log "KV v2 secrets engine 을 secret/ 에 활성화"
  vault_exec secrets enable -path=secret kv-v2
}

enable_k8s_auth() {
  if vault_auth_method_enabled "kubernetes"; then
    log "auth method 'kubernetes/' 이미 활성화됨"
  else
    log "Kubernetes auth method 활성화"
    vault_exec auth enable kubernetes
  fi

  log "Kubernetes auth method 설정 (kubernetes_host + ca + token_reviewer_jwt)"
  vault_exec_sh '
    vault write auth/kubernetes/config \
      kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
      kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
      token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
  ' >/dev/null
}

write_policies_and_roles() {
  log "policy 'vso-auth-platform' 작성 (identity-postgres/*, auth-server/*, keycloak/*, oauth2-proxy/*)"
  vault_exec_sh 'cat <<"EOF" | vault policy write vso-auth-platform -
path "secret/data/identity-postgres/*" {
  capabilities = ["read"]
}
path "secret/data/auth-server/*" {
  capabilities = ["read"]
}
path "secret/data/keycloak/*" {
  capabilities = ["read"]
}
path "secret/data/oauth2-proxy/*" {
  capabilities = ["read"]
}
EOF
' >/dev/null

  log "policy 'vso-storage' 작성 (minio/*, docker-registry/*)"
  vault_exec_sh 'cat <<"EOF" | vault policy write vso-storage -
path "secret/data/minio/*" {
  capabilities = ["read"]
}
path "secret/data/docker-registry/*" {
  capabilities = ["read"]
}
EOF
' >/dev/null

  log "k8s auth role 'vso-auth-platform' 작성"
  vault_exec write auth/kubernetes/role/vso-auth-platform \
    bound_service_account_names=vault-secrets-operator \
    bound_service_account_namespaces="$VAULT_NAMESPACE" \
    audience=vault \
    policies=vso-auth-platform \
    ttl=1h >/dev/null

  log "k8s auth role 'vso-storage' 작성"
  vault_exec write auth/kubernetes/role/vso-storage \
    bound_service_account_names=vault-secrets-operator \
    bound_service_account_namespaces="$VAULT_NAMESPACE" \
    audience=vault \
    policies=vso-storage \
    ttl=1h >/dev/null
}

cleanup_legacy() {
  log "구 policy/role 정리 (존재하면 삭제)"
  # 이전 단일 policy (세분화 전) 잔재
  vault_exec policy delete vault-secrets-operator >/dev/null 2>&1 || true
  vault_exec delete auth/kubernetes/role/vault-secrets-operator >/dev/null 2>&1 || true
  # Registry auth 제거로 더 이상 사용 안 하는 policy/role
  vault_exec policy delete vso-registry >/dev/null 2>&1 || true
  vault_exec delete auth/kubernetes/role/vso-registry >/dev/null 2>&1 || true
}

main() {
  require_cmd kubectl jq
  require_env REPO_ROOT

  resolve_keys_file
  initialize_if_needed
  unseal_if_needed
  vault_login_root_from_keyfile "$KEYS_FILE"
  enable_kv_v2
  enable_k8s_auth
  write_policies_and_roles
  cleanup_legacy
  log "vault-init 태스크 완료"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
