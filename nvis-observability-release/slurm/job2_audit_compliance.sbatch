#!/bin/bash
#SBATCH --job-name=audit-compliance-sim
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=01:00:00
#SBATCH --output=/var/log/slurm/audit_compliance_%j.log

# =============================================================================
# NVIS Demo Job 2: Audit & Compliance Simulation
# Generates fake users, orgs, GPU consumption data, SSH logins,
# certificate events — all visible in Security Audit dashboard
# =============================================================================

TEXTFILE_DIR="/var/lib/node_exporter/textfile"
LOG_DIR="/var/log/nvis-demo"
OBSVM_IP="${OBSVM_IP:-10.127.28.83}"
CLUSTER="${CLUSTER_NAME:-cod-a100-2node}"
NODE=$(hostname)
JOB_ID=${SLURM_JOB_ID:-99902}

mkdir -p "$TEXTFILE_DIR" "$LOG_DIR"

push_log() {
  local level="$1" msg="$2" ts=$(date +%s%N)
  curl -sf -X POST "http://${OBSVM_IP}:3100/loki/api/v1/push" \
    -H "Content-Type: application/json" \
    -d "{\"streams\":[{\"stream\":{\"job\":\"audit\",\"node\":\"${NODE}\",\"cluster\":\"${CLUSTER}\",\"level\":\"${level}\"},\"values\":[[\"${ts}\",\"${msg}\"]]}]}" \
    > /dev/null 2>&1 || true
}

# Fake users — realistic research org structure
declare -A USERS=(
  ["dr.sarah.chen"]="NVIDIA-Research|8|A100|active"
  ["j.patel"]="Eli-Lilly-Oncology|16|A100|active"
  ["m.rodriguez"]="Eli-Lilly-Genomics|8|A100|active"
  ["t.nakamura"]="NVIDIA-DGX-Cloud|24|A100|active"
  ["a.okonkwo"]="Eli-Lilly-Chemistry|8|A100|idle"
  ["r.kim"]="NVIDIA-Research|16|A100|active"
  ["p.gupta"]="Eli-Lilly-Oncology|8|A100|active"
  ["l.martinez"]="External-Partner|4|A100|active"
  ["b.johnson"]="Eli-Lilly-IT|0|A100|suspicious"
  ["x.zhang"]="Unknown-Org|8|A100|warning"
)

echo "[$(date)] Starting Audit/Compliance simulation — Job ${JOB_ID}"
push_log "INFO" "Audit simulation started — generating ${#USERS[@]} users across 6 organizations"

# Generate user/GPU metrics
write_audit_metrics() {
  local ts=$(date +%s)
  local metric_file="${TEXTFILE_DIR}/audit_compliance.prom"

  {
    echo "# HELP nvis_demo_user_gpu_hours_total GPU hours consumed by user"
    echo "# TYPE nvis_demo_user_gpu_hours_total counter"
    echo "# HELP nvis_demo_user_active_jobs Active jobs per user"
    echo "# TYPE nvis_demo_user_active_jobs gauge"
    echo "# HELP nvis_demo_user_gpu_count GPUs currently allocated to user"
    echo "# TYPE nvis_demo_user_gpu_count gauge"
    echo "# HELP nvis_demo_suspicious_login Suspicious login event detected"
    echo "# TYPE nvis_demo_suspicious_login gauge"

    local total_gpus=0
    for user in "${!USERS[@]}"; do
      IFS='|' read -r org gpus gpu_type status <<< "${USERS[$user]}"
      local gpu_hours=$(( RANDOM % 500 + 50 ))
      local active=$(( RANDOM % 3 + 1 ))
      local jitter=$(( RANDOM % 3 - 1 ))
      local actual_gpus=$(( gpus + jitter ))
      [[ "$actual_gpus" -lt 0 ]] && actual_gpus=0
      total_gpus=$(( total_gpus + actual_gpus ))

      echo "nvis_demo_user_gpu_hours_total{user=\"${user}\",org=\"${org}\",cluster=\"${CLUSTER}\"} ${gpu_hours}"
      echo "nvis_demo_user_active_jobs{user=\"${user}\",org=\"${org}\",status=\"${status}\",cluster=\"${CLUSTER}\"} ${active}"
      echo "nvis_demo_user_gpu_count{user=\"${user}\",org=\"${org}\",cluster=\"${CLUSTER}\"} ${actual_gpus}"

      if [[ "$status" == "suspicious" ]] || [[ "$status" == "warning" ]]; then
        echo "nvis_demo_suspicious_login{user=\"${user}\",org=\"${org}\",cluster=\"${CLUSTER}\"} 1"
      fi
    done

    echo "# HELP nvis_demo_total_allocated_gpus Total GPUs allocated across all users"
    echo "# TYPE nvis_demo_total_allocated_gpus gauge"
    echo "nvis_demo_total_allocated_gpus{cluster=\"${CLUSTER}\"} ${total_gpus}"

    echo "# HELP nvis_demo_bcm_cert_expiry_days BCM certificate expiry in days"
    echo "# TYPE nvis_demo_bcm_cert_expiry_days gauge"
    echo "nvis_demo_bcm_cert_expiry_days{service=\"bcm-api\",cluster=\"${CLUSTER}\"} 42"
    echo "nvis_demo_bcm_cert_expiry_days{service=\"slurm-tls\",cluster=\"${CLUSTER}\"} 8"
    echo "nvis_demo_bcm_cert_expiry_days{service=\"grafana-tls\",cluster=\"${CLUSTER}\"} 180"
    echo "nvis_demo_bcm_cert_expiry_days{service=\"prometheus-tls\",cluster=\"${CLUSTER}\"} 365"

    echo "# HELP nvis_demo_failed_ssh_attempts Failed SSH login attempts"
    echo "# TYPE nvis_demo_failed_ssh_attempts counter"
    echo "nvis_demo_failed_ssh_attempts{node=\"${NODE}\",cluster=\"${CLUSTER}\"} $(( RANDOM % 20 + 5 ))"

  } > "$metric_file"
}

# Simulate SSH login events
generate_ssh_events() {
  local events=(
    "INFO|Accepted publickey for dr.sarah.chen from 10.141.0.50 port 22 — LDAP group: NVIDIA-Research"
    "INFO|Accepted publickey for j.patel from 10.141.0.51 port 22 — LDAP group: Eli-Lilly-Oncology"
    "WARN|Failed password for b.johnson from 192.168.1.100 port 22 — 3rd attempt"
    "WARN|Failed password for b.johnson from 192.168.1.100 port 22 — 4th attempt"
    "ERROR|SECURITY ALERT: b.johnson — 5 failed SSH attempts in 60s from 192.168.1.100"
    "WARN|Login from unknown org: x.zhang from 203.0.113.42 — org not in LDAP"
    "INFO|TLS cert expiry WARNING: slurm-tls expires in 8 days — renewal required"
    "ERROR|TLS cert CRITICAL: slurm-tls expires in 8 days — jobs may fail"
    "INFO|Accepted publickey for r.kim from 10.141.0.52 — LDAP group: NVIDIA-Research"
    "INFO|GPU quota exceeded: t.nakamura allocated 24 GPUs — limit is 20 (OVERRIDE by admin)"
    "WARN|External partner l.martinez accessing cluster — data exfil monitoring active"
  )

  for event in "${events[@]}"; do
    IFS='|' read -r level msg <<< "$event"
    push_log "$level" "$msg"
    sleep 3
  done
}

# Certificate events
generate_cert_events() {
  push_log "WARN" "BCM Certificate Audit: bcm-api expires in 42 days"
  push_log "ERROR" "CRITICAL: slurm-tls certificate expires in 8 days — Slurm jobs will fail after expiry"
  push_log "INFO" "Grafana TLS certificate valid — 180 days remaining"
  push_log "INFO" "Prometheus TLS certificate valid — 365 days remaining"
  push_log "WARN" "Certificate renewal workflow triggered for slurm-tls"
}

# Main loop
for round in $(seq 1 6); do
  echo "[$(date)] Round $round — updating audit metrics..."
  write_audit_metrics
  generate_ssh_events
  generate_cert_events

  # GPU consumption logs
  push_log "INFO" "GPU Audit Report: 10 active users, 100 GPUs allocated, 6 orgs"
  push_log "INFO" "Top consumer: t.nakamura (NVIDIA-DGX-Cloud) — 24 GPUs for 6h"
  push_log "INFO" "Org breakdown: Eli-Lilly 40 GPUs, NVIDIA 48 GPUs, External 4 GPUs, Unknown 8 GPUs"
  push_log "WARN" "Unknown-Org user x.zhang consuming 8 GPUs — not in approved org list"

  sleep 30
done

push_log "INFO" "Audit simulation complete — review Security Audit dashboard"
sleep 300
rm -f "${TEXTFILE_DIR}/audit_compliance.prom"
