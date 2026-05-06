module "platform" {
  source = "./modules/platform"

  kyverno_enforcement_mode = var.kyverno_enforcement_mode
}

module "observability" {
  source = "./modules/observability"

  depends_on = [module.platform]
}

module "gitops" {
  source       = "./modules/gitops"
  project_root = var.project_root

  depends_on = [module.platform]
}

module "backstage" {
  source       = "./modules/backstage"
  project_root = var.project_root

  argocd_admin_password = module.gitops.argocd_admin_password

  depends_on = [module.gitops, module.observability]
}
