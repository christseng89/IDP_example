#!/usr/bin/env bash
# build-backstage.sh — Build the custom Backstage Docker image locally.
#
# The image is built from backstage-src/ and tagged as idp-backstage:latest.
# Docker Desktop shares the host daemon with Kubernetes, so no registry push
# is needed — Kubernetes uses the local image directly (pullPolicy: Never).
#
# First build: 8-15 min (yarn install + TypeScript + webpack bundle).
# Subsequent builds with Docker layer cache: 3-5 min.
#
# Usage:  bash scripts/build-backstage.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/backstage-src"
IMAGE="idp-backstage:latest"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}   $*"; }
fail() { echo -e "  ${RED}✘${NC}  $*" >&2; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

step "Build custom Backstage image — ${IMAGE}"
echo ""
echo "  Source : $SRC_DIR"
echo "  Image  : $IMAGE"
echo ""
echo "  First build takes 8-15 min (yarn install + webpack). Subsequent"
echo "  builds are faster thanks to Docker layer cache."
echo ""

if [[ ! -d "$SRC_DIR" ]]; then
  fail "backstage-src/ not found at $SRC_DIR"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  fail "Docker daemon not running. Start Docker Desktop and re-run."
  exit 1
fi

docker build \
  --progress=plain \
  -t "$IMAGE" \
  "$SRC_DIR"

ok "Image built: $IMAGE"
echo ""
docker images "$IMAGE"
