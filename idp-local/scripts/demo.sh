#!/bin/bash
# IDP Demo walkthrough — guided script for stakeholder presentation.
# Run each numbered step in sequence, pausing to show the audience each feature.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step()  { echo -e "\n${CYAN}${BOLD}[STEP $1]${NC} $2"; }
info()  { echo -e "  ${GREEN}→${NC} $1"; }
warn()  { echo -e "  ${YELLOW}!${NC} $1"; }
pause() { echo -e "\n  ${BOLD}Press Enter to continue...${NC}"; read -r; }

# ─── Step 0: Prerequisites ───────────────────────────────────────────────────
step 0 "Prerequisites check"

docker info > /dev/null 2>&1       && info "Docker: OK"            || { echo "Docker not running"; exit 1; }
kubectl cluster-info --context docker-desktop > /dev/null 2>&1 \
                                   && info "kubectl: OK"            || { echo "Docker Desktop K8s not available"; exit 1; }
terraform version > /dev/null 2>&1 && info "Terraform: OK"         || { echo "Terraform not installed"; exit 1; }
helm version > /dev/null 2>&1      && info "Helm: OK"              || { echo "Helm not installed"; exit 1; }
kubectl argo rollouts version > /dev/null 2>&1 \
                                   && info "kubectl-argo-rollouts: OK" \
                                   || { echo "kubectl argo-rollouts plugin not installed. Install from https://argoproj.github.io/argo-rollouts/installation/#kubectl-plugin-installation"; exit 1; }

pause

# ─── Step 1: Build images ────────────────────────────────────────────────────
step 1 "Build service images (v1 and v2 for both services)"
bash "$REPO_ROOT/scripts/build-images.sh"
pause

# ─── Step 2: Bootstrap platform ──────────────────────────────────────────────
step 2 "Bootstrap full IDP platform — single terraform apply"
info "Installs: NGINX Ingress, Kyverno, Crossplane, Prometheus+Grafana, Argo CD, Argo Rollouts, Backstage"
info "Estimated time: 5-10 minutes on first run"

cd "$REPO_ROOT/terraform"
terraform init -upgrade
terraform apply -var="project_root=$REPO_ROOT" -auto-approve

pause

# ─── Step 3: Wait for readiness ──────────────────────────────────────────────
step 3 "Wait for all deployments to become ready"
for ns in ingress-nginx kyverno crossplane-system monitoring argocd argo-rollouts backstage; do
  info "Waiting: namespace/$ns"
  kubectl wait --for=condition=available deployment --all -n "$ns" --timeout=300s 2>/dev/null \
    || warn "$ns: some components may still be starting — check with: kubectl get pods -n $ns"
done

# Rollouts are not Deployments; use argo rollouts status for service namespaces
for ns in svc-alpha svc-beta; do
  info "Waiting: rollout in $ns"
  kubectl argo rollouts status "$(kubectl get rollout -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
    -n "$ns" --timeout 300s 2>/dev/null \
    || warn "$ns: rollout not yet available — check with: kubectl argo rollouts get rollout -n $ns --watch"
done
pause

# ─── Step 4: Show URLs ───────────────────────────────────────────────────────
step 4 "Platform endpoints"
echo ""
echo -e "  ${BOLD}Backstage Portal:      ${GREEN}http://localhost/backstage${NC}"
echo -e "  ${BOLD}Argo CD:               ${GREEN}http://localhost/argocd${NC}"
echo -e "  ${BOLD}Argo Rollouts UI:      ${GREEN}http://localhost/rollouts${NC}"
echo -e "  ${BOLD}Grafana:               ${GREEN}http://localhost/grafana${NC}  (admin / idp-demo)"
echo ""
echo -e "  ${BOLD}svc-alpha v1:          ${GREEN}http://localhost/svc-alpha/v1/hello${NC}"
echo -e "  ${BOLD}svc-alpha v2:          ${GREEN}http://localhost/svc-alpha/v2/hello${NC}"
echo -e "  ${BOLD}svc-beta  v1:          ${GREEN}http://localhost/svc-beta/v1/hello${NC}"
echo -e "  ${BOLD}svc-beta  v2:          ${GREEN}http://localhost/svc-beta/v2/hello${NC}"
pause

# ─── Step 5: Backstage tour ──────────────────────────────────────────────────
step 5 "Backstage features tour (open browser to http://localhost/backstage)"
info "1. Catalog → see svc-alpha and svc-beta components"
info "2. svc-alpha → Overview tab → Argo CD status: Synced/Healthy"
info "3. svc-alpha → Kubernetes tab → live pods and rollout state"
info "4. svc-alpha → API tab → OpenAPI spec, v1 (deprecated) vs v2"
info "5. svc-alpha → Docs tab → TechDocs rendered from docs/index.md"
info "6. svc-alpha → Relations → dependency graph: svc-alpha → svc-beta"
info "7. Create → New IDP Service → fill form → see golden path"
pause

# ─── Step 6: Trigger canary rollout ─────────────────────────────────────────
step 6 "Trigger canary rollout: svc-alpha v1 → v2"
info "Updating charts/svc-alpha/values.yaml tag to v2 (Argo CD owns the release)"

# ArgoCD has selfHeal:true — only a values.yaml change + ArgoCD sync produces a
# durable rollout. A direct helm upgrade would be immediately reverted.
sed -i 's/^  tag: v1$/  tag: v2/' "$REPO_ROOT/charts/svc-alpha/values.yaml"

info "Forcing Argo CD refresh + sync of svc-alpha..."
kubectl annotate app svc-alpha -n argocd argocd.argoproj.io/refresh='normal' --overwrite
kubectl patch app svc-alpha -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"demo"},"sync":{"revision":"HEAD"}}}'

info "Rollout started. Watching progress (Ctrl-C to stop watching)..."
kubectl argo rollouts get rollout svc-alpha -n svc-alpha --watch &
WATCH_PID=$!

pause
kill "$WATCH_PID" 2>/dev/null || true

# ─── Step 7: Inspect at 20% ─────────────────────────────────────────────────
step 7 "Inspect canary at 20% traffic weight"
info "Open Grafana → IDP Services dashboard — you should see ~20% traffic to v2"
info "Open Argo Rollouts UI → svc-alpha → canary step 1 paused"
info "Test both versions directly:"
echo ""
echo "    curl http://localhost/svc-alpha/v1/hello"
echo "    curl http://localhost/svc-alpha/v2/hello"
pause

# ─── Step 8: Promote to 50% ─────────────────────────────────────────────────
step 8 "Promote to 50% — AnalysisTemplate begins evaluating Prometheus metrics"
kubectl argo rollouts promote svc-alpha -n svc-alpha
info "AnalysisTemplate checking: success rate >= 95% for 3 consecutive intervals (30s each)"
info "Watch Argo Rollouts UI for analysis status"
pause

# ─── Step 9: Full promotion ──────────────────────────────────────────────────
step 9 "Promote to 100% — v2 becomes stable"
kubectl argo rollouts promote svc-alpha -n svc-alpha
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
    curl -s "http://localhost/svc-alpha/v2/hello?fail=true" > /dev/null
  done
  info "Watch Argo Rollouts UI — AnalysisRun should fail → rollout aborts → back to v1"
  kubectl argo rollouts get rollout svc-alpha -n svc-alpha --watch
fi

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Demo complete.${NC}"
echo ""
echo "To tear down everything:"
echo "  cd $REPO_ROOT/terraform && terraform destroy -var=\"project_root=$REPO_ROOT\" -auto-approve"
