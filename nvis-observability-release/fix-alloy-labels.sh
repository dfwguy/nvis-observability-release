#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# fix-alloy-labels.sh — Fix Alloy instance labels on ALL GPU nodes
#
# Run from ObsVM:  bash fix-alloy-labels.sh
#
# Root cause: Alloy scrapes localhost:9400 → instance label = "localhost:9400".
# Fix: Push Alloy config with HARDCODED hostname to each node, restart Alloy.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/.nvis-config" ]] && source "${SCRIPT_DIR}/.nvis-config"
[[ -f "${SCRIPT_DIR}/.nvis-nodes"  ]] && source "${SCRIPT_DIR}/.nvis-nodes"

OBSVM_IP="${OBSVM_IP:?ERROR: OBSVM_IP not set in .nvis-config}"
CLUSTER_NAME="${CLUSTER_NAME:?ERROR: CLUSTER_NAME not set in .nvis-config}"
BCM_HOST="${BCM_HOST:?ERROR: BCM_HOST not set in .nvis-config}"
BCM_USER="${BCM_USER:-root}"
JUMP_HOST="${JUMP_HOST:-}"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

SSH_OPTS="-i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=10"
# Jump chain: ObsVM → [krusty5 →] BCM → node
if [[ -n "$JUMP_HOST" ]]; then
  SSH_J="${JUMP_HOST},${BCM_USER}@${BCM_HOST}"
else
  SSH_J="${BCM_USER}@${BCM_HOST}"
fi

node_ssh() {
  # node_ssh <ip> <command...>
  local ip="$1"; shift
  ssh $SSH_OPTS -J "$SSH_J" "root@${ip}" "$@" 2>&1
}

echo ""
echo "════════════════════════════════════════════════════════"
echo "  NVIS — Fix Alloy instance labels on GPU nodes"
echo "  OBSVM_IP    : $OBSVM_IP"
echo "  CLUSTER_NAME: $CLUSTER_NAME"
echo "  Jump chain  : ${JUMP_HOST:+$JUMP_HOST → }${BCM_USER}@${BCM_HOST} → nodes"
echo "════════════════════════════════════════════════════════"
echo ""

# Build node map: ip → name
declare -A NODES
for entry in "${UP_NODES[@]:-}"; do
  [[ -z "$entry" ]] && continue
  ip="${entry#*:}"
  name="${entry%%:*}"
  [[ "$ip" == "$entry" ]] && ip="$entry" && name="$entry"
  NODES["$ip"]="$name"
done

if [[ "${#NODES[@]}" -eq 0 ]]; then
  echo -e "${R}ERROR${N}: No nodes in .nvis-nodes. Check file or run: bash setup.sh --phase gpu_nodes"
  exit 1
fi

echo "Target nodes:"
for ip in "${!NODES[@]}"; do echo "  ${NODES[$ip]} ($ip)"; done
echo ""

PASS=0; FAIL_N=0

for node_ip in "${!NODES[@]}"; do
  node_hint="${NODES[$node_ip]}"
  echo "──────────────────────────────────────────────────────"
  echo "Processing ${node_hint} (${node_ip})..."

  # Get real hostname from node (if SSH works)
  hostname=$(node_ssh "$node_ip" "hostname -s" 2>/dev/null | tr -d '\r\n' || echo "")
  if [[ -z "$hostname" ]]; then
    echo -e "  ${Y}SSH failed getting hostname, using hint: ${node_hint}${N}"
    hostname="$node_hint"
  fi
  echo -e "  ${B}Hostname:${N} ${hostname}"

  # Build alloy config — each attribute on its own line (River syntax requires this)
  alloy_config="// NVIS GPU node agent — instance=${hostname} cluster=${CLUSTER_NAME}
prometheus.remote_write \"obsvm\" {
  endpoint {
    url = \"http://${OBSVM_IP}:9090/api/v1/write\"
  }
}

prometheus.scrape \"dcgm\" {
  targets          = [{ __address__ = \"localhost:9400\" }]
  scrape_interval  = \"15s\"
  honor_timestamps = false
  forward_to       = [prometheus.relabel.dcgm.receiver]
}
prometheus.relabel \"dcgm\" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule {
    target_label = \"job\"
    replacement  = \"dcgm-exporter\"
  }
  rule {
    target_label = \"cluster\"
    replacement  = \"${CLUSTER_NAME}\"
  }
  rule {
    target_label = \"instance\"
    replacement  = \"${hostname}\"
  }
  rule {
    target_label = \"node\"
    replacement  = \"${hostname}\"
  }
}

prometheus.scrape \"node_exporter\" {
  targets         = [{ __address__ = \"localhost:9100\" }]
  scrape_interval = \"15s\"
  forward_to      = [prometheus.relabel.node_exporter.receiver]
}
prometheus.relabel \"node_exporter\" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule {
    target_label = \"job\"
    replacement  = \"node-exporter\"
  }
  rule {
    target_label = \"cluster\"
    replacement  = \"${CLUSTER_NAME}\"
  }
  rule {
    target_label = \"instance\"
    replacement  = \"${hostname}\"
  }
  rule {
    target_label = \"node\"
    replacement  = \"${hostname}\"
  }
}

prometheus.scrape \"cgroup\" {
  targets         = [{ __address__ = \"localhost:9306\" }]
  scrape_interval = \"15s\"
  forward_to      = [prometheus.relabel.cgroup.receiver]
}
prometheus.relabel \"cgroup\" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule {
    target_label = \"job\"
    replacement  = \"slurm-cgroup-exporter\"
  }
  rule {
    target_label = \"cluster\"
    replacement  = \"${CLUSTER_NAME}\"
  }
  rule {
    target_label = \"instance\"
    replacement  = \"${hostname}\"
  }
  rule {
    target_label = \"node\"
    replacement  = \"${hostname}\"
  }
}

loki.write \"obsvm\" {
  endpoint {
    url = \"http://${OBSVM_IP}:3100/loki/api/v1/push\"
  }
}
local.file_match \"syslog\" {
  path_targets = [{ __path__ = \"/var/log/syslog\", job = \"syslog\", cluster = \"${CLUSTER_NAME}\", node = \"${hostname}\", instance = \"${hostname}\" }]
}
loki.source.file \"syslog\" {
  targets    = local.file_match.syslog.targets
  forward_to = [loki.write.obsvm.receiver]
}"

  # Base64 encode the config so it survives SSH transport cleanly
  b64=$(printf '%s' "$alloy_config" | base64 -w 0)

  # Push to node, decode, write, restart
  result=$(node_ssh "$node_ip" "
    set -uo pipefail
    # Decode and write config
    printf '%s' '${b64}' | base64 -d | sudo tee /etc/alloy/config.alloy > /dev/null
    echo CONFIG_WRITTEN

    # Verify hostname is in config
    grep -q '${hostname}' /etc/alloy/config.alloy && echo HOSTNAME_OK || echo HOSTNAME_MISSING

    # Belt+suspenders: systemd drop-in
    sudo mkdir -p /etc/systemd/system/alloy.service.d
    printf '[Service]\nEnvironment=HOSTNAME=%s\n' '${hostname}' | sudo tee /etc/systemd/system/alloy.service.d/nvis.conf > /dev/null

    # Reload and restart
    sudo systemctl daemon-reload
    sudo systemctl reset-failed alloy 2>/dev/null || true
    sudo systemctl restart alloy
    sleep 5

    # Status check
    systemctl is-active --quiet alloy && echo ALLOY_RUNNING || { echo ALLOY_DEAD; journalctl -u alloy --no-pager -n 20 2>/dev/null; }

    # Verify scrapers are reachable (non-fatal)
    curl -sf --max-time 3 http://localhost:9400/metrics 2>/dev/null | grep -qc 'DCGM_FI' && echo DCGM_UP || echo DCGM_DOWN
    curl -sf --max-time 3 http://localhost:9100/metrics 2>/dev/null | grep -qc 'node_cpu' && echo NODE_UP || echo NODE_DOWN
  " 2>&1 || true)

  # Parse output
  if echo "$result" | grep -q "ALLOY_RUNNING"; then
    echo -e "  ${G}[OK]${N} Alloy running"
    echo "$result" | grep -q "HOSTNAME_OK"    && echo -e "  ${G}[OK]${N} Hostname '${hostname}' in config" \
                                               || echo -e "  ${R}[!!]${N} Hostname NOT in config"
    echo "$result" | grep -q "DCGM_UP"        && echo -e "  ${G}[OK]${N} DCGM metrics reachable (:9400)" \
                                               || echo -e "  ${Y}[--]${N} DCGM :9400 not responding (check dcgm container)"
    echo "$result" | grep -q "NODE_UP"        && echo -e "  ${G}[OK]${N} node_exporter metrics reachable (:9100)" \
                                               || echo -e "  ${Y}[--]${N} node_exporter :9100 not responding"
    echo -e "  ${G}FIXED: ${hostname}${N}"
    ((PASS++)) || true
  else
    echo -e "  ${R}[FAIL]${N} Alloy not running on ${hostname} (${node_ip})"
    echo "--- output ---"
    echo "$result"
    echo "--- end ---"
    ((FAIL_N++)) || true
  fi
  echo ""
done

# Also update alloy/config.alloy in repo to match the multi-node push-based template
echo "──────────────────────────────────────────────────────"
echo "Updating repo alloy/config.alloy with canonical template..."
cat > "${SCRIPT_DIR}/alloy/config.alloy" << 'TMPL'
// ─────────────────────────────────────────────────────────────────────────────
// Grafana Alloy — GPU node agent config (template)
// Deployed per-node by setup.sh / fix-alloy-labels.sh
// Placeholders <OBSVM_IP>, <CLUSTER_NAME>, <NODE_HOSTNAME> substituted at deploy time.
//
// River syntax rules:
//   - Block attributes: one per line (newline is the terminator)
//   - Object literals inside arrays [{...}]: fields separated by commas
// ─────────────────────────────────────────────────────────────────────────────

prometheus.remote_write "obsvm" {
  endpoint {
    url = "http://<OBSVM_IP>:9090/api/v1/write"
  }
}

prometheus.scrape "dcgm" {
  targets          = [{ __address__ = "localhost:9400" }]
  scrape_interval  = "15s"
  honor_timestamps = false
  forward_to       = [prometheus.relabel.dcgm.receiver]
}
prometheus.relabel "dcgm" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule {
    target_label = "job"
    replacement  = "dcgm-exporter"
  }
  rule {
    target_label = "cluster"
    replacement  = "<CLUSTER_NAME>"
  }
  rule {
    target_label = "instance"
    replacement  = "<NODE_HOSTNAME>"
  }
  rule {
    target_label = "node"
    replacement  = "<NODE_HOSTNAME>"
  }
}

prometheus.scrape "node_exporter" {
  targets         = [{ __address__ = "localhost:9100" }]
  scrape_interval = "15s"
  forward_to      = [prometheus.relabel.node_exporter.receiver]
}
prometheus.relabel "node_exporter" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule {
    target_label = "job"
    replacement  = "node-exporter"
  }
  rule {
    target_label = "cluster"
    replacement  = "<CLUSTER_NAME>"
  }
  rule {
    target_label = "instance"
    replacement  = "<NODE_HOSTNAME>"
  }
  rule {
    target_label = "node"
    replacement  = "<NODE_HOSTNAME>"
  }
}

prometheus.scrape "cgroup" {
  targets         = [{ __address__ = "localhost:9306" }]
  scrape_interval = "15s"
  forward_to      = [prometheus.relabel.cgroup.receiver]
}
prometheus.relabel "cgroup" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule {
    target_label = "job"
    replacement  = "slurm-cgroup-exporter"
  }
  rule {
    target_label = "cluster"
    replacement  = "<CLUSTER_NAME>"
  }
  rule {
    target_label = "instance"
    replacement  = "<NODE_HOSTNAME>"
  }
  rule {
    target_label = "node"
    replacement  = "<NODE_HOSTNAME>"
  }
}

loki.write "obsvm" {
  endpoint {
    url = "http://<OBSVM_IP>:3100/loki/api/v1/push"
  }
}
local.file_match "syslog" {
  path_targets = [{ __path__ = "/var/log/syslog", job = "syslog", cluster = "<CLUSTER_NAME>", node = "<NODE_HOSTNAME>", instance = "<NODE_HOSTNAME>" }]
}
loki.source.file "syslog" {
  targets    = local.file_match.syslog.targets
  forward_to = [loki.write.obsvm.receiver]
}
TMPL
echo -e "  ${G}[OK]${N} alloy/config.alloy updated"
echo ""

echo "════════════════════════════════════════════════════════"
printf "  Fixed: %d   Failed: %d\n" "$PASS" "$FAIL_N"
echo ""
if [[ "$FAIL_N" -eq 0 && "$PASS" -gt 0 ]]; then
  echo -e "  ${G}SUCCESS — Wait ~30s then verify:${N}"
  echo ""
  echo "  curl -sg \"http://${OBSVM_IP}:9090/api/v1/query?query=up{job%3D%22node-exporter%22}\" \\"
  echo "    | python3 -m json.tool | grep instance"
  echo ""
  echo "  Expected: instance = node001 / node002 / node003 (not localhost:9100)"
elif [[ "$FAIL_N" -gt 0 ]]; then
  echo -e "  ${R}Some nodes failed. Debug:${N}"
  echo "    ssh -J ${SSH_J} root@<node_ip> 'systemctl status alloy; journalctl -u alloy -n 30'"
fi
echo "════════════════════════════════════════════════════════"
