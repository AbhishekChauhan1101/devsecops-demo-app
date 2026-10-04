#!/usr/bin/env bash
# SonarQube analysis for every non-.NET application using the generic sonar-scanner CLI.
# Run it inside Jenkins' withSonarQubeEnv(...) so SONAR_HOST_URL / SONAR_AUTH_TOKEN are injected.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env SONAR_HOST_URL SONAR_AUTH_TOKEN SONAR_PROJECT_KEY

scanner=""
if [ -n "${SONAR_SCANNER_HOME:-}" ] && [ -x "$SONAR_SCANNER_HOME/bin/sonar-scanner" ]; then
  scanner="$SONAR_SCANNER_HOME/bin/sonar-scanner"
elif command -v sonar-scanner >/dev/null 2>&1; then
  scanner="$(command -v sonar-scanner)"
else
  die "sonar-scanner CLI not found. Install it on this agent, or configure a 'SonarQube Scanner' tool in Jenkins and set SONAR_SCANNER_TOOL. See docs/sonarqube-setup.md" 10
fi

export SONAR_TOKEN="$SONAR_AUTH_TOKEN"    # read by the scanner from the environment (keeps the token out of the command line)
section "SonarQube (generic scanner)"
# shellcheck disable=SC2086   # SONAR_EXTRA_ARGS is an intentionally word-split list of -D options
"$scanner" \
  -Dsonar.projectKey="$SONAR_PROJECT_KEY" \
  -Dsonar.projectName="${SONAR_PROJECT_NAME:-$SONAR_PROJECT_KEY}" \
  -Dsonar.sources="${SONAR_SOURCES:-.}" \
  -Dsonar.host.url="$SONAR_HOST_URL" \
  ${SONAR_EXTRA_ARGS:-}
log "Analysis submitted to $SONAR_HOST_URL (project key: $SONAR_PROJECT_KEY)"
