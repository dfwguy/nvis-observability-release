variable "grafana_url" {
  description = "Grafana base URL"
  type        = string
  default     = "http://localhost:3000"
}

variable "grafana_user" {
  description = "Grafana admin username"
  type        = string
  default     = "admin"
}

variable "grafana_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
  default     = "nvis2024"
}

variable "prometheus_url" {
  description = "Prometheus URL reachable from Grafana container"
  type        = string
  default     = "http://nvis-prometheus:9090"
}

variable "loki_url" {
  description = "Loki URL reachable from Grafana container"
  type        = string
  default     = "http://nvis-loki:3100"
}

variable "victoriametrics_url" {
  description = "VictoriaMetrics URL reachable from Grafana container"
  type        = string
  default     = "http://nvis-victoriametrics:8428"
}
