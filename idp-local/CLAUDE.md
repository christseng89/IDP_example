# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A full five-layer CNCF Internal Developer Platform (IDP) running on Docker Desktop Kubernetes, bootstrapped with a single `terraform apply`. It demonstrates Argo CD, Argo Rollouts canary deployments, Backstage portal, Prometheus/Grafana observability, and Kyverno policy enforcement across two Node.js microservices.

## Common commands

### Platform

```bash
# Bootstrap everything (from terraform/)
terraform init
terraform apply -var="project_root=$(pwd)/.." -auto-approve

# Tear down
terraform destroy -var="project_root=$(pwd)/.." -auto-approve
```

### Services

```bash
# Build all Docker images (Docker Desktop shares the host daemon)
bash scripts/build-images.sh

# Lint a service
cd services/svc-alpha && npm run lint

# Test a service (npm install required — no lockfile committed)
cd services/svc-alpha && npm install && npm test

# Run a single test file or by name pattern
cd services/svc-alpha && npx jest src/app.test.js
cd services/svc-alpha && npx jest -t "GET /health"

# Run a service locally
cd services/svc-alpha && VERSION=v1 node src/index.js
```

### Demo walkthrough

```bash
bash scripts/demo.sh
```

### Rollout management

```bash
# Watch rollout progress
kubectl argo rollouts get rollout svc-alpha -n svc-alpha --watch

# Manually promote to next step
kubectl argo rollouts promote svc-alpha -n svc-alpha

# Abort and rollback
kubectl argo rollouts abort svc-alpha -n svc-alpha
```

## Architecture overview

### Repository structure

```
terraform/              # Single terraform apply bootstraps everything
  modules/
    platform/           # nginx-ingress, kyverno, crossplane
    observability/      # kube-prometheus-stack + Grafana dashboard ConfigMap
    gitops/             # argo-cd, argo-rollouts, ArgoCD Application CRs, RBAC ConfigMap
    backstage/          # Backstage helm_release + all ConfigMaps/Secrets
  templates/
    argocd-app.yaml.tpl # ArgoCD Application template (file:// repoURL for local charts)

charts/
  svc-alpha/            # Helm chart: Rollout, Services, Ingress, AnalysisTemplate, NetworkPolicy, ServiceMonitor
  svc-beta/             # Same structure as svc-alpha

services/
  svc-alpha/src/        # app.js (Express app, exportable), index.js (server start), routes/v1.js, routes/v2.js, metrics.js, app.test.js
  svc-alpha/docs/       # TechDocs source (index.md) — served by Backstage TechDocs plugin
  svc-beta/src/         # Same structure as svc-alpha
  svc-beta/docs/        # Same structure as svc-alpha/docs/

backstage/
  app-config.yaml       # Backstage config with ArgoCD + Kubernetes plugins
  catalog/              # all.yaml, svc-alpha-catalog.yaml, svc-beta-catalog.yaml (inlined OpenAPI)
  scaffolder-templates/ # new-service/template.yaml

scripts/
  build-images.sh       # Builds svc-alpha:v1, v2, svc-beta:v1, v2
  demo.sh               # Guided stakeholder demo script

.github/workflows/
  ci.yml                # lint, test, docker build, helm lint, terraform validate, yaml lint
```

### Critical design decisions

**ArgoCD owns the Helm releases** — `selfHeal: true` means any direct `helm upgrade` is immediately reverted. To change a release, update `charts/<name>/values.yaml` and trigger ArgoCD sync:
```bash
sed -i 's/tag: v1/tag: v2/' charts/svc-alpha/values.yaml
kubectl patch app svc-alpha -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"demo"},"sync":{"revision":"HEAD"}}}'
```

**Kubernetes provider** — uses `gavinbunney/kubectl` (NOT `hashicorp/kubectl`). Defined in all four module `main.tf` files.

**Prometheus service name** — `prometheus-stack-kube-prom-prometheus.monitoring:9090` (release name `prometheus-stack` + kube-prometheus-stack chart naming convention).

**Canary rollout flow** — steps: setWeight 20 → pause (manual) → setWeight 50 → pause (manual; AnalysisTemplate runs in background from step index 2) → setWeight 100. Two `kubectl argo rollouts promote` commands are needed to complete a full rollout.

**Backstage token** — The Kubernetes plugin reads from `kubernetes_secret.backstage_k8s_token` (type `kubernetes.io/service-account-token`). It's created in Terraform and auto-populated by Kubernetes.

**Services are testable** — `src/app.js` exports the Express app without starting a server. `src/index.js` only starts the listener. Tests use supertest against the exported app.

### Canary ingress architecture

Each service has two Kubernetes Ingresses (stable + canary) and two Services (stable + canary). The Argo Rollouts controller updates the `nginx.ingress.kubernetes.io/canary-weight` annotation on the canary ingress to shift traffic.

### Backstage features

| Feature | How it works |
|---------|-------------|
| Catalog | `backstage-catalog` ConfigMap mounted at `/backstage/catalog/` |
| Kubernetes plugin | ServiceAccount token from `backstage-k8s-token` secret; `skipTLSVerify: true` (Docker Desktop) |
| ArgoCD plugin | Password from `backstage-argocd` Secret env var; connects to `argocd-server.argocd.svc.cluster.local` |
| TechDocs | `builder: local`, `publisher: local` — reads docs/ from pod |
| Scaffolder | `backstage-scaffolder` ConfigMap mounts `template.yaml`; skeleton fetch won't work without additional mounts |

## Generated documentation

Four pre-generated Word documents live in the project root:

| File | Language | Contents |
|------|----------|----------|
| `IDP_Local_Functional_Spec.docx` | English | Architecture, services, canary flow, Backstage features |
| `IDP_Local_Installation_Guide.docx` | English | Prerequisites, step-by-step bootstrap, verification |
| `IDP_Local_功能規格書.docx` | Traditional Chinese | Same as functional spec |
| `IDP_Local_安裝指南.docx` | Traditional Chinese | Same as installation guide |

## Security controls

- All pods: `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`
- Backstage ClusterRole: read-only, no `configmaps` (prevents secret exposure via ConfigMaps)
- Argo CD RBAC: `policy.default: role:readonly` (unauthenticated callers are read-only)
- NetworkPolicies: deny-all default + selective allow per namespace
- Kyverno: two `Enforce` policies (require version label, require securityContext) — controlled by `var.kyverno_enforcement_mode` (default: `Enforce`; set to `Audit` for development)
- Dependency versions pinned (no `^` caret in package.json)
- CI: `npm audit --audit-level=high` blocks on HIGH/CRITICAL dependency vulnerabilities (SOC2 CC8.3)
- CI: Trivy container scan on all four images blocks on fixable HIGH/CRITICAL CVEs (SOC2 CC8.3)
- CI: `deploy-gate` job requires manual reviewer approval via GitHub Environment `production` before any push to main is considered deployment-ready (SOC2 CC8.2)

### GitHub Environment setup (one-time)

Create the `production` environment in **Settings → Environments → New environment** and add at least one required reviewer. The `deploy-gate` CI job will pause until a reviewer approves, providing the human approval evidence SOC2 CC8.2 requires.
