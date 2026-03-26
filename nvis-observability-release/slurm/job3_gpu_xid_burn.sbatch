#!/bin/bash
#SBATCH --job-name=gpu-xid-pressure
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:a100:1
#SBATCH --time=00:45:00
#SBATCH --output=/var/log/slurm/gpu_pressure_%j.log

# =============================================================================
# NVIS Demo Job 3: GPU Burn + XID Errors Simulation
# Runs real GPU stress via gpu-burn, injects XID error metrics,
# simulates GPU fallen-off-bus events visible in GPU Health dashboard
# =============================================================================

TEXTFILE_DIR="/var/lib/node_exporter/textfile"
LOG_DIR="/var/log/nvis-demo"
OBSVM_IP="${OBSVM_IP:-10.127.28.83}"
CLUSTER="${CLUSTER_NAME:-cod-a100-2node}"
NODE=$(hostname)
JOB_ID=${SLURM_JOB_ID:-99903}
NUM_GPUS=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo "8")

mkdir -p "$TEXTFILE_DIR" "$LOG_DIR"

push_log() {
  local level="$1" msg="$2" ts=$(date +%s%N)
  curl -sf -X POST "http://${OBSVM_IP}:3100/loki/api/v1/push" \
    -H "Content-Type: application/json" \
    -d "{\"streams\":[{\"stream\":{\"job\":\"gpu-xid\",\"node\":\"${NODE}\",\"cluster\":\"${CLUSTER}\",\"level\":\"${level}\"},\"values\":[[\"${ts}\",\"${msg}\"]]}]}" \
    > /dev/null 2>&1 || true
}

write_gpu_metrics() {
  local phase="$1"
  local metric_file="${TEXTFILE_DIR}/gpu_pressure.prom"

  {
    echo "# HELP nvis_demo_xid_errors_total XID error count per GPU"
    echo "# TYPE nvis_demo_xid_errors_total counter"
    echo "# HELP nvis_demo_gpu_fallen_off_bus GPU fallen off bus indicator"
    echo "# TYPE nvis_demo_gpu_fallen_off_bus gauge"
    echo "# HELP nvis_demo_gpu_ecc_errors_total ECC error count"
    echo "# TYPE nvis_demo_gpu_ecc_errors_total counter"
    echo "# HELP nvis_demo_gpu_throttle_reason GPU throttle reason bitmask"
    echo "# TYPE nvis_demo_gpu_throttle_reason gauge"
    echo "# HELP nvis_demo_gpu_nvlink_errors NVLink error count"
    echo "# TYPE nvis_demo_gpu_nvlink_errors counter"

    for gpu in $(seq 0 $(( NUM_GPUS - 1 ))); do
      local xid=0 fallen=0 ecc=0 throttle=0 nvlink_err=0
      local temp util power

      case "$phase" in
        baseline)
          temp=$(( 45 + RANDOM % 10 ))
          util=$(( 10 + RANDOM % 20 ))
          power=$(( 80 + RANDOM % 40 ))
          ;;
        burn)
          temp=$(( 75 + RANDOM % 10 ))
          util=$(( 95 + RANDOM % 5 ))
          power=$(( 380 + RANDOM % 30 ))
          throttle=$(( RANDOM % 4 ))
          ;;
        xid_storm)
          temp=$(( 85 + RANDOM % 10 ))
          util=$(( 90 + RANDOM % 10 ))
          power=$(( 390 + RANDOM % 15 ))
          xid=$(( RANDOM % 50 + 10 ))
          ecc=$(( RANDOM % 20 + 5 ))
          nvlink_err=$(( RANDOM % 10 ))
          throttle=4
          # GPU 3 and 6 fall off bus
          if [[ "$gpu" -eq 3 ]] || [[ "$gpu" -eq 6 ]]; then
            fallen=1
            xid=$(( xid + 79 ))  # XID 79 = GPU fallen off bus
            util=0
            temp=0
            power=0
          fi
          ;;
        recovery)
          temp=$(( 60 + RANDOM % 15 ))
          util=$(( 30 + RANDOM % 30 ))
          power=$(( 150 + RANDOM % 100 ))
          xid=$(( RANDOM % 5 ))
          ;;
      esac

      echo "nvis_demo_xid_errors_total{gpu=\"${gpu}\",node=\"${NODE}\",cluster=\"${CLUSTER}\",job_id=\"${JOB_ID}\"} ${xid}"
      echo "nvis_demo_gpu_fallen_off_bus{gpu=\"${gpu}\",node=\"${NODE}\",cluster=\"${CLUSTER}\",job_id=\"${JOB_ID}\"} ${fallen}"
      echo "nvis_demo_gpu_ecc_errors_total{gpu=\"${gpu}\",node=\"${NODE}\",cluster=\"${CLUSTER}\",job_id=\"${JOB_ID}\",type=\"corrected\"} ${ecc}"
      echo "nvis_demo_gpu_throttle_reason{gpu=\"${gpu}\",node=\"${NODE}\",cluster=\"${CLUSTER}\",job_id=\"${JOB_ID}\"} ${throttle}"
      echo "nvis_demo_gpu_nvlink_errors{gpu=\"${gpu}\",node=\"${NODE}\",cluster=\"${CLUSTER}\",job_id=\"${JOB_ID}\"} ${nvlink_err}"
    done
  } > "$metric_file"
}

echo "[$(date)] === GPU Burn + XID Demo Starting === Job: ${JOB_ID}"
push_log "INFO" "GPU pressure simulation starting — ${NUM_GPUS} GPUs on ${NODE}"

# Phase 1: Baseline
echo "[$(date)] Phase 1: Baseline..."
push_log "INFO" "GPU baseline established — all ${NUM_GPUS} GPUs healthy, utilization 10-20%"
for i in $(seq 1 6); do
  write_gpu_metrics "baseline"
  sleep 5
done

# Phase 2: Start gpu-burn (real GPU stress)
echo "[$(date)] Phase 2: Starting GPU burn..."
push_log "INFO" "GPU burn starting — targeting 100% utilization across all ${NUM_GPUS} GPUs"

if command -v gpu-burn &>/dev/null; then
  gpu-burn 300 &
  GPU_BURN_PID=$!
  push_log "INFO" "gpu-burn launched PID=${GPU_BURN_PID} — 300 second burn"
else
  # Fallback: use CUDA via python if available
  python3 -c "
import subprocess, time
procs = []
for i in range(min(8, $(( NUM_GPUS )))):
    p = subprocess.Popen(['python3', '-c', '''
import torch
device = torch.device('cuda:''' + str(i) + '''')
a = torch.randn(8192, 8192, device=device)
b = torch.randn(8192, 8192, device=device)
for _ in range(100000):
    c = torch.matmul(a, b)
'''])
    procs.append(p)
time.sleep(240)
for p in procs:
    p.terminate()
" &
  GPU_BURN_PID=$!
  push_log "INFO" "GPU stress via PyTorch launched — PID=${GPU_BURN_PID}"
fi

for i in $(seq 1 12); do
  write_gpu_metrics "burn"
  push_log "INFO" "GPU burn in progress — utilization 98%, temps rising: $(( 75 + i ))°C, power: $(( 380 + i * 2 ))W"
  sleep 5
done

# Phase 3: XID Error Storm
echo "[$(date)] Phase 3: Injecting XID errors..."
push_log "ERROR" "XID ERROR STORM BEGINNING — multiple GPU errors detected"

XID_MESSAGES=(
  "ERROR|NVRM: Xid (GPU-00000000): 13, pid='<unknown>', name=<unknown>, Graphics Exception: ESR 0x00000000"
  "ERROR|NVRM: Xid (GPU-00000003): 79, pid=0, name=<unknown>, GPU has fallen off the bus"
  "ERROR|NVRM: Xid (GPU-00000006): 79, pid=0, name=<unknown>, GPU has fallen off the bus"
  "ERROR|NVRM: Xid (GPU-00000001): 48, pid='<unknown>', Double Bit ECC Error"
  "ERROR|NVRM: Xid (GPU-00000002): 48, pid='<unknown>', Double Bit ECC Error"
  "ERROR|NVRM: Xid (GPU-00000004): 31, pid=12345, name=python, GPU memory page fault"
  "ERROR|NVRM: Xid (GPU-00000005): 45, pid=12346, name=python, Preemptive cleanup triggered"
  "ERROR|NVRM: Xid (GPU-00000007): 61, pid=12347, name=python, Internal micro-controller breakpoint"
  "ERROR|KERNEL: GPU 3 fallen off bus — remapping GPU indices"
  "ERROR|KERNEL: GPU 6 fallen off bus — remapping GPU indices"
  "ERROR|SLURM: Job ${JOB_ID} GPU fault detected — 2 of ${NUM_GPUS} GPUs unavailable"
  "ERROR|DCGM: XID 79 detected on GPU 3 and GPU 6 — marking unhealthy"
  "ERROR|IMPACT: Job throughput reduced from 366K GFLOP/s to 183K GFLOP/s (50% degradation)"
)

for msg_entry in "${XID_MESSAGES[@]}"; do
  IFS='|' read -r level msg <<< "$msg_entry"
  push_log "$level" "$msg"
  sleep 2
done

for i in $(seq 1 24); do
  write_gpu_metrics "xid_storm"
  if (( i % 3 == 0 )); then
    push_log "ERROR" "XID errors accumulating: GPU3=$(( 79 + i * 3 )) GPU6=$(( 79 + i * 2 )) errors — job degraded"
  fi
  sleep 5
done

# Kill gpu burn
kill $GPU_BURN_PID 2>/dev/null || true

# Phase 4: Recovery
echo "[$(date)] Phase 4: GPU recovery..."
push_log "WARN" "Attempting GPU recovery — nvidia-smi reset on affected GPUs"
push_log "INFO" "nvidia-smi --gpu-reset on GPU 3 and GPU 6"
push_log "INFO" "GPU 3 reset successful — back online"
push_log "INFO" "GPU 6 reset successful — back online"
push_log "WARN" "Job ${JOB_ID} resuming with reduced efficiency — checkpointing enabled"

for i in $(seq 1 12); do
  write_gpu_metrics "recovery"
  push_log "INFO" "GPU recovery phase ${i}/12 — errors decreasing, utilization stabilizing"
  sleep 5
done

push_log "INFO" "GPU pressure simulation complete — check GPU Health dashboard for full timeline"
echo "[$(date)] === Job Complete ==="

sleep 300
rm -f "${TEXTFILE_DIR}/gpu_pressure.prom"
