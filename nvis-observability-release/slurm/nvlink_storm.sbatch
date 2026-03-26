#!/bin/bash
#SBATCH -J nvlink-storm
#SBATCH -N 1
#SBATCH --gres=gpu:1
#SBATCH -t 00:10:00
#SBATCH -o /tmp/%x-%j.out
#SBATCH -e /tmp/%x-%j.err

set -euo pipefail

HOST="$(hostname)"
START="$(date -Is)"
GPU="${CUDA_VISIBLE_DEVICES:-na}"
USER="${SLURM_JOB_USER:-unknown}"
PART="${SLURM_JOB_PARTITION:-unknown}"

# Set this to whatever you're using as the Loki "cluster" label
CLUSTER="cod-a100-2node"

echo "JOBID=$SLURM_JOB_ID HOST=$HOST GPU=$GPU START=$START"
echo "This job writes fake NVLink error lines to syslog with jobid + node + gpu in the message."

META="cluster=${CLUSTER} event=nvlink jobid=${SLURM_JOB_ID} user=${USER} partition=${PART} node=${HOST} gpu=${GPU} jobname=${SLURM_JOB_NAME}"

log_line () {
  local pri="$1"; shift
  local tag="$1"; shift
  local msg="$*"

  if command -v logger >/dev/null 2>&1; then
    logger -p "${pri}" -t "${tag}" "${msg}"
  else
    echo "$(date -Is) ${tag}: ${msg}" | sudo tee -a /var/log/syslog >/dev/null
  fi
}

log_line "user.notice" "slurm-job" "event=job_start cluster=${CLUSTER} jobid=${SLURM_JOB_ID} user=${USER} partition=${PART} node=${HOST} gpu=${GPU} jobname=${SLURM_JOB_NAME}"

for i in $(seq 1 600); do
  log_line "user.err" "nvidia-nvlink" "${META} nvlink_code=0xdead link=0 msg=\"NVLink storm demo line ${i}\""
  sleep 0.2
done

log_line "user.notice" "slurm-job" "event=job_end cluster=${CLUSTER} jobid=${SLURM_JOB_ID} user=${USER} partition=${PART} node=${HOST} gpu=${GPU} jobname=${SLURM_JOB_NAME}"

echo "DONE=$(date -Is)"
