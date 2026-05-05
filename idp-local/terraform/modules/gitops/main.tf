terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
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
          nginx.ingress.kubernetes.io/rewrite-target: /$2
          nginx.ingress.kubernetes.io/ssl-passthrough: "false"
      extraArgs:
        - --insecure
        - --rootpath=/argocd

    repoServer:
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 200m
          memory: 256Mi

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
  version    = "2.35.1"
  namespace  = kubernetes_namespace.argo_rollouts.metadata[0].name

  values = [<<-YAML
    controller:
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 200m
          memory: 256Mi

    dashboard:
      enabled: true
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
      ingress:
        enabled: true
        ingressClassName: nginx
        hosts:
          - localhost
        paths:
          - /rollouts
        pathType: Prefix
        annotations:
          nginx.ingress.kubernetes.io/rewrite-target: /$2
  YAML
  ]

  wait    = true
  timeout = 300

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
resource "kubectl_manifest" "argocd_app_svc_alpha" {
  yaml_body = templatefile("${path.module}/../../templates/argocd-app.yaml.tpl", {
    app_name   = "svc-alpha"
    chart_path = "${var.project_root}/charts/svc-alpha"
    namespace  = "svc-alpha"
  })

  depends_on = [helm_release.argo_rollouts, kubernetes_namespace.svc_alpha]
}

# Argo CD Application — svc-beta
resource "kubectl_manifest" "argocd_app_svc_beta" {
  yaml_body = templatefile("${path.module}/../../templates/argocd-app.yaml.tpl", {
    app_name   = "svc-beta"
    chart_path = "${var.project_root}/charts/svc-beta"
    namespace  = "svc-beta"
  })

  depends_on = [helm_release.argo_rollouts, kubernetes_namespace.svc_beta]
}
