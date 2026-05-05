variable "grafana_admin_password" {
  description = "Grafana admin password — override for non-demo environments"
  type        = string
  default     = "idp-demo"
  sensitive   = true
}
