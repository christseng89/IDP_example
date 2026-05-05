#!/bin/bash
# Build svc-alpha and svc-beta images for both v1 and v2.
# Docker Desktop shares the host daemon — no push or local registry needed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Building svc-alpha:v1"
docker build -t svc-alpha:v1 \
  --build-arg VERSION=v1 \
  "$REPO_ROOT/services/svc-alpha"

echo "==> Building svc-alpha:v2"
docker build -t svc-alpha:v2 \
  --build-arg VERSION=v2 \
  "$REPO_ROOT/services/svc-alpha"

echo "==> Building svc-beta:v1"
docker build -t svc-beta:v1 \
  --build-arg VERSION=v1 \
  "$REPO_ROOT/services/svc-beta"

echo "==> Building svc-beta:v2"
docker build -t svc-beta:v2 \
  --build-arg VERSION=v2 \
  "$REPO_ROOT/services/svc-beta"

echo ""
echo "Images built:"
docker images | grep -E "^(svc-alpha|svc-beta)"
