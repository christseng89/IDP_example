locals {
  project_root = var.project_root != "" ? var.project_root : abspath("${path.module}/..")
}

module "platform" {
  source     = "./modules/platform"
  http_port  = var.http_port
  https_port = var.https_port
}

module "observability" {
  source = "./modules/observability"

  depends_on = [module.platform]
}

module "gitops" {
  source                   = "./modules/gitops"
  project_root             = local.project_root
  kyverno_enforcement_mode = var.kyverno_enforcement_mode

  depends_on = [module.platform]
}

module "backstage" {
  source       = "./modules/backstage"
  project_root = local.project_root

  argocd_admin_password = module.gitops.argocd_admin_password

  depends_on = [module.gitops, module.observability]
}
