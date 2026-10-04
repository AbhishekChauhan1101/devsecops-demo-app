#!/usr/bin/env bash
# Builds and tags the application image:  <image-repo>:<IMAGE_TAG>
# IMAGE_TAG should be immutable (BUILD_NUMBER-GITSHA); the Jenkinsfile sets it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/docker-lib.sh
. "$SCRIPT_DIR/lib/docker-lib.sh"

require_cmd docker "Install Docker Engine on this agent and add the Jenkins user to the 'docker' group."
require_env IMAGE_TAG
dockerfile="${DOCKERFILE_PATH:-Dockerfile}"
context="${DOCKER_CONTEXT:-.}"
[ -f "$dockerfile" ] || die "Dockerfile not found: $dockerfile (DOCKERFILE_PATH)." 2

IMAGE_REPO="$(resolve_image_repo)" || exit $?
image="${IMAGE_REPO}:${IMAGE_TAG}"

section "Docker build: $image"
export DOCKER_BUILDKIT=1
# shellcheck disable=SC2206   # DOCKER_BUILD_ARGS is an intentionally word-split list of flags
build_args=(${DOCKER_BUILD_ARGS:-})
docker build --pull \
  --file "$dockerfile" \
  --tag "$image" \
  --label "org.opencontainers.image.revision=${GIT_COMMIT_FULL:-unknown}" \
  --label "org.opencontainers.image.version=${IMAGE_TAG}" \
  --label "ci.build.number=${BUILD_NUMBER:-0}" \
  "${build_args[@]}" \
  "$context"
log "Image built: $image"
refs="$(reports_dir docker)"
printf '%s\n' "$image" > "$refs/image-ref.txt"          # read by the Jenkinsfile (image scan / deploy)
printf '%s\n' "$IMAGE_REPO" > "$refs/image-repo.txt"
docker image ls "$IMAGE_REPO" --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'
