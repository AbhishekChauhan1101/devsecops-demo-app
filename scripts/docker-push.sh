#!/usr/bin/env bash
# Logs in to the registry (ECR or generic) and pushes <image-repo>:<IMAGE_TAG>.
# Credentials are injected by Jenkins (AWS credentials binding / IAM role / registry credential).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/docker-lib.sh
. "$SCRIPT_DIR/lib/docker-lib.sh"

require_cmd docker "Install Docker Engine on this agent."
require_env IMAGE_TAG
if [ "${REGISTRY_TYPE:-none}" = "none" ]; then
  log "REGISTRY_TYPE=none - nothing to push (image stays on this agent)."
  exit 0
fi

IMAGE_REPO="$(resolve_image_repo)" || exit $?
image="${IMAGE_REPO}:${IMAGE_TAG}"
trap registry_logout EXIT

section "Registry push: $image"
registry_login

if [ "${REGISTRY_TYPE}" = "ecr" ] && is_true "${ECR_CREATE_REPO:-false}"; then
  repo="${IMAGE_REPO#*/}"
  if ! aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$repo" >/dev/null 2>&1; then
    log "Creating ECR repository '$repo' (scan on push, immutable tags)"
    aws ecr create-repository --region "$AWS_REGION" --repository-name "$repo" \
      --image-scanning-configuration scanOnPush=true --image-tag-mutability IMMUTABLE >/dev/null
  fi
fi

docker push "$image"
if is_true "${DOCKER_PUSH_LATEST:-false}"; then
  warn "DOCKER_PUSH_LATEST=true: pushing a mutable 'latest' tag as well (fails on ECR repositories with immutable tags)."
  docker tag "$image" "${IMAGE_REPO}:latest"
  docker push "${IMAGE_REPO}:latest"
fi
log "Pushed $image"
