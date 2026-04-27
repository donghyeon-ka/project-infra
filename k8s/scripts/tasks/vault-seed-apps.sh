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
#   AUTH_SERVER_INGRESS_CLIENT_SECRET   Keycloak realm client 'auth-server-ingress' 의 secret.
#                                       KeycloakRealmImport 가 ${AUTH_SERVER_INGRESS_CLIENT_SECRET}
#                                       env 치환으로 가져간다. oauth2-proxy 도 동일 값을 받음.
#
#   DOCKER_REGISTRY_MINIO_ACCESSKEY     docker-registry 가 MinIO 에 접근할 때 쓸 AK.
#                                       기본값 'docker-registry'. MinIO user 이름이 됨.
#   DOCKER_REGISTRY_MINIO_SECRETKEY     docker-registry MinIO SK (대소문자+숫자 8자 이상).
#
#   DOCKER_REGISTRY_PUSH_USERNAME       외부 Ingress push 용 BasicAuth username.
#                                       기본값 'registry-push'.
#   DOCKER_REGISTRY_PUSH_PASSWORD       외부 Ingress push 용 BasicAuth password.
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
: "${DOCKER_REGISTRY_MINIO_ACCESSKEY:=docker-registry}"
: "${DOCKER_REGISTRY_PUSH_USERNAME:=registry-push}"

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

# docker-registry 가 MinIO 에 접근할 때 쓸 AK/SK. 이 값으로 bootstrap 후속
# phase 에서 MinIO admin user 를 만들고 bucket-scoped policy 를 부착한다.
# registry Deployment 는 VSO 가 동기화한 Secret `docker-registry-minio` 에서
# 동일 값을 REGISTRY_STORAGE_S3_ACCESSKEY / SECRETKEY 로 읽는다.
seed_docker_registry_minio() {
  seed_if_missing "docker-registry/minio" || return 0
  local sk
  sk="$(resolve_password DOCKER_REGISTRY_MINIO_SECRETKEY "docker-registry MinIO secret key")"
  kv_put_json "docker-registry/minio" \
    '{access_key: $ak, secret_key: $sk}' \
    --arg ak "$DOCKER_REGISTRY_MINIO_ACCESSKEY" \
    --arg sk "$sk"
  log "  secret/docker-registry/minio 작성 (access_key=${DOCKER_REGISTRY_MINIO_ACCESSKEY})"
}

# 외부에서 registry.project.com 으로 push 할 때 Traefik BasicAuth 가 검증할
# htpasswd 라인을 저장한다. Registry 자체 auth 는 켜지지 않고, 외부 Ingress
# 경계에서만 인증한다.
seed_docker_registry_basic_auth() {
  seed_if_missing "docker-registry/basic-auth" || return 0
  local pw hash users
  pw="$(resolve_password DOCKER_REGISTRY_PUSH_PASSWORD "docker-registry 외부 push 비밀번호")"
  hash="$(openssl passwd -apr1 "$pw")"
  users="${DOCKER_REGISTRY_PUSH_USERNAME}:${hash}"
  kv_put_json "docker-registry/basic-auth" \
    '{username: $username, password: $password, users: $users}' \
    --arg username "$DOCKER_REGISTRY_PUSH_USERNAME" \
    --arg password "$pw" \
    --arg users "$users"
  log "  secret/docker-registry/basic-auth 작성 (username=${DOCKER_REGISTRY_PUSH_USERNAME})"
}

# Keycloak realm import 가 client secret 을 ${AUTH_SERVER_INGRESS_CLIENT_SECRET}
# env 치환으로 요구한다. oauth2-proxy 는 동일 값을 /etc/oauth2-proxy-secrets/
# client-secret 파일로 읽는다. 두 쪽이 같은 값을 써야 OIDC client 인증이 맞는다.
seed_keycloak_client_auth_server_ingress() {
  seed_if_missing "keycloak/clients/auth-server-ingress" || return 0
  local pw
  pw="$(resolve_password AUTH_SERVER_INGRESS_CLIENT_SECRET \
        "Keycloak client 'auth-server-ingress' secret")"
  kv_put_json "keycloak/clients/auth-server-ingress" \
    '{client_secret: $p}' \
    --arg p "$pw"
  log "  secret/keycloak/clients/auth-server-ingress 작성"
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
  seed_keycloak_client_auth_server_ingress
  seed_docker_registry_minio
  seed_docker_registry_basic_auth

  log "vault-seed-apps 태스크 완료"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
