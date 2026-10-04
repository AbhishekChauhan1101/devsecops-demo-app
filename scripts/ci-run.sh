#!/usr/bin/env bash
# Usage: ci-run.sh <restore|build|test>
# Ecosystem-aware build steps. A custom command (INSTALL_COMMAND / BUILD_COMMAND / TEST_COMMAND)
# always wins over the built-in behaviour.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

phase="${1:-}"
type="$(app_type)"
config="${DOTNET_CONFIGURATION:-Release}"

case "$phase" in
  restore) custom="${INSTALL_COMMAND:-}" ;;
  build)   custom="${BUILD_COMMAND:-}" ;;
  test)    custom="${TEST_COMMAND:-}" ;;
  *) die "Usage: ci-run.sh <restore|build|test>" 2 ;;
esac

section "$phase ($type)"

if [ -n "$custom" ]; then
  log "Running custom command: $custom"
  bash -c "$custom"
  exit 0
fi

dotnet_target() {
  if [ -n "${DOTNET_SOLUTION:-}" ]; then printf '%s' "$DOTNET_SOLUTION"; return 0; fi
  if [ -n "${DOTNET_PROJECT:-}" ];  then printf '%s' "$DOTNET_PROJECT";  return 0; fi
  local slns
  mapfile -t slns < <(find . -maxdepth 3 -name '*.sln' -not -path './node_modules/*' | sort)
  case "${#slns[@]}" in
    1) printf '%s' "${slns[0]}" ;;
    0) die "No .sln/.csproj found. Set DOTNET_SOLUTION or DOTNET_PROJECT." 2 ;;
    *) die "Several solutions found (${slns[*]}). Set DOTNET_SOLUTION." 2 ;;
  esac
}

dotnet_has_tests() {
  if [ -n "${DOTNET_TEST_PROJECT:-}" ]; then return 0; fi
  [ -n "$(grep -rIl --include='*.csproj' --include='*.fsproj' --include='*.vbproj' 'Microsoft.NET.Test.Sdk' . 2>/dev/null | head -n 1)" ]
}

py_activate() {
  if [ -f .venv/bin/activate ]; then
    # shellcheck disable=SC1091
    . .venv/bin/activate
  fi
}

case "$type:$phase" in
  dotnet:restore)
    require_cmd dotnet "Install the .NET SDK on this agent."
    target="$(dotnet_target)" || exit $?
    dotnet restore "$target" --nologo
    ;;
  dotnet:build)
    require_cmd dotnet "Install the .NET SDK on this agent."
    target="$(dotnet_target)" || exit $?
    dotnet build "$target" --configuration "$config" --no-restore --nologo
    ;;
  dotnet:test)
    require_cmd dotnet "Install the .NET SDK on this agent."
    if ! dotnet_has_tests; then
      log "No test project found (no reference to Microsoft.NET.Test.Sdk) - skipping tests. This is not a failure."
      exit 0
    fi
    target="${DOTNET_TEST_PROJECT:-$(dotnet_target)}"
    results="$(reports_dir tests)"
    dotnet test "$target" --configuration "$config" --no-build --no-restore --nologo \
      --logger "trx" --results-directory "$results"
    ;;

  node:restore)
    require_cmd npm "Install Node.js / npm on this agent."
    if [ -f package-lock.json ]; then
      npm ci
    else
      warn "package-lock.json not found - 'npm ci' needs a lock file. Falling back to 'npm install' (not reproducible)."
      npm install
    fi
    ;;
  node:build)
    require_cmd npm "Install Node.js / npm on this agent."
    npm run build --if-present
    ;;
  node:test)
    require_cmd npm "Install Node.js / npm on this agent."
    if ! grep -q '"test"[[:space:]]*:' package.json || grep -q 'no test specified' package.json; then
      log "package.json has no real 'test' script - skipping tests. This is not a failure."
      exit 0
    fi
    npm test
    ;;

  python:restore)
    require_cmd python3 "Install Python 3 on this agent."
    python3 -m venv .venv
    py_activate
    python -m pip install --upgrade pip
    if [ -f requirements.txt ]; then
      python -m pip install -r requirements.txt
    elif [ -f pyproject.toml ] || [ -f setup.py ]; then
      python -m pip install .
    else
      die "No requirements.txt / pyproject.toml / setup.py found." 2
    fi
    ;;
  python:build)
    log "No built-in build step for Python. Set BUILD_COMMAND if you need one."
    ;;
  python:test)
    py_activate
    has_tests="$(find . -maxdepth 4 -path ./.venv -prune -o \( -name 'test_*.py' -o -name '*_test.py' \) -print -quit)"
    if [ -z "$has_tests" ]; then
      log "No Python test files found - skipping tests. This is not a failure."
      exit 0
    fi
    python -m pytest --junitxml="$(reports_dir tests)/pytest.xml" \
      || die "Python tests failed (is pytest listed in requirements.txt?)." 1
    ;;

  docker:*|generic:*)
    log "No built-in '$phase' step for application type '$type'. Set INSTALL_COMMAND / BUILD_COMMAND / TEST_COMMAND to add one."
    ;;
  *)
    die "Unsupported combination: type='$type' phase='$phase'." 2
    ;;
esac
