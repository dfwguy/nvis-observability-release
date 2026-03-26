#!/bin/bash
#SBATCH -J gpu-burn
#SBATCH -N 1
#SBATCH --gres=gpu:1
#SBATCH -t 00:10:00
#SBATCH -o /tmp/%x-%j.out
#SBATCH -e /tmp/%x-%j.err

set -euo pipefail
echo "JOBID=$SLURM_JOB_ID HOST=$(hostname -s) START=$(date -Is)"

# Prefer SLURM_TMPDIR if it exists, else /tmp
WORKDIR="${SLURM_TMPDIR:-/tmp}/gpu-burn-${SLURM_JOB_ID}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Sanity: GPU visible
nvidia-smi -L || true

IMAGE="nvcr.io/nvidia/cuda:12.2.0-devel-ubuntu22.04"

# Build + run gpu-burn inside container
# (Assumes docker is installed and NVIDIA runtime works.)
docker run --rm --gpus all \
  -v "$WORKDIR:/work" -w /work \
  "$IMAGE" bash -lc '
    set -euo pipefail
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends git make g++ ca-certificates

    if [ ! -d gpu-burn ]; then
      git clone --depth 1 https://github.com/wilicc/gpu-burn.git
    fi
    cd gpu-burn
    make -j"$(nproc)"
    # Run ~5 minutes to create obvious utilization
    ./gpu_burn 300
  '

echo "DONE=$(date -Is)"
