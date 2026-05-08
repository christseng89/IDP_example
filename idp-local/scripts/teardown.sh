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

step "Step 3 — Bounded nginx-ingress teardown (3 min cap, then force-delete)"
# nginx-ingress installs a ValidatingWebhookConfiguration
# (ingress-nginx-admission) that calls back into a service inside the
# ingress-nginx namespace. Once the controller pod begins terminating, the
# webhook starts timing out, which can block helm uninstall and any in-flight
# Ingress create/update/delete elsewhere in the cluster. Strategy mirrors
# Step 5 (Kyverno): remove the webhook first, attempt targeted destroy with
# a 180s cap, then fall back to force-delete the namespace.
NGINX_TIMEOUT=60  # seconds — short fuse: graceful helm uninstall consistently
                   # crashes the provider on Windows due to AV/EDR injection,
                   # so wait 1 minute then go straight to force-delete instead
                   # of burning a 3-minute timer for every teardown.

# Remove the admission webhook so it can't reject anything mid-teardown.
# (The webhook also has a -admission ValidatingWebhookConfiguration variant
# in some chart versions; -A patterns cover both.)
if kubectl delete validatingwebhookconfiguration ingress-nginx-admission \
     --ignore-not-found 2>/dev/null; then
  ok "ValidatingWebhookConfiguration ingress-nginx-admission removed"
fi

cd "$REPO_ROOT/terraform"

if timeout "${NGINX_TIMEOUT}" terraform destroy \
     -var="http_port=${HTTP_PORT}" \
     -var="https_port=${HTTPS_PORT}" \
     -target='module.platform.helm_release.nginx_ingress' \
     -target='module.platform.kubernetes_namespace.ingress_nginx' \
     --auto-approve; then
  ok "nginx-ingress torn down gracefully within ${NGINX_TIMEOUT}s"
else
  rc=$?
  warn "nginx-ingress graceful teardown did not finish in ${NGINX_TIMEOUT}s (exit ${rc}). Forcing..."

  # nginx-ingress has no CRDs, so no CR finalizer-stripping needed — straight
  # to namespace force-delete.
  if kubectl get ns ingress-nginx >/dev/null 2>&1; then
    warn "Force-deleting namespace ingress-nginx..."
    kubectl delete ns ingress-nginx --force --grace-period=0 \
      --ignore-not-found --wait=false 2>/dev/null || true

    sleep 10
    if kubectl get ns ingress-nginx >/dev/null 2>&1; then
      warn "Namespace still Terminating; clearing spec.finalizers..."
      kubectl get ns ingress-nginx -o json \
        | python3 -c "import json,sys,signal; signal.signal(signal.SIGPIPE,signal.SIG_DFL) if hasattr(signal,'SIGPIPE') else None; d=json.load(sys.stdin); d['spec']['finalizers']=[]; sys.stdout.write(json.dumps(d)); sys.stdout.flush()" 2>/dev/null \
        | kubectl replace --raw "/api/v1/namespaces/ingress-nginx/finalize" -f - >/dev/null 2>&1 || true
    fi
    ok "Namespace ingress-nginx force-deleted"
  else
    ok "Namespace ingress-nginx already gone"
  fi

  # Remove nginx-ingress from terraform state so Step 6's destroy doesn't
  # try (and fail) to delete them again.
  terraform state rm 'module.platform.helm_release.nginx_ingress' >/dev/null 2>&1 || true
  terraform state rm 'module.platform.kubernetes_namespace.ingress_nginx' >/dev/null 2>&1 || true
  ok "nginx-ingress entries removed from terraform state"
fi
cd "$REPO_ROOT"

step "Step 4 — Bounded crossplane teardown (3 min cap, then force-delete)"
# Crossplane stalls destroy via two mechanisms:
#   1. Provider, ProviderRevision, and Configuration objects carry a
#      finalizer (pkg.crossplane.io/uninstaller) that the package manager
#      controller is supposed to remove — but the controller is shutting
#      down and can't.
#   2. Composition, CompositeResourceDefinition (XRD), and any composite
#      resources have their own finalizers tracking dependent claims; same
#      controller-shutdown problem.
# Crossplane also installs ValidatingWebhookConfiguration and
# MutatingWebhookConfiguration objects that can reject API calls during the
# teardown if their backing service is gone. Strip them first.
CROSSPLANE_TIMEOUT=60  # seconds — see NGINX_TIMEOUT comment.

# Remove Crossplane admission webhooks before anything else.
for wh in $(kubectl get validatingwebhookconfiguration -o name 2>/dev/null \
              | grep -E 'crossplane' || true); do
  kubectl delete "$wh" --ignore-not-found 2>/dev/null \
    && ok "Removed $wh"
done
for wh in $(kubectl get mutatingwebhookconfiguration -o name 2>/dev/null \
              | grep -E 'crossplane' || true); do
  kubectl delete "$wh" --ignore-not-found 2>/dev/null \
    && ok "Removed $wh"
done

cd "$REPO_ROOT/terraform"

if timeout "${CROSSPLANE_TIMEOUT}" terraform destroy \
     -var="http_port=${HTTP_PORT}" \
     -var="https_port=${HTTPS_PORT}" \
     -target='module.platform.helm_release.crossplane' \
     -target='module.platform.kubernetes_namespace.crossplane_system' \
     --auto-approve; then
  ok "crossplane torn down gracefully within ${CROSSPLANE_TIMEOUT}s"
else
  rc=$?
  warn "crossplane graceful teardown did not finish in ${CROSSPLANE_TIMEOUT}s (exit ${rc}). Forcing..."

  # Strip finalizers from every Crossplane CR — both pkg.crossplane.io
  # (Provider, ProviderRevision, Configuration, ConfigurationRevision, Lock)
  # and apiextensions.crossplane.io (Composition, CompositionRevision, XRD,
  # EnvironmentConfig, Usage). Discover dynamically so newer/older Crossplane
  # versions are both handled.
  for crd in $(kubectl get crd -o name 2>/dev/null \
                 | grep -E 'crossplane\.io$' \
                 | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); do
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
  done
  ok "Crossplane CR finalizers stripped"

  if kubectl get ns crossplane-system >/dev/null 2>&1; then
    warn "Force-deleting namespace crossplane-system..."
    kubectl delete ns crossplane-system --force --grace-period=0 \
      --ignore-not-found --wait=false 2>/dev/null || true

    sleep 10
    if kubectl get ns crossplane-system >/dev/null 2>&1; then
      warn "Namespace still Terminating; clearing spec.finalizers..."
      kubectl get ns crossplane-system -o json \
        | python3 -c "import json,sys,signal; signal.signal(signal.SIGPIPE,signal.SIG_DFL) if hasattr(signal,'SIGPIPE') else None; d=json.load(sys.stdin); d['spec']['finalizers']=[]; sys.stdout.write(json.dumps(d)); sys.stdout.flush()" 2>/dev/null \
        | kubectl replace --raw "/api/v1/namespaces/crossplane-system/finalize" -f - >/dev/null 2>&1 || true
    fi
    ok "Namespace crossplane-system force-deleted"
  else
    ok "Namespace crossplane-system already gone"
  fi

  terraform state rm 'module.platform.helm_release.crossplane' >/dev/null 2>&1 || true
  terraform state rm 'module.platform.kubernetes_namespace.crossplane_system' >/dev/null 2>&1 || true
  ok "crossplane entries removed from terraform state"
fi
cd "$REPO_ROOT"

step "Step 5 — Bounded Kyverno teardown (3 min cap, then force-delete)"
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
# Step 6 doesn't try to delete them again.
KYVERNO_TIMEOUT=60  # seconds — see NGINX_TIMEOUT comment.

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
        | python3 -c "import json,sys,signal; signal.signal(signal.SIGPIPE,signal.SIG_DFL) if hasattr(signal,'SIGPIPE') else None; d=json.load(sys.stdin); d['spec']['finalizers']=[]; sys.stdout.write(json.dumps(d)); sys.stdout.flush()" 2>/dev/null \
        | kubectl replace --raw "/api/v1/namespaces/kyverno/finalize" -f - >/dev/null 2>&1 || true
    fi
    ok "Namespace kyverno force-deleted"
  else
    ok "Namespace kyverno already gone"
  fi

  # Remove Kyverno from terraform state so Step 6's destroy doesn't try again.
  terraform state rm 'module.platform.helm_release.kyverno' >/dev/null 2>&1 || true
  terraform state rm 'module.platform.kubernetes_namespace.kyverno' >/dev/null 2>&1 || true
  ok "Kyverno entries removed from terraform state"
fi
cd "$REPO_ROOT"

step "Step 6 — Terraform destroy"
cd "$REPO_ROOT/terraform"
log "Running: terraform destroy -var=http_port=${HTTP_PORT} -var=https_port=${HTTPS_PORT} --auto-approve"
terraform destroy \
  -var="http_port=${HTTP_PORT}" \
  -var="https_port=${HTTPS_PORT}" \
  --auto-approve
cd "$REPO_ROOT"
ok "Terraform destroy complete"

step "Step 7 — Delete orphaned CRDs (kept by Helm resource policy)"
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
