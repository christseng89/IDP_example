#!/usr/bin/env bash
# teardown.sh — Safely tear down the idp-local IDP platform.
# Usage:  bash scripts/teardown.sh
#         HTTP_PORT=9080 bash scripts/teardown.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}${BOLD}[IDP]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}   $*"; }
err()  { echo -e "  ${RED}✘${NC}  $*"; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

step "Step 1 — Remove Kyverno admission webhooks"
# Kyverno webhooks must be deleted BEFORE helm uninstall. Terminating Kyverno
# pods cannot respond to their own ValidatingWebhookConfiguration calls, which
# causes a deadlock: webhook times out → Kubernetes retries → pods never finish
# terminating → Terraform hits its timeout. Deleting the webhook configs first
# breaks the cycle so pods can terminate cleanly.
if kubectl delete validatingwebhookconfiguration \
     -l app.kubernetes.io/instance=kyverno 2>/dev/null; then
  ok "ValidatingWebhookConfigurations removed"
else
  warn "No Kyverno ValidatingWebhookConfigurations found (already gone)"
fi
if kubectl delete mutatingwebhookconfiguration \
     -l app.kubernetes.io/instance=kyverno 2>/dev/null; then
  ok "MutatingWebhookConfigurations removed"
else
  warn "No Kyverno MutatingWebhookConfigurations found (already gone)"
fi

step "Step 2 — Remove ArgoCD Application finalizers"
# resources-finalizer.argocd.argoproj.io blocks namespace deletion until ArgoCD
# has pruned all managed resources. Remove it so terraform can delete the argocd
# namespace without waiting on ArgoCD's GC loop (which itself is being torn down).
for app in svc-alpha svc-beta; do
  if kubectl patch app "$app" -n argocd \
       -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null; then
    ok "Finalizer removed from ArgoCD app/$app"
  else
    warn "ArgoCD app/$app not found (already gone)"
  fi
done

step "Step 3 — Terraform destroy"
cd "$REPO_ROOT/terraform"
log "Running: terraform destroy -var=http_port=${HTTP_PORT} -var=https_port=${HTTPS_PORT} --auto-approve"
terraform destroy \
  -var="http_port=${HTTP_PORT}" \
  -var="https_port=${HTTPS_PORT}" \
  --auto-approve
cd "$REPO_ROOT"
ok "Terraform destroy complete"

step "Step 4 — Delete orphaned CRDs (kept by Helm resource policy)"
# ArgoCD and Argo Rollouts charts annotate their CRDs with
# helm.sh/resource-policy: keep so user data survives helm upgrades.
# On a full destroy we want a clean slate, so delete them explicitly.
ORPHAN_CRDS=(
  applications.argoproj.io
  applicationsets.argoproj.io
  appprojects.argoproj.io
  analysisruns.argoproj.io
  analysistemplates.argoproj.io
  clusteranalysistemplates.argoproj.io
  experiments.argoproj.io
  rollouts.argoproj.io
)
for crd in "${ORPHAN_CRDS[@]}"; do
  if kubectl delete crd "$crd" 2>/dev/null; then
    ok "CRD $crd deleted"
  fi
done

echo ""
echo -e "${GREEN}${BOLD}Platform torn down successfully.${NC}"
echo "To reinstall: HTTP_PORT=${HTTP_PORT} bash scripts/install.sh"
