terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# Translate project_root into the Docker Desktop in-pod hostPath. The variable
# may come in as any of:
#   - Git Bash form:   /c/Users/chris/IDP_example/idp-local
#   - Windows form:    C:/Users/chris/IDP_example/idp-local
#   - Backslash form:  C:\Users\chris\IDP_example\idp-local
#   - With trailing /<dir>/..  (e.g. when applying from terraform/ with $(pwd)/..)
# Final form must be: /run/desktop/mnt/host/c/Users/chris/IDP_example/idp-local
locals {
  # 1. backslashes -> forward slashes
  _gitops_slash_path = replace(var.project_root, "\\", "/")

  # 2. "C:" -> "/c"  (only if path starts with a drive letter)
  _gitops_unix_path = (
    can(regex("^[A-Za-z]:", local._gitops_slash_path))
    ? "/${lower(substr(local._gitops_slash_path, 0, 1))}${substr(local._gitops_slash_path, 2, length(local._gitops_slash_path) - 2)}"
    : local._gitops_slash_path
  )

  # 3. collapse trailing "/<segment>/.."  (apply twice to handle one nested level)
  _gitops_no_dotdot_1 = replace(local._gitops_unix_path, "/[^/]+/\\.\\.$/", "")
  _gitops_no_dotdot_2 = replace(local._gitops_no_dotdot_1, "/[^/]+/\\.\\.$/", "")

  host_repo_path = "${var.host_repo_mount_prefix}${local._gitops_no_dotdot_2}"
}

resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
}

resource "kubernetes_namespace" "argo_rollouts" {
  metadata { name = "argo-rollouts" }
}

resource "kubernetes_namespace" "svc_alpha" {
  metadata { name = "svc-alpha" }
}

resource "kubernetes_namespace" "svc_beta" {
  metadata { name = "svc-beta" }
}

resource "helm_release" "argo_cd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.3"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [<<-YAML
    server:
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 200m
          memory: 256Mi
      ingress:
        enabled: true
        ingressClassName: nginx
        hostname: localhost
        path: /argocd
        pathType: Prefix
        annotations:
          # Do NOT add rewrite-target here — argocd-server handles the
          # /argocd sub-path itself via --rootpath below, and a rewrite would
          # strip the prefix before argocd sees it, causing 404s.
          nginx.ingress.kubernetes.io/ssl-passthrough: "false"
      extraArgs:
        - --insecure
        - --rootpath=/argocd

    repoServer:
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 1Gi
      # Mount the local repo into the repo-server pod so Argo CD Applications
      # can use `repoURL: file:///idp-local/...` instead of needing a real Git
      # remote. This is the standard Docker Desktop pattern — the host path
      # /run/desktop/mnt/host/<drive>/... is the in-pod view of the Windows
      # filesystem when File Sharing is enabled in Docker Desktop.
      volumes:
        - name: idp-local
          hostPath:
            path: ${local.host_repo_path}
            type: Directory
      volumeMounts:
        - name: idp-local
          mountPath: /idp-local
          readOnly: true

    applicationSet:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi

    notifications:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi

    redis:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi

    configs:
      params:
        server.insecure: true
        server.rootpath: /argocd
  YAML
  ]

  wait    = true
  timeout = 600
}

resource "helm_release" "argo_rollouts" {
  name       = "argo-rollouts"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  # 2.37.0 ships argo-rollouts v1.7.x, which adds the --rootpath flag the
  # dashboard needs to be served under /rollouts/. Chart 2.35.1's v1.6.x
  # rejected --rootpath as "unknown flag" and the SPA isn't tolerant of
  # being mounted at a sub-path without that flag.
  version    = "2.37.0"
  namespace  = kubernetes_namespace.argo_rollouts.metadata[0].name

  values = [<<-YAML
    # Chart 2.37.0 templates the image reference as
    #   {{ image.registry }}/{{ image.repository }}:{{ image.tag }}
    # so registry MUST be split from repository. Concatenating "quay.io/" into
    # repository produces "quay.io/quay.io/argoproj/..." which doesn't exist
    # and causes ImagePullBackOff -> helm wait timeout.
    controller:
      image:
        registry: quay.io
        repository: argoproj/argo-rollouts
        tag: v1.7.2
        pullPolicy: IfNotPresent
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 200m
          memory: 256Mi

    # Dashboard at /rollouts via VERBATIM forwarding (no --rootpath, no
    # rewrite). Why each piece is the way it is:
    #
    # * NO --rootpath flag: in v1.7.2 the dashboard binary CrashLoopBackOffs
    #   when this is set under Docker Desktop. Confirmed empirically.
    #
    # * NO probe overrides: chart defaults probe /healthz at port 3100, which
    #   the binary serves regardless of mount path. Overriding to
    #   /rollouts/healthz returns 404 and causes the pod to be killed.
    #
    # * Ingress is Prefix /rollouts with NO rewrite-target: the dashboard
    #   binary already has a built-in SPA route at /rollouts (it's the
    #   rollouts list page). Forwarding the URL verbatim — browser hits
    #   /rollouts/foo, dashboard gets /rollouts/foo, dashboard serves the
    #   SPA — avoids the redirect loop you get when nginx strips the prefix
    #   (dashboard would 302 / -> /rollouts and the browser would loop back).
    dashboard:
      enabled: true
      replicas: 1
      image:
        registry: quay.io
        repository: argoproj/kubectl-argo-rollouts
        tag: v1.7.2
        pullPolicy: IfNotPresent
      containerPort: 3100
      service:
        type: ClusterIP
        port: 3100
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 256Mi
      ingress:
        enabled: true
        ingressClassName: nginx
        hosts:
          - localhost
        # /rollouts → dashboard SPA + assets (via dashboard's own /rollouts/*
        #             route; relative asset URLs in index.html resolve fine
        #             under this prefix).
        # /api      → dashboard API + SSE streams. Without --rootpath the
        #             SPA's JS bundle calls absolute /api/v1/* paths. We
        #             route those to the same service so the SPA can load
        #             namespace/rollout data AND subscribe to live updates
        #             via /api/v1/stream/rollouts/<ns>/info (Server-Sent
        #             Events). Safe because no other app owns /api/* at
        #             root (Argo CD's API is at /argocd/api/* via its own
        #             --rootpath).
        paths:
          - /rollouts
          - /api
        pathType: Prefix
        annotations:
          # SSE streaming for the rollouts dashboard requires:
          #   - proxy-buffering OFF: nginx must forward bytes as they arrive
          #     instead of buffering. Without this, the SPA subscribes to
          #     /api/v1/stream/... and the connection hangs forever waiting
          #     for the first event ("Loading..." stuck on the rollouts
          #     table even when curl can fetch the data).
          #   - long read/send timeouts so the SSE connection isn't reset
          #     after the default 60s of "no new events".
          #   - HTTP/1.1 explicitly so nginx keeps the connection alive
          #     (HTTP/1.0 would close after each response).
          nginx.ingress.kubernetes.io/proxy-buffering: "off"
          nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
          nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
          nginx.ingress.kubernetes.io/proxy-http-version: "1.1"

  YAML
  ]

  # 900s (15min) gives slow networks room to pull both images on first
  # install. With pre-pulled images the helm install completes in <60s.
  wait    = true
  timeout = 900

  depends_on = [helm_release.argo_cd]
}

# Restrict default Argo CD RBAC to read-only — prevents anonymous callers from
# mutating applications even when the server runs in --insecure (HTTP) mode.
resource "kubectl_manifest" "argocd_rbac_cm" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: argocd-rbac-cm
      namespace: argocd
    data:
      policy.default: role:readonly
      policy.csv: |
        p, role:admin, applications, *, */*, allow
        p, role:admin, clusters, get, *, allow
        p, role:admin, repositories, *, *, allow
        g, admin, role:admin
  YAML

  depends_on = [helm_release.argo_cd]
}

# Retrieve the auto-generated Argo CD admin password from the initial secret
data "kubernetes_secret" "argocd_initial_password" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  depends_on = [helm_release.argo_cd]
}

# Argo CD Application — svc-alpha
# chart_path is no longer needed: the template uses the fixed in-pod path
# /idp-local/charts/<app_name>, and the repo-server has the host repo mounted
# at /idp-local (see helm_release.argo_cd above).
resource "kubectl_manifest" "argocd_app_svc_alpha" {
  yaml_body = templatefile("${path.module}/../../templates/argocd-app.yaml.tpl", {
    app_name  = "svc-alpha"
    namespace = "svc-alpha"
  })

  depends_on = [helm_release.argo_rollouts, kubernetes_namespace.svc_alpha]
}

# Argo CD Application — svc-beta
resource "kubectl_manifest" "argocd_app_svc_beta" {
  yaml_body = templatefile("${path.module}/../../templates/argocd-app.yaml.tpl", {
    app_name  = "svc-beta"
    namespace = "svc-beta"
  })

  depends_on = [helm_release.argo_rollouts, kubernetes_namespace.svc_beta]
}

# ─── Kyverno ClusterPolicies for Argo Rollouts ───────────────────────────────
# These live here (not in modules/platform) because Kyverno's admission webhook
# resolves the matched GVK during ClusterPolicy creation, which requires the
# Rollout CRD to already exist. The CRD is installed by helm_release.argo_rollouts
# above, so the policies must be created *after* it.
#
# Pinning to argoproj.io/v1alpha1/Rollout (rather than argoproj.io/*/Rollout)
# avoids the wildcard-version GVR lookup which Kyverno 1.11/chart 3.1.4
# reports as "unable to convert GVK to GVR" when CRD discovery hasn't caught up.

# Demo policy: every Rollout must carry app.kubernetes.io/version label
resource "kubectl_manifest" "kyverno_require_version_label" {
  yaml_body = <<-YAML
    apiVersion: kyverno.io/v1
    kind: ClusterPolicy
    metadata:
      name: require-version-label
      annotations:
        policies.kyverno.io/title: Require version label
        policies.kyverno.io/description: >-
          All Argo Rollout resources must carry the app.kubernetes.io/version
          label so platform tooling can track which version is running.
    spec:
      validationFailureAction: ${var.kyverno_enforcement_mode}
      rules:
        - name: check-version-label
          match:
            any:
              - resources:
                  kinds:
                    - argoproj.io/v1alpha1/Rollout
          validate:
            message: "Rollout must have label app.kubernetes.io/version"
            pattern:
              metadata:
                labels:
                  app.kubernetes.io/version: "?*"
  YAML

  depends_on = [helm_release.argo_rollouts]
}

# Demo policy: every Rollout pod template must have securityContext with runAsNonRoot
resource "kubectl_manifest" "kyverno_require_security_context" {
  yaml_body = <<-YAML
    apiVersion: kyverno.io/v1
    kind: ClusterPolicy
    metadata:
      name: require-security-context
      annotations:
        policies.kyverno.io/title: Require securityContext
        policies.kyverno.io/description: >-
          All Argo Rollout pod templates must set runAsNonRoot: true and
          allowPrivilegeEscalation: false to prevent privilege escalation attacks.
    spec:
      validationFailureAction: ${var.kyverno_enforcement_mode}
      rules:
        - name: check-pod-security-context
          match:
            any:
              - resources:
                  kinds:
                    - argoproj.io/v1alpha1/Rollout
          validate:
            message: "Rollout pod template must set securityContext.runAsNonRoot: true"
            pattern:
              spec:
                template:
                  spec:
                    securityContext:
                      runAsNonRoot: true
        - name: check-container-security-context
          match:
            any:
              - resources:
                  kinds:
                    - argoproj.io/v1alpha1/Rollout
          validate:
            message: "All containers must set allowPrivilegeEscalation: false"
            pattern:
              spec:
                template:
                  spec:
                    containers:
                      - securityContext:
                          allowPrivilegeEscalation: false
  YAML

  depends_on = [helm_release.argo_rollouts]
}
