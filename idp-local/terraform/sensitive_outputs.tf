output "argocd_admin_password" {
  description = "Argo CD initial admin password — retrieve with: terraform output -raw argocd_admin_password"
  value       = module.gitops.argocd_admin_password
  sensitive   = true
}
