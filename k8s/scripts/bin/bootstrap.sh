#!/usr/bin/env bash
# Entry point: bootstrap the full infra stack for a given environment.
#
# Phases:
#   0. MinIO Operator Helm install            (tasks/minio-operator-install.sh)
#   1. Apply namespace + PSS labels           (kubectl apply -k base/managing/namespace)
#   2. (optional) Reset stale K8s Secrets     (RESET_STALE_SECRETS=yes 일 때만)
#   2.5 VSO CRD 선행 설치                     (VaultStaticSecret CR 가 overlay 에 포함돼 있어)
#   3. Render + diff + confirm + apply overlay  (--server-side --field-manager=project-infra-bootstrap)
#   4. Wait for vault-0 Running
#   5. Vault init + unseal + KV + k8s auth + policy / role  (tasks/vault-init.sh)
#   6. Seed 5 application secrets             (tasks/vault-seed-apps.sh)
#   7. Helm install VSO                       (tasks/vso-install.sh)
#   8. Apply VSO CRs                          (kubectl apply -k overlays/<env>/vso/)
#
# 대화형 실행 (bash history 에 비밀번호 남지 않음):
#   bash k8s/scripts/bin/bootstrap.sh dev
#
# Required context (안전 가드):
#   KUBE_CONTEXT_DEV / KUBE_CONTEXT_STAGING / KUBE_CONTEXT_PROD
#   또는 KUBE_CONTEXT= 로 명시. 쉘 rc 에 선언해 두면 현재 kubectl context
#   와 일치 여부를 자동 검증한다. 매핑이 없으면 대화형으로 context 이름
#   재입력을 요구.
#
# Optional env:
#   RESET_STALE_SECRETS=yes       이미 있는 VSO-managed K8s Secret 을 삭제 후 재생성
#   VAULT_KEYS_FILE=<path>        env=prod 필수 — repo 바깥 경로
#   SKIP_DIFF=yes                 Phase 3 의 kubectl diff preview 생략
#   CONFIRM=yes                   대화형 프롬프트 자동 승인 (CI)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
K8S_ROOT="$REPO_ROOT/k8s"
TASKS_DIR="$SCRIPT_DIR/../tasks"
export REPO_ROOT

NAMESPACE="mnt"
FIELD_MANAGER="project-infra-bootstrap"

# VSO 가 관리하는 K8s Secret 이름 목록 (기존 찌꺼기 감지용)
VSO_MANAGED_SECRETS=(
  identity-postgres-superuser
  keycloak-db
  auth-server-db
  keycloak-bootstrap-admin
  minio-tenant-env
)

usage() {
  cat >&2 <<EOF
Usage: bin/bootstrap.sh <dev|staging|prod>

Required env (권장 — 쉘 rc 에 선언):
  KUBE_CONTEXT_DEV / KUBE_CONTEXT_STAGING / KUBE_CONTEXT_PROD   env → kubectl context 매핑
  (또는 KUBE_CONTEXT=<name> 로 한 번만 overrides)

Options:
  RESET_STALE_SECRETS=yes   이미 존재하는 VSO-managed Secret 을 삭제 후 재생성
  VAULT_KEYS_FILE=<path>    env=prod 필수 — repo 바깥 경로
  SKIP_DIFF=yes             Phase 3 diff preview 생략 (비권장)
  CONFIRM=yes               대화형 확인 자동 승인 (CI)
EOF
  exit 1
}

precheck_namespace() {
  if ! ns_exists "$NAMESPACE"; then
    log "Precheck: namespace '$NAMESPACE' 없음 — 신규 생성 흐름"
    return 0
  fi
  local phase
  phase="$(ns_phase "$NAMESPACE")"
  if [[ "$phase" == "Terminating" ]]; then
    err "namespace '$NAMESPACE' 가 Terminating 상태입니다."
    err "이전 teardown 이 완료되지 않아 새 리소스 생성이 불가능합니다."
    err ""
    err "복구 절차:"
    err "  1) 이전 teardown 을 마저 끝내기:"
    err "       CONFIRM=yes bash k8s/scripts/bin/teardown.sh $ENV_NAME"
    err "  2) namespace 가 완전히 사라진 걸 확인한 뒤 bootstrap 재실행:"
    err "       kubectl get namespace $NAMESPACE"
    err "       bash k8s/scripts/bin/bootstrap.sh $ENV_NAME"
    die "bootstrap 중단"
  fi
  log "Precheck: namespace '$NAMESPACE' phase=$phase — 계속 진행"
}

phase0_minio_operator() {
  log "[0/8] MinIO Operator 설치 (Tenant CRD 선행)"
  bash "$TASKS_DIR/minio-operator-install.sh"
}

phase1_namespace() {
  log "[1/8] Namespace + PSS 라벨 선행 apply"
  kubectl apply -k "$K8S_ROOT/base/managing/namespace" \
    --server-side --field-manager="$FIELD_MANAGER"
  retry 5 1 kubectl get namespace "$NAMESPACE" >/dev/null
}

phase2_reset_stale_secrets() {
  log "[2/8] 기존 VSO-managed K8s Secret 점검"
  local stale_found=0 s
  for s in "${VSO_MANAGED_SECRETS[@]}"; do
    if kubectl -n "$NAMESPACE" get secret "$s" >/dev/null 2>&1; then
      stale_found=$((stale_found + 1))
      if [[ "${RESET_STALE_SECRETS:-}" == "yes" ]]; then
        log "  삭제: $s (RESET_STALE_SECRETS=yes)"
        kubectl -n "$NAMESPACE" delete secret "$s" --ignore-not-found
      else
        warn "  $s 이미 존재 (VSO 가 덮어쓰지 않음). Vault 값 반영이 필요하면 RESET_STALE_SECRETS=yes 로 재실행하거나 수동 삭제하세요."
      fi
    fi
  done
  (( stale_found == 0 )) && log "  기존 Secret 없음"
}

phase2_5_vso_crds() {
  # overlays/<env>/{database,keycloak,storage}/vault-secrets.yaml 에 VaultStaticSecret
  # CR 들이 포함돼 있어, Phase 3 overlay apply 시점에 CRD 가 없으면 "resource mapping
  # not found" 로 실패. Helm 차트 install 은 Phase 7 이므로 CRD 만 선행 적용.
  log "[2.5/8] VSO CRD 선행 설치"
  local version="${VSO_VERSION:-0.9.0}"
  helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
  helm repo update hashicorp >/dev/null
  helm show crds hashicorp/vault-secrets-operator --version "$version" \
    | kubectl apply -f - --server-side --field-manager="$FIELD_MANAGER"
}

# render → server-side dry-run → diff → confirm → apply
#
# kubectl diff exit codes (GNU man page):
#   0 — 변경 없음
#   1 — 변경 있음 (정상)
#   >1 — 실행 오류 (RBAC / API 연결 / invalid manifest 등)
# 이전 구현은 `|| true` 로 모든 비-0 을 흡수해서 에러가 apply 까지 흘러갔다.
phase3_overlay_apply() {
  log "[3/8] 인프라 overlay 배포 ($OVERLAY_DIR)"

  local tmpdir
  tmpdir="$(mktemp -d -t project-infra-bootstrap.XXXXXX)"
  trap_cleanup_path "$tmpdir"

  local rendered="$tmpdir/rendered.yaml"
  kustomize build "$OVERLAY_DIR" > "$rendered"
  log "  render 완료: $(grep -c '^kind:' "$rendered") resources"

  # --- server-side dry-run: admission / RBAC / schema 를 API server 로 검증 ---
  log "  server-side dry-run 검증"
  if ! kubectl apply -f "$rendered" --dry-run=server \
         --server-side --field-manager="$FIELD_MANAGER" \
         >"$tmpdir/dryrun.out" 2>&1; then
    err "  server-side dry-run 실패 — apply 중단"
    sed 's/^/    /' "$tmpdir/dryrun.out" >&2
    die "dry-run 검증 실패"
  fi

  # --- diff preview — 변경 있음(rc=1)은 정상, 실행 오류(rc>=2)는 die ---
  if [[ "${SKIP_DIFF:-}" == "yes" ]]; then
    warn "  SKIP_DIFF=yes → diff preview 생략"
  else
    log "  server-side diff preview (대용량이면 스크롤)"
    local rc=0
    kubectl diff -f "$rendered" --server-side --field-manager="$FIELD_MANAGER" \
      >"$tmpdir/diff.out" 2>&1 || rc=$?
    case "$rc" in
      0) log "    (변경 없음)" ;;
      1)
        if [[ -s "$tmpdir/diff.out" ]]; then
          sed 's/^/    /' "$tmpdir/diff.out" >&2
        else
          log "    (diff 출력 없음)"
        fi
        ;;
      *)
        err "  kubectl diff 실행 실패 (exit=$rc) — apply 중단"
        sed 's/^/    /' "$tmpdir/diff.out" >&2
        die "diff 실패"
        ;;
    esac
  fi

  confirm "위 변경사항을 env=$ENV_NAME context='$(kubectl config current-context)' 에 apply 하시겠습니까?" \
    || die "사용자 취소"

  kubectl apply -f "$rendered" --server-side --field-manager="$FIELD_MANAGER"
  log "  vault/registry/앱 워크로드 apply 완료"
}

phase4_wait_vault_running() {
  # Vault readiness probe 는 initialized+unsealed 일 때만 통과하므로 초기화 *전*
  # 에는 Ready 가 될 수 없음 → Running 단계까지만 기다림.
  log "[4/8] vault-0 Running 대기 (120s × 재시도 3회)"
  retry 3 10 kubectl -n "$NAMESPACE" wait \
    --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=120s
}

phase5_vault_init() {
  log "[5/8] Vault 초기화 / unseal / auth / policy / role"
  ENV_NAME="$ENV_NAME" bash "$TASKS_DIR/vault-init.sh"
}

phase6_seed_apps() {
  log "[6/8] 앱 시크릿 5 개 Vault KV 에 seed"
  ENV_NAME="$ENV_NAME" bash "$TASKS_DIR/vault-seed-apps.sh"
}

phase7_vso_install() {
  log "[7/8] VSO Helm upgrade --install"
  ENV_NAME="$ENV_NAME" bash "$TASKS_DIR/vso-install.sh"
}

phase8_vso_crs() {
  log "[8/8] VSO CR 적용 ($OVERLAY_DIR/vso/)"
  kubectl apply -k "$OVERLAY_DIR/vso/" \
    --server-side --field-manager="$FIELD_MANAGER"
}

summary() {
  log "============================================"
  log "  $ENV_NAME 부트스트랩 완료"
  log "============================================"
  log "unseal keys + root token: ${VAULT_KEYS_FILE:-$REPO_ROOT/vault-init-keys.json} (0600)"
  log "  → 오프라인 / 외부 KMS 로 즉시 이동하세요 (Git 반입 금지)"
  log ""
  log "앱 시크릿 5 개는 Phase 6 에서 입력/seed 됨."
  log "조회: vault kv get -field=password secret/<path>"
  log ""
  log "다음 확인:"
  log "  kubectl -n $NAMESPACE get pods"
  log "  kubectl -n $NAMESPACE get secrets"
  log "  kubectl -n $NAMESPACE get vaultstaticsecret"
}

main() {
  ENV_NAME="${1:-}"
  case "$ENV_NAME" in
    dev|staging|prod) ;;
    *) usage ;;
  esac

  OVERLAY_DIR="$K8S_ROOT/overlays/$ENV_NAME"
  [[ -d "$OVERLAY_DIR" ]] || die "overlay 디렉토리 없음: $OVERLAY_DIR"

  require_cmd kubectl helm jq kustomize

  # 안전 가드 — 실수 클러스터 apply 방지
  require_kube_context "$ENV_NAME"

  log "============================================"
  log "  Project-Infra 부트스트랩 ($ENV_NAME)"
  log "  context : $(kubectl config current-context)"
  log "============================================"

  precheck_namespace
  phase0_minio_operator
  phase1_namespace
  phase2_reset_stale_secrets
  phase2_5_vso_crds
  phase3_overlay_apply
  phase4_wait_vault_running
  phase5_vault_init
  phase6_seed_apps
  phase7_vso_install
  phase8_vso_crs
  summary
}

# Google shell style — 직접 실행일 때만 main 호출 (source 된 경우 함수만 노출).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
