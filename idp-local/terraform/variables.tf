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
  description = "Absolute path to the idp-local repository root (defaults to parent of the terraform/ directory)"
  type        = string
  default     = ""
}

# SOC2 CC7.1 — pass Enforce for production, Audit for development environments.
variable "kyverno_enforcement_mode" {
  description = "Kyverno validationFailureAction: Enforce blocks non-compliant resources; Audit only logs violations."
  type        = string
  default     = "Enforce"
}

# On Windows 11, HTTP.SYS or Docker Desktop's own proxy may hold port 80,
# causing all LoadBalancer traffic to return a Go 404 instead of reaching
# nginx.  Override to 8080 (and https_port to 8443) when port 80 is occupied:
#   terraform apply -var="http_port=8080" -var="https_port=8443"
# Or set HTTP_PORT=8080 before running install.sh — it passes the var automatically.
variable "http_port" {
  description = "Host HTTP port for the nginx-ingress LoadBalancer service (default 80; use 8080 when port 80 is occupied on Windows)."
  type        = number
  default     = 80
}

variable "https_port" {
  description = "Host HTTPS port for the nginx-ingress LoadBalancer service (default 443; use 8443 when port 443 is occupied on Windows)."
  type        = number
  default     = 443
}
