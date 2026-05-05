variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubernetes context to use (Docker Desktop)"
  type        = string
  default     = "docker-desktop"
}

variable "project_root" {
  description = "Absolute path to the idp-local repository root"
  type        = string
}
