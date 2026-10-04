#!/usr/bin/env bash
# Usage: docker-deploy.sh deploy|finalize
#   deploy   : saves the current version, stops the old container (kept as <name>-previous), starts the new one
#   finalize : call AFTER the health check passed - removes <name>-previous and prunes old images
# The health check and the rollback decision are made by the pipeline (so they are visible in the build log).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/docker-lib.sh
. "$SCRIPT_DIR/lib/docker-lib.sh"

action="${1:-deploy}"
require_cmd docker "Install Docker Engine on this agent and add the Jenkins user to the 'docker' group."
CONTAINER_NAME="$(container_name)"
[ -n "$CONTAINER_NAME" ] || die "DOCKER_CONTAINER (or APP_NAME) is not set." 2
require_env IMAGE_TAG
IMAGE_REPO="$(resolve_image_repo)" || exit $?
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
PREVIOUS_NAME="${CONTAINER_NAME}-previous"
STATE_DIR="${DEPLOY_STATE_DIR:-$HOME/.devsecops-deploy}/${APP_NAME:-$CONTAINER_NAME}/${DEPLOY_ENV:-default}"
mkdir -p "$STATE_DIR"

container_exists() { docker container inspect "$1" >/dev/null 2>&1; }

deploy() {
  section "Docker deploy: ${CONTAINER_NAME} <- ${IMAGE}"

  # Forget the state of the PREVIOUS deployment: rollback must only ever act on THIS one
  rm -f "$STATE_DIR/previous.env"

  if [ "${REGISTRY_TYPE:-none}" != "none" ]; then
    trap registry_logout EXIT
    registry_login
    log "Pulling ${IMAGE}"
    docker pull "$IMAGE" || die "Cannot pull ${IMAGE}. Was it pushed by the previous stage and does this agent have pull access?" 1
  else
    docker image inspect "$IMAGE" >/dev/null 2>&1 \
      || die "Image ${IMAGE} not found on this agent (REGISTRY_TYPE=none requires building on the deploy agent)." 1
  fi

  # 1. Save the current version (used by rollback)
  if container_exists "$CONTAINER_NAME"; then
    prev_image="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")"
    prev_id="$(docker inspect --format '{{.Image}}' "$CONTAINER_NAME")"
    {
      echo "PREV_IMAGE=${prev_image}"
      echo "PREV_IMAGE_ID=${prev_id}"
      echo "NEW_IMAGE=${IMAGE}"
      echo "SAVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$STATE_DIR/previous.env"
    log "Saved current version: ${prev_image}"

    # 2. Keep the old container (stopped + renamed) until the new one is healthy
    if container_exists "$PREVIOUS_NAME"; then
      log "Removing stale container ${PREVIOUS_NAME}"
      docker rm -f "$PREVIOUS_NAME" >/dev/null
    fi
    log "Stopping current container ${CONTAINER_NAME}"
    docker stop --time 30 "$CONTAINER_NAME" >/dev/null
    docker rename "$CONTAINER_NAME" "$PREVIOUS_NAME"
  else
    log "No existing container '${CONTAINER_NAME}' - this is a first deployment (rollback will not be possible)."
  fi

  # 3. Start the new version
  log "Starting ${CONTAINER_NAME} from ${IMAGE}"
  run_app_container "$IMAGE" || die "Docker could not start the new container (see the error above). The pipeline will attempt a rollback." 1
  echo "CURRENT_IMAGE=${IMAGE}" > "$STATE_DIR/current.env"
  docker ps --filter "name=^/${CONTAINER_NAME}\$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

prune_images() {
  local keep="${DOCKER_KEEP_IMAGES:-5}"
  if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -eq 0 ]; then return 0; fi
  local in_use prev="" ref count=0
  in_use="$(docker ps -a --format '{{.Image}}')"
  if [ -f "$STATE_DIR/previous.env" ]; then
    prev="$(. "$STATE_DIR/previous.env"; printf '%s' "${PREV_IMAGE:-}")"
  fi
  while read -r ref; do
    [ -n "$ref" ] || continue
    count=$((count + 1))
    if [ "$count" -le "$keep" ]; then continue; fi
    if printf '%s\n' "$in_use" | grep -qxF "$ref" || [ "$ref" = "$prev" ]; then continue; fi
    log "Removing old image ${ref}"
    docker rmi "$ref" >/dev/null 2>&1 || warn "Could not remove ${ref} (still in use?)"
  done < <(docker images "$IMAGE_REPO" --format '{{.Repository}}:{{.Tag}}' | grep -v ':<none>$' || true)
}

finalize() {
  section "Finalizing deployment"
  if is_true "${DOCKER_KEEP_PREVIOUS_CONTAINER:-false}"; then
    log "Keeping ${PREVIOUS_NAME} (DOCKER_KEEP_PREVIOUS_CONTAINER=true)"
  elif container_exists "$PREVIOUS_NAME"; then
    log "Removing ${PREVIOUS_NAME}"
    docker rm "$PREVIOUS_NAME" >/dev/null
  fi
  prune_images
  log "Deployment of ${IMAGE} finalized."
}

case "$action" in
  deploy)   deploy ;;
  finalize) finalize ;;
  *) die "Usage: docker-deploy.sh deploy|finalize" 2 ;;
esac
