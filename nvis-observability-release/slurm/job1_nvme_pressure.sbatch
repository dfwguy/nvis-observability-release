#!/bin/bash
#SBATCH --job-name=nvme-pressure-sim
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=01:00:00
#SBATCH --output=/var/log/slurm/nvme_pressure_%j.log
#SBATCH --error=/var/log/slurm/nvme_pressure_%j.err

# =============================================================================
# NVIS Demo Job 1: NVMe/RAID Pressure Simulation
# Generates disk pressure, simulates 98% full LLM training disk,
# writes alerts to node_exporter textfile, and logs storage events.
# =============================================================================

TEXTFILE_DIR="/var/lib/node_exporter/textfile"
LOG_DIR="/var/log/nvis-demo"
OBSVM_IP="${OBSVM_IP:-10.127.28.83}"
CLUSTER="${CLUSTER_NAME:-cod-a100-2node}"
NODE=$(hostname)
JOB_ID=${SLURM_JOB_ID:-99901}

mkdir -p "$TEXTFILE_DIR" "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/nvme_pressure_${JOB_ID}.log"; }

# Push log to Loki
push_log() {
  local level="$1"
  local msg="$2"
  local ts=$(date +%s%N)
  curl -sf -X POST "http://${OBSVM_IP}:3100/loki/api/v1/push" \
    -H "Content-Type: application/json" \
    -d "{\"streams\":[{\"stream\":{\"job\":\"storage-pressure\",\"node\":\"${NODE}\",\"cluster\":\"${CLUSTER}\",\"level\":\"${level}\"},\"values\":[[\"${ts}\",\"${msg}\"]]}]}" \
    > /dev/null 2>&1 || true
}

# Write metrics to textfile collector
write_metrics() {
  local disk_util="$1"
  local read_bw="$2"
  local write_bw="$3"
  local disk_full="$4"
  local raid_degraded="$5"

  cat > "${TEXTFILE_DIR}/storage_pressure.prom" << PROM
# HELP nvis_demo_disk_utilization_percent Simulated disk utilization percent
# TYPE nvis_demo_disk_utilization_percent gauge
nvis_demo_disk_utilization_percent{node="${NODE}",cluster="${CLUSTER}",device="nvme0n1",job_id="${JOB_ID}"} ${disk_util}

# HELP nvis_demo_disk_read_bytes_per_sec Simulated disk read throughput
# TYPE nvis_demo_disk_read_bytes_per_sec gauge
nvis_demo_disk_read_bytes_per_sec{node="${NODE}",cluster="${CLUSTER}",device="nvme0n1",job_id="${JOB_ID}"} ${read_bw}

# HELP nvis_demo_disk_write_bytes_per_sec Simulated disk write throughput
# TYPE nvis_demo_disk_write_bytes_per_sec gauge
nvis_demo_disk_write_bytes_per_sec{node="${NODE}",cluster="${CLUSTER}",device="nvme0n1",job_id="${JOB_ID}"} ${write_bw}

# HELP nvis_demo_llm_training_disk_full_percent LLM training dataset disk usage percent
# TYPE nvis_demo_llm_training_disk_full_percent gauge
nvis_demo_llm_training_disk_full_percent{node="${NODE}",cluster="${CLUSTER}",mount="/data/llm-training",job_id="${JOB_ID}"} ${disk_full}

# HELP nvis_demo_raid_degraded RAID array degraded state
# TYPE nvis_demo_raid_degraded gauge
nvis_demo_raid_degraded{node="${NODE}",cluster="${CLUSTER}",device="md0",job_id="${JOB_ID}"} ${raid_degraded}

# HELP nvis_demo_job_throughput_tokens_per_sec LLM training tokens/sec (affected by I/O pressure)
# TYPE nvis_demo_job_throughput_tokens_per_sec gauge
nvis_demo_job_throughput_tokens_per_sec{node="${NODE}",cluster="${CLUSTER}",job_id="${JOB_ID}"} $(echo "scale=0; $read_bw / 50000" | bc 2>/dev/null || echo "1200")
PROM
}

log "=== NVMe/RAID Pressure Demo Starting === Job: ${JOB_ID} Node: ${NODE}"
push_log "INFO" "NVMe pressure simulation started on ${NODE} job=${JOB_ID}"

# Phase 1: Normal baseline (60s)
log "Phase 1: Establishing baseline..."
push_log "INFO" "Storage baseline: read=2.1GB/s write=1.8GB/s utilization=45% disk_usage=72%"
for i in $(seq 1 12); do
  UTIL=$(echo "40 + $RANDOM % 15" | bc)
  READ=$(echo "2100000000 - $RANDOM % 200000000" | bc)
  WRITE=$(echo "1800000000 - $RANDOM % 150000000" | bc)
  write_metrics "$UTIL" "$READ" "$WRITE" "72.3" "0"
  sleep 5
done

# Phase 2: LLM training data load begins — disk fill starts
log "Phase 2: LLM training data loading — disk filling up..."
push_log "WARN" "ALERT: /data/llm-training filling rapidly — LLM checkpoint writes accelerating"
for i in $(seq 1 8); do
  FILL=$(echo "72 + $i * 3" | bc)
  READ=$(echo "3200000000 + $RANDOM % 400000000" | bc)
  WRITE=$(echo "2900000000 + $RANDOM % 300000000" | bc)
  UTIL=$(echo "70 + $i * 2" | bc)
  write_metrics "$UTIL" "$READ" "$WRITE" "$FILL.$(( RANDOM % 9 ))" "0"
  push_log "WARN" "disk_usage=${FILL}% on /data/llm-training — checkpoint size growing"
  sleep 5
done

# Phase 3: Critical — disk at 98%, I/O pressure begins
log "Phase 3: CRITICAL — disk at 98%, I/O pressure affecting training!"
push_log "ERROR" "CRITICAL: /data/llm-training at 98% capacity — disk pressure detected"
push_log "ERROR" "SUDDEN DROP in read throughput: 3.4GB/s → 0.8GB/s — LLM training stalled"
push_log "ERROR" "Simulated disk nvme2 showing high latency: avg_lat=45ms (normal: 0.1ms)"

# Actual disk pressure via dd (real I/O)
TMPDIR=$(mktemp -d)
log "Generating real I/O pressure via dd..."
dd if=/dev/urandom of="${TMPDIR}/pressure_file_1" bs=1M count=512 oflag=direct 2>/dev/null &
dd if=/dev/urandom of="${TMPDIR}/pressure_file_2" bs=1M count=512 oflag=direct 2>/dev/null &
DD_PID1=$!
DD_PID2=$!

for i in $(seq 1 16); do
  # Simulate dramatic throughput drop
  COLLAPSE=$(echo "scale=2; 0.9^$i" | bc 2>/dev/null || echo "0.5")
  READ=$(echo "3400000000 * $COLLAPSE / 1" | bc 2>/dev/null || echo "800000000")
  WRITE=$(echo "2800000000 * $COLLAPSE / 1" | bc 2>/dev/null || echo "400000000")
  [[ "$READ" -lt "400000000" ]] && READ="400000000"
  [[ "$WRITE" -lt "200000000" ]] && WRITE="200000000"
  write_metrics "98" "$READ" "$WRITE" "98.$(( RANDOM % 9 ))" "0"
  push_log "ERROR" "I/O throughput collapsed: read=$(( READ / 1000000 ))MB/s write=$(( WRITE / 1000000 ))MB/s — job performance degraded $(( i * 6 ))%"
  sleep 5
done

wait $DD_PID1 $DD_PID2 2>/dev/null || true
rm -rf "$TMPDIR"

# Phase 4: Simulated RAID disk failure
log "Phase 4: Simulating RAID disk failure..."
push_log "ERROR" "RAID ALERT: /dev/nvme2 removed from array md0 — RAID degraded"
push_log "ERROR" "md0: Disk failure detected — array operating in degraded mode"
push_log "ERROR" "IMPACT: LLM training throughput reduced 60% — checkpoint saves failing"

for i in $(seq 1 12); do
  READ=$(echo "800000000 + $RANDOM % 200000000" | bc)
  WRITE=$(echo "200000000 + $RANDOM % 100000000" | bc)
  write_metrics "99" "$READ" "$WRITE" "98.9" "1"
  push_log "ERROR" "RAID degraded — disk_read=$(( READ / 1000000 ))MB/s job throughput critically low"
  sleep 5
done

# Phase 5: Recovery simulation
log "Phase 5: Simulating recovery..."
push_log "WARN" "RECOVERY: Emergency disk cleanup initiated — deleting old checkpoints"
push_log "INFO" "Freed 45GB on /data/llm-training — disk usage dropping"

for i in $(seq 1 12); do
  FILL=$(echo "98 - $i * 2" | bc)
  [[ "$FILL" -lt "75" ]] && FILL="75"
  READ=$(echo "800000000 + $i * 100000000" | bc)
  WRITE=$(echo "200000000 + $i * 80000000" | bc)
  write_metrics "$(( 50 + i * 3 ))" "$READ" "$WRITE" "$FILL" "0"
  push_log "INFO" "Recovery progress: disk_usage=${FILL}% throughput recovering"
  sleep 5
done

push_log "INFO" "NVMe pressure simulation complete — check Impact Analysis dashboard"
log "=== Job Complete ==="

# Cleanup metrics after 5 min
sleep 300
rm -f "${TEXTFILE_DIR}/storage_pressure.prom"
