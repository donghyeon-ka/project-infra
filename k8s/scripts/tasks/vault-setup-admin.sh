#!/usr/bin/env bash
# Configure operator authentication for Vault.
#
# Adds a `userpass` auth method + `vault-admin` policy + one or more admin users.
# Operators use these credentials instead of the root token for day-to-day work.
# The root token stays offline and is only used for break-glass / rekey.
#
# Required env:
#   REPO_ROOT              — repo root (for vault-init-keys.json path)
#
# Required env for each admin user to create (at least one required):
#   VAULT_ADMIN_USERNAME   — login name (e.g. alice)
#   VAULT_ADMIN_PASSWORD   — initial password (user must change after first login)
#
# Optional env:
#   VAULT_ADMIN_TTL        — token TTL per login (default: 8h)
#   VAULT_ADMIN_MAX_TTL    — maximum TTL (default: 24h)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/vault.sh
. "$SCRIPT_DIR/../lib/vault.sh"

require_cmd kubectl jq
require_env REPO_ROOT VAULT_ADMIN_USERNAME VAULT_ADMIN_PASSWORD

KEYS_FILE="${VAULT_KEYS_FILE:-$REPO_ROOT/vault-init-keys.json}"
ADMIN_TTL="${VAULT_ADMIN_TTL:-8h}"
ADMIN_MAX_TTL="${VAULT_ADMIN_MAX_TTL:-24h}"

# -----------------------------------------------------------------------------
# 1. Authenticate with root (stdin piped — token never reaches stdout / argv)
# -----------------------------------------------------------------------------
vault_login_root_from_keyfile "$KEYS_FILE"

# -----------------------------------------------------------------------------
# 2. Enable userpass auth method (idempotent)
# -----------------------------------------------------------------------------
if vault_auth_method_enabled "userpass"; then
  log "auth method 'userpass/' 이미 활성화됨"
else
  log "userpass auth method 활성화"
  vault_exec auth enable userpass
fi

# -----------------------------------------------------------------------------
# 3. Write vault-admin policy (always re-apply)
# -----------------------------------------------------------------------------
# Note: sudo capability is required for a few sys/* endpoints (seal, audit,
# generate-root). 일반 read/write 보다 권한이 강하므로 이 정책은
# 인프라 담당자에게만 부여한다.
log "policy 'vault-admin' 작성"
vault_exec_sh 'cat <<"EOF" | vault policy write vault-admin -
# KV v2 — 전 경로 관리
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Auth method / identity 관리
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "identity/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# policy 관리 (자기 자신 포함)
path "sys/policies/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/policy/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# 상태 / 감사 장치 / mount 관리
path "sys/health" { capabilities = ["read"] }
path "sys/seal-status" { capabilities = ["read"] }
path "sys/mounts" { capabilities = ["read", "list"] }
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "sys/audit" { capabilities = ["read", "list"] }
path "sys/audit/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}
EOF
' >/dev/null

# -----------------------------------------------------------------------------
# 4. Create / update admin user (password on stdin — 비밀번호가 프로세스 argv 에
#    남지 않도록 kv-put 과 같은 트릭을 쓸 수 없는 API 이므로 env 로 넘기되
#    log 에는 찍지 않는다. kubectl exec -i 로 stdin 전달.)
# -----------------------------------------------------------------------------
log "userpass user '${VAULT_ADMIN_USERNAME}' 생성/갱신 (ttl=${ADMIN_TTL} max_ttl=${ADMIN_MAX_TTL})"
printf '%s' "$VAULT_ADMIN_PASSWORD" \
  | kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
      sh -c "read -r pw; vault write auth/userpass/users/${VAULT_ADMIN_USERNAME} \
        password=\"\$pw\" \
        token_policies=vault-admin \
        token_ttl=${ADMIN_TTL} \
        token_max_ttl=${ADMIN_MAX_TTL}" \
      >/dev/null

log "vault-setup-admin 태스크 완료"
log ""
log "다음 단계:"
log "  1) 운영자는 다음 명령으로 로그인 (root token 사용 중단)"
log "       vault login -method=userpass username=${VAULT_ADMIN_USERNAME}"
log "  2) 각 운영자는 첫 로그인 후 비밀번호를 변경"
log "       vault write auth/userpass/users/${VAULT_ADMIN_USERNAME}/password password='<new>'"
log "  3) root token 은 오프라인 금고로 이동 후 vault-init-keys.json 에서 삭제 검토"
log "     (재발급은 \"vault operator generate-root -init\" 으로 가능)"
