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
GHCR_MIRROR="${GHCR_MIRROR:-ghcr.m.daocloud.io}"
KYVERNO_MODE="${KYVERNO_MODE:-Enforce}"
SKIP_BUILD="${SKIP_BUILD:-false}"
# Override to 8080/8443 when Windows HTTP.SYS or Docker Desktop holds port 80:
#   HTTP_PORT=8080 bash scripts/install.sh
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"

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
step "Step 1b — Host port availability (HTTP_PORT=${HTTP_PORT})"
# ────────────────────────────────────────────────────────────────────────────
# On Windows 11, HTTP.SYS (PID 4 / System) or Docker Desktop's own Go proxy
# can hold port 80, causing ALL ingress routes to return a Go 404 instead of
# reaching nginx.  Detect early and guide the operator to the fix.
if command -v powershell.exe >/dev/null 2>&1; then
  # Helper: return the PID listening on a given port, or empty string if free.
  _port_pid() {
    powershell.exe -NoProfile -Command \
      "(Get-NetTCPConnection -LocalPort $1 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess" \
      2>/dev/null | tr -d '[:space:]\r'
  }
  _port_proc() {
    powershell.exe -NoProfile -Command \
      "(Get-Process -Id $1 -ErrorAction SilentlyContinue).Name" \
      2>/dev/null | tr -d '[:space:]\r'
  }

  port_pid=$(_port_pid "${HTTP_PORT}")
  if [[ -n "$port_pid" && "$port_pid" =~ ^[0-9]+$ && "$port_pid" != "0" ]]; then
    proc=$(_port_proc "$port_pid")
    fail "Port ${HTTP_PORT} is held by PID ${port_pid} (${proc:-unknown})."
    warn "  nginx-ingress LoadBalancer requires an unoccupied host port."

    # Scan candidate ports for a free one — skip the Kubernetes NodePort range
    # floor (30000+) to avoid confusion; try application-tier ports first.
    CANDIDATE_PORTS=(9080 9090 9443 38080 39080)
    FREE_PORT=""
    for p in "${CANDIDATE_PORTS[@]}"; do
      cand_pid=$(_port_pid "$p")
      if [[ -z "$cand_pid" || ! "$cand_pid" =~ ^[0-9]+$ || "$cand_pid" == "0" ]]; then
        FREE_PORT="$p"
        break
      fi
    done

    case "${proc:-}" in
      com.docker.backend|docker*)
        warn "  Docker Desktop's backend (com.docker.backend) binds ports 80 and 8080 for"
        warn "  its Dashboard and internal API — these cannot be stopped."
        warn "  To free port 80: open Docker Desktop → Settings → uncheck"
        warn "  'Enable Docker Dashboard web access' (if present), then restart Docker Desktop."
        ;;
      W3SVC|iisexpress*)
        warn "  IIS is holding port ${HTTP_PORT}. To release (run as Administrator):"
        warn "    Stop-Service W3SVC; Set-Service W3SVC -StartupType Disabled"
        warn "  Then restart Docker Desktop."
        ;;
      *)
        warn "  Stop PID ${port_pid} (${proc:-unknown}) and restart Docker Desktop."
        ;;
    esac

    if [[ -n "$FREE_PORT" ]]; then
      warn "  → Use this confirmed-free port instead:"
      warn "    HTTP_PORT=${FREE_PORT} bash scripts/install.sh"
    else
      warn "  → All scanned ports (${CANDIDATE_PORTS[*]}) are also occupied."
      warn "    Run: netstat -ano | findstr LISTEN  to find a free port, then:"
      warn "    HTTP_PORT=<free_port> bash scripts/install.sh"
    fi
    exit 1
  else
    ok "Port ${HTTP_PORT} available on Windows host"
  fi
fi

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

  # NOTE: bitnami/kubectl:1.28.5 (used by Kyverno cleanup CronJobs) left
  # Docker Hub in Oct 2023; registry.bitnami.com is often blocked on
  # mirrored networks.  The CronJobs are disabled in Terraform values
  # (cleanupJobs.*.enabled=false) so this image is no longer needed.
)

# GitHub Container Registry images — pulled via GHCR_MIRROR.
# These cannot go through the Docker Hub mirror path.
GHCR_IMAGES=(
  # Kyverno cleanup-controller Deployment (chart 3.1.4 / app v1.11.4)
  "kyverno/cleanup-controller:v1.11.4"
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

prepull_ghcr() {
  local img="$1"                            # e.g. kyverno/cleanup-controller:v1.11.4
  local canonical="ghcr.io/${img}"
  local mirrored="${GHCR_MIRROR}/${img}"

  echo "  ⇣ ${mirrored}"
  if docker pull --quiet "$mirrored" >/dev/null 2>&1; then
    docker tag "$mirrored" "$canonical" >/dev/null 2>&1 || true
    ok "${canonical} cached locally"
  else
    warn "Could not pull ${mirrored} — kubelet may fail this image."
    warn "  Override mirror: export GHCR_MIRROR=<host> and re-run."
  fi
}

for img in "${HUB_IMAGES[@]}"; do
  prepull "$img"
done

for img in "${GHCR_IMAGES[@]}"; do
  prepull_ghcr "$img"
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
  if err=$(helm repo add "$name" "${HELM_REPOS[$name]}" --force-update 2>&1 1>/dev/null); then
    ok "repo $name registered"
  else
    idx="${HELM_REPO_CACHE}/${name}-index.yaml"
    if [[ -f "$idx" ]]; then
      warn "repo $name add failed (cached index exists — Terraform may still succeed)"
      warn "  Error: $err"
    else
      warn "repo $name add failed (no cached index — Terraform helm_release for '$name' will likely fail)"
      warn "  Error: $err"
      warn "  If $name is blocked, run: helm repo add $name ${HELM_REPOS[$name]} manually on a reachable network first."
    fi
  fi
done

log "Running helm repo update..."
if helm repo update; then
  ok "Helm repo cache refreshed"
else
  warn "helm repo update had errors — Terraform may still succeed if required repos are cached"
fi

# ────────────────────────────────────────────────────────────────────────────
step "Step 4b — Initialize local git repo for ArgoCD file:// access"
# ────────────────────────────────────────────────────────────────────────────
# ArgoCD repo-server mounts this idp-local/ directory at /idp-local in the pod
# and clones repoURL: file:///idp-local.  That requires a .git/ at the root of
# idp-local/ — NOT the outer IDP_example repo which owns the real .git.
# Creating a standalone nested git repo here is safe: the outer repo treats it
# as an embedded repository and ignores the inner .git/.
if [[ ! -d "$REPO_ROOT/.git" ]]; then
  log "Initializing standalone git repo in $REPO_ROOT for ArgoCD..."
  (cd "$REPO_ROOT" \
    && git init -q \
    && git add -A \
    && git -c user.email="install@idp-local" -c user.name="install" \
           commit -q --allow-empty -m "idp-local snapshot for ArgoCD")
  ok "Standalone git repo initialized"
else
  pending=$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${pending:-0}" -gt 0 ]]; then
    (cd "$REPO_ROOT" \
      && git add -A \
      && git -c user.email="install@idp-local" -c user.name="install" \
             commit -q --allow-empty -m "idp-local snapshot for ArgoCD")
    ok "Standalone git repo updated (${pending} changed files committed)"
  else
    ok "Standalone git repo up to date"
  fi
fi

# ────────────────────────────────────────────────────────────────────────────
step "Step 5 — Terraform apply (10–20 min on first run)"
# ────────────────────────────────────────────────────────────────────────────

cd "$REPO_ROOT/terraform"
terraform init -upgrade -input=false
terraform apply \
  -var="project_root=$REPO_ROOT" \
  -var="kyverno_enforcement_mode=$KYVERNO_MODE" \
  -var="http_port=${HTTP_PORT}" \
  -var="https_port=${HTTPS_PORT}" \
  -auto-approve \
  -input=false
cd "$REPO_ROOT"
ok "Terraform apply complete"

# ────────────────────────────────────────────────────────────────────────────
step "Step 6 — Wait for platform readiness"
# ────────────────────────────────────────────────────────────────────────────

# Terraform-managed namespaces — wait for standard Deployment readiness.
for ns in ingress-nginx kyverno crossplane-system monitoring argocd argo-rollouts backstage; do
  echo "  ⏳ ns/$ns"
  if kubectl wait --for=condition=available deployment --all -n "$ns" --timeout=300s 2>/dev/null; then
    ok "ns/$ns ready"
  else
    warn "ns/$ns not fully ready — inspect with: kubectl get pods -n $ns"
  fi
done

# ArgoCD-managed namespaces (svc-alpha, svc-beta) use Argo Rollouts, not
# standard Deployments — kubectl wait deployment returns immediately with no
# resources found.  Poll until ArgoCD syncs and pods appear, then wait Ready.
for ns in svc-alpha svc-beta; do
  echo "  ⏳ ns/$ns (ArgoCD sync + Rollout — up to 300s)"
  synced=false
  for _ in $(seq 1 30); do
    pod_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${pod_count:-0}" -gt 0 ]]; then
      if kubectl wait pod --all -n "$ns" --for=condition=Ready --timeout=120s 2>/dev/null; then
        ok "ns/$ns pods ready"
        synced=true
        break
      fi
    fi
    sleep 10
  done
  $synced || warn "ns/$ns not ready — check: kubectl get app $ns -n argocd && kubectl get pods -n $ns"
done

# ────────────────────────────────────────────────────────────────────────────
step "Step 7 — Endpoints"
# ────────────────────────────────────────────────────────────────────────────

ARGOCD_PWD="$(cd "$REPO_ROOT/terraform" && terraform output -raw argocd_admin_password 2>/dev/null \
              || echo '<run: terraform output -raw argocd_admin_password>')"

# Build the base URL — omit :80 so URLs look clean on standard installs.
if [[ "$HTTP_PORT" == "80" ]]; then
  BASE_URL="http://localhost"
else
  BASE_URL="http://localhost:${HTTP_PORT}"
fi

echo ""
echo -e "${BOLD}Platform endpoints${NC}"
echo "  Backstage Portal    ${BASE_URL}/backstage"
echo "  Argo CD             ${BASE_URL}/argocd            admin / $ARGOCD_PWD"
echo "  Argo Rollouts UI    ${BASE_URL}/rollouts"
echo "  Grafana             ${BASE_URL}/grafana           admin / idp-demo"
echo ""
echo "  svc-alpha v1        ${BASE_URL}/svc-alpha/v1/hello"
echo "  svc-alpha v2        ${BASE_URL}/svc-alpha/v2/hello"
echo "  svc-beta  v1        ${BASE_URL}/svc-beta/v1/hello"
echo "  svc-beta  v2        ${BASE_URL}/svc-beta/v2/hello"
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
