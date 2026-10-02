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
# Interactive inputs (대화형 TTY 에서 자동 프롬프트):
#   VAULT_ADMIN_USERNAME   — login name (비면 프롬프트)
#   VAULT_ADMIN_PASSWORD   — 초기 비밀번호 (비면 무음 입력 프롬프트)
#
# Non-interactive 시 (CI 등): 위 두 개를 env var 로 전달해야 함.
#
# Optional env:
#   VAULT_ADMIN_TTL        — token TTL per login (default: 8h)
#   VAULT_ADMIN_MAX_TTL    — maximum TTL (default: 24h)
#
# 입력 검증:
#   - username: 영문/숫자/._- 만 허용, 1..64 자
#   - TTL/MAX_TTL: 숫자+단위(s|m|h|d), 1..16 자
#   이 값들은 Vault API 경로/파라미터에 쓰이는데, 과거 구현은 `sh -c` 문자열에
#   직접 보간했다. allowlist 를 통과시키면 쉘 메타문자 주입 경로가 닫히고,
#   아래 `vault write` 호출은 `sh -c` 없이 kubectl exec 로 직접 실행한다.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/vault.sh
. "$SCRIPT_DIR/../lib/vault.sh"

USERNAME_RE='^[A-Za-z0-9._-]{1,64}$'
TTL_RE='^[0-9]+[smhd]?$'

validate_inputs() {
  [[ "$VAULT_ADMIN_USERNAME" =~ $USERNAME_RE ]] \
    || die "VAULT_ADMIN_USERNAME 형식 불일치 (영문/숫자/._- 만 허용, 1..64자): '$VAULT_ADMIN_USERNAME'"
  [[ "$ADMIN_TTL" =~ $TTL_RE ]] \
    || die "VAULT_ADMIN_TTL 형식 불일치 (예: 8h, 3600, 30m): '$ADMIN_TTL'"
  [[ "$ADMIN_MAX_TTL" =~ $TTL_RE ]] \
    || die "VAULT_ADMIN_MAX_TTL 형식 불일치 (예: 24h, 86400): '$ADMIN_MAX_TTL'"
  (( ${#ADMIN_TTL} <= 16 && ${#ADMIN_MAX_TTL} <= 16 )) \
    || die "TTL 값이 너무 깁니다."
}

prompt_username_if_missing() {
  [[ -n "${VAULT_ADMIN_USERNAME:-}" ]] && return 0
  if [[ ! -t 0 ]]; then
    die "VAULT_ADMIN_USERNAME 환경 변수가 비어있습니다 (비대화 환경)."
  fi
  read -r -p "운영자 username (e.g. alice): " VAULT_ADMIN_USERNAME
  [[ -n "$VAULT_ADMIN_USERNAME" ]] || die "username 이 비어있습니다."
}

prompt_password_if_missing() {
  [[ -n "${VAULT_ADMIN_PASSWORD:-}" ]] && return 0
  if [[ ! -t 0 ]]; then
    die "VAULT_ADMIN_PASSWORD 환경 변수가 비어있습니다 (비대화 환경)."
  fi
  read -r -s -p "${VAULT_ADMIN_USERNAME} 초기 비밀번호: " VAULT_ADMIN_PASSWORD
  echo >&2
  [[ -n "$VAULT_ADMIN_PASSWORD" ]] || die "비밀번호가 비어있습니다."

  local confirm
  read -r -s -p "비밀번호 한 번 더 입력: " confirm
  echo >&2
  [[ "$VAULT_ADMIN_PASSWORD" == "$confirm" ]] \
    || die "비밀번호가 일치하지 않습니다."
  unset confirm
}

enable_userpass() {
  if vault_auth_method_enabled "userpass"; then
    log "auth method 'userpass/' 이미 활성화됨"
  else
    log "userpass auth method 활성화"
    vault_exec auth enable userpass
  fi
}

write_admin_policy() {
  # sudo capability 는 sys/* 일부 엔드포인트 (seal/audit/generate-root) 때문에 필요.
  # 권한이 강하므로 인프라 담당자에게만 부여.
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
}

# 사용자 생성/갱신 — `sh -c` 를 쓰지 않는다.
#
# 비밀번호는 `vault write -` 의 JSON stdin 으로 전달해 argv / 쉘 히스토리 노출이
# 전혀 없다. 나머지 파라미터 (username / TTL) 는 allowlist 를 통과한 값만
# kubectl exec argv 로 직접 전달된다 (쉘 해석 없음).
create_or_update_user() {
  log "userpass user '${VAULT_ADMIN_USERNAME}' 생성/갱신 (ttl=${ADMIN_TTL} max_ttl=${ADMIN_MAX_TTL})"
  jq -n --arg p "$VAULT_ADMIN_PASSWORD" \
        --arg ttl "$ADMIN_TTL" \
        --arg max "$ADMIN_MAX_TTL" \
    '{password:$p, token_policies:"vault-admin", token_ttl:$ttl, token_max_ttl:$max}' \
    | kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
        vault write "auth/userpass/users/${VAULT_ADMIN_USERNAME}" - >/dev/null
}

print_next_steps() {
  log "vault-setup-admin 태스크 완료"
  log ""
  log "다음 단계:"
  log "  1) 운영자는 다음 명령으로 로그인 (root token 사용 중단)"
  log "       vault login -method=userpass username=${VAULT_ADMIN_USERNAME}"
  log "  2) 각 운영자는 첫 로그인 후 비밀번호를 변경"
  log "       vault write auth/userpass/users/${VAULT_ADMIN_USERNAME}/password password='<new>'"
  log "  3) root token 은 오프라인 금고로 이동 후 vault-init-keys.json 에서 삭제 검토"
  log "     (재발급은 \"vault operator generate-root -init\" 으로 가능)"
}

main() {
  require_cmd kubectl jq
  require_env REPO_ROOT

  prompt_username_if_missing
  prompt_password_if_missing

  ADMIN_TTL="${VAULT_ADMIN_TTL:-8h}"
  ADMIN_MAX_TTL="${VAULT_ADMIN_MAX_TTL:-24h}"
  validate_inputs

  local keys_file="${VAULT_KEYS_FILE:-$REPO_ROOT/vault-init-keys.json}"
  vault_login_root_from_keyfile "$keys_file"

  enable_userpass
  write_admin_policy
  create_or_update_user
  print_next_steps
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
