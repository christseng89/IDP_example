variable "http_port" {
  description = "Host HTTP port for the nginx-ingress LoadBalancer service."
  type        = number
  default     = 80
}

variable "https_port" {
  description = "Host HTTPS port for the nginx-ingress LoadBalancer service."
  type        = number
  default     = 443
}
