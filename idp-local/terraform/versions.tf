terraform {
  required_version = ">= 1.6.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    # Kubernetes provider 2.38.0 was observed to crash with a Go runtime stack
    # fault during parallel namespace creates on Windows. Pin to the 2.30.x
    # series (which has been stable on Docker Desktop K8s) as a safe upper bound.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
