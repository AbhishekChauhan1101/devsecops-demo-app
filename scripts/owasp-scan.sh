#!/usr/bin/env bash
# OWASP Dependency-Check. Produces reports/owasp/dependency-check-report.{html,json,xml}.
# The CVSS gate is evaluated HERE from the JSON report (no --failOnCVSS) so the result is
# explicit and configurable:
#   exit 0  -> no vulnerability at or above OWASP_FAIL_THRESHOLD
#   exit 1  -> at least one vulnerability >= threshold (Jenkins security gate decides what happens)
#   exit 10 -> the tool is missing / failed to run (never reported as a pass)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

threshold="${OWASP_FAIL_THRESHOLD:-7}"
[[ "$threshold" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "OWASP_FAIL_THRESHOLD must be a number between 0 and 10 (got '$threshold'). Use 11 for report-only." 2

odc=""
if [ -n "${OWASP_DC_HOME:-}" ]; then
  odc="$OWASP_DC_HOME/bin/dependency-check.sh"
elif command -v dependency-check.sh >/dev/null 2>&1; then
  odc="$(command -v dependency-check.sh)"
elif command -v dependency-check >/dev/null 2>&1; then
  odc="$(command -v dependency-check)"
fi
if [ -z "$odc" ] || [ ! -x "$odc" ]; then
  die "OWASP Dependency-Check CLI not found. Install it on this agent and either put it on PATH or set OWASP_DC_HOME. See docs/owasp-setup.md. (Disable the scan with ENABLE_OWASP=false - it is never silently skipped.)" 10
fi
require_cmd jq "Install jq (apt install jq) - it is used to evaluate the CVSS threshold."

out="$(reports_dir owasp)"
args=(--scan "${OWASP_SCAN_PATH:-.}" --project "${APP_NAME:-application}" --out "$out"
      --format HTML --format JSON --format XML --disableAssembly)
if [ -n "${OWASP_DATA_DIR:-}" ]; then
  mkdir -p "$OWASP_DATA_DIR"
  args+=(--data "$OWASP_DATA_DIR")
fi
if [ -n "${NVD_API_KEY:-}" ]; then
  args+=(--nvdApiKey "$NVD_API_KEY")
else
  warn "No NVD API key configured (OWASP_NVD_API_KEY_CRED_ID). The first database download is very slow and may be rate-limited."
fi
# shellcheck disable=SC2206   # OWASP_EXTRA_ARGS is an intentionally word-split list of options
extra=(${OWASP_EXTRA_ARGS:-})

section "OWASP Dependency-Check (threshold: CVSS >= $threshold)"
set +e
"$odc" "${args[@]}" "${extra[@]}"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  die "Dependency-Check failed to run (exit code $rc). Check the output above (NVD download / network / data directory)." 10
fi

json="$out/dependency-check-report.json"
[ -f "$json" ] || die "Dependency-Check did not produce $json" 10

max="$(jq -r '[.dependencies[]?.vulnerabilities[]? | ((.cvssv3.baseScore // .cvssv2.score // 0) | tonumber)] | (max // 0)' "$json")"
total="$(jq -r '[.dependencies[]?.vulnerabilities[]?] | length' "$json")"
over="$(jq -r --argjson t "$threshold" '[.dependencies[]?.vulnerabilities[]? | ((.cvssv3.baseScore // .cvssv2.score // 0) | tonumber) | select(. >= $t)] | length' "$json")"

log "Vulnerabilities found: $total | highest CVSS: $max | at/above threshold ($threshold): $over"
log "HTML report: $out/dependency-check-report.html"

if [ "$over" -gt 0 ]; then
  write_summary owasp FAIL "MAX_CVSS=$max" "TOTAL=$total" "OVER_THRESHOLD=$over" "THRESHOLD=$threshold"
  err "OWASP: $over vulnerabilities with CVSS >= $threshold (highest $max)."
  exit 1
fi
write_summary owasp PASS "MAX_CVSS=$max" "TOTAL=$total" "OVER_THRESHOLD=0" "THRESHOLD=$threshold"
log "OWASP: no vulnerability at or above CVSS $threshold."
