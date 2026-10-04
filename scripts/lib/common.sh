#!/usr/bin/env bash
# Shared helpers for the Linux scripts. Source this file; do not execute it.
# shellcheck shell=bash
#
# Exit-code convention used by every script in this framework:
#   0   success / policy satisfied
#   1   policy failure or operation failed (findings above threshold, health check failed, ...)
#   2   invalid configuration (a required setting is missing or malformed)
#   10  a required tool is missing or could not run (setup problem, NOT a policy decision)

_ts() { date '+%H:%M:%S'; }
log()     { printf '[%s] [INFO ] %s\n' "$(_ts)" "$*"; }
warn()    { printf '[%s] [WARN ] %s\n' "$(_ts)" "$*" >&2; }
err()     { printf '[%s] [ERROR] %s\n' "$(_ts)" "$*" >&2; }
die()     { local code="${2:-1}"; err "$1"; exit "$code"; }
section() { printf '\n===== %s =====\n' "$*"; }

is_true() {
  case "${1:-}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy]|[Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() { # require_cmd <command> [hint]
  command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' was not found on this agent. ${2:-}" 10
}

require_env() { # require_env VAR [VAR...]
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "Required setting '$v' is empty. Set it in the CFG block of the Jenkinsfile (or in your env file)." 2
  done
}

# Resolved application type (detect-app-type.sh result wins over the configured value)
app_type() { printf '%s' "${APP_TYPE_RESOLVED:-${APP_TYPE:-generic}}"; }

# reports_dir <name>  -> creates and prints reports/<name>
reports_dir() {
  local d="${REPORTS_DIR:-reports}/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# write_summary <name> <STATUS> [KEY=value ...]   -> reports/summary/<name>.env
write_summary() {
  local name="$1" status="$2"
  shift 2
  local dir kv
  dir="$(reports_dir summary)"
  {
    printf 'STATUS=%s\n' "$status"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$dir/$name.env"
}
