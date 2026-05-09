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
# quay.io hosts Argo CD, Argo Rollouts, Prometheus operator/server,
# Alertmanager, node-exporter — all of which kubelet pulls during install.
# A reachable quay.io mirror is the difference between a 5-minute install and
# a 5-minute helm timeout ("context deadline exceeded") on networks that
# block or throttle quay.io directly.
QUAY_MIRROR="${QUAY_MIRROR:-quay.m.daocloud.io}"
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

  # Backstage Postgres backing store (modules/backstage/main.tf).
  # Pre-pulling avoids a 1-2 minute first-install stall while kubelet
  # downloads from docker.io directly on networks where it is throttled.
  "postgres:16-alpine"

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
  # Backstage official image (chart 1.9.4 default appVersion). Pre-pulling
  # via GHCR_MIRROR keeps the helm install from blocking on a slow ghcr.io
  # download — same pattern as the quay.io / docker.io image pre-pulls.
  "backstage/backstage:1.27.0"
)

# quay.io images — pulled via QUAY_MIRROR and retagged to quay.io. Tags below
# are the defaults baked into the Helm chart versions pinned in this repo:
#   - argo-cd chart 6.7.3        → argocd v2.10.7
#   - argo-rollouts chart 2.37.0 → argo-rollouts / kubectl-argo-rollouts v1.7.0
#   - kube-prometheus-stack 57.2.0 → prometheus-operator v0.72.0,
#                                    prometheus v2.51.0, alertmanager v0.27.0,
#                                    config-reloader v0.72.0, node-exporter v1.7.0
# If a chart version is bumped, the matching tag here usually needs updating
# too — but a tag mismatch only degrades to "kubelet pulls from quay.io
# directly", it does not cause the install to fail.
QUAY_IMAGES=(
  "argoproj/argocd:v2.10.7"
  # argo-rollouts: pin to v1.7.2 (matches modules/gitops/main.tf). v1.7.2
  # ships dashboard --rootpath fixes that v1.7.0 lacked. Pre-pull v1.7.0 as
  # well in case state already has v1.7.0 from a prior install.
  "argoproj/argo-rollouts:v1.7.2"
  "argoproj/kubectl-argo-rollouts:v1.7.2"
  "argoproj/argo-rollouts:v1.7.0"
  "argoproj/kubectl-argo-rollouts:v1.7.0"
  "prometheus-operator/prometheus-operator:v0.72.0"
  "prometheus-operator/prometheus-config-reloader:v0.72.0"
  "prometheus/prometheus:v2.51.0"
  "prometheus/alertmanager:v0.27.0"
  "prometheus/node-exporter:v1.7.0"
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

prepull_quay() {
  local img="$1"                            # e.g. argoproj/argo-rollouts:v1.7.0
  local canonical="quay.io/${img}"
  local mirrored="${QUAY_MIRROR}/${img}"

  echo "  ⇣ ${mirrored}"
  if docker pull --quiet "$mirrored" >/dev/null 2>&1; then
    docker tag "$mirrored" "$canonical" >/dev/null 2>&1 || true
    ok "${canonical} cached locally"
  else
    # Soft failure — kubelet may still reach quay.io directly. The mirror
    # mismatch (e.g. tag bumped in the chart but not in this list) shouldn't
    # break the install, just slow it down on first pull.
    warn "Could not pull ${mirrored} — kubelet will try quay.io directly."
    warn "  If quay.io is also blocked, override mirror: export QUAY_MIRROR=<host>"
  fi
}

for img in "${HUB_IMAGES[@]}"; do
  prepull "$img"
done

for img in "${GHCR_IMAGES[@]}"; do
  prepull_ghcr "$img"
done

for img in "${QUAY_IMAGES[@]}"; do
  prepull_quay "$img"
done

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

# CDN fallback URLs for repos hosted on GitHub Pages. jsdelivr serves any
# GitHub branch's contents at https://cdn.jsdelivr.net/gh/<owner>/<repo>@<branch>
# and has strong China connectivity, so it works on networks where direct
# *.github.io is throttled or blocked. The published Helm repos all live on
# the gh-pages branch — both index.yaml and chart .tgz files are reachable
# through the same prefix, no rewriting needed.
declare -A HELM_REPO_CDN_FALLBACK=(
  [ingress-nginx]="https://cdn.jsdelivr.net/gh/kubernetes/ingress-nginx@gh-pages"
  [kyverno]="https://cdn.jsdelivr.net/gh/kyverno/kyverno@gh-pages"
  [prometheus-community]="https://cdn.jsdelivr.net/gh/prometheus-community/helm-charts@gh-pages"
  [backstage]="https://cdn.jsdelivr.net/gh/backstage/charts@gh-pages"
  [argo]="https://cdn.jsdelivr.net/gh/argoproj/argo-helm@gh-pages"
)

# Per-repo URL overrides via env, e.g.:
#   PROMETHEUS_COMMUNITY_REPO_URL=https://my-mirror/helm-charts bash scripts/install.sh
# Hyphens in the repo name become underscores; the result is uppercased and
# suffixed with _REPO_URL.
for name in "${!HELM_REPOS[@]}"; do
  env_var="${name//-/_}"
  env_var="${env_var^^}_REPO_URL"
  override="${!env_var:-}"
  if [[ -n "$override" ]]; then
    warn "Using URL override for $name: $override"
    HELM_REPOS[$name]="$override"
  fi
done

# try_register_one — single-URL attempt: 3× helm repo add with backoff,
# then direct curl of <url>/index.yaml into the helm cache. Returns 0 on
# success (cache populated), 1 on failure. Helper for register_helm_repo.
try_register_one() {
  local name="$1" url="$2" tag="$3"
  local cache_file="${HELM_REPO_CACHE}/${name}-index.yaml"
  local attempt=0 max=3 err=""

  while (( attempt < max )); do
    attempt=$((attempt + 1))
    if err=$(helm repo add "$name" "$url" --force-update 2>&1 1>/dev/null); then
      ok "repo $name registered (${tag}, helm repo add, attempt $attempt)"
      return 0
    fi
    if (( attempt < max )); then
      warn "repo $name (${tag}) add failed (attempt $attempt/$max) — retrying in $((attempt * 5))s"
    fi
    sleep $((attempt * 5))
  done
  warn "repo $name (${tag}): helm repo add failed after $max attempts"
  warn "  Last error: $err"

  if command -v curl >/dev/null 2>&1; then
    log "Trying direct index.yaml download for '$name' (${tag})..."
    mkdir -p "$HELM_REPO_CACHE" 2>/dev/null || true
    if curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused \
            --connect-timeout 30 --max-time 180 \
            -o "$cache_file" "${url%/}/index.yaml" 2>/dev/null; then
      local tmp_idx="${cache_file}.curl.tmp"
      cp "$cache_file" "$tmp_idx"
      helm repo add "$name" "$url" --force-update >/dev/null 2>&1 || true
      if [[ ! -s "$cache_file" ]]; then
        cp "$tmp_idx" "$cache_file"
      fi
      rm -f "$tmp_idx"
      if [[ -s "$cache_file" ]]; then
        ok "repo $name registered (${tag}, curl-cached index, ${url%/}/index.yaml)"
        return 0
      fi
    fi
    warn "  curl could not reach ${url%/}/index.yaml either"
  fi
  return 1
}

# register_helm_repo — four-tier fallback:
#   Tier 1+2: try the primary URL (helm repo add with retries, then curl).
#   Tier 3:   if a CDN fallback is registered (jsdelivr → gh-pages branch),
#             retry the same recipe against the CDN URL. Works on networks
#             where direct *.github.io is throttled/blocked.
#   Tier 4:   surface clear remediation hints. Caller decides whether to
#             abort or proceed (script aborts if any repo fails, with copy-
#             paste recovery commands).
# Returns 0 if the repo is usable (helm has a cached index), 1 otherwise.
register_helm_repo() {
  local name="$1" url="$2"
  local cache_file="${HELM_REPO_CACHE}/${name}-index.yaml"

  if try_register_one "$name" "$url" "primary"; then
    return 0
  fi

  local cdn="${HELM_REPO_CDN_FALLBACK[$name]:-}"
  if [[ -n "$cdn" && "$cdn" != "$url" ]]; then
    log "Trying CDN fallback for '$name': $cdn"
    if try_register_one "$name" "$cdn" "CDN"; then
      return 0
    fi
  fi

  fail "repo $name unreachable — Terraform helm_release for '$name' will fail"
  warn "  Workarounds:"
  local upper="${name//-/_}"; upper="${upper^^}"
  warn "    1. Use a mirror URL: export ${upper}_REPO_URL=<reachable_url>"
  if [[ -n "$cdn" ]]; then
    warn "       (suggested: ${upper}_REPO_URL=$cdn)"
  fi
  warn "    2. Set a proxy:      export HTTPS_PROXY=<proxy_url> HTTP_PROXY=<proxy_url>"
  warn "    3. Cache manually on a reachable network and copy"
  warn "       ${cache_file##*/} into ${HELM_REPO_CACHE}/"
  return 1
}

failed_repos=()
for name in "${!HELM_REPOS[@]}"; do
  if ! register_helm_repo "$name" "${HELM_REPOS[$name]}"; then
    failed_repos+=("$name")
  fi
done

log "Running helm repo update..."
if helm repo update 2>/dev/null; then
  ok "Helm repo cache refreshed"
else
  warn "helm repo update had errors — Terraform may still succeed if required repos are cached"
fi

if (( ${#failed_repos[@]} > 0 )); then
  echo
  fail "═══════════════════════════════════════════════════════════════════"
  fail "  ${#failed_repos[@]} helm repo(s) unreachable: ${failed_repos[*]}"
  fail "  Terraform will spin in retry hell (5×5min apply cycles) before"
  fail "  failing the same way every time. Aborting now to save 25 minutes."
  fail "═══════════════════════════════════════════════════════════════════"
  echo
  fail "  Pick ONE of these recovery commands and re-run install.sh:"
  echo
  for r in "${failed_repos[@]}"; do
    upper="${r//-/_}"; upper="${upper^^}"
    cdn="${HELM_REPO_CDN_FALLBACK[$r]:-}"
    if [[ -n "$cdn" ]]; then
      fail "    # ${r}: jsdelivr CDN mirror (works on most blocked networks)"
      fail "    export ${upper}_REPO_URL=$cdn"
    else
      fail "    # ${r}: this repo has no GitHub Pages CDN fallback;"
      fail "    # use a corporate proxy or download index.yaml manually."
    fi
  done
  echo
  fail "  Then:    bash scripts/install.sh"
  echo
  fail "  Or, if you have a proxy:"
  fail "    export HTTPS_PROXY=http://your.proxy:port"
  fail "    export HTTP_PROXY=http://your.proxy:port"
  fail "    bash scripts/install.sh"
  echo
  fail "  Set SKIP_HELM_REPO_CHECK=true to override and proceed anyway"
  fail "  (only useful if helm_release resources are already in state)."
  echo
  if [[ "${SKIP_HELM_REPO_CHECK:-false}" != "true" ]]; then
    exit 2
  fi
  warn "SKIP_HELM_REPO_CHECK=true — proceeding despite unreachable repos."
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

# Release any stale lock left by a previous crashed apply before init touches
# the state. The lock info file is written by Terraform core and contains the
# lock UUID we need to pass to force-unlock.
if [[ -f .terraform.tfstate.lock.info ]]; then
  lock_id=$(python3 -c "import sys,json; print(json.load(open('.terraform.tfstate.lock.info')).get('ID',''))" 2>/dev/null || true)
  if [[ -n "$lock_id" ]]; then
    warn "Stale state lock detected (ID: ${lock_id}) — releasing..."
    terraform force-unlock -force "$lock_id" 2>/dev/null \
      && ok "Stale lock released" \
      || warn "Could not release lock — proceeding anyway"
  fi
fi

# Normalize state for the pinned 2.30.x kubernetes provider BEFORE init.
#
# A previous run of this script may have used a newer kubernetes provider
# (e.g. 2.36+ / 2.38), which writes per-instance `identity` and
# `identity_schema_version: 1` blocks introduced by Terraform's managed
# resource identity feature. The pinned 2.30.x provider does not understand
# those fields and rejects the state with:
#
#   Error: Resource instance managed by newer provider version
#
# `terraform state rm` cannot reliably evict these instances — the same
# newer-version check fires inside the state subcommand, so the entries
# stay put and every retry fails identically.
#
# Direct surgery on terraform.tfstate is the only fix: strip the unknown
# fields from each hashicorp/kubernetes instance, bump `serial`, and let
# Terraform load the state cleanly under 2.30.x. The on-cluster resources
# are untouched, so the next plan sees them as already-managed (no
# spurious creates or destroys).
# Set to "true" by normalize_state_for_provider_version when the state was
# either already compatible OR successfully rewritten. evict_newer_provider_state
# checks this flag and skips its work entirely in that case — saves us from
# emitting misleading "Could not evict" warnings when terraform state rm
# returns non-zero on perfectly healthy state entries.
STATE_NORMALIZED="false"

normalize_state_for_provider_version() {
  local state_file="$REPO_ROOT/terraform/terraform.tfstate"
  if [[ ! -f "$state_file" ]]; then
    STATE_NORMALIZED="true"
    return 0
  fi

  # Run a single Python pass that detects + strips. Exit code:
  #   0 = nothing to do, 1 = stripped fields (state was rewritten), 2 = error.
  # We use a quoted heredoc (<<'PY') so bash performs zero expansion inside —
  # the python source survives intact regardless of $-signs or quotes.
  local backup="${state_file}.preNormalize.$(date +%s)"
  cp "$state_file" "$backup"

  local rc=0
  # Python protocol: 0 = no work needed (state already clean),
  #                  1 = state was rewritten,
  #                  2 = error (e.g. JSON parse failure on a corrupted state).
  # Wrap the body in try/except so a Python exception exits with rc=2
  # rather than the default rc=1, which would otherwise be indistinguishable
  # from "successfully normalized" in the case statement below.
  #
  # Robustness — tfstate corruption recovery: on Windows, interrupted writes
  # leave terraform.tfstate padded with NUL bytes (\x00) after the trailing
  # `}`. python's json.load then errors with "Extra data". We handle this by
  # reading as bytes, trimming trailing NULs / whitespace, and decoding as
  # UTF-8 — recovering the original valid JSON without any data loss.
  python3 - "$state_file" <<'PY' || rc=$?
import json, sys
try:
    path = sys.argv[1]
    with open(path, "rb") as f:
        raw = f.read()
    trimmed = raw.rstrip(b"\x00 \t\r\n")
    if len(trimmed) < len(raw):
        print("  trimmed {} trailing NUL/whitespace byte(s) from corrupted state".format(
            len(raw) - len(trimmed)))
    state = json.loads(trimmed.decode("utf-8"))
    stripped = 0
    for r in state.get("resources", []):
        if "hashicorp/kubernetes" not in r.get("provider", ""):
            continue
        for inst in r.get("instances", []):
            if inst.pop("identity", None) is not None:
                stripped += 1
            if inst.pop("identity_schema_version", None) is not None:
                stripped += 1
    # Rewrite if we stripped fields OR if we trimmed corruption (always
    # heal a NUL-padded state file even if no identity blocks were present).
    needs_write = bool(stripped) or (len(trimmed) < len(raw))
    if needs_write:
        state["serial"] = state.get("serial", 0) + 1
        with open(path, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)
        msg = []
        if stripped:
            msg.append("normalized {} field(s) across kubernetes_* instances".format(stripped))
        if len(trimmed) < len(raw):
            msg.append("recovered NUL-padded state")
        print("  " + "; ".join(msg))
        sys.exit(1)
    sys.exit(0)
except Exception as e:
    print("  state normalization error: {}".format(e), file=sys.stderr)
    sys.exit(2)
PY
  case "$rc" in
    0)
      rm -f "$backup"
      ok "State already 2.30-compatible (no identity blocks present)"
      STATE_NORMALIZED="true"
      ;;
    1)
      ok "State normalized for provider 2.30 compatibility (backup: ${backup##*/})"
      STATE_NORMALIZED="true"
      ;;
    *)
      warn "State normalization failed (rc=$rc) — restoring backup and continuing"
      mv "$backup" "$state_file"
      STATE_NORMALIZED="false"
      ;;
  esac
}

normalize_state_for_provider_version

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
  -target='module.backstage.kubernetes_secret.backstage_postgres'
  -target='module.backstage.kubernetes_deployment.backstage_postgres'
  -target='module.backstage.kubernetes_service.backstage_postgres'
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
  "module.backstage.kubernetes_secret.backstage_postgres|backstage/backstage-postgres"
  "module.backstage.kubernetes_deployment.backstage_postgres|backstage/backstage-postgres"
  "module.backstage.kubernetes_service.backstage_postgres|backstage/backstage-postgres"
)

# evict_newer_provider_state — secondary safety net for the "Resource instance
# managed by newer provider version" error. The primary fix is
# normalize_state_for_provider_version (run before init), which strips the
# offending identity blocks from terraform.tfstate directly. This function
# remains as a belt-and-braces measure: if anything still trips the check,
# it removes ALL kubernetes_* state entries the script knows about so
# reconcile_orphans can re-import them under the current provider.
#
# We deliberately cover every entry in K8S_IMPORTS (namespaces + RBAC +
# config maps + secrets) — not just namespaces — because state instances of
# any kind can carry the forward-only identity_schema_version field.
#
# Parsing terraform plan output to detect which resources are affected is
# fragile (Terraform wraps the resource address across two lines depending on
# terminal width). Instead we unconditionally evict every known address and
# let reconcile_orphans restore them from the live cluster — a safe no-op on
# entries that were already correct.
evict_newer_provider_state() {
  # Skip entirely if normalize_state_for_provider_version already produced
  # a clean state. terraform state rm returns non-zero on entries that the
  # provider considers healthy (the operation is treated as a no-op error),
  # which would otherwise emit "Could not evict" warnings for every entry
  # despite nothing actually being wrong.
  if [[ "$STATE_NORMALIZED" == "true" ]]; then
    ok "State already normalized — skipping evict (no provider-version mismatch)"
    return 0
  fi

  log "Evicting kubernetes_* state entries for provider-version normalization..."
  local state_list
  state_list=$(terraform state list 2>/dev/null || echo "")
  local removed=0
  for entry in "${K8S_IMPORTS[@]}"; do
    local addr="${entry%%|*}"
    if grep -Fxq "$addr" <<<"$state_list"; then
      if terraform state rm -input=false "$addr" >/dev/null 2>&1; then
        ok "  Evicted: $addr"
        removed=$((removed + 1))
      else
        warn "  Could not evict: $addr"
      fi
    fi
  done
  if (( removed == 0 )); then
    ok "No kubernetes_* state entries present — nothing to evict"
  else
    ok "Evicted ${removed} entries; reconcile_orphans will re-import from cluster"
  fi
}

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
      service_account|config_map|secret|deployment|service)
        local ns="${cid%%/*}" name="${cid##*/}"
        # config_map → configmap, service_account → serviceaccount, deployment → deployment, service → service
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

evict_newer_provider_state
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
      # CRITICAL: reconcile orphans between retry attempts.
      #
      # When the plugin crashes mid-create, the resource lands on the cluster
      # BUT terraform never gets the success response and doesn't write it to
      # state. The next attempt then plans a "create" for that resource and
      # fails with "<kind> already exists". Without this re-reconcile,
      # subsequent retries are guaranteed to fail the same way and burn all
      # 5 attempts on the same orphan.
      #
      # Re-importing here means attempt N+1 sees the orphan in state and
      # plans an "update in place" (or no-op) instead of "create".
      reconcile_orphans
      sleep 2
    fi
    attempt=$((attempt + 1))
  done
  fail "${label} failed after ${max_attempts} attempts. Inspect output above."
  fail "  This is almost always Windows AV/EDR corrupting the provider's Go runtime."
  fail "  Fix: add Defender exclusions for the provider binary (see comment above)."
  return 1
}

apply_with_retry "Phase 1/2: creating 19 kubernetes_* resources serially" \
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
# Backstage runs on its own hostname (backstage.localhost). The host port
# is the same as nginx-ingress (HTTP_PORT). RFC 6761 + modern browsers
# resolve *.localhost → 127.0.0.1 automatically; no hosts file edit needed.
if [[ "$HTTP_PORT" == "80" ]]; then
  BACKSTAGE_URL="http://backstage.localhost"
else
  BACKSTAGE_URL="http://backstage.localhost:${HTTP_PORT}"
fi
echo "  Backstage Portal    ${BACKSTAGE_URL}"
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
