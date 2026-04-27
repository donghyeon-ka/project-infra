#!/usr/bin/env bash
# MinIO Tenant 기동 후 docker-registry 용 bucket / 서비스 user / policy 를
# 프로비저닝.
#
# 전제:
#   - MinIO Tenant Pod 가 Ready (VSO 가 minio-tenant-env Secret 을 이미 동기화)
#   - Vault 가 init + unseal 완료
#   - vault-seed 가 다음 경로를 seed 완료:
#       secret/minio/tenant-env             (root 계정, config.env 포맷)
#       secret/docker-registry/minio        (access_key / secret_key)
#
# 수행 순서:
#   1. Vault 에서 MinIO root 자격증명 + registry 전용 AK/SK 읽기
#   2. kubectl port-forward 로 127.0.0.1 → MinIO Service 터널 생성
#   3. mc alias 등록 → bucket 생성 → policy 작성 → user 생성 → policy 부착
#
# idempotent: 이미 있는 bucket/user/policy 는 건너뜀 (회전은 별도 절차).
#
# Required env:
#   REPO_ROOT
#
# Optional env:
#   DOCKER_REGISTRY_BUCKET   기본 docker-registry
#   DOCKER_REGISTRY_POLICY   기본 docker-registry-rw
#   PF_LOCAL_PORT            기본 9900 (local port-forward)
#   MINIO_SERVICE_PORT       기본 443  (Service 쪽 포트 — autoCert HTTPS)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/vault.sh
. "$SCRIPT_DIR/../lib/vault.sh"

: "${DOCKER_REGISTRY_BUCKET:=docker-registry}"
: "${DOCKER_REGISTRY_POLICY:=docker-registry-rw}"
: "${PF_LOCAL_PORT:=9900}"
: "${MINIO_SERVICE_PORT:=443}"
: "${MINIO_NAMESPACE:=mnt}"
: "${MINIO_SERVICE:=minio}"

MC_ALIAS="minio-prov"
PF_PID=""

cleanup_port_forward() {
  if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}

wait_minio_ready() {
  log "MinIO Tenant Pod Ready 대기"
  retry 30 5 kubectl -n "$MINIO_NAMESPACE" wait --for=condition=Ready --timeout=10s \
    pod -l "v1.min.io/tenant=$MINIO_SERVICE"
}

start_port_forward() {
  log "port-forward 터널 생성 (127.0.0.1:${PF_LOCAL_PORT} → svc/${MINIO_SERVICE}:${MINIO_SERVICE_PORT})"
  kubectl -n "$MINIO_NAMESPACE" port-forward \
    "svc/${MINIO_SERVICE}" "${PF_LOCAL_PORT}:${MINIO_SERVICE_PORT}" \
    >/dev/null 2>&1 &
  PF_PID=$!
  trap_cleanup_fn cleanup_port_forward

  retry 15 1 curl -ks --max-time 2 \
    "https://127.0.0.1:${PF_LOCAL_PORT}/minio/health/live" -o /dev/null
  log "  터널 응답 OK"
}

read_root_credentials() {
  # secret/minio/tenant-env 는 "config.env" 필드 하나에 쉘 export 문 2 줄이
  # 들어 있다. 파싱해서 ROOT_USER / ROOT_PASSWORD 전역에 적재.
  local env_blob
  env_blob="$(vault_exec kv get -format=json secret/minio/tenant-env \
    | jq -r '.data.data["config.env"]')"
  ROOT_USER="$(printf '%s\n' "$env_blob" \
    | sed -n 's/^export MINIO_ROOT_USER="\(.*\)"$/\1/p')"
  ROOT_PASSWORD="$(printf '%s\n' "$env_blob" \
    | sed -n 's/^export MINIO_ROOT_PASSWORD="\(.*\)"$/\1/p')"
  [[ -n "$ROOT_USER" && -n "$ROOT_PASSWORD" ]] \
    || die "MinIO root 자격증명 파싱 실패 — secret/minio/tenant-env 확인"
}

read_registry_credentials() {
  local json
  json="$(vault_exec kv get -format=json secret/docker-registry/minio)"
  REG_AK="$(printf '%s' "$json" | jq -r '.data.data.access_key')"
  REG_SK="$(printf '%s' "$json" | jq -r '.data.data.secret_key')"
  [[ -n "$REG_AK" && -n "$REG_SK" && "$REG_AK" != "null" && "$REG_SK" != "null" ]] \
    || die "docker-registry 자격증명 읽기 실패 — secret/docker-registry/minio 확인"
}

configure_mc_alias() {
  log "mc alias 등록 (alias=${MC_ALIAS})"
  mc --insecure alias set "$MC_ALIAS" \
    "https://127.0.0.1:${PF_LOCAL_PORT}" \
    "$ROOT_USER" "$ROOT_PASSWORD" >/dev/null
}

ensure_bucket() {
  log "bucket 보장 (${DOCKER_REGISTRY_BUCKET})"
  mc --insecure mb --ignore-existing "${MC_ALIAS}/${DOCKER_REGISTRY_BUCKET}" >/dev/null
}

ensure_policy() {
  log "policy 작성 (${DOCKER_REGISTRY_POLICY}) — bucket-scoped read/write"
  local policy_file policy_json
  policy_file="$(mktemp)"
  trap_cleanup_path "$policy_file"
  policy_json="$(jq -n --arg b "$DOCKER_REGISTRY_BUCKET" '{
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: [
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:GetBucketLocation"
        ],
        Resource: ["arn:aws:s3:::\($b)"]
      },
      {
        Effect: "Allow",
        Action: [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload"
        ],
        Resource: ["arn:aws:s3:::\($b)/*"]
      }
    ]
  }')"
  printf '%s' "$policy_json" > "$policy_file"
  chmod 600 "$policy_file"
  # `policy create` 는 idempotent: 이미 있으면 덮어쓴다.
  mc --insecure admin policy create "$MC_ALIAS" \
    "$DOCKER_REGISTRY_POLICY" "$policy_file" >/dev/null
}

ensure_user() {
  if mc --insecure admin user info "$MC_ALIAS" "$REG_AK" >/dev/null 2>&1; then
    log "user '${REG_AK}' 이미 존재 — 재생성 skip (secret key 회전은 별도 절차)"
    return 0
  fi
  log "user '${REG_AK}' 생성"
  mc --insecure admin user add "$MC_ALIAS" "$REG_AK" "$REG_SK" >/dev/null
}

attach_policy() {
  log "policy '${DOCKER_REGISTRY_POLICY}' → user '${REG_AK}' 부착"
  # 이미 부착돼 있으면 mc 가 exit 1 을 반환. 우리는 idempotent 를 의도하므로
  # stderr 를 소비해서 noise 만 판별한 뒤 무시한다.
  local out rc=0
  out="$(mc --insecure admin policy attach "$MC_ALIAS" \
    "$DOCKER_REGISTRY_POLICY" --user "$REG_AK" 2>&1)" || rc=$?
  if (( rc != 0 )) && ! grep -qi "already" <<<"$out"; then
    err "  policy attach 실패: $out"
    return "$rc"
  fi
}

main() {
  require_cmd kubectl jq mc curl
  require_env REPO_ROOT

  local keys_file="${VAULT_KEYS_FILE:-$REPO_ROOT/vault-init-keys.json}"
  vault_login_root_from_keyfile "$keys_file"

  wait_minio_ready
  start_port_forward

  read_root_credentials
  read_registry_credentials

  configure_mc_alias
  ensure_bucket
  ensure_policy
  ensure_user
  attach_policy

  log "minio-provision-registry 태스크 완료"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
