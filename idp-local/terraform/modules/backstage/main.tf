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
        # Backstage serves on its OWN hostname (backstage.localhost) instead
        # of a sub-path. The official ghcr.io/backstage/backstage image is
        # built with webpack publicPath='/' at compile time, so the SPA's
        # HTML hardcodes absolute paths (/static/..., /manifest.json,
        # /vendor.css). Mounting at /backstage and stripping the prefix
        # in nginx breaks every one of those static assets — they 404
        # because the browser fetches them from the root of localhost.
        # Putting Backstage on its own host means the frontend can keep
        # using absolute paths and they all resolve correctly.
        #
        # *.localhost resolves to 127.0.0.1 automatically per RFC 6761
        # in Chrome/Firefox/Safari/modern Windows, so no hosts file edit
        # is required. If your resolver disagrees, add this to hosts:
        #   127.0.0.1 backstage.localhost
        base_url    = "http://backstage.localhost:${var.http_port}"
        cors_origin = "http://backstage.localhost:${var.http_port}"
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

resource "kubernetes_secret" "backstage_argocd" {
  metadata {
    name      = "backstage-argocd"
    namespace = kubernetes_namespace.backstage.metadata[0].name
  }

  data = {
    ARGOCD_ADMIN_PASSWORD = var.argocd_admin_password
  }
}


# ── Postgres backing store for Backstage ─────────────────────────────────────
# Replaces the previous in-memory SQLite (better-sqlite3 ":memory:") so
# Backstage data — catalog entities, locations, scaffolder runs, auth tokens
# — survives backend restarts. emptyDir storage is fine for the demo: the
# catalog itself is reloaded from backstage-catalog ConfigMap on every start,
# so losing pgdata only forces Backstage to re-process the catalog.

resource "kubernetes_secret" "backstage_postgres" {
  metadata {
    name      = "backstage-postgres"
    namespace = kubernetes_namespace.backstage.metadata[0].name
  }
  data = {
    POSTGRES_USER     = "backstage"
    POSTGRES_PASSWORD = "demo-password-rotate-for-prod"
    POSTGRES_DB       = "backstage"
  }
}

resource "kubernetes_deployment" "backstage_postgres" {
  metadata {
    name      = "backstage-postgres"
    namespace = kubernetes_namespace.backstage.metadata[0].name
    labels    = { app = "backstage-postgres" }
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }   # avoid two pods writing to the same emptyDir
    selector { match_labels = { app = "backstage-postgres" } }

    template {
      metadata { labels = { app = "backstage-postgres" } }
      spec {
        container {
          name  = "postgres"
          image = "postgres:16-alpine"
          image_pull_policy = "IfNotPresent"
          port {
            name           = "postgres"
            container_port = 5432
          }
          env_from {
            secret_ref { name = kubernetes_secret.backstage_postgres.metadata[0].name }
          }
          # subPath lets postgres own a sub-directory of the emptyDir mount —
          # required because the postgres image's init scripts reject mounts
          # that aren't empty (and emptyDir contains a "lost+found" entry on
          # some kernels).
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
            sub_path   = "pgdata"
          }
          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
          readiness_probe {
            exec { command = ["pg_isready", "-U", "backstage", "-d", "backstage"] }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            exec { command = ["pg_isready", "-U", "backstage", "-d", "backstage"] }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }
        volume {
          name = "data"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "backstage_postgres" {
  metadata {
    name      = "backstage-postgres"
    namespace = kubernetes_namespace.backstage.metadata[0].name
  }
  spec {
    selector = { app = "backstage-postgres" }
    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
    }
  }
}

resource "helm_release" "backstage" {
  name       = "backstage"
  repository = "https://backstage.github.io/charts"
  chart      = "backstage"
  version    = "1.9.4"
  namespace  = kubernetes_namespace.backstage.metadata[0].name

  values = [<<-YAML
    # Use the OFFICIAL Backstage image from the chart (ghcr.io/backstage/backstage,
    # tag defaults to the chart's appVersion). This replaces the previous
    # self-built idp-backstage:latest image, which kept hitting node module
    # resolution / CMD-override issues that left the pod in CrashLoopBackOff.
    #
    # Chart 1.9.4 templates the image as:
    #   {{ .Values.backstage.image.registry }}/{{ .Values.backstage.image.repository }}:{{ .Values.backstage.image.tag | default .Chart.AppVersion }}
    # so registry MUST be a separate field — embedding "ghcr.io/" in repository
    # produces "ghcr.io/ghcr.io/..." which 404s.
    backstage:
      image:
        registry: ghcr.io
        repository: backstage/backstage
        # Pin to the chart's released appVersion so a chart bump doesn't
        # silently change the binary. install.sh pre-pulls this exact tag
        # via GHCR_MIRROR (default ghcr.m.daocloud.io) and retags it to the
        # canonical reference, so kubelet finds it locally.
        tag: "1.27.0"
        pullPolicy: IfNotPresent

      resources:
        requests:
          cpu: 200m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 1Gi

      # Inject runtime secrets the official Backstage image needs at startup:
      # - ARGOCD_ADMIN_PASSWORD: substituted into app-config.yaml's argocd
      #   stanza (currently no-op because the official image lacks the argocd
      #   plugin, but kept so the catalog config remains valid).
      # - POSTGRES_PASSWORD: substituted into app-config.yaml's
      #   backend.database.connection.password — the in-cluster Postgres
      #   instance defined above is reached via the backstage-postgres
      #   ClusterIP service.
      extraEnvVars:
        - name: ARGOCD_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: backstage-argocd
              key: ARGOCD_ADMIN_PASSWORD
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: backstage-postgres
              key: POSTGRES_PASSWORD

      # Mount our IDP app-config + catalog + scaffolder template into the
      # official image. The image bundles a default app-config.yaml; we
      # override it via --config (chart-default args) pointing at our mount.
      extraAppConfig:
        - filename: app-config.yaml
          configMapRef: backstage-app-config

      extraVolumes:
        - name: catalog
          configMap:
            name: backstage-catalog
        - name: scaffolder
          configMap:
            name: backstage-scaffolder

      extraVolumeMounts:
        - name: catalog
          mountPath: /backstage/catalog
          readOnly: true
        - name: scaffolder
          mountPath: /backstage/scaffolder-templates/new-service/template.yaml
          subPath: template.yaml
          readOnly: true

      # NOTE: deliberately NO `command:` / `args:` overrides. The official
      # image has the correct entrypoint baked in (node packages/backend ...);
      # overriding them is what broke the previous self-built image.

    # Chart's built-in ingress only supports root path "/" — we create our own
    # below so NGINX can rewrite /backstage/* to / for the Backstage SPA.
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
    kubernetes_cluster_role_binding.backstage_reader,
    kubernetes_secret.backstage_postgres,
    kubernetes_deployment.backstage_postgres,
    kubernetes_service.backstage_postgres,
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
    spec:
      ingressClassName: nginx
      rules:
        # backstage.localhost — RFC 6761 reserves *.localhost for loopback,
        # so modern OSes resolve it to 127.0.0.1 without a hosts entry.
        # If your resolver disagrees, add: 127.0.0.1 backstage.localhost
        # to %WINDIR%\System32\drivers\etc\hosts (admin required).
        # No rewrite-target / no regex / no configuration-snippet — the
        # SPA's hardcoded absolute paths (/static/*, /manifest.json) resolve
        # cleanly when Backstage owns the entire host.
        - host: backstage.localhost
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: backstage
                    port:
                      number: 7007
  YAML

  depends_on = [helm_release.backstage]
}
