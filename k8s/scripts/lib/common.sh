#!/usr/bin/env bash
# Common shell library for Project-Infra scripts.
#
# Source this with: . "$(dirname "$0")/../lib/common.sh"
# or from tasks/:   . "$SCRIPT_DIR/../lib/common.sh"
#
# Provides:
#   - strict mode + safe IFS
#   - log()/warn()/err()/die() to stderr with ISO 8601 + level prefix
#   - trap_cleanup_path() / trap_cleanup_fn() — EXIT 시 경로 rm -rf 또는 함수 호출
#   - require_cmd() / require_env() — preconditions
#   - confirm()    — interactive + CONFIRM=yes env-var gate
#   - mask_secret() — masks sensitive values in logs
#   - retry()       — retry a command with linear backoff
#   - require_kube_context() / require_production_gate() — env 타깃 검증 가드
#   - ns_exists() / ns_phase() / strip_finalizers_in_ns() /
#     strip_finalizers_all_ns_resources() / force_finalize_namespace() /
#     wait_namespace_gone() — namespace teardown 복구 헬퍼
#
# All functions emit diagnostic output to stderr; stdout stays clean
# so callers can pipe subcommand output normally.

# shellcheck shell=bash

# -----------------------------------------------------------------------------
# strict mode
# -----------------------------------------------------------------------------
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# logging
# -----------------------------------------------------------------------------
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log()  { printf '%s [INFO]  %s\n' "$(_ts)" "$*" >&2; }
warn() { printf '%s [WARN]  %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# -----------------------------------------------------------------------------
# cleanup registration
#
# eval 기반 문자열 cleanup 은 공통 라이브러리에 두기에 부적절하다 (셸 인젝션
# 경로가 열리기 쉽고, Google shell 가이드 기준 code smell). 대신 두 가지 구체
# 타입만 제공한다:
#   - trap_cleanup_path <path>  : EXIT 시 rm -rf 로 삭제할 경로
#   - trap_cleanup_fn <fname>   : EXIT 시 인자 없이 호출할 함수 이름
# 두 종류 다 LIFO 로 실행되고, 실패해도 전체 종료 코드는 보존된다.
# -----------------------------------------------------------------------------
_CLEANUP_PATHS=()
_CLEANUP_FNS=()

trap_cleanup_path() {
  local p="$1"
  [[ -n "$p" ]] || return 0
  _CLEANUP_PATHS+=("$p")
}

trap_cleanup_fn() {
  local fn="$1"
  declare -F "$fn" >/dev/null 2>&1 \
    || { err "trap_cleanup_fn: 함수를 찾을 수 없음: $fn"; return 1; }
  _CLEANUP_FNS+=("$fn")
}

_run_cleanups() {
  local rc=$?
  local i
  for ((i = ${#_CLEANUP_FNS[@]} - 1; i >= 0; i--)); do
    "${_CLEANUP_FNS[$i]}" || true
  done
  for ((i = ${#_CLEANUP_PATHS[@]} - 1; i >= 0; i--)); do
    rm -rf -- "${_CLEANUP_PATHS[$i]}" || true
  done
  exit "$rc"
}

trap _run_cleanups EXIT INT TERM

# -----------------------------------------------------------------------------
# preconditions
# -----------------------------------------------------------------------------
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "필수 명령어가 PATH 에 없습니다: $cmd"
  done
}

require_env() {
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      die "필수 환경 변수가 비어있습니다: $var"
    fi
  done
}

# -----------------------------------------------------------------------------
# destructive gate
# -----------------------------------------------------------------------------
# Usage: confirm "namespace 'mnt' 의 모든 리소스를 삭제합니다. 계속?"
# Returns 0 if the user said yes (interactively or via CONFIRM=yes env).
confirm() {
  local prompt="$1"
  if [[ "${CONFIRM:-}" == "yes" ]]; then
    log "CONFIRM=yes → 자동 진행: $prompt"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "비대화 환경에서는 CONFIRM=yes 환경 변수를 지정하세요: $prompt"
  fi
  local answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# -----------------------------------------------------------------------------
# secret masking (for logs)
# -----------------------------------------------------------------------------
# Usage: log "root token = $(mask_secret "$ROOT_TOKEN")"
mask_secret() {
  local s="$1"
  local n=${#s}
  if (( n <= 8 )); then
    printf '***'
  else
    printf '%s***%s' "${s:0:4}" "${s: -4}"
  fi
}

# -----------------------------------------------------------------------------
# retry helper
# -----------------------------------------------------------------------------
# Usage: retry 5 2 kubectl wait --for=condition=Ready pod/vault-0 -n mnt --timeout=10s
#   - $1: max attempts
#   - $2: sleep seconds between attempts
#   - $3..: command and arguments
retry() {
  local attempts="$1"; shift
  local delay="$1"; shift
  local i=0
  until "$@"; do
    i=$((i + 1))
    if (( i >= attempts )); then
      err "최대 시도 횟수 ${attempts} 회 초과: $*"
      return 1
    fi
    warn "실패 ($i/$attempts), ${delay}s 후 재시도: $*"
    sleep "$delay"
  done
}

# -----------------------------------------------------------------------------
# kube-context / env 타깃 검증
# -----------------------------------------------------------------------------
# require_kube_context <env_name>
#
# env → 기대 context 매핑을 다음 우선순위로 해결한다:
#   1) $KUBE_CONTEXT (명시적으로 주입된 값 — CI 에서 사용)
#   2) $KUBE_CONTEXT_<ENV_UPPER> (env 별 매핑 — 쉘 rc 에 선언하면 편함)
#
# 매칭 실패 시 현재 context 를 출력하고 사용자에게 context 이름을 직접
# 재입력받아 확인한다. 비대화 환경은 die.
#
# 이 함수를 통과하면 다음이 보장된다:
#   - kubectl 이 가리키는 cluster 가 env 의 의도된 cluster
#   - 사용자/CI 가 그 사실을 명시적으로 인지함 (실수 클러스터 apply 방지)
require_kube_context() {
  local env_name="$1"
  require_cmd kubectl

  local current
  current="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$current" ]] || die "kubectl current-context 가 비어있습니다. kubeconfig 를 먼저 설정하세요."

  local env_upper
  env_upper="$(printf '%s' "$env_name" | tr '[:lower:]' '[:upper:]')"
  local mapped_var="KUBE_CONTEXT_${env_upper}"
  local expected="${KUBE_CONTEXT:-${!mapped_var:-}}"

  if [[ -n "$expected" ]]; then
    if [[ "$current" != "$expected" ]]; then
      die "kube-context 불일치: env=$env_name 기대='$expected' 현재='$current' (KUBE_CONTEXT 또는 ${mapped_var} 와 kubectl 현재 context 가 다름)"
    fi
    log "kube-context OK: env=$env_name context='$current'"
    return 0
  fi

  # 매핑이 없을 때:
  #   - 비대화(CI) → 무조건 die. CONFIRM=yes 로도 우회 불가 (context 는
  #     destructive 작업의 타깃이라 명시성이 절대 원칙).
  #   - 대화형 TTY → 현재 context 이름 재입력으로 확인.
  if [[ ! -t 0 ]]; then
    die "비대화 환경에서는 KUBE_CONTEXT 또는 ${mapped_var} 가 필수입니다 (CONFIRM=yes 로 우회 불가)."
  fi
  warn "env=$env_name 의 기대 context 가 지정되지 않았습니다."
  warn "  (권장) export KUBE_CONTEXT_${env_upper}='<context-name>' 를 쉘 rc 에 선언"
  warn "현재 context: $current"
  local typed
  read -r -p "확인을 위해 현재 context 이름을 그대로 입력하세요 ('$current'): " typed
  [[ "$typed" == "$current" ]] || die "context 이름 불일치 — 중단"
}

# require_production_gate <env_name>
#
# env=prod 에서 파괴적 작업을 실행하려면 ALLOW_PROD_DESTRUCTIVE=yes 를 요구.
# 추가로 namespace 이름 재입력을 강제해서 오타 한 번으로 prod 가 날아가는 것을 막는다.
# dev/staging 은 통과.
require_production_gate() {
  local env_name="$1"
  local ns="$2"
  [[ "$env_name" == "prod" ]] || return 0

  if [[ "${ALLOW_PROD_DESTRUCTIVE:-}" != "yes" ]]; then
    die "env=prod 파괴적 작업은 ALLOW_PROD_DESTRUCTIVE=yes 환경 변수가 필요합니다."
  fi
  if [[ ! -t 0 ]]; then
    die "env=prod 는 대화형 TTY 에서만 실행 가능합니다 (namespace 재입력 확인 필요)."
  fi
  local typed
  warn "env=prod 파괴적 작업 — namespace '$ns' 를 그대로 재입력하세요."
  read -r -p "namespace: " typed
  [[ "$typed" == "$ns" ]] || die "namespace 재입력 불일치 — 중단"
}

# -----------------------------------------------------------------------------
# namespace / finalizer 정리 헬퍼
# -----------------------------------------------------------------------------

# ns_phase <namespace> — namespace 의 .status.phase 를 출력. 없으면 빈 문자열.
ns_phase() {
  local ns="$1"
  kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

# ns_exists <namespace> — 존재하면 0, 없으면 1
ns_exists() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

# strip_finalizers_in_ns <namespace> <kind...>
# 지정한 kind 들의 모든 인스턴스에서 metadata.finalizers 를 제거한다.
# kind 가 CRD 여도 동작 (kubectl 이 해당 API 서버에 등록되어 있기만 하면).
strip_finalizers_in_ns() {
  local ns="$1"; shift
  local kind obj
  for kind in "$@"; do
    while IFS= read -r obj; do
      [[ -z "$obj" ]] && continue
      kubectl -n "$ns" patch "$obj" --type=merge \
        -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      log "  finalizer 제거: -n $ns $obj"
    done < <(kubectl -n "$ns" get "$kind" -o name 2>/dev/null || true)
  done
}

# strip_finalizers_all_ns_resources <namespace>
# namespace 에 남아있는 모든 namespaced 리소스의 finalizer 를 일괄 제거.
# 최후 수단 — Terminating 에 걸린 리소스들을 떼어낼 때만 사용.
strip_finalizers_all_ns_resources() {
  local ns="$1"
  local kinds
  # namespaced=true 리소스 종류만
  kinds=$(kubectl api-resources --namespaced=true --verbs=delete -o name 2>/dev/null)
  local kind
  for kind in $kinds; do
    while IFS= read -r obj; do
      [[ -z "$obj" ]] && continue
      kubectl -n "$ns" patch "$obj" --type=merge \
        -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done < <(kubectl -n "$ns" get "$kind" -o name 2>/dev/null || true)
  done
}

# force_finalize_namespace <namespace>
# namespace 자체의 spec.finalizers 를 비워서 API 서버가 강제 삭제하도록 한다.
# kubectl replace --raw 로 /finalize 엔드포인트 호출.
# 전제: kubectl + jq 존재. 주의 — orphaned PV 등이 남을 수 있음.
force_finalize_namespace() {
  local ns="$1"
  require_cmd jq
  log "  namespace $ns 강제 finalize (API /finalize)"
  kubectl get namespace "$ns" -o json \
    | jq '.spec.finalizers = [] | .metadata.finalizers = []' \
    | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null
}

# wait_namespace_gone <namespace> <timeout_seconds>
# namespace 가 완전히 사라질 때까지 대기. timeout 초과 시 1 반환.
wait_namespace_gone() {
  local ns="$1" timeout="${2:-60}" i=0
  while ns_exists "$ns"; do
    i=$((i + 1))
    if (( i >= timeout )); then
      return 1
    fi
    sleep 1
  done
  return 0
}
