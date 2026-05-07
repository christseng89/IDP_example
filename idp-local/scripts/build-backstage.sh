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

# Detect host arch — on ARM64 (Surface Pro 11 / Snapdragon X, Apple Silicon)
# we build under linux/amd64 emulation because Backstage's isolate-vm fails
# to compile on ARM64 Linux. binfmt_misc must know how to run amd64 binaries.
HOST_ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null || uname -m)"
case "$HOST_ARCH" in
  aarch64|arm64)
    warn "Detected ARM64 host (${HOST_ARCH}). Building image as linux/amd64 under emulation."
    if ! docker run --rm --platform=linux/amd64 alpine:3.19 uname -m 2>/dev/null | grep -q x86_64; then
      warn "amd64 emulation does not appear to be registered. Installing QEMU binfmt handlers..."
      docker run --privileged --rm tonistiigi/binfmt --install amd64 || {
        fail "Failed to register amd64 emulation. On Docker Desktop, enable 'Use Rosetta' or 'Use QEMU' in Settings > General."
        exit 1
      }
    fi
    ;;
esac

# Memory pre-flight — Backstage's webpack bundle + native compiles need ≥4 GB.
MEM_BYTES="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
MEM_GB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
if (( MEM_GB > 0 && MEM_GB < 4 )); then
  warn "Docker only has ${MEM_GB} GB RAM allocated; yarn install / webpack may OOM."
  warn "Bump it in Docker Desktop > Settings > Resources > Memory to at least 6 GB."
fi

docker build \
  --progress=plain \
  -t "$IMAGE" \
  "$SRC_DIR"

ok "Image built: $IMAGE"
echo ""
docker images "$IMAGE"
