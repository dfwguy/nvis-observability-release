#!/bin/bash
#SBATCH --job-name=nvis-demo
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --gpus=1
#SBATCH --mem=8G
#SBATCH --time=00:12:00
#SBATCH --output=/var/log/slurm/nvis-demo-%j.out
#SBATCH --error=/var/log/slurm/nvis-demo-%j.err
#SBATCH --comment="NVIS 10-min all-panels demo"

# ═══════════════════════════════════════════════════════════════════════════════
# NVIS 10-minute All-Panels Demo
# Cluster: node001/node002 — 1x A100, 4 CPU, 14GB RAM per node
#
# Everything runs in parallel — all panels lit within 2 minutes.
#
#   GPU Util / Temp / Power / Memory     → matmul burn (background)
#   Clock Throttle Reason = 32           → power cap on GPU0 (background)
#   Power Violation counter              → side effect of cap
#   ECC SBE / DBE log entries            → logger -t NVRM
#   XID errors log                       → logger -t NVRM Xid 48/63/94
#   Remapped rows log                    → logger -t NVRM Xid 94
#   NVLink CRC log                       → logger -t NVRM NVLink CRC
#   OOM Kill counter                     → intentional malloc bomb
#   Slurm log                            → automatic from slurmd
#   nv-hostengine.log                    → DCGM scrapes during burn + injected
#   syslog                               → logger calls below
#   Kernel log panel                     → NVRM syslog entries
# ═══════════════════════════════════════════════════════════════════════════════

JOBID=$SLURM_JOB_ID
NODE=$SLURMD_NODENAME

log() { logger -t "nvis-demo[$JOBID]" "$1"; echo "[$(date +%T)] $1"; }

log "═══ NVIS demo job $JOBID starting on $NODE ═══"
nvidia-smi --query-gpu=index,name,power.limit,ecc.mode.current \
           --format=csv,noheader | logger -t "nvis-demo[$JOBID]"

# ─────────────────────────────────────────────────────────────────────────────
# TRACK 1 — GPU burn (8 min background)
# Lights up: GPU Util, Temp, Memory, Power, nv-hostengine.log
# ─────────────────────────────────────────────────────────────────────────────
log "TRACK 1 → GPU burn starting (8 min)"
python3 -c "
import torch, time, signal, sys
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
dev = torch.device('cuda:0')
total = torch.cuda.get_device_properties(dev).total_memory
sz = int(((total * 0.50) / 4) ** 0.5)
A = torch.randn(sz, sz, device=dev)
B = torch.randn(sz, sz, device=dev)
mem_hog = torch.randn(sz // 2, sz // 2, device=dev)
print(f'GPU burn started — matrix {sz}x{sz} mem={torch.cuda.memory_allocated(dev)/1024**2:.0f}MB')
t_end = time.time() + 480
itr = 0
while time.time() < t_end:
    C = torch.mm(A, B)
    torch.cuda.synchronize()
    itr += 1
print(f'GPU burn done — {itr} iters')
" &
BURN_PID=$!

# ─────────────────────────────────────────────────────────────────────────────
# TRACK 2 — Power cap → forces throttle reason = 32
# Lights up: Clock Throttle Reason panel, Power Violation counter
# ─────────────────────────────────────────────────────────────────────────────
log "TRACK 2 → Power cap 150W on GPU0 (throttle reason=32)"
ORIG=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader -i 0 | tr -d ' W')
nvidia-smi -pl 150 -i 0 2>&1 | logger -t "nvis-demo[$JOBID]"
log "Power cap set 150W (was ${ORIG}W) — restoring at job end"

# ─────────────────────────────────────────────────────────────────────────────
# TRACK 3 — All log injections (fire immediately)
# Lights up: ECC DBE/SBE, XID, Remapped Rows, NVLink CRC, nv-hostengine, kernel
# ─────────────────────────────────────────────────────────────────────────────
log "TRACK 3 → Log injections — all Loki panels"

# syslog panel
logger -t "nvis-demo[$JOBID]" -p syslog.info \
    "JOB_START job=$JOBID user=$USER node=$NODE"
logger -t "nvis-demo[$JOBID]" -p syslog.warning \
    "GPU memory pressure detected job=$JOBID node=$NODE"

# nv-hostengine log panel
logger -t "nv-hostengine" \
    "INFO  DCGM health check started job=$JOBID GPU=0"
logger -t "nv-hostengine" \
    "WARN  ECC SBE count increasing GPU 0 correctable errors job=$JOBID"
logger -t "nv-hostengine" \
    "ERROR DBE ECC GPU 0 double-bit uncorrectable job=$JOBID action=reset_required"
logger -t "nv-hostengine" \
    "WARN  Power violation GPU 0 throttling active job=$JOBID"

# kernel log panel — ECC SBE
logger -t "NVRM" -p kern.warning \
    "ECC SBE: GPU-00000000:03:00.0 correctable error count=4 job=$JOBID"

# kernel log panel — ECC DBE (double-bit) → DBE panel goes RED
logger -t "NVRM" -p kern.crit \
    "Xid (PCI:0000:03:00): 48, pid=$$, name=nvis-demo, Double Bit ECC Error GPU 0 job=$JOBID"

# kernel log panel — remapped rows
logger -t "NVRM" -p kern.warning \
    "Xid (PCI:0000:03:00): 94, pid=$$, name=nvis-demo, Row Remapper: New row to remap detected. Reset GPU to activate. job=$JOBID"

# kernel log panel — XID hardware error
logger -t "NVRM" -p kern.err \
    "Xid (PCI:0000:03:00): 63, pid=$$, name=nvis-demo, Row Remapper: HW error job=$JOBID"

# kernel log panel — NVLink CRC
logger -t "NVRM" -p kern.warning \
    "NVLink: GPU 0 Link 2 CRC FLIT error detected — check cable/connector job=$JOBID"

log "TRACK 3 → Log injections done — Loki panels populate within ~30s"

# ─────────────────────────────────────────────────────────────────────────────
# TRACK 4 — OOM kill (fires at t+30s)
# Lights up: OOM Kill counter (cgroup_memory_fail_count)
# ─────────────────────────────────────────────────────────────────────────────
log "TRACK 4 → OOM trigger in 30s"
(sleep 30 && \
    logger -t "nvis-demo[$JOBID]" "OOM test starting" && \
    python3 -c "
chunks = []
for i in range(500):
    chunks.append(bytearray(100 * 1024 * 1024))
" || logger -t "nvis-demo[$JOBID]" "OOM killed as expected — cgroup_memory_fail_count incremented") &
OOM_PID=$!

# ─────────────────────────────────────────────────────────────────────────────
# Hold until burn finishes (~8 min) then clean up
# ─────────────────────────────────────────────────────────────────────────────
log "All tracks running — open Grafana now"
log "  GPU Health dashboard → node=$NODE, time=Last 15 min"
log "  Single-Job Stats     → JobID=$JOBID,  time=Last 15 min"

wait $BURN_PID

kill $OOM_PID 2>/dev/null; wait $OOM_PID 2>/dev/null || true

nvidia-smi -pl $ORIG -i 0 2>&1 | logger -t "nvis-demo[$JOBID]"
log "Power restored to ${ORIG}W"

logger -t "nvis-demo[$JOBID]" -p syslog.info \
    "JOB_END job=$JOBID node=$NODE status=COMPLETED"
logger -t "nv-hostengine" \
    "INFO  DCGM health check complete job=$JOBID no persistent faults"

log "═══ NVIS demo job $JOBID DONE ═══"
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  Panel                    Expected               ║"
echo "║  ─────────────────────────────────────────────   ║"
echo "║  GPU Utilization         ~80-95%                 ║"
echo "║  GPU Temperature         ~70-82C                 ║"
echo "║  GPU Memory Used         ~50% FB                 ║"
echo "║  GPU Power Draw          ~280-350W               ║"
echo "║  Clock Throttle Reason   32 = power cap orange   ║"
echo "║  Power Violations        non-zero                ║"
echo "║  ECC DBE Counter         red (log inject)        ║"
echo "║  ECC SBE Counter         non-zero (log inject)   ║"
echo "║  Remapped Rows           log entry               ║"
echo "║  XID Errors              red (log inject)        ║"
echo "║  NVLink CRC              log entry               ║"
echo "║  OOM Kill Counter        1+ events               ║"
echo "║  Syslog panel            job events              ║"
echo "║  nv-hostengine log       WARN + ERROR entries    ║"
echo "║  Slurm log               job start/end           ║"
echo "║  Kernel log              NVRM/Xid entries        ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Single-Job Stats → JobID = $JOBID              "
echo "╚══════════════════════════════════════════════════╝"

