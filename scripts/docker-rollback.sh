#!/usr/bin/env bash
# Restores the previous version of the application container. Safe to run at any time:
#   * <name>-previous exists            -> a deployment swapped the containers: remove the new one, restore the old one
#   * no <name>-previous, previous.env  -> recreate from the saved previous image, but ONLY if the running container is
#                                          the new version (otherwise the running one already IS the previous version)
#   * nothing recorded                  -> fail clearly (first deployment: there is nothing to restore)
# Usage: docker-rollback.sh [manual|auto]
#   auto   = called by the pipeline after a failed deployment: "nothing to roll back" is reported but not an error
#   manual = requested by a person (ACTION=rollback): nothing to roll back to is an error
# The health check after the rollback is run by the pipeline.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/docker-lib.sh
. "$SCRIPT_DIR/lib/docker-lib.sh"

MODE="${1:-manual}"
require_cmd docker "Install Docker Engine on this agent."
CONTAINER_NAME="$(container_name)"
[ -n "$CONTAINER_NAME" ] || die "DOCKER_CONTAINER (or APP_NAME) is not set." 2
PREVIOUS_NAME="${CONTAINER_NAME}-previous"
STATE_DIR="${DEPLOY_STATE_DIR:-$HOME/.devsecops-deploy}/${APP_NAME:-$CONTAINER_NAME}/${DEPLOY_ENV:-default}"
container_exists() { docker container inspect "$1" >/dev/null 2>&1; }
current_image() { docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true; }

remove_current() {
  if container_exists "$CONTAINER_NAME"; then
    warn "Last 50 log lines of ${CONTAINER_NAME} (for diagnosis):"
    docker logs --tail 50 "$CONTAINER_NAME" 2>&1 || true
    log "Stopping and removing ${CONTAINER_NAME}"
    docker stop --time 20 "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm -f "$CONTAINER_NAME" >/dev/null
  fi
}

section "Docker ROLLBACK: ${CONTAINER_NAME}"

if container_exists "$PREVIOUS_NAME"; then
  remove_current
  log "Restoring previous container ${PREVIOUS_NAME} -> ${CONTAINER_NAME}"
  docker rename "$PREVIOUS_NAME" "$CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null
elif [ -f "$STATE_DIR/previous.env" ]; then
  PREV_IMAGE=""; NEW_IMAGE=""
  # shellcheck disable=SC1091
  . "$STATE_DIR/previous.env"
  [ -n "$PREV_IMAGE" ] || die "previous.env does not contain PREV_IMAGE - cannot roll back." 1
  running_image="$(current_image)"
  if [ -n "$running_image" ] && [ "$running_image" != "$NEW_IMAGE" ]; then
    log "The running container uses ${running_image}, which is not the new version (${NEW_IMAGE}) - the deployment never replaced it. Nothing to roll back."
    docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
  else
    log "Previous container not found - recreating it from image ${PREV_IMAGE}"
    if ! docker image inspect "$PREV_IMAGE" >/dev/null 2>&1; then
      if [ "${REGISTRY_TYPE:-none}" != "none" ]; then
        IMAGE_REPO="${PREV_IMAGE%:*}"
        trap registry_logout EXIT
        registry_login
        docker pull "$PREV_IMAGE" || die "Previous image ${PREV_IMAGE} is neither on this agent nor pullable." 1
      else
        die "Previous image ${PREV_IMAGE} is not available on this agent." 1
      fi
    fi
    remove_current
    run_app_container "$PREV_IMAGE" || die "Could not start the previous image ${PREV_IMAGE}." 1
    echo "CURRENT_IMAGE=${PREV_IMAGE}" > "$STATE_DIR/current.env"
  fi
else
  if [ "$MODE" = "auto" ]; then
    warn "No previous version is recorded for ${CONTAINER_NAME}: the deployment failed before the running container was replaced, or this was the first deployment. Nothing to restore."
    exit 0
  fi
  die "No previous version is recorded for ${CONTAINER_NAME} (first deployment?). Nothing to roll back to." 1
fi

state="$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)"
[ "$state" = "true" ] || die "The restored container is not running." 1
log "Active version: $(current_image)"
