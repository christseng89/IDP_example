#!/bin/bash
# IDP Demo walkthrough — guided script for stakeholder presentation.
# Run each numbered step in sequence, pausing to show the audience each feature.
#
# Usage:
#   bash scripts/demo.sh              # default ports (80/443)
#   HTTP_PORT=9080 bash scripts/demo.sh   # Windows / port-80-occupied environments
#
# Prerequisite — Backstage hostname resolution:
#   Backstage runs at http://backstage.localhost (its own hostname, not a
#   subpath of localhost). On corporate networks where DNS returns NXDOMAIN
#   for *.localhost, add this line to your hosts file BEFORE running:
#
#     127.0.0.1 backstage.localhost
#
#   Windows (admin PowerShell):
#     Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "127.0.0.1 backstage.localhost"
#     ipconfig /flushdns
#
#   See README-install.md for full instructions.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"

# Build base URLs — omit :80 for clean output on standard installs
if [[ "$HTTP_PORT" == "80" ]]; then
  BASE_URL="http://localhost"
  BACKSTAGE_URL="http://backstage.localhost"
else
  BASE_URL="http://localhost:${HTTP_PORT}"
  BACKSTAGE_URL="http://backstage.localhost:${HTTP_PORT}"
fi

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step()  { echo -e "\n${CYAN}${BOLD}[STEP $1]${NC} $2"; }
info()  { echo -e "  ${GREEN}→${NC} $1"; }
warn()  { echo -e "  ${YELLOW}!${NC} $1"; }
pause() { echo -e "\n  ${BOLD}Press Enter to continue...${NC}"; read -r; }

# Convenience helper — prefer kubectl-argo-rollouts plugin if present, fall back to plain kubectl
ROLLOUTS_PLUGIN_OK=false
if kubectl argo rollouts version >/dev/null 2>&1; then
  ROLLOUTS_PLUGIN_OK=true
fi

# ─── Step 0: Prerequisites ───────────────────────────────────────────────────
step 0 "Prerequisites check"

docker info > /dev/null 2>&1       && info "Docker: OK"            || { echo "Docker not running"; exit 1; }
kubectl cluster-info --context docker-desktop > /dev/null 2>&1 \
                                   && info "kubectl: OK"            || { echo "Docker Desktop K8s not available"; exit 1; }
terraform version > /dev/null 2>&1 && info "Terraform: OK"         || { echo "Terraform not installed"; exit 1; }
helm version > /dev/null 2>&1      && info "Helm: OK"              || { echo "Helm not installed"; exit 1; }

if $ROLLOUTS_PLUGIN_OK; then
  info "kubectl-argo-rollouts plugin: OK (CLI rollout commands enabled)"
else
  warn "kubectl-argo-rollouts plugin not installed — Steps 6/8/9/10 will use the dashboard UI instead"
  warn "  Install: https://argoproj.github.io/argo-rollouts/installation/#kubectl-plugin-installation"
fi

# Verify backstage.localhost resolves — fail fast if hosts file is missing
if ! getent hosts backstage.localhost >/dev/null 2>&1 \
   && ! ping -n 1 -w 1 backstage.localhost >/dev/null 2>&1 \
   && ! ping -c 1 -W 1 backstage.localhost >/dev/null 2>&1; then
  warn "backstage.localhost does NOT resolve — Backstage will be unreachable in browser/curl."
  warn "  Add to hosts file (admin/root): 127.0.0.1 backstage.localhost"
  warn "  Demo will continue, but Step 5 (Backstage tour) will fail."
fi

pause

# ─── Step 1: Build images ────────────────────────────────────────────────────
step 1 "Build service images (svc-alpha v1/v2 + svc-beta v1/v2)"
bash "$REPO_ROOT/scripts/build-images.sh"
pause

# ─── Step 2: Bootstrap platform ──────────────────────────────────────────────
step 2 "Bootstrap full IDP platform via install.sh"
info "Installs: NGINX Ingress, Kyverno, Crossplane, Prometheus+Grafana, Argo CD, Argo Rollouts, Backstage (+ Postgres)"
info "install.sh handles: image pre-pull → helm repo cache → state normalization → 2-phase apply with retry"
info "Estimated time: 10-20 minutes on first run; ~3 minutes on re-run"

# Delegate to install.sh — single source of truth for all the install plumbing
# (mirror pre-pulls, state surgery, parallelism=1 phase, helm repo CDN fallback, etc.)
HTTP_PORT="$HTTP_PORT" HTTPS_PORT="$HTTPS_PORT" bash "$REPO_ROOT/scripts/install.sh"

pause

# ─── Step 3: Wait for readiness ──────────────────────────────────────────────
step 3 "Wait for all deployments to become ready"
# Note: install.sh already waits in its Step 6, but we re-verify here so the
# audience can see explicit "ready" output for each namespace.
for ns in ingress-nginx kyverno crossplane-system monitoring argocd argo-rollouts backstage; do
  info "Waiting: namespace/$ns"
  kubectl wait --for=condition=available deployment --all -n "$ns" --timeout=300s 2>/dev/null \
    || warn "$ns: some components may still be starting — check with: kubectl get pods -n $ns"
done

# Rollouts are not Deployments
for ns in svc-alpha svc-beta; do
  info "Waiting: rollout in $ns"
  if $ROLLOUTS_PLUGIN_OK; then
    kubectl argo rollouts status "$(kubectl get rollout -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
      -n "$ns" --timeout 300s 2>/dev/null \
      || warn "$ns: rollout not yet available"
  else
    # Plain kubectl fallback — wait for rollout's pods to become Ready
    kubectl wait pod --all -n "$ns" --for=condition=Ready --timeout=300s 2>/dev/null \
      || warn "$ns: pods not yet Ready — check with: kubectl get pods -n $ns"
  fi
done
pause

# ─── Step 4: Show URLs ───────────────────────────────────────────────────────
step 4 "Platform endpoints"
echo ""
echo -e "  ${BOLD}Backstage Portal:      ${GREEN}${BACKSTAGE_URL}${NC}  (separate hostname — see README)"
echo -e "  ${BOLD}Argo CD:               ${GREEN}${BASE_URL}/argocd${NC}"
echo -e "  ${BOLD}Argo Rollouts UI:      ${GREEN}${BASE_URL}/rollouts/svc-alpha${NC}  (or /rollouts/svc-beta)"
echo -e "  ${BOLD}Grafana:               ${GREEN}${BASE_URL}/grafana${NC}  (admin / idp-demo)"
echo ""
echo -e "  ${BOLD}svc-alpha v1:          ${GREEN}${BASE_URL}/svc-alpha/v1/hello${NC}"
echo -e "  ${BOLD}svc-alpha v2:          ${GREEN}${BASE_URL}/svc-alpha/v2/hello${NC}"
echo -e "  ${BOLD}svc-beta  v1:          ${GREEN}${BASE_URL}/svc-beta/v1/hello${NC}"
echo -e "  ${BOLD}svc-beta  v2:          ${GREEN}${BASE_URL}/svc-beta/v2/hello${NC}"
echo ""
echo -e "  ${BOLD}Argo CD admin password:${NC} run \`(cd $REPO_ROOT/terraform && terraform output -raw argocd_admin_password)\`"
pause

# ─── Step 5: Backstage tour ──────────────────────────────────────────────────
step 5 "Backstage features tour (open browser to ${BACKSTAGE_URL})"
info "1. Sign in as Guest"
info "2. Catalog → see svc-alpha and svc-beta components"
info "3. svc-alpha → Overview tab → component metadata + relations"
info "4. svc-alpha → Kubernetes tab → live pods and rollout state (uses in-cluster SA token)"
info "5. svc-alpha → API tab → OpenAPI spec, v1 (deprecated) vs v2"
info "6. svc-alpha → Docs tab → TechDocs rendered from docs/index.md"
info "7. svc-alpha → Relations → dependency graph: svc-alpha → svc-beta"
info "8. Create → New IDP Service → fill form → see golden path"
pause

# ─── Step 6: Trigger canary rollout ─────────────────────────────────────────
step 6 "Trigger canary rollout: svc-alpha v1 → v2"
info "Updating charts/svc-alpha/values.yaml tag to v2 (Argo CD owns the release)"

# ArgoCD has selfHeal:true — only a values.yaml change + ArgoCD sync produces a
# durable rollout. A direct helm upgrade would be immediately reverted.
sed -i 's/^  tag: v1$/  tag: v2/' "$REPO_ROOT/charts/svc-alpha/values.yaml"

# install.sh's Step 4b auto-commits any uncommitted changes in idp-local/.git/
# so ArgoCD's repo-server (cloning file:///idp-local) sees the new tag.
info "Committing the values change so ArgoCD repo-server can pick it up..."
(cd "$REPO_ROOT" && git add charts/svc-alpha/values.yaml \
   && git -c user.email='demo@idp-local' -c user.name='demo' \
          commit -q -m 'demo: bump svc-alpha to v2' --allow-empty)

info "Forcing Argo CD refresh + sync of svc-alpha..."
kubectl annotate app svc-alpha -n argocd argocd.argoproj.io/refresh='normal' --overwrite
kubectl patch app svc-alpha -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"demo"},"sync":{"revision":"HEAD"}}}'

info "Rollout started. Watching progress (Ctrl-C to stop watching)..."
if $ROLLOUTS_PLUGIN_OK; then
  kubectl argo rollouts get rollout svc-alpha -n svc-alpha --watch &
else
  info "(plugin missing — open Argo Rollouts dashboard at ${BASE_URL}/rollouts/svc-alpha for live view)"
  kubectl get rollout -n svc-alpha -w &
fi
WATCH_PID=$!

pause
kill "$WATCH_PID" 2>/dev/null || true

# ─── Step 7: Inspect at 20% ─────────────────────────────────────────────────
step 7 "Inspect canary at 20% traffic weight"
info "Open Grafana → IDP Services dashboard — you should see ~20% traffic to v2"
info "Open Argo Rollouts UI → svc-alpha → canary step 1 paused"
info "Test both versions directly:"
echo ""
echo "    curl ${BASE_URL}/svc-alpha/v1/hello"
echo "    curl ${BASE_URL}/svc-alpha/v2/hello"
pause

# ─── Step 8: Promote to 50% ─────────────────────────────────────────────────
step 8 "Promote to 50% — AnalysisTemplate begins evaluating Prometheus metrics"
if $ROLLOUTS_PLUGIN_OK; then
  kubectl argo rollouts promote svc-alpha -n svc-alpha
else
  warn "Plugin missing — promote via dashboard UI: ${BASE_URL}/rollouts/svc-alpha (click the Promote button)"
  pause
fi
info "AnalysisTemplate checking: success rate >= 95% for 3 consecutive intervals (30s each)"
info "Watch Argo Rollouts UI for analysis status"
pause

# ─── Step 9: Full promotion ──────────────────────────────────────────────────
step 9 "Promote to 100% — v2 becomes stable"
if $ROLLOUTS_PLUGIN_OK; then
  kubectl argo rollouts promote svc-alpha -n svc-alpha
else
  warn "Plugin missing — click Promote in dashboard UI"
  pause
fi
info "svc-alpha is now fully on v2. Grafana shows 100% traffic to v2."
pause

# ─── Step 10: Simulate failure and auto-rollback ────────────────────────────
step 10 "Bonus demo: simulate canary failure → auto-rollback to v1"
warn "Sending error traffic to trigger the AnalysisTemplate failure condition (error rate > 10%)"

echo ""
read -rp "  Run failure demo? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  info "Sending error requests..."
  for _i in {1..60}; do
    curl -s "${BASE_URL}/svc-alpha/v2/hello?fail=true" > /dev/null
  done
  info "Watch Argo Rollouts UI — AnalysisRun should fail → rollout aborts → back to v1"
  if $ROLLOUTS_PLUGIN_OK; then
    kubectl argo rollouts get rollout svc-alpha -n svc-alpha --watch
  else
    info "Open ${BASE_URL}/rollouts/svc-alpha to watch the rollback"
  fi
fi

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Demo complete.${NC}"
echo ""
echo "To tear down everything (uses scripts/teardown.sh — handles Kyverno"
echo "webhook deadlock + force-deletes stuck namespaces):"
if [[ "$HTTP_PORT" != "80" ]]; then
  echo "  HTTP_PORT=${HTTP_PORT} bash $REPO_ROOT/scripts/teardown.sh"
else
  echo "  bash $REPO_ROOT/scripts/teardown.sh"
fi
