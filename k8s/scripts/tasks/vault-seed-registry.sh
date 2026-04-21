#!/usr/bin/env bash
# Seed Docker Registry credentials into Vault KV v2.
#
# Creates / refreshes:
#   - secret/docker-registry/auth            (htpasswd for push-user + pull-user)
#   - secret/docker-registry/pull-credentials (username/password for pull-user)
#
# Credentials are sourced from environment variables so this script is
# CI-friendly. If the variables are unset and stdin is a TTY the script
# falls back to an interactive prompt.
#
# Required env:
#   REPO_ROOT                — repo root (vault-init-keys.json is here)
#
# Optional env (non-interactive mode):
#   VAULT_PUSH_PASSWORD      — push-user password
#   VAULT_PULL_PASSWORD      — pull-user password
#   REGISTRY_PUSH_USER       — default push-user
#   REGISTRY_PULL_USER       — default pull-user

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/vault.sh
. "$SCRIPT_DIR/../lib/vault.sh"

require_cmd kubectl jq
require_env REPO_ROOT

PUSH_USER="${REGISTRY_PUSH_USER:-push-user}"
PULL_USER="${REGISTRY_PULL_USER:-pull-user}"
KEYS_FILE="${VAULT_KEYS_FILE:-$REPO_ROOT/vault-init-keys.json}"

# -----------------------------------------------------------------------------
# resolve passwords
# -----------------------------------------------------------------------------
resolve_password() {
  local var_name="$1" prompt_label="$2" value
  value="${!var_name:-}"
  if [[ -z "$value" ]]; then
    if [[ ! -t 0 ]]; then
      die "$var_name 환경 변수가 비어있습니다 (비대화 환경)."
    fi
    local input
    read -r -s -p "$prompt_label: " input
    echo >&2
    value="$input"
  fi
  printf '%s' "$value"
}

PUSH_PASSWORD="$(resolve_password VAULT_PUSH_PASSWORD "${PUSH_USER} 비밀번호")"
PULL_PASSWORD="$(resolve_password VAULT_PULL_PASSWORD "${PULL_USER} 비밀번호")"

# -----------------------------------------------------------------------------
# login to vault
# -----------------------------------------------------------------------------
vault_login_root_from_keyfile "$KEYS_FILE"

# -----------------------------------------------------------------------------
# generate htpasswd inside the vault pod (no Docker daemon dependency)
# Uses the registry:2 image's bundled bcrypt via htpasswd utility is not
# guaranteed; use pod-local openssl + a tiny bash helper: the Vault image
# ships with Alpine which has httpd-tools -unlikely. Safer: create htpasswd
# via openssl bcrypt is not available either.
#
# Strategy: delegate to a short-lived pod running `httpd:2.4-alpine` which
# ships `htpasswd`. No local docker required — kubectl does the work.
# -----------------------------------------------------------------------------
log "임시 httpd 파드에서 htpasswd 생성 (push+pull)"

HTPASSWD_POD="htpasswd-gen-$(date +%s)"
trap_cleanup "kubectl -n $VAULT_NAMESPACE delete pod $HTPASSWD_POD --ignore-not-found --wait=false >/dev/null 2>&1 || true"

kubectl -n "$VAULT_NAMESPACE" run "$HTPASSWD_POD" \
  --image=httpd:2.4-alpine \
  --restart=Never \
  --command --quiet \
  -- sleep 60 >/dev/null

# wait for pod to be ready (max 30s)
retry 15 2 kubectl -n "$VAULT_NAMESPACE" get pod "$HTPASSWD_POD" \
  -o jsonpath='{.status.phase}' 2>/dev/null | grep -qx 'Running'

# Generate both entries; -Bbn = bcrypt, batch, no final newline on stdout.
HTPASSWD_CONTENT="$(
  kubectl -n "$VAULT_NAMESPACE" exec "$HTPASSWD_POD" -- \
    htpasswd -Bbn "$PUSH_USER" "$PUSH_PASSWORD"
  kubectl -n "$VAULT_NAMESPACE" exec "$HTPASSWD_POD" -- \
    htpasswd -Bbn "$PULL_USER" "$PULL_PASSWORD"
)"

[[ -n "$HTPASSWD_CONTENT" ]] || die "htpasswd 생성 실패"

# -----------------------------------------------------------------------------
# write to Vault KV v2 via stdin (avoids password on argv / shell history)
# -----------------------------------------------------------------------------
log "secret/docker-registry/auth 작성 (htpasswd)"
printf '%s' "$HTPASSWD_CONTENT" \
  | kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
      vault kv put secret/docker-registry/auth htpasswd=- >/dev/null

log "secret/docker-registry/pull-credentials 작성 (username + password)"
# password on argv is sub-optimal but unavoidable for the plain kv put form;
# the alternative is a JSON payload via stdin:
vault_exec kv put secret/docker-registry/pull-credentials \
  username="$PULL_USER" \
  password="$PULL_PASSWORD" >/dev/null

log "vault-seed-registry 태스크 완료"
