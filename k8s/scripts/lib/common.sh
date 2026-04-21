#!/usr/bin/env bash
# Common shell library for Project-Infra scripts.
#
# Source this with: . "$(dirname "$0")/../lib/common.sh"
# or from tasks/:   . "$SCRIPT_DIR/../lib/common.sh"
#
# Provides:
#   - strict mode + safe IFS
#   - log()/die()/warn() to stderr with ISO 8601 + level prefix
#   - trap_cleanup() — registers a single cleanup handler
#   - require_cmd() / require_env() — preconditions
#   - confirm()    — interactive + CONFIRM=yes env-var gate
#   - mask_secret() — masks sensitive values in logs
#   - retry()       — retry a command with linear backoff
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
# -----------------------------------------------------------------------------
_CLEANUP_CMDS=()

trap_cleanup() {
  _CLEANUP_CMDS+=("$*")
}

_run_cleanups() {
  local rc=$?
  local i
  for ((i = ${#_CLEANUP_CMDS[@]} - 1; i >= 0; i--)); do
    # Best-effort: cleanup must never abort the script further.
    eval "${_CLEANUP_CMDS[$i]}" || true
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
