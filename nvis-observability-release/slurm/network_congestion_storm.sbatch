#!/bin/bash
#SBATCH --job-name=net_congestion
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:12:00
#SBATCH --output=/tmp/netcong_%j.log
NODE=$(hostname)
echo "[$(date)] NETWORK CONGESTION STORM on $NODE"
mkdir -p /var/lib/node_exporter/textfile

echo "[$(date)] Phase 1: PFC starting — topology goes YELLOW"
cat > /var/lib/node_exporter/textfile/nvis_network.prom << PROM
# HELP nvis_node_health Node health
# TYPE nvis_node_health gauge
nvis_node_health{node="${NODE}",cluster="cod-a100-2node"} 1
# HELP nvis_pfc_pause_frames PFC pause frames
# TYPE nvis_pfc_pause_frames counter
nvis_pfc_pause_frames{node="${NODE}",cluster="cod-a100-2node"} 450000
# HELP nvis_ecn_marked_packets ECN marked packets
# TYPE nvis_ecn_marked_packets counter
nvis_ecn_marked_packets{node="${NODE}",cluster="cod-a100-2node"} 125000
# HELP nvis_queue_depth Queue depth bytes
# TYPE nvis_queue_depth gauge
nvis_queue_depth{node="${NODE}",cluster="cod-a100-2node"} 268435456
PROM
logger -t "spectrum-x" -p daemon.warning "WARNING: PFC pause frames on ${NODE} — congestion building"
sleep 30

echo "[$(date)] Phase 2: Queue buildup — topology goes ORANGE"
cat > /var/lib/node_exporter/textfile/nvis_network.prom << PROM
# HELP nvis_node_health Node health
# TYPE nvis_node_health gauge
nvis_node_health{node="${NODE}",cluster="cod-a100-2node"} 1
# HELP nvis_pfc_pause_frames PFC pause frames
# TYPE nvis_pfc_pause_frames counter
nvis_pfc_pause_frames{node="${NODE}",cluster="cod-a100-2node"} 4800000
# HELP nvis_ecn_marked_packets ECN marked packets
# TYPE nvis_ecn_marked_packets counter
nvis_ecn_marked_packets{node="${NODE}",cluster="cod-a100-2node"} 3200000
# HELP nvis_queue_depth Queue depth — 1GB backlog
# TYPE nvis_queue_depth gauge
nvis_queue_depth{node="${NODE}",cluster="cod-a100-2node"} 1073741824
PROM
logger -t "spectrum-x" -p daemon.error "ERROR: Queue depth critical 1GB backlog on ${NODE} port swp4"
logger -t "roce-config" -p daemon.error "ERROR: RoCE QoS degraded — ECN rate 48% above threshold"
sleep 30

echo "[$(date)] Phase 3: XID + full congestion — topology goes RED"
cat > /var/lib/node_exporter/textfile/nvis_network.prom << PROM
# HELP nvis_node_health Node health
# TYPE nvis_node_health gauge
nvis_node_health{node="${NODE}",cluster="cod-a100-2node"} 0
# HELP nvis_xid_error XID error
# TYPE nvis_xid_error gauge
nvis_xid_error{node="${NODE}",cluster="cod-a100-2node"} 79
# HELP nvis_pfc_pause_frames PFC pause frames
# TYPE nvis_pfc_pause_frames counter
nvis_pfc_pause_frames{node="${NODE}",cluster="cod-a100-2node"} 9800000
# HELP nvis_ecn_marked_packets ECN marked packets
# TYPE nvis_ecn_marked_packets counter
nvis_ecn_marked_packets{node="${NODE}",cluster="cod-a100-2node"} 8100000
# HELP nvis_queue_depth Queue depth — 2GB CRITICAL
# TYPE nvis_queue_depth gauge
nvis_queue_depth{node="${NODE}",cluster="cod-a100-2node"} 2147483648
PROM
logger -t "NVRM" -p kern.error "NVRM: Xid (PCI:0000:00:06): 79, GPU-${NODE} NVLink error — fabric congestion cascade"
logger -t "slurmd" -p daemon.error "ERROR: Job terminated — GPU NVLink timeout 30s congestion"
logger -t "spectrum-x" -p daemon.crit "CRITICAL: ${NODE} fabric port isolated — auto-recovery triggered"
logger -t "nccl-monitor" -p daemon.crit "CRITICAL: NCCL collective timeout — job killed"
sleep 60

echo "[$(date)] Phase 4: Recovery — topology back to GREEN"
cat > /var/lib/node_exporter/textfile/nvis_network.prom << PROM
# HELP nvis_node_health Node health
# TYPE nvis_node_health gauge
nvis_node_health{node="${NODE}",cluster="cod-a100-2node"} 1
# HELP nvis_xid_error XID error
# TYPE nvis_xid_error gauge
nvis_xid_error{node="${NODE}",cluster="cod-a100-2node"} 0
# HELP nvis_pfc_pause_frames PFC pause frames
# TYPE nvis_pfc_pause_frames counter
nvis_pfc_pause_frames{node="${NODE}",cluster="cod-a100-2node"} 12000
# HELP nvis_ecn_marked_packets ECN marked packets
# TYPE nvis_ecn_marked_packets counter
nvis_ecn_marked_packets{node="${NODE}",cluster="cod-a100-2node"} 8000
# HELP nvis_queue_depth Queue depth recovered
# TYPE nvis_queue_depth gauge
nvis_queue_depth{node="${NODE}",cluster="cod-a100-2node"} 4096
PROM
logger -t "spectrum-x" -p daemon.info "INFO: ${NODE} fabric recovered — congestion cleared"
sleep 60
rm -f /var/lib/node_exporter/textfile/nvis_network.prom
echo "[$(date)] CONGESTION STORM complete"

