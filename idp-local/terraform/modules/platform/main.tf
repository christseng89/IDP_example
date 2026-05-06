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

# SOC2 CC7.1 — policy enforcement mode.
# Default is Enforce (blocks non-compliant resources).
# Set to Audit in development environments to log-only.
variable "kyverno_enforcement_mode" {
  description = "Kyverno validationFailureAction: Enforce blocks non-compliant resources; Audit only logs violations."
  type        = string
  default     = "Enforce"

  validation {
    condition     = contains(["Audit", "Enforce"], var.kyverno_enforcement_mode)
    error_message = "kyverno_enforcement_mode must be Audit or Enforce."
  }
}

resource "kubernetes_namespace" "ingress_nginx" {
  metadata { name = "ingress-nginx" }
}

resource "kubernetes_namespace" "kyverno" {
  metadata { name = "kyverno" }
}

resource "kubernetes_namespace" "crossplane_system" {
  metadata { name = "crossplane-system" }
}

resource "helm_release" "nginx_ingress" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.9.1"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name

  set {
    name  = "controller.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = "200m"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "256Mi"
  }

  wait    = true
  timeout = 300
}

resource "helm_release" "kyverno" {
  name       = "kyverno"
  repository = "https://kyverno.github.io/kyverno"
  chart      = "kyverno"
  version    = "3.1.4"
  namespace  = kubernetes_namespace.kyverno.metadata[0].name

  set {
    name  = "admissionController.replicas"
    value = "1"
  }
  set {
    name  = "backgroundController.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "cleanupController.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "reportsController.resources.requests.memory"
    value = "64Mi"
  }

  wait    = true
  timeout = 300
}

resource "helm_release" "crossplane" {
  name       = "crossplane"
  repository = "https://charts.crossplane.io/stable"
  chart      = "crossplane"
  version    = "1.15.0"
  namespace  = kubernetes_namespace.crossplane_system.metadata[0].name

  set {
    name  = "resourcesCrossplane.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resourcesCrossplane.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "resourcesCrossplane.limits.cpu"
    value = "200m"
  }
  set {
    name  = "resourcesCrossplane.limits.memory"
    value = "256Mi"
  }

  wait    = true
  timeout = 300
}

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
                    - argoproj.io/*/Rollout
          validate:
            message: "Rollout must have label app.kubernetes.io/version"
            pattern:
              metadata:
                labels:
                  app.kubernetes.io/version: "?*"
  YAML

  depends_on = [helm_release.kyverno]
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
                    - argoproj.io/*/Rollout
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
                    - argoproj.io/*/Rollout
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

  depends_on = [helm_release.kyverno]
}
