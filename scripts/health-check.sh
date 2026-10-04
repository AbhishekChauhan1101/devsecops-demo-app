#!/usr/bin/env bash
# HTTP(S) health check with retries.
#   HEALTH_CHECK_URL (required)  HEALTH_CHECK_RETRIES (10)  HEALTH_CHECK_DELAY (6s)
#   HEALTH_CHECK_TIMEOUT (15s per request)  HEALTH_EXPECTED_STATUS ("200", comma list allowed)
#   HEALTH_SKIP_TLS_VERIFY (false)  HC_USER / HC_PASS (optional HTTP basic auth, from Jenkins credentials)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_cmd curl "Install curl on this agent."
require_env HEALTH_CHECK_URL
url="$HEALTH_CHECK_URL"
retries="${HEALTH_CHECK_RETRIES:-10}"
delay="${HEALTH_CHECK_DELAY:-6}"
timeout="${HEALTH_CHECK_TIMEOUT:-15}"
expected="${HEALTH_EXPECTED_STATUS:-200}"
for n in "$retries" "$delay" "$timeout"; do
  [[ "$n" =~ ^[0-9]+$ ]] || die "HEALTH_CHECK_RETRIES / DELAY / TIMEOUT must be whole numbers." 2
done

shown="${url%%\?*}"      # never print the query string (it may contain tokens)
section "Health check: ${shown} (expect HTTP ${expected}, ${retries} tries, ${delay}s apart)"

curl_args=(-sS -o /dev/null -w '%{http_code}' --max-time "$timeout" -L --max-redirs 5)
if is_true "${HEALTH_SKIP_TLS_VERIFY:-false}"; then
  warn "TLS certificate verification is DISABLED for this health check (HEALTH_SKIP_TLS_VERIFY=true)."
  curl_args+=(-k)
fi

probe() {
  if [ -n "${HC_USER:-}" ]; then
    local cred="${HC_USER}:${HC_PASS:-}"
    cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"
    printf 'user = "%s"\n' "$cred" | curl "${curl_args[@]}" -K - "$url"   # credentials via stdin, not argv
  else
    curl "${curl_args[@]}" "$url"
  fi
}

attempt=1
while [ "$attempt" -le "$retries" ]; do
  set +e
  code="$(probe 2>/tmp/hc.err.$$)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || code="000"
  case ",${expected}," in
    *",${code},"*)
      log "Health check OK: HTTP ${code} (attempt ${attempt}/${retries})"
      rm -f "/tmp/hc.err.$$"
      exit 0
      ;;
  esac
  reason="$(head -c 200 "/tmp/hc.err.$$" 2>/dev/null | tr '\n' ' ')"
  warn "Attempt ${attempt}/${retries}: HTTP ${code} ${reason}"
  attempt=$((attempt + 1))
  if [ "$attempt" -le "$retries" ]; then sleep "$delay"; fi
done
rm -f "/tmp/hc.err.$$"
err "Health check FAILED after ${retries} attempts: ${shown}"
exit 1
