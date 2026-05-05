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

resource "kubernetes_namespace" "backstage" {
  metadata { name = "backstage" }
}

# ServiceAccount for the Kubernetes plugin (read access to cluster)
resource "kubernetes_service_account" "backstage" {
  metadata {
    name      = "backstage"
    namespace = kubernetes_namespace.backstage.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "backstage_reader" {
  metadata { name = "backstage-reader" }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "namespaces", "events"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["rollouts", "analysisruns", "analysistemplates"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "backstage_reader" {
  metadata { name = "backstage-reader" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.backstage_reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.backstage.metadata[0].name
    namespace = kubernetes_namespace.backstage.metadata[0].name
  }
}

# Mount app-config.yaml and catalog as ConfigMaps
resource "kubernetes_config_map" "backstage_app_config" {
  metadata {
    name      = "backstage-app-config"
    namespace = kubernetes_namespace.backstage.metadata[0].name
  }

  data = {
    "app-config.yaml" = file("${var.project_root}/backstage/app-config.yaml")
  }
}

resource "kubernetes_config_map" "backstage_catalog" {
  metadata {
    name      = "backstage-catalog"
    namespace = kubernetes_namespace.backstage.metadata[0].name
  }

  data = {
    "all.yaml"               = file("${var.project_root}/backstage/catalog/all.yaml")
    "svc-alpha-catalog.yaml" = file("${var.project_root}/backstage/catalog/svc-alpha-catalog.yaml")
    "svc-beta-catalog.yaml"  = file("${var.project_root}/backstage/catalog/svc-beta-catalog.yaml")
  }
}

resource "kubernetes_config_map" "backstage_scaffolder" {
  metadata {
    name      = "backstage-scaffolder"
    namespace = kubernetes_namespace.backstage.metadata[0].name
  }

  data = {
    "template.yaml" = file("${var.project_root}/backstage/scaffolder-templates/new-service/template.yaml")
  }
}

# ServiceAccount token for the Kubernetes plugin — referenced in app-config.yaml
resource "kubernetes_secret" "backstage_k8s_token" {
  metadata {
    name      = "backstage-k8s-token"
    namespace = kubernetes_namespace.backstage.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.backstage.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_secret" "backstage_argocd" {
  metadata {
    name      = "backstage-argocd"
    namespace = kubernetes_namespace.backstage.metadata[0].name
  }

  data = {
    ARGOCD_ADMIN_PASSWORD = var.argocd_admin_password
  }
}

resource "helm_release" "backstage" {
  name       = "backstage"
  repository = "https://backstage.github.io/charts"
  chart      = "backstage"
  version    = "1.9.4"
  namespace  = kubernetes_namespace.backstage.metadata[0].name

  values = [<<-YAML
    backstage:
      image:
        registry: ghcr.io
        repository: backstage/backstage
        tag: latest
        pullPolicy: IfNotPresent

      resources:
        requests:
          cpu: 200m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 512Mi

      extraEnvVars:
        - name: ARGOCD_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: backstage-argocd
              key: ARGOCD_ADMIN_PASSWORD

      extraVolumes:
        - name: app-config
          configMap:
            name: backstage-app-config
        - name: catalog
          configMap:
            name: backstage-catalog
        - name: scaffolder
          configMap:
            name: backstage-scaffolder

      extraVolumeMounts:
        - name: app-config
          mountPath: /app/app-config.yaml
          subPath: app-config.yaml
          readOnly: true
        - name: catalog
          mountPath: /backstage/catalog
          readOnly: true
        - name: scaffolder
          mountPath: /backstage/scaffolder-templates/new-service/template.yaml
          subPath: template.yaml
          readOnly: true

      args:
        - "--config"
        - "/app/app-config.yaml"

    ingress:
      enabled: true
      className: nginx
      annotations:
        nginx.ingress.kubernetes.io/rewrite-target: /$2
      host: localhost
      path: /backstage(/|$)(.*)
      pathType: Prefix

    serviceAccount:
      name: backstage
      create: false
  YAML
  ]

  wait    = true
  timeout = 600

  depends_on = [
    kubernetes_config_map.backstage_app_config,
    kubernetes_config_map.backstage_catalog,
    kubernetes_config_map.backstage_scaffolder,
    kubernetes_secret.backstage_argocd,
    kubernetes_secret.backstage_k8s_token,
    kubernetes_cluster_role_binding.backstage_reader,
  ]
}
