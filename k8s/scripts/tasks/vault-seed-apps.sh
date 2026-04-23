#!/usr/bin/env bash
# Seed 5 application secrets into Vault KV v2.
#
# 이미 Vault KV 에 있는 경로는 skip — 운영자가 회전한 값을 절대 덮어쓰지 않는다.
# 아직 없는 경로에 대해 다음 순으로 값을 결정:
#   1) 환경 변수에 값이 있으면 사용
#   2) TTY 면 read -r -s 로 프롬프트 (확인 재입력 + echo 없음, bash history 안전)
#   3) 비대화 + env 비어있고 AUTO_GENERATE=yes 면 openssl rand 로 자동 생성
#      → 생성된 값은 stdout 에 절대 출력하지 않음. 필요 시 나중에:
#        vault kv get -field=password secret/<path>
#
# Vault CLI 의 `vault kv put <path> -` 모드로 **JSON payload 를 stdin** 으로 전달해
# 비밀번호가 argv / 프로세스 테이블 / 쉘 히스토리 어디에도 노출되지 않는다.
#
# Required env:
#   REPO_ROOT
#
# Optional env (비면 대화형 입력 or AUTO_GENERATE):
#   POSTGRES_SUPERUSER_USERNAME   기본 postgres
#   POSTGRES_SUPERUSER_PASSWORD
#
#   KEYCLOAK_DB_PASSWORD
#
#   AUTH_SERVER_DB_USERNAME       기본 auth_server
#   AUTH_SERVER_DB_PASSWORD
#
#   KEYCLOAK_ADMIN_USERNAME       기본 admin
#   KEYCLOAK_ADMIN_PASSWORD
#
#   MINIO_ROOT_USER               기본 minioadmin
#   MINIO_ROOT_PASSWORD
#
# Options:
#   AUTO_GENERATE=yes   대화형 TTY 가 아니고 env 도 비었을 때 랜덤 값 생성
#
# NOTE: 비밀번호에 큰따옴표 " 는 사용 금지 (MinIO env-file 포맷이 깨짐).

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/vault.sh
. "$SCRIPT_DIR/../lib/vault.sh"

: "${POSTGRES_SUPERUSER_USERNAME:=postgres}"
: "${AUTH_SERVER_DB_USERNAME:=auth_server}"
: "${KEYCLOAK_ADMIN_USERNAME:=admin}"
: "${MINIO_ROOT_USER:=minioadmin}"

generate_random_password() {
  openssl rand -base64 48 | tr -d '/+=' | head -c 24
}

resolve_password() {
  local var_name="$1"
  local prompt_label="$2"
  local value="${!var_name:-}"

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi

  if [[ -t 0 ]]; then
    local input confirm
    while true; do
      read -r -s -p "${prompt_label}: " input
      echo >&2
      if [[ -z "$input" ]]; then
        err "  비밀번호가 비어있습니다. 다시 입력하세요."
        continue
      fi
      if [[ "$input" == *'"'* ]]; then
        err "  큰따옴표(\") 는 사용할 수 없습니다 (MinIO env 포맷)."
        continue
      fi
      read -r -s -p "${prompt_label} 한 번 더: " confirm
      echo >&2
      if [[ "$input" == "$confirm" ]]; then
        printf '%s' "$input"
        return 0
      fi
      err "  일치하지 않습니다. 다시."
    done
  fi

  if [[ "${AUTO_GENERATE:-}" == "yes" ]]; then
    local generated
    generated="$(generate_random_password)"
    warn "  ${var_name}: 자동 생성 (vault kv get 으로 조회 가능)"
    printf '%s' "$generated"
    return 0
  fi

  die "${var_name} 가 비어있고 비대화 환경이며 AUTO_GENERATE=yes 도 아닙니다."
}

seed_if_missing() {
  local path="$1"
  if vault_kv_exists "$path"; then
    log "  secret/${path}: 이미 존재 → skip (회전된 값 보호)"
    return 1
  fi
  return 0
}

kv_put_json() {
  local path="$1"; shift
  local jq_expr="$1"; shift
  jq -n "$@" "$jq_expr" \
    | kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
        vault kv put "secret/${path}" - >/dev/null
}

seed_identity_postgres_superuser() {
  seed_if_missing "identity-postgres/superuser" || return 0
  local pw
  pw="$(resolve_password POSTGRES_SUPERUSER_PASSWORD "Postgres superuser 비밀번호")"
  kv_put_json "identity-postgres/superuser" \
    '{username: $u, password: $p}' \
    --arg u "$POSTGRES_SUPERUSER_USERNAME" \
    --arg p "$pw"
  log "  secret/identity-postgres/superuser 작성"
}

seed_keycloak_db() {
  seed_if_missing "keycloak/db" || return 0
  local pw
  pw="$(resolve_password KEYCLOAK_DB_PASSWORD "Keycloak DB 비밀번호")"
  kv_put_json "keycloak/db" \
    '{password: $p}' \
    --arg p "$pw"
  log "  secret/keycloak/db 작성"
}

seed_auth_server_db() {
  seed_if_missing "auth-server/db" || return 0
  local pw
  pw="$(resolve_password AUTH_SERVER_DB_PASSWORD "auth-server DB 비밀번호")"
  kv_put_json "auth-server/db" \
    '{SPRING_DATASOURCE_USERNAME: $u, SPRING_DATASOURCE_PASSWORD: $p}' \
    --arg u "$AUTH_SERVER_DB_USERNAME" \
    --arg p "$pw"
  log "  secret/auth-server/db 작성"
}

seed_keycloak_bootstrap_admin() {
  seed_if_missing "keycloak/bootstrap-admin" || return 0
  local pw
  pw="$(resolve_password KEYCLOAK_ADMIN_PASSWORD "Keycloak 관리자 비밀번호")"
  kv_put_json "keycloak/bootstrap-admin" \
    '{KEYCLOAK_ADMIN: $u, KEYCLOAK_ADMIN_PASSWORD: $p}' \
    --arg u "$KEYCLOAK_ADMIN_USERNAME" \
    --arg p "$pw"
  log "  secret/keycloak/bootstrap-admin 작성"
}

seed_minio_tenant_env() {
  seed_if_missing "minio/tenant-env" || return 0
  local pw env_content
  pw="$(resolve_password MINIO_ROOT_PASSWORD "MinIO 루트 비밀번호")"
  env_content=$(
    printf 'export MINIO_ROOT_USER="%s"\nexport MINIO_ROOT_PASSWORD="%s"\n' \
      "$MINIO_ROOT_USER" "$pw"
  )
  kv_put_json "minio/tenant-env" \
    '{"config.env": $cfg}' \
    --arg cfg "$env_content"
  log "  secret/minio/tenant-env 작성"
}

main() {
  require_cmd kubectl jq openssl
  require_env REPO_ROOT

  local keys_file="${VAULT_KEYS_FILE:-$REPO_ROOT/vault-init-keys.json}"
  vault_login_root_from_keyfile "$keys_file"
  log "앱 시크릿 5 개 seed 시작 (이미 존재하는 경로는 skip)"

  seed_identity_postgres_superuser
  seed_keycloak_db
  seed_auth_server_db
  seed_keycloak_bootstrap_admin
  seed_minio_tenant_env

  log "vault-seed-apps 태스크 완료"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
