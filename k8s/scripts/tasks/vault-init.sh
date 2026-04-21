#!/usr/bin/env bash
# Initialize Vault (Shamir 5-of-3) and bootstrap the Kubernetes auth method,
# KV v2 secrets engine, and the vault-secrets-operator policy/role.
#
# Idempotent: if Vault is already initialized this is a no-op. Unsealing and
# post-init configuration are re-run so the function is safe to invoke
# multiple times, including as part of bin/bootstrap.sh.
#
# Required env:
#   REPO_ROOT   — repository root (vault-init-keys.json is written here)
#
# Optional env:
#   VAULT_NAMESPACE / VAULT_POD / VAULT_KEYS_FILE — see lib/vault.sh

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/vault.sh
. "$SCRIPT_DIR/../lib/vault.sh"

require_cmd kubectl jq
require_env REPO_ROOT

KEYS_FILE="${VAULT_KEYS_FILE:-$REPO_ROOT/vault-init-keys.json}"
KEY_SHARES=5
KEY_THRESHOLD=3

# -----------------------------------------------------------------------------
# 1. Initialize (only if not initialized)
# -----------------------------------------------------------------------------
if vault_is_initialized; then
  log "Vault 는 이미 초기화되어 있습니다. 초기화 단계를 건너뜁니다."
else
  log "Vault 초기화 중 (shares=${KEY_SHARES}, threshold=${KEY_THRESHOLD})..."
  tmp_out="$(mktemp)"
  trap_cleanup "rm -f '$tmp_out'"

  vault_exec operator init \
    -key-shares="$KEY_SHARES" \
    -key-threshold="$KEY_THRESHOLD" \
    -format=json > "$tmp_out"

  # Write keys file with owner-only perms before moving into place.
  chmod 600 "$tmp_out"
  mv "$tmp_out" "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
  log "unseal keys + root token 저장: $KEYS_FILE (권한 0600)"
fi

# -----------------------------------------------------------------------------
# 2. Unseal if necessary
# -----------------------------------------------------------------------------
if vault_is_sealed; then
  log "Vault sealed 상태, unseal 진행"
  vault_unseal_from_keyfile "$KEYS_FILE"
else
  log "Vault unsealed 상태"
fi

# -----------------------------------------------------------------------------
# 3. Log in with root token (stdout suppressed — token is never printed)
# -----------------------------------------------------------------------------
vault_login_root_from_keyfile "$KEYS_FILE"

# -----------------------------------------------------------------------------
# 4. Enable KV v2 at secret/ (idempotent)
# -----------------------------------------------------------------------------
if vault_secrets_engine_enabled "secret"; then
  log "secrets engine 'secret/' 이미 활성화됨"
else
  log "KV v2 secrets engine 을 secret/ 에 활성화"
  vault_exec secrets enable -path=secret kv-v2
fi

# -----------------------------------------------------------------------------
# 5. Enable Kubernetes auth method (idempotent) + configure
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 6. Create / update VSO policy + role (always re-apply — cheap and safe)
# -----------------------------------------------------------------------------
log "policy 'vso-registry' 작성 (docker-registry/*)"
vault_exec_sh 'cat <<"EOF" | vault policy write vso-registry -
path "secret/data/docker-registry/*" {
  capabilities = ["read"]
}
EOF
' >/dev/null

log "policy 'vso-auth-platform' 작성 (identity-postgres/*, auth-server/*, keycloak/*)"
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
EOF
' >/dev/null

log "policy 'vso-storage' 작성 (minio/*)"
vault_exec_sh 'cat <<"EOF" | vault policy write vso-storage -
path "secret/data/minio/*" {
  capabilities = ["read"]
}
EOF
' >/dev/null

log "k8s auth role 'vso-registry' 작성"
vault_exec write auth/kubernetes/role/vso-registry \
  bound_service_account_names=vault-secrets-operator \
  bound_service_account_namespaces="$VAULT_NAMESPACE" \
  policies=vso-registry \
  ttl=1h >/dev/null

log "k8s auth role 'vso-auth-platform' 작성"
vault_exec write auth/kubernetes/role/vso-auth-platform \
  bound_service_account_names=vault-secrets-operator \
  bound_service_account_namespaces="$VAULT_NAMESPACE" \
  policies=vso-auth-platform \
  ttl=1h >/dev/null

log "k8s auth role 'vso-storage' 작성"
vault_exec write auth/kubernetes/role/vso-storage \
  bound_service_account_names=vault-secrets-operator \
  bound_service_account_namespaces="$VAULT_NAMESPACE" \
  policies=vso-storage \
  ttl=1h >/dev/null

log "이전 단일 policy/role 'vault-secrets-operator' 정리 (존재하면 삭제)"
vault_exec policy delete vault-secrets-operator >/dev/null 2>&1 || true
vault_exec delete auth/kubernetes/role/vault-secrets-operator >/dev/null 2>&1 || true

log "vault-init 태스크 완료"
