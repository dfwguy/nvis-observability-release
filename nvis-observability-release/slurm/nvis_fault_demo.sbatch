#!/bin/bash
#SBATCH --job-name=nvis-fault-demo
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:30:00
#SBATCH --output=/var/log/slurm/nvis-fault-demo-%j.out
#SBATCH --error=/var/log/slurm/nvis-fault-demo-%j.err

JOB_ID="${SLURM_JOB_ID}"
log() { echo "[$(date '+%H:%M:%S')] $*"; logger -t nvis-fault-demo "$*"; }
log "=== NVIS Fault Demo Job ${JOB_ID} started ==="

write_metrics() {
  cat > /var/lib/node_exporter/textfile/nvis_network.prom << EOF
# HELP nvis_node_health Node health 1=ok 0=error
# TYPE nvis_node_health gauge
nvis_node_health{node="node001",job="${JOB_ID}"} $1
nvis_node_health{node="node002",job="${JOB_ID}"} $2
# HELP nvis_xid_error XID error code
# TYPE nvis_xid_error gauge
nvis_xid_error{node="node001",job="${JOB_ID}"} 0
nvis_xid_error{node="node002",job="${JOB_ID}"} $3
# HELP nvis_traffic_bytes_total Cross-node traffic
# TYPE nvis_traffic_bytes_total counter
nvis_traffic_bytes_total{src="node001",dst="node002",job="${JOB_ID}"} $4
nvis_traffic_bytes_total{src="node002",dst="node001",job="${JOB_ID}"} $5
# HELP nvis_queue_depth Queue backlog bytes
# TYPE nvis_queue_depth gauge
nvis_queue_depth{node="node001",dst="node002",job="${JOB_ID}"} $6
nvis_queue_depth{node="node002",dst="node001",job="${JOB_ID}"} 0
# HELP nvis_pfc_pause_frames PFC pause frames
# TYPE nvis_pfc_pause_frames counter
nvis_pfc_pause_frames{node="node001",priority="3",job="${JOB_ID}"} $7
nvis_pfc_pause_frames{node="node002",priority="3",job="${JOB_ID}"} $7
# HELP nvis_ecn_marked_packets ECN marked packets
# TYPE nvis_ecn_marked_packets counter
nvis_ecn_marked_packets{node="node001",job="${JOB_ID}"} $8
nvis_ecn_marked_packets{node="node002",job="${JOB_ID}"} $8
EOF
}

mkdir -p /var/lib/node_exporter/textfile

# Phase 1: Healthy traffic (5 min)
log "Phase 1: Healthy cross-node traffic..."
TRAFFIC=0; PFC=0; ECN=0
for i in $(seq 1 30); do
  TRAFFIC=$((TRAFFIC + 1073741824 + RANDOM*32768))
  PFC=$((PFC + RANDOM % 10)); ECN=$((ECN + RANDOM % 5))
  write_metrics 1 1 0 $TRAFFIC $((TRAFFIC*85/100)) 0 $PFC $ECN
  log "Phase1 [$i/30] traffic=$TRAFFIC pfc=$PFC ecn=$ECN"
  sleep 10
done

# Phase 2: XID 94 injection
log "Phase 2: Injecting XID 94 on node002..."
logger -t kernel "NVRM: Xid (PCI:0000:00:06.0): 94, pid=${JOB_ID}, name=nvis-fault-demo, Timeout waiting for RPC from GSP!"
log "XID 94 injected"

# Phase 3: Congestion builds (3 min)
log "Phase 3: node002 RED - traffic queueing..."
QUEUE=0; PFC_S=$PFC; ECN_S=$ECN
for i in $(seq 1 18); do
  TRAFFIC=$((TRAFFIC + 536870912))
  QUEUE=$((QUEUE + 2500000 + RANDOM*1000))
  PFC_S=$((PFC_S + 500 + RANDOM*50))
  ECN_S=$((ECN_S + 200 + RANDOM*20))
  write_metrics 1 0 94 $TRAFFIC $((TRAFFIC*85/100)) $QUEUE $PFC_S $ECN_S
  log "Phase3 [$i/18] node002=RED xid=94 queue=$QUEUE pfc=$PFC_S ecn=$ECN_S"
  sleep 10
done

# Phase 4: Recovery (1 min)
log "Phase 4: node002 recovering..."
for i in $(seq 1 6); do
  QUEUE=$((QUEUE - QUEUE/3))
  PFC_S=$((PFC_S - PFC_S/4))
  ECN_S=$((ECN_S - ECN_S/4))
  write_metrics 1 1 0 $TRAFFIC $((TRAFFIC*85/100)) $QUEUE $PFC_S $ECN_S
  log "Phase4 [$i/6] recovering queue=$QUEUE"
  sleep 10
done

log "=== Demo complete ==="
rm -f /var/lib/node_exporter/textfile/nvis_network.prom
