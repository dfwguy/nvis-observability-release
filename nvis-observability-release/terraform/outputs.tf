output "single_job_stats_url" {
  value = "${var.grafana_url}/d/single-job-stats-cod"
}
output "prometheus_uid" {
  value = grafana_data_source.prometheus.uid
}
output "loki_uid" {
  value = grafana_data_source.loki.uid
}
