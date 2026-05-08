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
  # Backstage is built locally (idp-backstage:latest) — no pre-pull needed
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
step "Step 3a — Build custom Backstage image (idp-backstage:latest)"
# ────────────────────────────────────────────────────────────────────────────
# The custom image bakes in the notifications plugin so the frontend DI
# container has an implementation for notificationsApiRef at startup.
# Docker Desktop shares the host daemon, so the image is available to
# Kubernetes immediately without a registry push (pullPolicy: Never).

if [[ "$SKIP_BUILD" == "true" ]]; then
  warn "SKIP_BUILD=true — skipping Backstage image build"
  if docker image inspect idp-backstage:latest >/dev/null 2>&1; then
    ok "idp-backstage:latest already present"
  else
    fail "idp-backstage:latest missing — re-run without SKIP_BUILD."
    exit 1
  fi
else
  bash "$REPO_ROOT/scripts/build-backstage.sh"
fi

# ────────────────────────────────────────────────────────────────────────────
step "Step 3b — Build service images (svc-alpha, svc-beta)"
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

# Phase 1 — every kubernetes_* resource, serialized.
#
# The hashicorp/kubernetes provider on Windows / Docker Desktop crashes its
# plugin process with a Go runtime fault ("traceback did not unwind
# completely" in copystack/morestack) any time it handles more than one
# concurrent ApplyResourceChange RPC. Symptoms in Terraform's output: "Plugin
# did not respond" / "(*GRPCProvider).ApplyResourceChange call". Reproduced
# on provider 2.30.0 and 2.38.0 — not a version regression, a longstanding
# Go runtime + Windows interaction (often AV/EDR-aggravated).
#
# Affects ALL kubernetes_* resources, not just namespaces — e.g.
# kubernetes_service_account, kubernetes_cluster_role, kubernetes_config_map,
# kubernetes_secret. Helm and gavinbunney/kubectl providers are separate
# binaries and don't have the bug, so we keep their parallelism intact.
#
# Workaround: Phase 1 creates every kubernetes_* resource with -parallelism=1.
# Phase 2 runs everything else at default parallelism (10).
#
# If you add a new kubernetes_* resource to any module, append its address to
# K8S_TARGETS below. Regenerate the list with:
#   grep -rln 'resource "kubernetes_' modules/ | while read f; do
#     mod=$(echo "$f" | sed -E 's|modules/([^/]+)/.*|\1|')
#     grep -E '^resource "kubernetes_' "$f" \
#       | sed -E "s|^resource \"([^\"]+)\" \"([^\"]+)\".*|module.${mod}.\1.\2|"
#   done | sort -u
TF_VARS=(
  -var="project_root=$REPO_ROOT"
  -var="kyverno_enforcement_mode=$KYVERNO_MODE"
  -var="http_port=${HTTP_PORT}"
  -var="https_port=${HTTPS_PORT}"
)

K8S_TARGETS=(
  # Namespaces
  -target='module.platform.kubernetes_namespace.ingress_nginx'
  -target='module.platform.kubernetes_namespace.kyverno'
  -target='module.platform.kubernetes_namespace.crossplane_system'
  -target='module.gitops.kubernetes_namespace.argocd'
  -target='module.gitops.kubernetes_namespace.argo_rollouts'
  -target='module.gitops.kubernetes_namespace.svc_alpha'
  -target='module.gitops.kubernetes_namespace.svc_beta'
  -target='module.observability.kubernetes_namespace.monitoring'
  -target='module.backstage.kubernetes_namespace.backstage'
  # Backstage RBAC + config (all hit the same crash if run in parallel)
  -target='module.backstage.kubernetes_service_account.backstage'
  -target='module.backstage.kubernetes_cluster_role.backstage_reader'
  -target='module.backstage.kubernetes_cluster_role_binding.backstage_reader'
  -target='module.backstage.kubernetes_config_map.backstage_app_config'
  -target='module.backstage.kubernetes_config_map.backstage_catalog'
  -target='module.backstage.kubernetes_config_map.backstage_scaffolder'
  -target='module.backstage.kubernetes_secret.backstage_argocd'
  -target='module.backstage.kubernetes_secret.backstage_k8s_token'
)

# Reconcile orphan resources — when the provider plugin crashes mid-create,
# the resource lands in the cluster but never makes it into terraform state.
# The next apply then tries to create it again and fails with
# "<kind> 'X' already exists". This loop walks each kubernetes_* target,
# checks whether it exists on the cluster but is missing from state, and
# imports it if so. Safe to run on a clean install (every check fails fast).
#
# Format: "<terraform-address>|<cluster-id>". For namespaced resources the
# cluster-id is "<namespace>/<name>"; for cluster-scoped it's just "<name>".
K8S_IMPORTS=(
  "module.platform.kubernetes_namespace.ingress_nginx|ingress-nginx"
  "module.platform.kubernetes_namespace.kyverno|kyverno"
  "module.platform.kubernetes_namespace.crossplane_system|crossplane-system"
  "module.gitops.kubernetes_namespace.argocd|argocd"
  "module.gitops.kubernetes_namespace.argo_rollouts|argo-rollouts"
  "module.gitops.kubernetes_namespace.svc_alpha|svc-alpha"
  "module.gitops.kubernetes_namespace.svc_beta|svc-beta"
  "module.observability.kubernetes_namespace.monitoring|monitoring"
  "module.backstage.kubernetes_namespace.backstage|backstage"
  "module.backstage.kubernetes_service_account.backstage|backstage/backstage"
  "module.backstage.kubernetes_cluster_role.backstage_reader|backstage-reader"
  "module.backstage.kubernetes_cluster_role_binding.backstage_reader|backstage-reader"
  "module.backstage.kubernetes_config_map.backstage_app_config|backstage/backstage-app-config"
  "module.backstage.kubernetes_config_map.backstage_catalog|backstage/backstage-catalog"
  "module.backstage.kubernetes_config_map.backstage_scaffolder|backstage/backstage-scaffolder"
  "module.backstage.kubernetes_secret.backstage_argocd|backstage/backstage-argocd"
  "module.backstage.kubernetes_secret.backstage_k8s_token|backstage/backstage-k8s-token"
)

reconcile_orphans() {
  log "Reconciling orphan resources (cluster-but-not-in-state)..."
  local state_list
  state_list=$(terraform state list 2>/dev/null || echo "")
  local imported=0
  local checked=0
  for entry in "${K8S_IMPORTS[@]}"; do
    local addr="${entry%%|*}"
    local cid="${entry##*|}"
    checked=$((checked + 1))
    # Already in state — skip.
    if grep -Fxq "$addr" <<<"$state_list"; then
      continue
    fi
    # Determine whether the resource exists on the cluster. Resource kind is
    # parsed from the terraform address (kubernetes_<kind>).
    local kind
    kind=$(sed -E 's|.*\.kubernetes_([^.]+)\..*|\1|' <<<"$addr")
    local exists=false
    case "$kind" in
      namespace)
        kubectl get ns "$cid" >/dev/null 2>&1 && exists=true ;;
      service_account|config_map|secret)
        local ns="${cid%%/*}" name="${cid##*/}"
        # config_map → configmap, service_account → serviceaccount
        local k="${kind//_/}"
        kubectl get "$k" "$name" -n "$ns" >/dev/null 2>&1 && exists=true ;;
      cluster_role)
        kubectl get clusterrole "$cid" >/dev/null 2>&1 && exists=true ;;
      cluster_role_binding)
        kubectl get clusterrolebinding "$cid" >/dev/null 2>&1 && exists=true ;;
    esac
    if $exists; then
      if terraform import -input=false "${TF_VARS[@]}" "$addr" "$cid" >/dev/null 2>&1; then
        ok "Imported orphan: $addr ($cid)"
        imported=$((imported + 1))
      else
        warn "Found orphan $cid on cluster but import failed for $addr"
      fi
    fi
  done
  if (( imported == 0 )); then
    ok "No orphan kubernetes resources detected (${checked} checked)"
  else
    ok "Reconciled ${imported} orphan resource(s)"
  fi
}

reconcile_orphans

# Retry wrapper — the kubernetes provider plugin can crash mid-apply due to
# Go runtime GC stack-corruption faults caused by Windows AV/EDR injecting
# hooks into the provider process ("invalid pointer found on stack" /
# "traceback did not unwind completely"). Each crash still saves
# already-created resources to state, so re-running continues from where it
# stopped. Cap at 5 attempts so a genuine config error surfaces instead of
# spinning forever.
#
# To eliminate the crash entirely, exclude the provider binary from your AV:
#   Add-MpPreference -ExclusionPath "$HOME\IDP_example\idp-local\terraform\.terraform\providers\registry.terraform.io\hashicorp\kubernetes"
#   Add-MpPreference -ExclusionProcess "terraform-provider-kubernetes_v2.30.0_x5.exe"
apply_with_retry() {
  local label="$1"; shift
  local max_attempts=5
  local attempt=1
  while (( attempt <= max_attempts )); do
    log "${label} (attempt ${attempt}/${max_attempts})..."
    if terraform apply -auto-approve -input=false "$@"; then
      return 0
    fi
    warn "${label} attempt ${attempt} failed (likely kubernetes provider plugin crash)."
    if (( attempt < max_attempts )); then
      warn "  Already-created resources are saved in state. Retrying..."
      sleep 2
    fi
    attempt=$((attempt + 1))
  done
  fail "${label} failed after ${max_attempts} attempts. Inspect output above."
  fail "  This is almost always Windows AV/EDR corrupting the provider's Go runtime."
  fail "  Fix: add Defender exclusions for the provider binary (see comment above)."
  return 1
}

apply_with_retry "Phase 1/2: creating 17 kubernetes_* resources serially" \
  -parallelism=1 "${TF_VARS[@]}" "${K8S_TARGETS[@]}"
ok "Kubernetes resources created"

apply_with_retry "Phase 2/2: applying remaining resources (helm, kubectl_manifest, ...)" \
  "${TF_VARS[@]}"
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
