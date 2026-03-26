#!/bin/bash
#SBATCH -J gpu-tensor-storm
#SBATCH -N 1
#SBATCH --gres=gpu:1
#SBATCH -t 00:05:00
#SBATCH -o /tmp/%x-%j.out
#SBATCH -e /tmp/%x-%j.err

set -euo pipefail

echo "JOBID=$SLURM_JOB_ID HOST=$(hostname) START=$(date -Is)"
nvidia-smi -L

# Use docker + nvidia runtime. Keep it simple.
# This container already has torch + cuda.
IMG="nvcr.io/nvidia/pytorch:24.01-py3"

# Pull once (optional but nice for repeatability)
docker pull "$IMG"

# Run a tight GEMM loop to force high SM util
docker run --rm --gpus all --ipc=host "$IMG" bash -lc '
python3 - << "PY"
import torch, time, os
torch.cuda.init()
dev="cuda:0"
a=torch.randn(16384,16384,device=dev,dtype=torch.float16)
b=torch.randn(16384,16384,device=dev,dtype=torch.float16)
torch.cuda.synchronize()
t0=time.time()
end=t0+240
i=0
while time.time()<end:
    c=a@b
    # keep it from being optimized away
    c[0,0].item()
    i+=1
torch.cuda.synchronize()
print("iters", i, "secs", time.time()-t0)
PY
'
echo "DONE=$(date -Is)"
