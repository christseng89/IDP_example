#!/usr/bin/env bash
# install.sh — Simple, predictable installation of the idp-local IDP platform.
#
# Strategy: pre-pull every Docker Hub image kubelet will need via a working
# mirror, retag to the original references, then run terraform. Kubelet finds
# the images locally and never tries to reach Docker Hub itself, so installs
# work even when registry-1.docker.io is blocked / DNS-hijacked.
#
# Usage:
#   bash scripts/install.sh
#
# Optional env vars:
#   DOCKER_MIRROR   docker.io mirror (default: docker.m.daocloud.io)
#   K8S_MIRROR      registry.k8s.io mirror (default: k8s.m.daocloud.io)
#   KYVERNO_MODE    Audit | Enforce  (default: Enforce)
#   SKIP_BUILD      true to skip building svc-alpha/svc-beta images

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_MIRROR="${DOCKER_MIRROR:-docker.m.daocloud.io}"
K8S_MIRROR="${K8S_MIRROR:-k8s.m.daocloud.io}"
KYVERNO_MODE="${KYVERNO_MODE:-Enforce}"
SKIP_BUILD="${SKIP_BUILD:-false}"

# ── Logging helpers ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}${BOLD}[IDP]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "  ${RED}✘${NC}  $*" >&2; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ────────────────────────────────────────────────────────────────────────────
step "Step 1 — Prerequisites"
# ────────────────────────────────────────────────────────────────────────────

for tool in docker kubectl helm terraform; do
  if command -v "$tool" >/dev/null; then
    ok "$tool found"
  else
    fail "$tool not found in PATH"
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  fail "Docker daemon not running. Start Docker Desktop and re-run."
  exit 1
fi
ok "Docker daemon reachable"

if ! kubectl cluster-info --context docker-desktop >/dev/null 2>&1; then
  fail "Docker Desktop Kubernetes not running. Enable in Settings → Kubernetes → Enable Kubernetes."
  exit 1
fi
ok "Docker Desktop Kubernetes reachable"

# ────────────────────────────────────────────────────────────────────────────
step "Step 2 — Pre-pull images via mirrors"
# ────────────────────────────────────────────────────────────────────────────
# registry.k8s.io images — pulled via K8S_MIRROR (default: k8s.m.daocloud.io).
# The nginx-ingress controller image is the #1 cause of "context deadline exceeded"
# on Docker Desktop when registry.k8s.io is slow or blocked.

K8S_IMAGES=(
  # ingress-nginx chart 4.9.1 → controller v1.9.6
  "ingress-nginx/controller:v1.9.6"
)

for img in "${K8S_IMAGES[@]}"; do
  mirrored="${K8S_MIRROR}/${img}"
  canonical="registry.k8s.io/${img}"
  echo "  ⇣ ${mirrored}"
  if docker pull --quiet "$mirrored" >/dev/null 2>&1; then
    docker tag "$mirrored" "$canonical" >/dev/null 2>&1 || true
    ok "${canonical} cached locally"
  else
    warn "Could not pull ${mirrored} — kubelet will try registry.k8s.io directly."
    warn "  Override mirror: export K8S_MIRROR=<host> and re-run."
  fi
done

# Docker Hub images — pulled via DOCKER_MIRROR and retagged to docker.io.
HUB_IMAGES=(
  # kube-prometheus-stack (Grafana subchart — already overridden in values too,
  # but pre-pulling makes the install robust if the override fails).
  "grafana/grafana:10.4.0"

  # ArgoCD — Redis subchart from Bitnami / docker.io
  "redis:7.2.4-alpine"

  # Backstage — community image used by the chart
  "backstage/backstage:latest"

  # Kyverno cleanup controller image (failing as of last run)
  "ghcr.io/kyverno/cleanup-controller:v1.11.4"
)

prepull() {
  local img="$1"
  local mirrored="${DOCKER_MIRROR}/${img}"

  echo "  ⇣ ${mirrored}"
  if docker pull --quiet "$mirrored" >/dev/null 2>&1; then
    docker tag "$mirrored" "docker.io/${img}" >/dev/null 2>&1 || true
    docker tag "$mirrored" "${img}"           >/dev/null 2>&1 || true
    ok "${img} cached locally"
  else
    warn "Could not pull ${mirrored} — kubelet may fail this image."
    warn "  Try a different mirror: export DOCKER_MIRROR=<host> and re-run."
  fi
}

for img in "${HUB_IMAGES[@]}"; do
  prepull "$img"
done

# ────────────────────────────────────────────────────────────────────────────
step "Step 3 — Build service images (svc-alpha, svc-beta)"
# ────────────────────────────────────────────────────────────────────────────

if [[ "$SKIP_BUILD" == "true" ]]; then
  warn "SKIP_BUILD=true — skipping image builds"
  for img in svc-alpha:v1 svc-alpha:v2 svc-beta:v1 svc-beta:v2; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      ok "$img already present"
    else
      fail "$img missing — re-run without SKIP_BUILD."
      exit 1
    fi
  done
else
  DOCKER_MIRROR="$DOCKER_MIRROR" bash "$REPO_ROOT/scripts/build-images.sh"
fi

# ────────────────────────────────────────────────────────────────────────────
step "Step 4 — Helm repo sync"
# ────────────────────────────────────────────────────────────────────────────
# The Terraform Helm provider validates ALL repos in ~/.config/helm/repositories.yaml
# before running any chart operation — even repos the current apply doesn't use.
# A stale or never-cached index (e.g. kubernetes-dashboard) causes every
# helm_release to fail with "no cached repo found".  Registering every repo
# used by this stack and running 'helm repo update' ensures all indexes exist.

# Remove any repos whose index cache is missing — the Helm provider fails ALL
# helm_release resources if even one registered repo lacks a cached index file.
# Use 'helm env' so the cache path is always correct regardless of OS/shell.
HELM_REPO_CACHE="$(helm env HELM_REPOSITORY_CACHE 2>/dev/null | tr '\\' '/')"

if [[ -n "$HELM_REPO_CACHE" ]]; then
  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue
    idx_file="${HELM_REPO_CACHE}/${repo_name}-index.yaml"
    if [[ ! -f "$idx_file" ]]; then
      warn "Removing stale repo '${repo_name}' — missing cache: ${idx_file}"
      helm repo remove "$repo_name" >/dev/null 2>&1 || true
    fi
  done < <(helm repo list -o json 2>/dev/null \
           | python3 -c "import sys,json; [print(r['name']) for r in json.load(sys.stdin)]" \
           2>/dev/null || true)
fi

declare -A HELM_REPOS=(
  [ingress-nginx]="https://kubernetes.github.io/ingress-nginx"
  [kyverno]="https://kyverno.github.io/kyverno"
  [crossplane-stable]="https://charts.crossplane.io/stable"
  [prometheus-community]="https://prometheus-community.github.io/helm-charts"
  [backstage]="https://backstage.github.io/charts"
  [argo]="https://argoproj.github.io/argo-helm"
)

for name in "${!HELM_REPOS[@]}"; do
  helm repo add "$name" "${HELM_REPOS[$name]}" --force-update >/dev/null 2>&1 \
    && ok "repo $name registered" \
    || warn "repo $name add failed (continuing)"
done

log "Running helm repo update..."
if helm repo update; then
  ok "Helm repo cache refreshed"
else
  warn "helm repo update had errors — Terraform may still succeed if required repos are cached"
fi

# ────────────────────────────────────────────────────────────────────────────
step "Step 5 — Terraform apply (10–20 min on first run)"
# ────────────────────────────────────────────────────────────────────────────

cd "$REPO_ROOT/terraform"
terraform init -upgrade -input=false
terraform apply \
  -var="project_root=$REPO_ROOT" \
  -var="kyverno_enforcement_mode=$KYVERNO_MODE" \
  -auto-approve \
  -input=false
cd "$REPO_ROOT"
ok "Terraform apply complete"

# ────────────────────────────────────────────────────────────────────────────
step "Step 6 — Wait for platform readiness"
# ────────────────────────────────────────────────────────────────────────────

for ns in ingress-nginx kyverno crossplane-system monitoring argocd argo-rollouts backstage svc-alpha svc-beta; do
  echo "  ⏳ ns/$ns"
  if kubectl wait --for=condition=available deployment --all -n "$ns" --timeout=300s 2>/dev/null; then
    ok "ns/$ns ready"
  else
    warn "ns/$ns not fully ready — inspect with: kubectl get pods -n $ns"
  fi
done

# ────────────────────────────────────────────────────────────────────────────
step "Step 7 — Endpoints"
# ────────────────────────────────────────────────────────────────────────────

ARGOCD_PWD="$(cd "$REPO_ROOT/terraform" && terraform output -raw argocd_admin_password 2>/dev/null \
              || echo '<run: terraform output -raw argocd_admin_password>')"

echo ""
echo -e "${BOLD}Platform endpoints${NC}"
echo "  Backstage Portal    http://localhost/backstage"
echo "  Argo CD             http://localhost/argocd            admin / $ARGOCD_PWD"
echo "  Argo Rollouts UI    http://localhost/rollouts"
echo "  Grafana             http://localhost/grafana           admin / idp-demo"
echo ""
echo "  svc-alpha v1        http://localhost/svc-alpha/v1/hello"
echo "  svc-alpha v2        http://localhost/svc-alpha/v2/hello"
echo "  svc-beta  v1        http://localhost/svc-beta/v1/hello"
echo "  svc-beta  v2        http://localhost/svc-beta/v2/hello"
echo ""
echo -e "${GREEN}${BOLD}Installation complete.${NC}"
echo ""
echo "If a URL returns 404 or hangs:"
echo "  kubectl get pods -A | grep -vE 'Running|Completed'"
echo "  kubectl get ingress -A"
echo ""
echo "Tear down everything:"
echo "  cd $REPO_ROOT/terraform && terraform destroy \\"
echo "    -var=\"project_root=$REPO_ROOT\" -auto-approve"
