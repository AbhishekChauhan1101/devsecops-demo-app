#!/usr/bin/env bash
# Docker / registry helpers. Source AFTER common.sh.
# shellcheck shell=bash

container_name() { printf '%s' "${DOCKER_CONTAINER:-${APP_NAME:-}}"; }

# Prints the full image repository (without tag), e.g. <acct>.dkr.ecr.<region>.amazonaws.com/<repo>
resolve_image_repo() {
  if [ -n "${IMAGE_REPO:-}" ]; then printf '%s' "$IMAGE_REPO"; return 0; fi
  local reg acct image="${DOCKER_IMAGE:-${APP_NAME:-}}"
  [ -n "$image" ] || die "DOCKER_IMAGE (or APP_NAME) is not set." 2
  case "${REGISTRY_TYPE:-none}" in
    ecr)
      [ -n "${AWS_REGION:-}" ] || die "AWS_REGION is required for REGISTRY_TYPE=ecr." 2
      reg="${ECR_REGISTRY:-}"
      if [ -z "$reg" ]; then
        command -v aws >/dev/null 2>&1 || die "AWS CLI v2 is required to resolve the ECR registry (or set ECR_REGISTRY)." 10
        acct="$(AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}" aws sts get-caller-identity --query Account --output text)" \
          || die "Cannot determine the AWS account. Check the AWS credentials binding / the agent's IAM role." 1
        reg="${acct}.dkr.ecr.${AWS_REGION}.amazonaws.com"
      fi
      printf '%s/%s' "$reg" "${ECR_REPOSITORY:-$image}"
      ;;
    generic)
      [ -n "${REGISTRY_URL:-}" ] || die "REGISTRY_URL is required for REGISTRY_TYPE=generic." 2
      printf '%s/%s' "${REGISTRY_URL%/}" "${REGISTRY_REPOSITORY:-$image}"
      ;;
    none|"")
      printf '%s' "$image"
      ;;
    *)
      die "Unknown REGISTRY_TYPE '${REGISTRY_TYPE}' (allowed: ecr, generic, none)." 2
      ;;
  esac
}

# registry_login  (needs IMAGE_REPO). Credentials come from Jenkins bindings, never from files.
registry_login() {
  case "${REGISTRY_TYPE:-none}" in
    ecr)
      require_cmd aws "Install AWS CLI v2 on this agent."
      local reg="${IMAGE_REPO%%/*}"
      log "Logging in to ECR registry ${reg}"
      aws ecr get-login-password --region "$AWS_REGION" \
        | docker login --username AWS --password-stdin "$reg" >/dev/null \
        || die "ECR login failed. Check AWS credentials / IAM permissions (ecr:GetAuthorizationToken)." 1
      ;;
    generic)
      if [ -z "${REGISTRY_USER:-}" ] || [ -z "${REGISTRY_PASSWORD:-}" ]; then
        die "Registry credentials missing. Set REGISTRY_CREDENTIALS_ID (Username/Password credential) in the Jenkinsfile." 2
      fi
      log "Logging in to registry ${REGISTRY_URL}"
      printf '%s' "$REGISTRY_PASSWORD" \
        | docker login "$REGISTRY_URL" --username "$REGISTRY_USER" --password-stdin >/dev/null \
        || die "Registry login failed." 1
      ;;
    *) : ;;
  esac
}

registry_logout() {   # best-effort cleanup only
  case "${REGISTRY_TYPE:-none}" in
    ecr)     docker logout "${IMAGE_REPO%%/*}" >/dev/null 2>&1 || true ;;
    generic) docker logout "${REGISTRY_URL}" >/dev/null 2>&1 || true ;;
    *) : ;;
  esac
}

# run_app_container <image>  - starts the application container with the configured options
run_app_container() {
  local image="$1" name
  name="$(container_name)"
  local args=(run -d --name "$name" --restart unless-stopped
              --label "app=${APP_NAME:-$name}"
              --label "deploy.environment=${DEPLOY_ENV:-unknown}"
              --label "deploy.build=${BUILD_NUMBER:-0}")
  if [ -n "${DOCKER_HOST_PORT:-}" ]; then
    [ -n "${DOCKER_CONTAINER_PORT:-}" ] || die "DOCKER_CONTAINER_PORT is required when DOCKER_HOST_PORT is set." 2
    args+=(-p "${DOCKER_HOST_PORT}:${DOCKER_CONTAINER_PORT}")
  fi
  if [ -n "${DOCKER_NETWORK:-}" ]; then args+=(--network "$DOCKER_NETWORK"); fi
  if [ -n "${DOCKER_ENV_FILE:-}" ]; then
    [ -f "$DOCKER_ENV_FILE" ] || die "DOCKER_ENV_FILE does not exist: $DOCKER_ENV_FILE" 2
    args+=(--env-file "$DOCKER_ENV_FILE")
  fi
  if ! is_true "${DOCKER_ALLOW_NEW_PRIVILEGES:-false}"; then args+=(--security-opt no-new-privileges:true); fi
  # shellcheck disable=SC2206   # DOCKER_EXTRA_RUN_ARGS is an intentionally word-split list of flags
  local extra=(${DOCKER_EXTRA_RUN_ARGS:-})
  docker "${args[@]}" "${extra[@]}" "$image"
}
