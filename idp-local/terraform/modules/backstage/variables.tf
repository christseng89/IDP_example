variable "project_root" {
  description = "Absolute path to the idp-local repository root"
  type        = string
}

variable "argocd_admin_password" {
  description = "Argo CD initial admin password (sensitive)"
  type        = string
  sensitive   = true
}

variable "http_port" {
  description = "Host HTTP port for nginx-ingress (used in app-config.yaml baseUrl)"
  type        = number
  default     = 80
}
