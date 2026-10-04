#!/usr/bin/env bash
# Prints the application type (dotnet | node | python | docker | generic) on STDOUT.
# All log output goes to STDERR so the result can be captured by Jenkins.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

configured="${APP_TYPE:-auto}"
case "$configured" in
  dotnet|node|python|docker|generic)
    log "Application type taken from configuration: $configured" >&2
    printf '%s\n' "$configured"
    exit 0
    ;;
  auto|"") : ;;
  *) die "Unknown APP_TYPE '$configured' (allowed: auto, dotnet, node, python, docker, generic)." 2 ;;
esac

found() { [ -n "$(find . -maxdepth 4 \( -path ./node_modules -o -path ./.git \) -prune -o "$@" -print -quit)" ]; }

detected="generic"
if found \( -name '*.sln' -o -name '*.csproj' \); then
  detected="dotnet"
elif [ -f package.json ]; then
  detected="node"
elif [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -f setup.py ]; then
  detected="python"
elif [ -f "${DOCKERFILE_PATH:-Dockerfile}" ]; then
  detected="docker"
fi
log "Application type detected automatically: $detected" >&2
printf '%s\n' "$detected"
