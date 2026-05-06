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

# SOC2 CC7.1 — pass Enforce for production, Audit for development environments.
variable "kyverno_enforcement_mode" {
  description = "Kyverno validationFailureAction: Enforce blocks non-compliant resources; Audit only logs violations."
  type        = string
  default     = "Enforce"
}
