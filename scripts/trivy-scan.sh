#!/usr/bin/env bash
# Usage: trivy-scan.sh fs [path]        (source / dependency / secret scan - for IIS or any non-container app)
#        trivy-scan.sh image <ref>      (container image scan - for Docker deployments)
#
# Policy: findings at TRIVY_SEVERITY make the script exit with TRIVY_EXIT_CODE (default 1).
#         TRIVY_EXIT_CODE=0 turns the scan into report-only.
#   exit 0 / $TRIVY_EXIT_CODE -> policy result      exit 10 -> trivy missing / failed to run
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

mode="${1:-}"
target="${2:-.}"
case "$mode" in
  fs|image) : ;;
  *) die "Usage: trivy-scan.sh <fs|image> [target]" 2 ;;
esac
[ "$mode" = "image" ] && [ "$target" = "." ] && die "trivy-scan.sh image needs an image reference, e.g. repo/app:tag" 2

severity="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
fail_code="${TRIVY_EXIT_CODE:-1}"
[[ "$fail_code" =~ ^[0-9]+$ ]] || die "TRIVY_EXIT_CODE must be a number (got '$fail_code')." 2
require_cmd jq "Install jq (apt install jq) - it is used to count findings."

trivy_run() {
  if is_true "${TRIVY_USE_DOCKER:-false}"; then
    require_cmd docker "TRIVY_USE_DOCKER=true needs Docker on this agent."
    local cache="${TRIVY_CACHE_DIR:-$HOME/.cache/trivy}" sock_gid
    mkdir -p "$cache"
    sock_gid="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 0)"
    docker run --rm --user "$(id -u):$(id -g)" --group-add "$sock_gid" \
      -e HOME=/tmp -e TRIVY_CACHE_DIR=/tmp/trivy-cache -v "$cache:/tmp/trivy-cache" \
      -v "$PWD:$PWD" -w "$PWD" -v /var/run/docker.sock:/var/run/docker.sock \
      "aquasec/trivy:${TRIVY_DOCKER_TAG:-latest}" "$@"
  else
    command -v trivy >/dev/null 2>&1 \
      || die "Trivy is not installed on this agent. Install it (see docs/trivy-setup.md) or set TRIVY_USE_DOCKER=true. It is never silently skipped; disable it with ENABLE_TRIVY=false." 10
    trivy "$@"
  fi
}

out="$(reports_dir trivy)"
name="trivy-$mode"
json="$out/$name.json"
txt="$out/$name.txt"

args=(--severity "$severity" --scanners "${TRIVY_SCANNERS:-vuln,secret}" --timeout "${TRIVY_TIMEOUT:-10m}"
      --exit-code 0 --format json --output "$json")
if is_true "${TRIVY_IGNORE_UNFIXED:-false}"; then args+=(--ignore-unfixed); fi
if [ -n "${TRIVY_SKIP_DIRS:-}" ]; then
  IFS=',' read -r -a skip <<< "$TRIVY_SKIP_DIRS"
  for d in "${skip[@]}"; do args+=(--skip-dirs "$d"); done
fi

section "Trivy $mode scan: $target (severity: $severity, fail exit code: $fail_code)"
set +e
trivy_run "$mode" "${args[@]}" "$target"
rc=$?
set -e
[ "$rc" -eq 0 ] || die "Trivy failed to run (exit code $rc). Check the output above (database download / image not found)." 10
[ -f "$json" ] || die "Trivy did not produce $json" 10

trivy_run convert --format table --output "$txt" "$json" || warn "Could not render the table report (JSON report is still available)."
if [ -f "$txt" ]; then cat "$txt"; fi

vulns="$(jq -r '[.Results[]? | (.Vulnerabilities // [])[]] | length' "$json")"
secrets="$(jq -r '[.Results[]? | (.Secrets // [])[]] | length' "$json")"
misconf="$(jq -r '[.Results[]? | (.Misconfigurations // [])[] | select(.Status == "FAIL")] | length' "$json")"
total=$((vulns + secrets + misconf))
log "Trivy findings at $severity: vulnerabilities=$vulns secrets=$secrets misconfigurations=$misconf"

if [ "$total" -gt 0 ] && [ "$fail_code" -ne 0 ]; then
  write_summary "$name" FAIL "VULNERABILITIES=$vulns" "SECRETS=$secrets" "MISCONFIGURATIONS=$misconf" "SEVERITY=$severity"
  err "Trivy: $total finding(s) at severity $severity."
  exit "$fail_code"
fi
write_summary "$name" PASS "VULNERABILITIES=$vulns" "SECRETS=$secrets" "MISCONFIGURATIONS=$misconf" "SEVERITY=$severity"
if [ "$total" -gt 0 ]; then
  warn "Trivy found $total issue(s) but TRIVY_EXIT_CODE=0 (report-only mode)."
else
  log "Trivy: no findings at severity $severity."
fi
