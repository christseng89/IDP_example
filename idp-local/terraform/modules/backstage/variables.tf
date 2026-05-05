variable "project_root" {
  description = "Absolute path to the idp-local repository root"
  type        = string
}

variable "argocd_admin_password" {
  description = "Argo CD initial admin password (sensitive)"
  type        = string
  sensitive   = true
}
