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
    # Template-render so the configured baseUrl matches the actual host port.
    # Without this, Backstage's React Router compares against a hardcoded
    # baseUrl ("http://localhost/backstage" — no port) and rejects every
    # route as not-found, rendering its own 404 page even though the request
    # reached the pod successfully. The "$${VAR}" form is the templatefile()
    # escape syntax — it passes "${VAR}" through to the rendered file so
    # Backstage's own env-var substitution still works for ARGOCD_ADMIN_PASSWORD.
    "app-config.yaml" = templatefile(
      "${var.project_root}/backstage/app-config.yaml",
      {
        base_url   = "http://localhost:${var.http_port}/backstage"
        # CORS origin must be scheme://host:port WITHOUT path. Setting it to
        # the full base_url (with /backstage suffix) silently breaks POSTs
        # from the frontend to the backend, including the guest auth flow
        # — Chrome rejects the response, frontend errors out, React Router
        # falls through to NotFoundPage rendering "dropped the mic" 404.
        cors_origin = "http://localhost:${var.http_port}"
      }
    )
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
        registry: ""
        repository: idp-backstage
        tag: latest
        # Backstage chart 1.9.4's values.schema.json restricts pullPolicy to
        # "Always" or "IfNotPresent" — "Never" is rejected with a schema
        # error. IfNotPresent is functionally equivalent here: Docker Desktop
        # shares its image daemon with Kubernetes, and scripts/build-backstage.sh
        # always builds idp-backstage:latest before this Helm release runs, so
        # the image is present and kubelet skips the pull.
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

      # The Backstage chart 1.9.4 deployment template hardcodes
      #   command: ["node", "packages/backend"]
      # which OVERRIDES whatever CMD is set in the Docker image. With modern
      # @backstage/cli, packages/backend has no index.js and its package.json
      # has no "main" field — Node fails with:
      #   Error: Cannot find module '/app/packages/backend'
      # Override command here to point at the compiled entry directly. Patching
      # the Dockerfile alone is not sufficient: Kubernetes uses the chart's
      # command, not the image's CMD.
      command:
        - "node"
        - "packages/backend/dist/index.cjs.js"

      args:
        - "--config"
        - "/app/app-config.yaml"

    # Chart's built-in ingress only supports root path "/" — we create our own
    # below so that NGINX can rewrite /backstage/* to / for the Backstage app.
    ingress:
      enabled: false

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


# Custom Ingress for Backstage with regex path + rewrite (the chart's
# built-in ingress can only mount at "/").
resource "kubectl_manifest" "backstage_ingress" {
  yaml_body = <<-YAML
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: backstage
      namespace: backstage
      annotations:
        nginx.ingress.kubernetes.io/use-regex: "true"
        nginx.ingress.kubernetes.io/rewrite-target: /$2
        # Redirect /backstage (no trailing slash) to /backstage/ so the SPA
        # asset paths (/backstage/static/...) resolve correctly.
        nginx.ingress.kubernetes.io/configuration-snippet: |
          rewrite ^/backstage$ /backstage/ permanent;
    spec:
      ingressClassName: nginx
      rules:
        - host: localhost
          http:
            paths:
              - path: /backstage(/|$)(.*)
                pathType: ImplementationSpecific
                backend:
                  service:
                    name: backstage
                    port:
                      number: 7007
  YAML

  depends_on = [helm_release.backstage]
}
