# Platform endpoints. URLs are rendered with the configured HTTP_PORT — when
# port 80 is used the suffix is omitted for clean URLs; otherwise ":<port>"
# is appended. install.sh prints the same set; these outputs are useful when
# you want to look them up after the fact via `terraform output`.

locals {
  # Suffix is empty for the standard port 80, ":<port>" otherwise.
  port_suffix = var.http_port == 80 ? "" : ":${var.http_port}"
}

output "backstage_url" {
  description = <<-EOT
    Backstage portal URL. Backstage runs on its OWN hostname (backstage.localhost,
    not localhost) because the official ghcr.io/backstage/backstage image is
    built with webpack publicPath='/' at compile time and cannot be served
    from a sub-path.

    Modern browsers / Windows 10+ / macOS / Linux usually resolve *.localhost
    to 127.0.0.1 automatically per RFC 6761 — no hosts file edit is required.

    If a corporate DNS resolver returns NXDOMAIN for backstage.localhost (so
    kubectl, curl, scripts can't reach it), add this line to your hosts file
    (Windows: %WINDIR%\System32\drivers\etc\hosts ; Linux/macOS:
    /etc/hosts) — admin/root required:

        127.0.0.1 backstage.localhost
  EOT
  value       = "http://backstage.localhost${local.port_suffix}"
}

output "argocd_url" {
  description = "Argo CD UI. Login: admin / <see argocd_admin_password>."
  value       = "http://localhost${local.port_suffix}/argocd"
}

output "grafana_url" {
  description = "Grafana UI. Login: admin / idp-demo."
  value       = "http://localhost${local.port_suffix}/grafana"
}

output "argo_rollouts_url" {
  description = "Argo Rollouts dashboard. Use /rollouts/<namespace> to scope to a namespace (e.g. /rollouts/svc-alpha)."
  value       = "http://localhost${local.port_suffix}/rollouts"
}

output "svc_alpha_v1_url" {
  description = "Demo service svc-alpha v1 endpoint."
  value       = "http://localhost${local.port_suffix}/svc-alpha/v1/hello"
}

output "svc_alpha_v2_url" {
  description = "Demo service svc-alpha v2 endpoint."
  value       = "http://localhost${local.port_suffix}/svc-alpha/v2/hello"
}

output "svc_beta_v1_url" {
  description = "Demo service svc-beta v1 endpoint."
  value       = "http://localhost${local.port_suffix}/svc-beta/v1/hello"
}

output "svc_beta_v2_url" {
  description = "Demo service svc-beta v2 endpoint."
  value       = "http://localhost${local.port_suffix}/svc-beta/v2/hello"
}
