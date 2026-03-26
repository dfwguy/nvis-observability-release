terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.0"
    }
  }
}

provider "grafana" {
  url  = var.grafana_url
  auth = "${var.grafana_user}:${var.grafana_password}"
}

resource "grafana_folder" "nvis" {
  title = "NVIS Observability"
  uid   = "nvis-observability"
}

resource "grafana_data_source" "prometheus" {
  name       = "Prometheus"
  type       = "prometheus"
  uid        = "nvis-prometheus"
  url        = var.prometheus_url
  is_default = true
  json_data_encoded = jsonencode({
    timeInterval = "15s"
  })
}

resource "grafana_data_source" "loki" {
  name = "Loki"
  type = "loki"
  uid  = "nvis-loki"
  url  = var.loki_url
  json_data_encoded = jsonencode({
    maxLines = 5000
  })
}

resource "grafana_data_source" "victoriametrics" {
  name = "VictoriaMetrics"
  type = "prometheus"
  uid  = "nvis-victoriametrics"
  url  = var.victoriametrics_url
  json_data_encoded = jsonencode({
    timeInterval = "15s"
  })
}

locals {
  dashboards = {
    "cluster-overview" = "dashboards/01_cluster_overview.json"
    "gpu-health"       = "dashboards/02_gpu_health.json"
    "single-job-stats" = "dashboards/03_single_job_stats.json"
    "node-deep-dive"   = "dashboards/04_node_deep_dive.json"
    "network-fabric"   = "dashboards/05_network_fabric.json"
    "impact-analysis"  = "dashboards/06_impact_analysis.json"
    "security-audit"   = "dashboards/07_security_audit.json"
    "live-topology"    = "dashboards/08_live_topology.json"
    "log-explorer"     = "dashboards/09_log_explorer.json"
    "demo-home"        = "dashboards/10_demo_home.json"
    "executive"        = "dashboards/nvis-executive.json"
    "cio"              = "dashboards/nvis-superpod-cio.json"
  }
}

resource "grafana_dashboard" "nvis" {
  for_each    = local.dashboards
  folder      = grafana_folder.nvis.uid
  config_json = file("${path.module}/${each.value}")
  overwrite   = true

  depends_on = [
    grafana_data_source.prometheus,
    grafana_data_source.loki
  ]
}
