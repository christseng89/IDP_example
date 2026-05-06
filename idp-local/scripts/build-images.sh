#!/bin/bash
# Build svc-alpha and svc-beta images for both v1 and v2.
#
# When registry-1.docker.io is unreachable, resolve_base_image() probes a
# prioritised list of Docker Hub mirrors using `docker manifest inspect`
# (fast — fetches only the manifest JSON, no layer download) and passes the
# first reachable mirror URL directly as --build-arg BASE_IMAGE=<ref>.
# Passing the mirror URL as BASE_IMAGE is the correct BuildKit fix: BuildKit
# fetches the manifest from wherever BASE_IMAGE points, bypassing Docker Hub.
#
# Optional env var (bare hostname, no scheme):
#   DOCKER_MIRROR   Probed first before the built-in candidate list.
#                   Example: export DOCKER_MIRROR=docker.m.daocloud.io

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }

BASE_IMAGE="node:20-alpine"

# ── Resolve a reachable base-image reference ──────────────────────────────────
# Sets BASE_IMAGE to the first mirror that responds to `docker manifest inspect`.
# Uses timeout so unreachable hosts fail fast rather than waiting 20+ seconds.
resolve_base_image() {
  # Use curl for the Docker Hub check — fast (4 s connect, 6 s total), avoids
  # the process-wrapper issue that makes `timeout docker ...` unreliable on
  # Windows Git Bash.  If Docker Hub is reachable (or daemon mirrors route it),
  # leave BASE_IMAGE as the default and let docker build proceed normally.
  if curl -sf --connect-timeout 4 --max-time 6 \
       "https://registry-1.docker.io/v2/" >/dev/null 2>&1; then
    ok "Docker Hub reachable — using $BASE_IMAGE"
    return 0
  fi

  warn "Docker Hub unreachable — probing mirror candidates…"

  # Build candidate list: user-supplied DOCKER_MIRROR first, then well-known ones.
  # Mirrors differ on path layout; try /library/ (most common) before /docker.io/library/.
  local candidates=()
  if [[ -n "${DOCKER_MIRROR:-}" ]]; then
    local m="${DOCKER_MIRROR%/}"; m="${m#https://}"; m="${m#http://}"
    candidates+=("${m}/library/node:20-alpine" "${m}/docker.io/library/node:20-alpine")
  fi
  candidates+=(
    "docker.m.daocloud.io/library/node:20-alpine"
    "docker.m.daocloud.io/docker.io/library/node:20-alpine"
    "dockerhub.azk8s.cn/library/node:20-alpine"
    "registry.cn-hangzhou.aliyuncs.com/library/node:20-alpine"
  )

  # `docker manifest inspect` without `timeout`: sub-second on reachable hosts,
  # fast error on 403/EOF/TLS failures; only slow (~20 s) on pure TCP timeout.
  # DaoCloud is first, so a working mirror is found before any slow fallback.
  for ref in "${candidates[@]}"; do
    echo "  Trying: $ref"
    if docker manifest inspect "$ref" >/dev/null 2>&1; then
      BASE_IMAGE="$ref"
      ok "Using mirror: $BASE_IMAGE"
      return 0
    fi
  done

  warn "All mirror manifest checks failed. Build will try Docker Hub directly."
  warn "Set an accessible mirror: export DOCKER_MIRROR=<host>  (bare hostname, no https://)"
  return 1
}

resolve_base_image || true

# ── Build helper ──────────────────────────────────────────────────────────────
build_image() {
  local tag="$1" version="$2" context="$3"
  echo -e "${BOLD}==> Building ${tag}${NC}"
  docker build -t "$tag" \
    --build-arg VERSION="$version" \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    "$context"
}

build_image svc-alpha:v1 v1 "$REPO_ROOT/services/svc-alpha"
build_image svc-alpha:v2 v2 "$REPO_ROOT/services/svc-alpha"
build_image svc-beta:v1  v1 "$REPO_ROOT/services/svc-beta"
build_image svc-beta:v2  v2 "$REPO_ROOT/services/svc-beta"

echo ""
echo "Images built:"
docker images | grep -E "^(svc-alpha|svc-beta)"
