# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Two independent components live here:

1. **`idp-local/`** — A working Internal Developer Platform demo on Docker Desktop Kubernetes. Single-command bootstrap, full CNCF stack (Argo CD, Argo Rollouts, Backstage, Prometheus/Grafana, Kyverno, Crossplane, nginx-ingress), two Node.js microservices with canary rollout.

2. **`cs-idp-propose.skill`** — A Claude Skill archive (ZIP) that generates Traditional Chinese IDP proposal documents (Word + PowerPoint).

---

## idp-local: Platform Commands

All commands run from `idp-local/`:

```bash
# Bootstrap everything (~10–20 min first run)
bash scripts/install.sh

# If port 80 is occupied (common on Windows):
HTTP_PORT=9080 bash scripts/install.sh

# Run interactive stakeholder demo
bash scripts/demo.sh
HTTP_PORT=9080 bash scripts/demo.sh

# Tear down (use this instead of terraform destroy — handles webhook deadlock)
bash scripts/teardown.sh

# Build service images only
bash scripts/build-images.sh

# Get ArgoCD admin password
cd terraform && terraform output -raw argocd_admin_password
```

**Environment variables for install.sh / demo.sh:**

| Variable | Default | Purpose |
|---|---|---|
| `HTTP_PORT` | 80 | nginx-ingress LoadBalancer port |
| `HTTPS_PORT` | 443 | nginx-ingress HTTPS port |
| `KYVERNO_MODE` | `Enforce` | `Enforce` or `Audit` |
| `SKIP_BUILD` | — | Skip Docker image build step |
| `DOCKER_MIRROR`, `K8S_MIRROR`, `GHCR_MIRROR`, `QUAY_MIRROR` | DaoCloud CDN | Registry mirrors for restricted networks |

**Platform endpoints (with HTTP_PORT=9080):**

| Service | URL | Credentials |
|---|---|---|
| Backstage | `http://backstage.localhost:9080` | Guest sign-in |
| Argo CD | `http://localhost:9080/argocd` | admin / `terraform output -raw argocd_admin_password` |
| Grafana | `http://localhost:9080/grafana` | admin / idp-demo |
| Argo Rollouts | `http://localhost:9080/rollouts/svc-alpha` | — |
| svc-alpha | `http://localhost:9080/svc-alpha/v1/hello` | — |

Backstage requires a hosts file entry: `127.0.0.1 backstage.localhost` — it cannot be served from a sub-path because the official image has webpack `publicPath='/'` hardcoded.

## idp-local: Service Development

Each service (`services/svc-alpha/`, `services/svc-beta/`) is a Node.js 20 Express app:

```bash
cd services/svc-alpha
npm install
npm test          # Jest + supertest
npm run lint      # ESLint with security plugin
```

CI blocks on `npm audit --audit-level=high` and Trivy scan at HIGH/CRITICAL severity. The GitHub Actions workflow also has a manual approval gate on pushes to `main` (SOC2 CC8.2).

## idp-local: Terraform Architecture

Four modules with explicit dependency order:

```
platform (nginx-ingress, Kyverno, Crossplane)
  └── observability (kube-prometheus-stack)
  └── gitops (Argo CD, Argo Rollouts, ClusterPolicies, ArgoCD Application CRs)
        └── backstage (Backstage official chart + PostgreSQL 16)
```

**Two-phase apply** — `install.sh` runs Terraform in two phases to work around a Windows provider Go stack corruption issue:
- Phase 1: `parallelism=1`, applies only `kubernetes_*` resources
- Phase 2: normal apply for `helm_release` and `kubectl_manifest`

**Provider note:** Uses `gavinbunney/kubectl` (not `hashicorp/kubectl`) for `kubectl_manifest` resources across all modules.

**Windows path normalization** — The `gitops` module translates `C:\Users\...\idp-local` to `/run/desktop/mnt/host/c/users/.../idp-local` so Argo CD's repo-server (a Linux container) can mount the local repo via Docker Desktop hostPath. This enables `repoURL: file:///idp-local/charts/svc-alpha` without an external Git remote.

## idp-local: Triggering a Canary Rollout

ArgoCD owns the Helm releases with `selfHeal: true`. Never run `helm upgrade` directly — ArgoCD will revert it. The correct workflow:

```bash
# 1. Edit values.yaml
sed -i 's/^  tag: v1$/  tag: v2/' charts/svc-alpha/values.yaml

# 2. Commit (required — ArgoCD reads the local git repo)
git add charts/svc-alpha/values.yaml
git commit -m "Trigger canary: v1 → v2"

# 3. Trigger ArgoCD sync
kubectl patch app svc-alpha -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"demo"},"sync":{"revision":"HEAD"}}}'
```

Rollout steps: 20% (manual pause) → 50% (manual pause + AnalysisTemplate starts) → 100%. The AnalysisTemplate queries Prometheus for HTTP success rate ≥ 95% over 3 × 30s intervals. If success rate drops below 90%, the rollout aborts and traffic returns to v1.

## idp-local: Helm Charts

Charts in `charts/svc-alpha/` and `charts/svc-beta/` are deployed exclusively by Argo CD. Key templates:

- `rollout.yaml` — Argo Rollouts spec (canary with nginx traffic routing)
- `analysis-template.yaml` — Prometheus success-rate gate (≥ 95% required)
- `services.yaml` — separate stable and canary Services
- `ingress.yaml` — separate stable and canary Ingresses
- `network-policy.yaml` — deny-all default + allow from monitoring/argocd namespaces
- `service-monitor.yaml` — Prometheus scrape config

Helm lint: `helm lint charts/svc-alpha` (also runs in CI).

---

## Skill Archive: Document Generation

Extract `cs-idp-propose.skill` (it's a ZIP) to work with source files:

```bash
unzip cs-idp-propose.skill
cd cs-idp-propose/
```

Generate documents:

```bash
# All three deliverables
bash scripts/build.sh [WORK_DIR] all

# Individual
bash scripts/build.sh [WORK_DIR] docx       # IDP 提案白皮書 (~18 pages)
bash scripts/build.sh [WORK_DIR] pptx       # IDP 提案簡報 (13 slides)
bash scripts/build.sh [WORK_DIR] backstack  # Backstack 架構指南 (~16 pages)
```

Or manually:

```bash
python3 assets/render_diagram.py            # Must run first; generates shared PNG
npm install docx pptxgenjs
node assets/create_idp_doc.js              # → IDP_內部開發者平台.docx
node assets/create_idp_pptx.js             # → IDP_提案_簡報.pptx
node assets/create_backstack_doc.js        # → IDP_Backstack架構指南.docx
```

The `references/` directory is the content library — edit those files to update document content without touching generator code.

### Content conventions

**CNCF status** — cite on first mention with status + year:
- Argo CD (CNCF Graduated, 2022-12) — note the space
- Crossplane (CNCF Graduated, 2024-10), Kyverno (CNCF Graduated, 2024-11)
- Istio (CNCF Graduated, 2024-08), Cilium (CNCF Graduated, 2023-10)
- Backstage (CNCF Incubating), OpenTelemetry (CNCF Incubating)
- Label explicitly as NOT CNCF: Grafana, Kong, Apigee, Port, Humanitec

**Bilingual first-mention**: `降低認知負擔（Cognitive Load Reduction）` — English in full-width parentheses, Chinese-only on subsequent mentions.

**Tone**: neutral (`選用考量` not `推薦理由`); cite CNCF/DORA/Humanitec for adoption claims; no emojis.

**Punctuation**: full-width Chinese (`，。：；「」（）`); em-dash as `——` (doubled full-width).

**Document styling** (baked into generators — do not change ad hoc):
- Body: 9.5pt single line spacing
- H1: 16pt bold `#1F3A5F`, page break before
- H2: 13pt bold `#2F5496`, H3: 11.5pt bold `#1F3864`
- Table headers: navy `#1F3A5F` + white bold; alternating rows white/`#F4F9FC`
- Code blocks: Consolas 9pt, `#F2F4F7` background
