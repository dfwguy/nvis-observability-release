#!/bin/bash
#SBATCH -N 1
#SBATCH -t 00:05:00
#SBATCH --job-name=cpu-mem-storm
#SBATCH -o /var/log/slurm-storm/%x-%j.out
#SBATCH -e /var/log/slurm-storm/%x-%j.err

set -euxo pipefail
mkdir -p /var/log/slurm-storm

echo "HOST=$(hostname) JOBID=$SLURM_JOB_ID START=$(date -Is)"

python3 - <<'PY'
import os, time, math
# allocate ~2GB RAM (adjust down if needed)
buf = bytearray(2 * 1024 * 1024 * 1024)
t = time.time() + 240
x = 0.0
while time.time() < t:
    x += math.sqrt(12345.6789)
print("done", x, "pid", os.getpid())
time.sleep(30)
PY

echo "END=$(date -Is)"
