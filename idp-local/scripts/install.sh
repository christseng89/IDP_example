#!/usr/bin/env bash
# install.sh — Full non-interactive installation of the idp-local IDP platform.
# Run from any directory; the script locates the repository root automatically.
#
# Usage:
#   bash scripts/install.sh [--dry-run] [--skip-images] [--enforce-mode Audit|Enforce]
#
# Flags:
#   --dry-run         Print what would be done; do not execute destructive commands.
#   --skip-images     Skip Docker image builds (use if images are already present).
#   --enforce-mode    Kyverno validationFailureAction (default: Enforce).

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()     { echo -e "${CYAN}${BOLD}[IDP]${NC} $*"; }
ok()      { echo -e "  ${GREEN}✔${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail()    { echo -e "  ${RED}✘${NC}  $*" >&2; }
section() { echo -e "\n${BOLD}━━━  $* ━━━${NC}"; }
hr()      { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_IMAGES=false
KYVERNO_MODE="Enforce"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true ;;
    --skip-images)   SKIP_IMAGES=true ;;
    --enforce-mode)  KYVERNO_MODE="${2:?--enforce-mode requires Audit or Enforce}"; shift ;;
    *) fail "Unknown flag: $1"; exit 1 ;;
  esac
  shift
done

if [[ "$DRY_RUN" == "true" ]]; then
  warn "DRY-RUN mode — no state will be changed."
fi

# ── Resolve repository root ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log "Repository root : $REPO_ROOT"
log "Kyverno mode    : $KYVERNO_MODE"
echo ""

# ── Helper: run or print ──────────────────────────────────────────────────────
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "  ${YELLOW}[dry-run]${NC} $*"
  else
    "$@"
  fi
}

# ── Helper: require a command ─────────────────────────────────────────────────
require() {
  local cmd="$1" hint="${2:-}"
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd $(${cmd} --version 2>&1 | head -1)"
  else
    fail "$cmd not found.${hint:+ Install from: $hint}"
    PREREQ_FAIL=true
  fi
}

# ── Helper: wait for all Deployments in a namespace ──────────────────────────
wait_namespace() {
  local ns="$1" timeout="${2:-300}"
  log "Waiting for deployments in namespace/$ns (timeout ${timeout}s)…"
  if ! kubectl wait --for=condition=available deployment --all -n "$ns" \
       --timeout="${timeout}s" 2>/dev/null; then
    warn "Some pods in $ns are still starting. Check with:"
    warn "  kubectl get pods -n $ns"
  else
    ok "namespace/$ns ready"
  fi
}

# ── Helper: wait for an Argo Rollout ─────────────────────────────────────────
# Uses plain kubectl so the kubectl-argo-rollouts plugin is not required.
wait_rollout() {
  local ns="$1" timeout="${2:-180}"
  local name
  name="$(kubectl get rollout -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$name" ]]; then
    warn "No rollout found in $ns — skipping."
    return
  fi
  log "Waiting for rollout/$name in $ns (timeout ${timeout}s)…"
  local deadline=$(( SECONDS + timeout ))
  while [[ $SECONDS -lt $deadline ]]; do
    local phase
    phase="$(kubectl get rollout "$name" -n "$ns" \
              -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Healthy" || "$phase" == "Paused" ]]; then
      ok "rollout/$name $phase"
      return
    fi
    sleep 5
  done
  warn "rollout/$name not yet Healthy after ${timeout}s. Check with:"
  warn "  kubectl get rollout $name -n $ns -o yaml"
}

# ── Helper: HTTP smoke test ───────────────────────────────────────────────────
smoke_test() {
  local label="$1" url="$2" expected_status="${3:-200}"
  local status
  status="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")"
  if [[ "$status" == "$expected_status" ]]; then
    ok "HTTP $status  $label  ($url)"
  else
    warn "HTTP $status  $label  ($url)  — expected $expected_status"
  fi
}

# ── Helper: auto-configure Docker registry mirrors ────────────────────────────
# Two-pronged fix:
#   A) Patches daemon.json → benefits Kubernetes pod image pulls (persistent).
#   B) Exports DOCKER_MIRROR → build-images.sh uses it immediately without
#      waiting for a Docker Desktop restart.
# Docker Desktop is restarted so daemon.json takes effect for K8s; if the
# restart fails for any reason, DOCKER_MIRROR still covers the build phase.
configure_registry_mirrors() {
  # Always export DOCKER_MIRROR first so build-images.sh can proceed even if
  # daemon.json patching or Docker Desktop restart fails or is slow.
  export DOCKER_MIRROR="${DOCKER_MIRROR:-docker.m.daocloud.io}"

  log "Auto-configuring Docker registry mirrors in daemon.json…"

  # ── Step A: patch daemon.json ─────────────────────────────────────────────
  local ps_patch
  ps_patch="$(mktemp).ps1"

  cat > "$ps_patch" <<'POWERSHELL'
$daemonJson = "$env:APPDATA\Docker\daemon.json"
$mirrors = @(
  "https://docker.m.daocloud.io",
  "https://dockerhub.azk8s.cn"
)

if (Test-Path $daemonJson) {
  try   { $cfg = Get-Content $daemonJson -Raw | ConvertFrom-Json }
  catch { $cfg = [PSCustomObject]@{} }
} else {
  $null = New-Item -ItemType Directory -Force -Path (Split-Path $daemonJson)
  $cfg = [PSCustomObject]@{}
}

$existing = if ($cfg.PSObject.Properties['registry-mirrors']) {
              [string[]]$cfg.'registry-mirrors'
            } else { @() }

$merged = @($mirrors + $existing | Select-Object -Unique)

if ($cfg.PSObject.Properties['registry-mirrors']) {
  $cfg.'registry-mirrors' = $merged
} else {
  $cfg | Add-Member -MemberType NoteProperty -Name 'registry-mirrors' -Value $merged
}

$cfg | ConvertTo-Json -Depth 10 | Set-Content $daemonJson -Encoding UTF8
Write-Host "  Written  : $daemonJson"
Write-Host "  Mirrors  : $($merged -join ', ')"
POWERSHELL

  if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
       -File "$(cygpath -w "$ps_patch")" 2>&1; then
    ok "daemon.json updated"
  else
    warn "daemon.json patch failed — DOCKER_MIRROR env var will cover the build phase."
  fi
  rm -f "$ps_patch"

  # ── Step B: restart Docker Desktop so daemon.json takes effect for K8s ───
  # Docker Desktop 4.x runs dockerd inside WSL2; com.docker.service is not the
  # live daemon.  We must kill the full process tree and relaunch.
  log "Restarting Docker Desktop to apply mirror settings (~45 s)…"

  local ps_restart
  ps_restart="$(mktemp).ps1"

  cat > "$ps_restart" <<'POWERSHELL'
# Kill every Docker Desktop-related process, then relaunch
$names = @("Docker Desktop", "com.docker.backend", "com.docker.dev-envs")
foreach ($n in $names) {
  Get-Process $n -ErrorAction SilentlyContinue |
    ForEach-Object {
      $_.CloseMainWindow() | Out-Null
      $_ | Wait-Process -Timeout 8 -ErrorAction SilentlyContinue
      if (-not $_.HasExited) { $_ | Stop-Process -Force -ErrorAction SilentlyContinue }
    }
}
Start-Sleep -Seconds 8   # let WSL2 backend fully shut down

$exe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
if (-not (Test-Path $exe)) {
  $exe = Join-Path $env:LOCALAPPDATA "Programs\Docker\Docker\Docker Desktop.exe"
}
if (-not (Test-Path $exe)) {
  Write-Error "Docker Desktop executable not found — restart it manually."
  exit 1
}
Start-Process $exe -WindowStyle Hidden
Write-Host "  Launched : $exe"
POWERSHELL

  if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
       -File "$(cygpath -w "$ps_restart")" 2>&1; then
    # ── Step C: wait for daemon to respond (up to 90 s) ──────────────────
    log "Waiting for Docker daemon to become ready…"
    local i=0
    while ! docker info &>/dev/null 2>&1; do
      sleep 3; i=$(( i + 1 ))
      if [[ $i -ge 30 ]]; then
        warn "Docker daemon did not respond within 90 s — continuing anyway."
        break
      fi
    done
    if docker info &>/dev/null 2>&1; then
      ok "Docker Desktop restarted; registry mirrors active for K8s pulls"
      DOCKER_RESTARTED=true
    fi
  else
    warn "Docker Desktop restart failed. daemon.json is updated for the next startup."
    warn "For K8s pod pulls to use mirrors now: right-click Docker tray → Restart."
  fi
  rm -f "$ps_restart"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "STEP 1 — Prerequisites"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PREREQ_FAIL=false
DOCKER_RESTARTED=false

# docker, terraform support --version; kubectl and helm need their own flags
require docker    "https://docs.docker.com/desktop/"
require terraform "https://developer.hashicorp.com/terraform/install"

if command -v kubectl &>/dev/null; then
  ok "kubectl $(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1 | awk '{print $2}')"
else
  fail "kubectl not found. Install from: https://kubernetes.io/docs/tasks/tools/"
  PREREQ_FAIL=true
fi

if command -v helm &>/dev/null; then
  ok "helm $(helm version --short 2>/dev/null)"
else
  fail "helm not found. Install from: https://helm.sh/docs/intro/install/"
  PREREQ_FAIL=true
fi

# kubectl-argo-rollouts is a client-side kubectl plugin; the controller is
# installed by Terraform via Helm. The plugin is only needed for the
# `kubectl argo rollouts` convenience commands; installation continues without it.
HAS_ARGO_PLUGIN=false
if kubectl argo rollouts version &>/dev/null 2>&1; then
  HAS_ARGO_PLUGIN=true
  ok "kubectl-argo-rollouts $(kubectl argo rollouts version --short 2>/dev/null | head -1)"
else
  warn "kubectl-argo-rollouts plugin not found (optional)."
  warn "  The Argo Rollouts controller is installed by Terraform via Helm."
  warn "  Install the plugin for richer CLI commands:"
  warn "    https://argoproj.github.io/argo-rollouts/installation/#kubectl-plugin-installation"
fi

# Docker daemon reachable
if ! docker info &>/dev/null; then
  fail "Docker daemon is not running. Start Docker Desktop first."
  PREREQ_FAIL=true
fi

# Docker Hub connectivity — auto-configure registry mirrors if blocked.
# This fixes both local docker builds and Kubernetes image pulls (both use
# the same Docker daemon whose daemon.json we patch).
if [[ "$DRY_RUN" == "false" ]]; then
  if curl -sf --connect-timeout 4 --max-time 6 \
       "https://registry-1.docker.io/v2/" >/dev/null 2>&1; then
    ok "Docker Hub reachable"
  else
    warn "Docker Hub (registry-1.docker.io) is unreachable — configuring mirrors."
    configure_registry_mirrors
    # Verify that the daemon-level mirror works: a plain docker pull of a
    # Docker Hub image should now succeed via the configured registry-mirrors.
    if docker pull --quiet hello-world:latest >/dev/null 2>&1; then
      ok "Mirror pull verified (hello-world:latest via daemon mirror)"
      docker rmi hello-world:latest >/dev/null 2>&1 || true
    else
      warn "Mirror pull test failed — Helm image pulls may still fail."
      warn "If pods stay in ImagePullBackOff, configure mirrors manually:"
      warn "  Docker Desktop → Settings → Docker Engine → registry-mirrors"
    fi
  fi
else
  warn "[dry-run] Skipping Docker Hub connectivity check."
fi

# Docker Desktop Kubernetes reachable.
# If Docker was just restarted above, the K8s API may need up to 2 min to recover.
if [[ "$DOCKER_RESTARTED" == "true" ]]; then
  log "Waiting for Kubernetes API to recover after Docker restart (up to 2 min)…"
  k=0
  until kubectl cluster-info --context docker-desktop &>/dev/null 2>&1; do
    sleep 5; k=$(( k + 1 ))
    if [[ $k -ge 24 ]]; then break; fi
  done
fi

if ! kubectl cluster-info --context docker-desktop &>/dev/null; then
  fail "Docker Desktop Kubernetes is not available."
  fail "Enable it in Docker Desktop → Settings → Kubernetes → Enable Kubernetes."
  PREREQ_FAIL=true
else
  ok "Docker Desktop Kubernetes cluster reachable"
fi

if [[ "$PREREQ_FAIL" == "true" ]]; then
  fail "One or more prerequisites are missing. Fix them and re-run."
  exit 1
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "STEP 2 — Build Docker Images"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [[ "$SKIP_IMAGES" == "true" ]]; then
  warn "Skipping image builds (--skip-images)."
  log "Verifying images exist locally…"
  MISSING_IMAGES=false
  for img in svc-alpha:v1 svc-alpha:v2 svc-beta:v1 svc-beta:v2; do
    if docker image inspect "$img" &>/dev/null; then
      ok "$img present"
    else
      fail "$img not found — run without --skip-images to build it."
      MISSING_IMAGES=true
    fi
  done
  if [[ "$MISSING_IMAGES" == "true" ]]; then exit 1; fi
else
  run bash "$REPO_ROOT/scripts/build-images.sh"
  ok "All four images built"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "STEP 3 — Terraform Bootstrap"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Estimated time on first run: 10–20 minutes (downloads Helm charts + images)"

cd "$REPO_ROOT/terraform"

run terraform init -upgrade -input=false
run terraform apply \
  -var="project_root=$REPO_ROOT" \
  -var="kyverno_enforcement_mode=$KYVERNO_MODE" \
  -auto-approve \
  -input=false

ok "Terraform apply complete"
cd "$REPO_ROOT"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "STEP 4 — Wait for Platform Readiness"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [[ "$DRY_RUN" == "false" ]]; then
  for ns in ingress-nginx kyverno crossplane-system monitoring argocd argo-rollouts backstage; do
    wait_namespace "$ns" 300
  done

  for ns in svc-alpha svc-beta; do
    wait_rollout "$ns" 180
  done
else
  warn "[dry-run] Skipping readiness wait."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "STEP 5 — Smoke Tests"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [[ "$DRY_RUN" == "false" ]]; then
  log "Running HTTP smoke tests (allow 30 s for NGINX to be ready)…"
  sleep 30

  smoke_test "svc-alpha /health"       "http://localhost/svc-alpha/health"
  smoke_test "svc-alpha v1 /hello"     "http://localhost/svc-alpha/v1/hello"
  smoke_test "svc-alpha v2 /hello"     "http://localhost/svc-alpha/v2/hello"
  smoke_test "svc-beta  /health"       "http://localhost/svc-beta/health"
  smoke_test "svc-beta  v1 /hello"     "http://localhost/svc-beta/v1/hello"
  smoke_test "Backstage portal"        "http://localhost/backstage"
  smoke_test "Argo CD UI"              "http://localhost/argocd"       200
  smoke_test "Grafana UI"              "http://localhost/grafana"      302
  smoke_test "Argo Rollouts UI"        "http://localhost/rollouts"     200
else
  warn "[dry-run] Skipping smoke tests."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "STEP 6 — Credentials & Endpoints"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [[ "$DRY_RUN" == "false" ]]; then
  ARGOCD_PWD="$(cd "$REPO_ROOT/terraform" && terraform output -raw argocd_admin_password 2>/dev/null || echo '<run: terraform output -raw argocd_admin_password>')"
else
  ARGOCD_PWD="<dry-run — not retrieved>"
fi

hr
echo ""
echo -e "  ${BOLD}Platform endpoints${NC}"
echo ""
echo -e "  Backstage Portal    ${GREEN}http://localhost/backstage${NC}         (no auth in demo mode)"
echo -e "  Argo CD             ${GREEN}http://localhost/argocd${NC}            admin / ${YELLOW}${ARGOCD_PWD}${NC}"
echo -e "  Argo Rollouts UI    ${GREEN}http://localhost/rollouts${NC}"
echo -e "  Grafana             ${GREEN}http://localhost/grafana${NC}           admin / idp-demo"
echo ""
echo -e "  svc-alpha v1        ${GREEN}http://localhost/svc-alpha/v1/hello${NC}"
echo -e "  svc-alpha v2        ${GREEN}http://localhost/svc-alpha/v2/hello${NC}"
echo -e "  svc-beta  v1        ${GREEN}http://localhost/svc-beta/v1/hello${NC}"
echo -e "  svc-beta  v2        ${GREEN}http://localhost/svc-beta/v2/hello${NC}"
echo ""
hr
echo ""
echo -e "  ${BOLD}Useful commands${NC}"
echo ""
echo -e "  Watch a canary rollout (plain kubectl — no plugin needed):"
echo -e "    kubectl get rollout svc-alpha -n svc-alpha -w"
if [[ "$HAS_ARGO_PLUGIN" == "true" ]]; then
echo -e "  Or with the argo plugin (richer output):"
echo -e "    kubectl argo rollouts get rollout svc-alpha -n svc-alpha --watch"
fi
echo ""
echo -e "  Trigger a new rollout (v1 → v2):"
echo -e "    bash $REPO_ROOT/scripts/demo.sh"
echo ""
echo -e "  Tear down everything:"
echo -e "    cd $REPO_ROOT/terraform && terraform destroy -var=\"project_root=$REPO_ROOT\" -auto-approve"
echo ""
hr
echo ""
echo -e "${GREEN}${BOLD}Installation complete.${NC}"
echo ""
