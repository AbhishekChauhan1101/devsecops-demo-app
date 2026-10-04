#!/usr/bin/env bash
# SonarQube analysis for .NET using the SonarScanner for .NET:
#   dotnet sonarscanner begin  ->  dotnet build (+ test)  ->  dotnet sonarscanner end
# Run it inside Jenkins' withSonarQubeEnv(...) so SONAR_HOST_URL / SONAR_AUTH_TOKEN are injected.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_cmd dotnet "Install the .NET SDK on this agent."
require_cmd java "SonarScanner for .NET needs a Java runtime (17+) on this agent."
require_env SONAR_HOST_URL SONAR_AUTH_TOKEN SONAR_PROJECT_KEY

export PATH="$PATH:$HOME/.dotnet/tools"
if ! dotnet tool list --global 2>/dev/null | grep -qi 'dotnet-sonarscanner'; then
  if is_true "${SONAR_DOTNET_AUTO_INSTALL:-false}"; then
    log "Installing dotnet-sonarscanner (SONAR_DOTNET_AUTO_INSTALL=true)"
    dotnet tool install --global dotnet-sonarscanner
  else
    die "dotnet-sonarscanner is not installed on this agent. Install it once with:  dotnet tool install --global dotnet-sonarscanner  (or set SONAR_DOTNET_AUTO_INSTALL=true). See docs/sonarqube-setup.md" 10
  fi
fi

auth_prop="${SONAR_AUTH_PROPERTY:-sonar.token}"      # use sonar.login for SonarQube < 10
config="${DOTNET_CONFIGURATION:-Release}"

if [ -n "${DOTNET_SOLUTION:-}" ]; then target="$DOTNET_SOLUTION"
elif [ -n "${DOTNET_PROJECT:-}" ]; then target="$DOTNET_PROJECT"
else
  mapfile -t slns < <(find . -maxdepth 3 -name '*.sln' | sort)
  [ "${#slns[@]}" -eq 1 ] || die "Set DOTNET_SOLUTION or DOTNET_PROJECT (found ${#slns[@]} solutions)." 2
  target="${slns[0]}"
fi

section "SonarQube (.NET): begin"
# shellcheck disable=SC2086   # SONAR_EXTRA_ARGS is an intentionally word-split list of /d: options
dotnet sonarscanner begin \
  /k:"$SONAR_PROJECT_KEY" \
  /n:"${SONAR_PROJECT_NAME:-$SONAR_PROJECT_KEY}" \
  /d:sonar.host.url="$SONAR_HOST_URL" \
  /d:"${auth_prop}=${SONAR_AUTH_TOKEN}" \
  ${SONAR_EXTRA_ARGS:-}

section "SonarQube (.NET): build"
dotnet build "$target" --configuration "$config" --no-restore --no-incremental --nologo

if is_true "${SONAR_RUN_TESTS:-false}"; then
  section "SonarQube (.NET): test"
  "$SCRIPT_DIR/ci-run.sh" test
fi

section "SonarQube (.NET): end (uploads the analysis)"
dotnet sonarscanner end /d:"${auth_prop}=${SONAR_AUTH_TOKEN}"
log "Analysis submitted to $SONAR_HOST_URL (project key: $SONAR_PROJECT_KEY)"
