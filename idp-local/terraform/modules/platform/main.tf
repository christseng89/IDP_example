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

# NOTE: The two Kyverno ClusterPolicies that target argoproj.io/Rollout used to
# live here, but they fail at admission time because Kyverno tries to resolve
# the Rollout GVK during policy creation — and the Rollout CRD is installed by
# the gitops module, not this one. They have been moved to modules/gitops where
# they can declare a depends_on against helm_release.argo_rollouts.

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

  # The validating admission webhook intermittently fails to respond on
  # Docker Desktop first installs ("context deadline exceeded" within 10 s).
  # The webhook only validates Ingress *schema* — schema errors here are
  # already caught client-side, so disabling it for a local demo loses no
  # protection and removes the install-time race.
  set {
    name  = "controller.admissionWebhooks.enabled"
    value = "false"
  }

  # Docker Desktop assigns EXTERNAL-IP=localhost to LoadBalancer services and
  # routes traffic through the VM transparently — hostNetwork is not needed.
  # hostNetwork caused orphan nginx processes to hold port 80 in the VM's
  # network namespace after pod termination, making every subsequent pod crash
  # with "port 80 is already in use" and blocking scheduler placement.
  set {
    name  = "controller.replicaCount"
    value = "1"
  }

  # Recreate (not RollingUpdate) ensures the old pod releases its ports before
  # the replacement pod starts — safe with replicaCount=1 on a single node.
  set {
    name  = "controller.updateStrategy.type"
    value = "Recreate"
  }

  wait    = true
  # 600 s: registry.k8s.io image pull on a slow/mirrored network can take
  # 3-5 minutes; the original 300 s caused "context deadline exceeded" before
  # the pod ever reached Running.
  timeout = 600
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

# Expose the Kyverno helm release as an output so other modules (e.g. gitops)
# can declare an explicit depends_on against it when creating ClusterPolicies.
output "kyverno_release_name" {
  value = helm_release.kyverno.name
}
