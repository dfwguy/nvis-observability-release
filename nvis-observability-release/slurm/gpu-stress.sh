#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# NVIS GPU Stress Jobs — populate all dashboard panels with live data
# Run this on BCM/Slurm head node:  bash gpu-stress.sh
#
# Submits 20+ jobs targeting all GPU nodes, exercising:
#   - GPU compute (DCGM: util, power, temp, memory)
#   - CPU + memory (node_exporter: load, memory pressure)
#   - Disk I/O (node_exporter: read/write throughput)
#   - Network (node_exporter: NIC tx/rx bytes)
#   - Slurm metrics (job counts, pending queue, GPU allocation)
#   - cgroup metrics (per-job CPU/mem tracking)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
SLURM_PARTITION="${SLURM_PARTITION:-all}"
JOB_DIR="/tmp/nvis-stress-jobs"
mkdir -p "$JOB_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Helper: submit a job and log its ID ──────────────────────────────────────
sub() {
  local name="$1" script="$2"
  local jid
  jid=$(sbatch --parsable "$script" 2>/dev/null || echo "FAILED")
  log "Submitted $name → job $jid"
}

# ── 1. GPU Burn (DCGM util, power, temp) ─────────────────────────────────────
for i in $(seq 1 5); do
cat > "$JOB_DIR/gpu-burn-${i}.sh" << JOBEOF
#!/bin/bash
#SBATCH --job-name=nvis-gpuburn-${i}
#SBATCH --partition=${SLURM_PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --time=00:30:00
#SBATCH --output=/tmp/nvis-stress-jobs/gpuburn-${i}-%j.log

# Use nvidia-smi to stress GPU if gpu_burn not available
for x in \$(seq 1 100); do
  nvidia-smi -q -d UTILIZATION 2>/dev/null || true
  python3 -c "
import torch, time
if torch.cuda.is_available():
    device = torch.device('cuda')
    a = torch.randn(4096, 4096, device=device)
    for _ in range(1000):
        b = torch.mm(a, a)
    torch.cuda.synchronize()
    del a, b
    torch.cuda.empty_cache()
    time.sleep(2)
else:
    # fallback: CPU stress
    import numpy as np
    a = np.random.randn(2048, 2048)
    for _ in range(500):
        np.dot(a, a)
    time.sleep(5)
" 2>/dev/null || python3 -c "
import time, random
# Light CPU workload as fallback
for _ in range(10000):
    x = [random.random() ** 2 for _ in range(1000)]
time.sleep(10)
"
done
JOBEOF
sub "gpu-burn-${i}" "$JOB_DIR/gpu-burn-${i}.sh"
done

# ── 2. Memory pressure (node_exporter mem metrics) ───────────────────────────
for i in $(seq 1 3); do
cat > "$JOB_DIR/mem-stress-${i}.sh" << JOBEOF
#!/bin/bash
#SBATCH --job-name=nvis-memstress-${i}
#SBATCH --partition=${SLURM_PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mem=4G
#SBATCH --time=00:20:00
#SBATCH --output=/tmp/nvis-stress-jobs/memstress-${i}-%j.log

python3 -c "
import time
# Allocate and touch memory in waves to show memory pressure
buf = []
for i in range(8):
    chunk = bytearray(512 * 1024 * 1024)  # 512MB
    buf.append(chunk)
    time.sleep(10)
    if i % 2 == 0:
        buf.pop(0)
time.sleep(60)
" 2>/dev/null || stress-ng --vm 2 --vm-bytes 1G --timeout 300s 2>/dev/null || sleep 300
JOBEOF
sub "mem-stress-${i}" "$JOB_DIR/mem-stress-${i}.sh"
done

# ── 3. Disk I/O (node_exporter disk metrics) ──────────────────────────────────
for i in $(seq 1 3); do
cat > "$JOB_DIR/disk-io-${i}.sh" << JOBEOF
#!/bin/bash
#SBATCH --job-name=nvis-diskio-${i}
#SBATCH --partition=${SLURM_PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:20:00
#SBATCH --output=/tmp/nvis-stress-jobs/diskio-${i}-%j.log

SCRATCH=\${SCRATCH:-/tmp}
WORKDIR="\$SCRATCH/nvis-diskio-\$SLURM_JOB_ID"
mkdir -p "\$WORKDIR"

# Sustained sequential write + read
for wave in \$(seq 1 20); do
  # Write 2GB file
  dd if=/dev/urandom of="\$WORKDIR/data_\${wave}.bin" bs=64M count=32 2>/dev/null || \
  dd if=/dev/zero of="\$WORKDIR/data_\${wave}.bin" bs=64M count=32 2>/dev/null
  # Read it back
  dd if="\$WORKDIR/data_\${wave}.bin" of=/dev/null bs=64M 2>/dev/null
  # Cleanup to avoid filling disk
  rm -f "\$WORKDIR/data_\${wave}.bin"
  sleep 5
done
rm -rf "\$WORKDIR"
JOBEOF
sub "disk-io-${i}" "$JOB_DIR/disk-io-${i}.sh"
done

# ── 4. Network stress (NIC TX/RX bytes) ───────────────────────────────────────
for i in $(seq 1 2); do
cat > "$JOB_DIR/net-stress-${i}.sh" << JOBEOF
#!/bin/bash
#SBATCH --job-name=nvis-netbw-${i}
#SBATCH --partition=${SLURM_PARTITION}
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:20:00
#SBATCH --output=/tmp/nvis-stress-jobs/netbw-${i}-%j.log

# Use iperf3 for network stress, fallback to python socket transfer
if command -v iperf3 &>/dev/null; then
  if [ "\$SLURM_PROCID" = "0" ]; then
    iperf3 -s -1 &
    sleep 2
    iperf3 -c \$SLURM_NODELIST -t 300 -P 4 --bidir 2>/dev/null || true
  fi
else
  # Python fallback: generate network traffic
  python3 -c "
import socket, time, os
data = os.urandom(65536)
# Send to localhost to generate NIC traffic at least
for _ in range(10000):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.sendto(data, ('127.0.0.1', 9999))
    s.close()
    time.sleep(0.01)
" 2>/dev/null || sleep 300
fi
JOBEOF
sub "net-stress-${i}" "$JOB_DIR/net-stress-${i}.sh"
done

# ── 5. CPU-only jobs (Slurm pending queue, CPU metrics) ───────────────────────
for i in $(seq 1 8); do
cat > "$JOB_DIR/cpu-load-${i}.sh" << JOBEOF
#!/bin/bash
#SBATCH --job-name=nvis-cpuload-${i}
#SBATCH --partition=${SLURM_PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=2
#SBATCH --time=00:15:00
#SBATCH --output=/tmp/nvis-stress-jobs/cpuload-${i}-%j.log

python3 -c "
import multiprocessing, time, math
def burn(n):
    end = time.time() + 600
    while time.time() < end:
        math.factorial(10000)
procs = [multiprocessing.Process(target=burn, args=(i,)) for i in range(4)]
[p.start() for p in procs]
[p.join() for p in procs]
" 2>/dev/null || yes > /dev/null &
sleep 600
kill %1 2>/dev/null || true
JOBEOF
sub "cpu-load-${i}" "$JOB_DIR/cpu-load-${i}.sh"
done

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "Submitted 21 stress jobs. Monitor with:"
log "  squeue -u \$(whoami) --format='%.10i %.20j %.8T %.10l %.6D %R'"
log ""
log "Dashboard panels that should light up:"
log "  - GPU Utilization (DCGM_FI_DEV_GPU_UTIL) — from gpu-burn jobs"
log "  - GPU Power (DCGM_FI_DEV_POWER_USAGE) — from gpu-burn jobs"
log "  - GPU Temp (DCGM_FI_DEV_GPU_TEMP) — from gpu-burn jobs"
log "  - CPU Load (node_load1/5/15) — from cpu-load jobs"
log "  - Memory Usage — from mem-stress jobs"
log "  - Disk I/O (node_disk_read/write_bytes_total) — from disk-io jobs"
log "  - NIC traffic (node_network_receive/transmit_bytes_total) — from net-stress jobs"
log "  - Active Jobs count (slurm_jobs_running_total) — all jobs"
log "  - cgroup per-job metrics — all jobs via slurmstepd cgroup"
