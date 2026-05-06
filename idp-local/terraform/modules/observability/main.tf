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

resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "57.2.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [<<-YAML
    prometheus:
      prometheusSpec:
        resources:
          requests:
            cpu: 200m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        # Pick up ServiceMonitors from all namespaces
        serviceMonitorSelectorNilUsesHelmValues: false
        serviceMonitorSelector: {}
        serviceMonitorNamespaceSelector: {}
        retention: 6h
        storageSpec:
          volumeClaimTemplate:
            spec:
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 2Gi

    alertmanager:
      alertmanagerSpec:
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi

    grafana:
      # Use a Docker Hub mirror to work around DNS hijacking / GFW blocking docker.io
      image:
        registry: docker.m.daocloud.io
        repository: grafana/grafana
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 200m
          memory: 256Mi
      adminPassword: "${var.grafana_admin_password}"
      ingress:
        enabled: true
        ingressClassName: nginx
        path: /grafana
        pathType: Prefix
        # No rewrite-target annotation — Grafana handles the /grafana sub-path
        # itself via grafana.ini (serve_from_sub_path + root_url) below.
        hosts:
          - localhost
      grafana.ini:
        server:
          root_url: "%(protocol)s://%(domain)s/grafana"
          serve_from_sub_path: true

    # Reduce footprint for single-node Docker Desktop
    kubeStateMetrics:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi

    # Disabled on Docker Desktop — host root filesystem is not exposed as
    # shared/slave mount, which causes node-exporter to CrashLoopBackOff.
    nodeExporter:
      enabled: false

    prometheusOperator:
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 200m
          memory: 256Mi
  YAML
  ]

  wait    = true
  timeout = 1200
}

# Pre-built dashboard for canary traffic split visualisation
resource "kubectl_manifest" "idp_services_dashboard" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: idp-services-dashboard
      namespace: monitoring
      labels:
        grafana_dashboard: "1"
    data:
      idp-services.json: |
        {
          "title": "IDP Services — Canary Traffic Split",
          "uid": "idp-services",
          "schemaVersion": 38,
          "panels": [
            {
              "type": "timeseries",
              "title": "Request Rate by Version (svc-alpha)",
              "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
              "targets": [
                {
                  "expr": "sum(rate(http_requests_total{service='svc-alpha'}[1m])) by (version)",
                  "legendFormat": "{{version}}"
                }
              ]
            },
            {
              "type": "timeseries",
              "title": "Request Rate by Version (svc-beta)",
              "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
              "targets": [
                {
                  "expr": "sum(rate(http_requests_total{service='svc-beta'}[1m])) by (version)",
                  "legendFormat": "{{version}}"
                }
              ]
            },
            {
              "type": "timeseries",
              "title": "Error Rate by Service",
              "gridPos": {"h": 8, "w": 24, "x": 0, "y": 8},
              "targets": [
                {
                  "expr": "sum(rate(http_requests_total{status=~'5..'}[1m])) by (service) / sum(rate(http_requests_total[1m])) by (service)",
                  "legendFormat": "{{service}} error rate"
                }
              ]
            }
          ]
        }
  YAML

  depends_on = [helm_release.kube_prometheus_stack]
}
