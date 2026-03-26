#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# fix-node-exporter.sh — Install/fix node_exporter on ALL GPU nodes
#
# Run from ObsVM:  bash fix-node-exporter.sh
#
# Strategy (tried in order):
#   1. Already running → skip
#   2. apt/dnf package install (prometheus-node-exporter or node_exporter)
#   3. Copy binary from ObsVM if it exists locally
#   4. wget from GitHub (may fail if no internet)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/.nvis-config" ]] && source "${SCRIPT_DIR}/.nvis-config"
[[ -f "${SCRIPT_DIR}/.nvis-nodes"  ]] && source "${SCRIPT_DIR}/.nvis-nodes"

OBSVM_IP="${OBSVM_IP:?ERROR: OBSVM_IP not set in .nvis-config}"
BCM_HOST="${BCM_HOST:?ERROR: BCM_HOST not set in .nvis-config}"
BCM_USER="${BCM_USER:-root}"
JUMP_HOST="${JUMP_HOST:-}"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

SSH_OPTS="-i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=10"
if [[ -n "$JUMP_HOST" ]]; then
  SSH_J="${JUMP_HOST},${BCM_USER}@${BCM_HOST}"
else
  SSH_J="${BCM_USER}@${BCM_HOST}"
fi

node_ssh() {
  local ip="$1"; shift
  ssh $SSH_OPTS -J "$SSH_J" "root@${ip}" "$@" 2>&1
}

node_scp() {
  local src="$1" dst_ip="$2" dst_path="$3"
  scp $SSH_OPTS -o "ProxyJump=$SSH_J" "$src" "root@${dst_ip}:${dst_path}" 2>&1
}

# Build node map
declare -A NODES
for entry in "${UP_NODES[@]:-}"; do
  [[ -z "$entry" ]] && continue
  ip="${entry#*:}"; name="${entry%%:*}"
  [[ "$ip" == "$entry" ]] && ip="$entry" && name="$entry"
  NODES["$ip"]="$name"
done

if [[ "${#NODES[@]}" -eq 0 ]]; then
  echo -e "${R}ERROR${N}: No nodes in .nvis-nodes."
  exit 1
fi

# Check if ObsVM has a node_exporter binary to copy
LOCAL_NE=""
for p in /usr/local/bin/node_exporter /usr/bin/node_exporter; do
  [[ -x "$p" ]] && LOCAL_NE="$p" && break
done
if [[ -n "$LOCAL_NE" ]]; then
  echo -e "${B}Found local node_exporter at $LOCAL_NE — will copy to nodes${N}"
fi

PASS=0; FAIL_N=0

NE_SERVICE='[Unit]
Description=Prometheus Node Exporter
After=network-online.target
[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter \
    --collector.textfile.directory=/var/lib/node_exporter/textfile \
    --collector.cpu.info --collector.netdev --collector.netstat \
    --web.listen-address=:9100
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target'

NE_SERVICE_B64=$(printf '%s' "$NE_SERVICE" | base64 -w 0)

for node_ip in "${!NODES[@]}"; do
  node_name="${NODES[$node_ip]}"
  echo "──────────────────────────────────────────────────────"
  echo "Processing ${node_name} (${node_ip})..."

  # First check current status
  status=$(node_ssh "$node_ip" "
    systemctl is-active node_exporter 2>/dev/null || echo inactive
    ss -tlnp 2>/dev/null | grep ':9100' | head -1 || echo ''
  " 2>/dev/null || echo "ssh_failed")

  if echo "$status" | grep -q "^active"; then
    echo -e "  ${G}[OK]${N} node_exporter already running"
    ((PASS++)) || true
    continue
  fi

  echo "  Status: not running — attempting install..."

  # Try to copy binary from ObsVM if available
  if [[ -n "$LOCAL_NE" ]]; then
    echo "  Copying binary from ObsVM..."
    node_scp "$LOCAL_NE" "$node_ip" "/usr/local/bin/node_exporter" 2>/dev/null && \
      echo -e "  ${G}Binary copied${N}" || echo -e "  ${Y}SCP failed, will try other methods${N}"
  fi

  # Full install attempt
  result=$(node_ssh "$node_ip" "
    set -uo pipefail

    # Skip if already running
    systemctl is-active --quiet node_exporter 2>/dev/null && echo ALREADY_RUNNING && exit 0
    curl -sf --max-time 3 http://localhost:9100/metrics &>/dev/null && echo ALREADY_RUNNING && exit 0

    # Method 1: package manager
    if [[ -f /etc/debian_version ]]; then
      apt-get install -y -qq prometheus-node-exporter 2>/dev/null && \
        systemctl enable prometheus-node-exporter && \
        systemctl restart prometheus-node-exporter && \
        sleep 3 && \
        curl -sf http://localhost:9100/metrics | grep -qc node_ && echo PKG_OK && exit 0
    elif [[ -f /etc/redhat-release ]]; then
      # RHEL/Rocky/CentOS — try prometheus repo or direct binary
      dnf install -y -q golang-github-prometheus-node-exporter 2>/dev/null && \
        systemctl enable node_exporter && systemctl restart node_exporter && \
        sleep 3 && curl -sf http://localhost:9100/metrics | grep -qc node_ && echo PKG_OK && exit 0
    fi

    # Method 2: binary already copied or wget
    if [[ ! -x /usr/local/bin/node_exporter ]]; then
      echo 'Binary not found, trying wget...'
      cd /tmp
      wget -q --timeout=30 https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz -O ne.tar.gz 2>&1 || \
        curl -sfL --max-time 30 https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz -o ne.tar.gz 2>&1 || \
        { echo DOWNLOAD_FAILED; exit 1; }
      tar xzf ne.tar.gz
      cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
      rm -rf ne.tar.gz node_exporter-1.8.2.linux-amd64
    fi
    chmod +x /usr/local/bin/node_exporter

    # Create user and dirs
    useradd -rs /bin/false node_exporter 2>/dev/null || true
    mkdir -p /var/lib/node_exporter/textfile
    chown -R node_exporter:node_exporter /var/lib/node_exporter 2>/dev/null || true

    # Write systemd unit
    printf '%s' '${NE_SERVICE_B64}' | base64 -d > /etc/systemd/system/node_exporter.service

    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl restart node_exporter
    sleep 4

    systemctl is-active --quiet node_exporter && echo SERVICE_RUNNING || { echo SERVICE_FAILED; journalctl -u node_exporter -n 20 --no-pager; exit 1; }
    curl -sf --max-time 5 http://localhost:9100/metrics | grep -qc node_ && echo NE_OK || echo METRICS_UNREACHABLE
  " 2>&1 || true)

  echo "$result" | grep -v '^$' | while IFS= read -r line; do echo "  $line"; done

  if echo "$result" | grep -qE "NE_OK|ALREADY_RUNNING|PKG_OK"; then
    echo -e "  ${G}[OK]${N} node_exporter running on ${node_name}"
    ((PASS++)) || true
  else
    echo -e "  ${R}[FAIL]${N} node_exporter install failed on ${node_name} (${node_ip})"
    ((FAIL_N++)) || true
  fi
  echo ""
done

echo "════════════════════════════════════════════════════════"
printf "  Fixed: %d   Failed: %d\n" "$PASS" "$FAIL_N"
echo ""
if [[ "$FAIL_N" -eq 0 && "$PASS" -gt 0 ]]; then
  echo -e "  ${G}SUCCESS${N} — node_exporter running on all nodes"
  echo ""
  echo "  Verify metrics flowing:"
  echo "  curl -sg \"http://${OBSVM_IP}:9090/api/v1/query?query=node_cpu_seconds_total{cluster%3D%22${CLUSTER_NAME}%22}\" \\"
  echo "    | python3 -m json.tool | grep instance | sort -u"
elif [[ "$FAIL_N" -gt 0 ]]; then
  echo -e "  ${R}Some nodes failed.${N}"
  echo ""
  echo "  Manual check:"
  echo "    ssh -J ${SSH_J} root@<node_ip> 'systemctl status node_exporter; journalctl -u node_exporter -n 30'"
  echo ""
  echo "  If internet blocked, copy binary from another machine:"
  echo "    scp node_exporter root@<node_ip>:/usr/local/bin/"
fi
echo "════════════════════════════════════════════════════════"
