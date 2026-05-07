terraform {
  required_version = ">= 1.6.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    # Kubernetes provider 2.38.0 was observed to crash with a Go runtime stack
    # fault ("Plugin did not respond") during parallel namespace creates on
    # Windows / Docker Desktop. Pin to 2.30.x — the last series confirmed stable
    # for this stack. The pessimistic constraint "~> 2.30.0" expands to
    # ">= 2.30.0, < 2.31.0", which actually excludes 2.38.0 (the prior
    # "~> 2.25" allowed any 2.x and let 2.38.0 slip through).
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
