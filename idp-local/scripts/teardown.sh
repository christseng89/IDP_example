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

step "Step 3 — Bounded Kyverno teardown (3 min cap, then force-delete)"
# Kyverno is the most common destroy stall: even with the admission webhooks
# removed in Step 1, the helm uninstall still has to drain ClusterPolicies,
# AdmissionReports, BackgroundScanReports, and the Kyverno CRDs themselves.
# Each of these can hold finalizers that reference the Kyverno controller —
# but the controller is mid-shutdown and can't process them.
#
# Strategy: try a normal terraform destroy targeted at the Kyverno helm
# release + namespace with a 3-minute wall-clock cap. If it doesn't finish
# in time, force-delete the namespace (after stripping CRD finalizers, which
# is what `kubectl delete ns --force` actually requires to make progress)
# and remove the resources from terraform state so the main destroy in
# Step 4 doesn't try to delete them again.
KYVERNO_TIMEOUT=180  # seconds

cd "$REPO_ROOT/terraform"

if timeout "${KYVERNO_TIMEOUT}" terraform destroy \
     -var="http_port=${HTTP_PORT}" \
     -var="https_port=${HTTPS_PORT}" \
     -target='module.platform.helm_release.kyverno' \
     -target='module.platform.kubernetes_namespace.kyverno' \
     --auto-approve; then
  ok "Kyverno torn down gracefully within ${KYVERNO_TIMEOUT}s"
else
  rc=$?
  warn "Kyverno graceful teardown did not finish in ${KYVERNO_TIMEOUT}s (exit ${rc}). Forcing..."

  # Strip finalizers from any Kyverno CRD instances so they can be deleted.
  # Without this, `kubectl delete ns kyverno --force` blocks on stuck CRs.
  for crd in clusterpolicies.kyverno.io policies.kyverno.io \
             admissionreports.kyverno.io clusteradmissionreports.kyverno.io \
             backgroundscanreports.kyverno.io clusterbackgroundscanreports.kyverno.io \
             policyexceptions.kyverno.io updaterequests.kyverno.io \
             clustercleanuppolicies.kyverno.io cleanuppolicies.kyverno.io; do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
      kubectl get "$crd" -A -o name 2>/dev/null | while read obj; do
        ns=$(kubectl get "$obj" -A -o jsonpath='{.metadata.namespace}' 2>/dev/null || echo "")
        if [[ -n "$ns" ]]; then
          kubectl patch "$obj" -n "$ns" --type=merge \
            -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        else
          kubectl patch "$obj" --type=merge \
            -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        fi
      done
    fi
  done
  ok "Kyverno CR finalizers stripped"

  # Now the requested kubectl force-delete. On a stuck namespace this still
  # needs the spec.finalizers ([kubernetes]) cleared via the /finalize
  # subresource — `--force` alone doesn't do that. We try both.
  if kubectl get ns kyverno >/dev/null 2>&1; then
    warn "Force-deleting namespace kyverno..."
    kubectl delete ns kyverno --force --grace-period=0 --ignore-not-found --wait=false 2>/dev/null || true

    # If the namespace is still stuck in Terminating after 10s, clear its
    # spec.finalizers via the /finalize subresource (the canonical fix).
    sleep 10
    if kubectl get ns kyverno >/dev/null 2>&1; then
      warn "Namespace still Terminating; clearing spec.finalizers..."
      kubectl get ns kyverno -o json \
        | python3 -c "import json,sys; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
        | kubectl replace --raw "/api/v1/namespaces/kyverno/finalize" -f - >/dev/null 2>&1 || true
    fi
    ok "Namespace kyverno force-deleted"
  else
    ok "Namespace kyverno already gone"
  fi

  # Remove Kyverno from terraform state so Step 4's destroy doesn't try again.
  terraform state rm 'module.platform.helm_release.kyverno' >/dev/null 2>&1 || true
  terraform state rm 'module.platform.kubernetes_namespace.kyverno' >/dev/null 2>&1 || true
  ok "Kyverno entries removed from terraform state"
fi
cd "$REPO_ROOT"

step "Step 4 — Terraform destroy"
cd "$REPO_ROOT/terraform"
log "Running: terraform destroy -var=http_port=${HTTP_PORT} -var=https_port=${HTTPS_PORT} --auto-approve"
terraform destroy \
  -var="http_port=${HTTP_PORT}" \
  -var="https_port=${HTTPS_PORT}" \
  --auto-approve
cd "$REPO_ROOT"
ok "Terraform destroy complete"

step "Step 5 — Delete orphaned CRDs (kept by Helm resource policy)"
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
