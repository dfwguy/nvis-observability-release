#!/usr/bin/env bash
# =============================================================================
# NVIS Observability Suite — BCM Fallback Script
# Run this FROM the BCM head node when ObsVM cannot reach BCM directly.
#
# Usage: bash setup_bcm.sh --obsvm OBSVM_IP --cluster CLUSTER_NAME
# =============================================================================
set -euo pipefail

OBSVM_IP=""
CLUSTER_NAME="hpc-cluster"
BCM_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $*${NC}"; }
error()   { echo -e "${RED}❌ $*${NC}"; }

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --obsvm)   OBSVM_IP="$2"; shift 2 ;;
    --cluster) CLUSTER_NAME="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$OBSVM_IP" ]] && read -rp "ObsVM IP: " OBSVM_IP
[[ -z "$CLUSTER_NAME" ]] && read -rp "Cluster name [hpc-cluster]: " CLUSTER_NAME

log "BCM Fallback: deploying agents to all nodes from BCM head node"
log "ObsVM: $OBSVM_IP | Cluster: $CLUSTER_NAME"

# Discover nodes via cmsh
log "Discovering nodes via cmsh..."
CMSH=$(command -v cmsh 2>/dev/null || echo "/cm/local/apps/cmd/bin/cmsh")
NODE_IPS=()
while IFS= read -r line; do
  ip=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  status=$(echo "$line" | grep -oE '\[\s*UP\s*\]')
  [[ -n "$ip" && -n "$status" ]] && NODE_IPS+=("$ip")
done < <(sudo "$CMSH" -c "device list" 2>/dev/null)

success "Found ${#NODE_IPS[@]} UP nodes"

INSTALL_SCRIPT=$(cat << NODEINSTALL
#!/bin/bash
set -e
OBSVM="${OBSVM_IP}"
CLUSTER="${CLUSTER_NAME}"
NODE_IP=\$(hostname -I | awk '{print \$1}')

# node_exporter
if ! command -v node_exporter &>/dev/null; then
  cd /tmp
  wget -q https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
  tar xzf node_exporter-1.8.2.linux-amd64.tar.gz
  sudo cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
  sudo useradd -rs /bin/false node_exporter 2>/dev/null || true
  sudo mkdir -p /var/lib/node_exporter/textfile
  sudo tee /etc/systemd/system/node_exporter.service > /dev/null << 'SVC'
[Unit]
Description=Prometheus Node Exporter
After=network.target
[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile --collector.cpu.info --collector.netdev --web.listen-address=:9100
Restart=on-failure
[Install]
WantedBy=multi-user.target
SVC
  sudo systemctl daemon-reload
  sudo systemctl enable --now node_exporter
fi

# Grafana Alloy
if ! command -v alloy &>/dev/null; then
  sudo mkdir -p /etc/apt/keyrings
  wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
  sudo apt-get update -qq && sudo apt-get install -y -qq alloy
fi

sudo tee /etc/alloy/config.alloy > /dev/null << ALLOY
prometheus.remote_write "obsvm" { endpoint { url = "http://\${OBSVM}:9090/api/v1/write" } }
prometheus.scrape "node" {
  targets = [{ __address__ = "localhost:9100", cluster = "\${CLUSTER}", node = env("HOSTNAME") }]
  forward_to = [prometheus.remote_write.obsvm.receiver]
  scrape_interval = "15s"
  job_name = "node-exporter"
}
loki.write "obsvm" { endpoint { url = "http://\${OBSVM}:3100/loki/api/v1/push" } }
local.file_match "syslog" {
  path_targets = [{ __path__ = "/var/log/syslog", job = "syslog", cluster = "\${CLUSTER}", node = env("HOSTNAME") }]
}
loki.source.file "syslog" { targets = local.file_match.syslog.targets; forward_to = [loki.write.obsvm.receiver] }
ALLOY

sudo systemctl enable --now alloy
echo "DONE: \$(hostname) (\$NODE_IP)"
NODEINSTALL
)

# Deploy to all nodes
success_count=0
fail_count=0
for node_ip in "${NODE_IPS[@]}"; do
  log "  Deploying to $node_ip..."
  result=$(ssh $BCM_SSH_OPTS "root@$node_ip" "bash -s" <<< "$INSTALL_SCRIPT" 2>&1) || true
  if echo "$result" | grep -q "DONE:"; then
    success "  $node_ip ✅"
    ((success_count++)) || true
  else
    warn "  $node_ip ❌ — check /tmp/nvis-node-${node_ip}.log"
    echo "$result" > "/tmp/nvis-node-${node_ip}.log"
    ((fail_count++)) || true
  fi
done

echo ""
success "BCM deployment complete: $success_count success, $fail_count failed"
log "Return to ObsVM ($OBSVM_IP) and continue with: bash setup.sh"
