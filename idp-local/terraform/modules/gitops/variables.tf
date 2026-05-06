variable "project_root" {
  description = "Absolute path to the idp-local repository root (Git Bash form, e.g. /c/Users/chris/IDP_example/idp-local)"
  type        = string
}

# Docker Desktop on Windows exposes the host filesystem to K8s pods at
# /run/desktop/mnt/host/<drive>/... Override this if you are running Docker
# Desktop on macOS (use "/host_mnt") or a custom mount layout.
variable "host_repo_mount_prefix" {
  description = "Prefix prepended to project_root to form the in-pod hostPath for the Argo CD repo-server"
  type        = string
  default     = "/run/desktop/mnt/host"
}

# SOC2 CC7.1 — controls whether Kyverno blocks (Enforce) or only logs (Audit)
# the Rollout-targeted ClusterPolicies that this module creates.
variable "kyverno_enforcement_mode" {
  description = "Kyverno validationFailureAction: Enforce blocks non-compliant resources; Audit only logs violations."
  type        = string
  default     = "Enforce"

  validation {
    condition     = contains(["Audit", "Enforce"], var.kyverno_enforcement_mode)
    error_message = "kyverno_enforcement_mode must be Audit or Enforce."
  }
}
