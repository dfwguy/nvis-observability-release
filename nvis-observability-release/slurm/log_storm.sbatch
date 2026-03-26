#!/bin/bash
#SBATCH -N 1
#SBATCH -t 00:05:00
#SBATCH --job-name=log-storm
#SBATCH -o /var/log/slurm-storm/%x-%j.out
#SBATCH -e /var/log/slurm-storm/%x-%j.err

set -euxo pipefail
mkdir -p /var/log/slurm-storm

echo "HOST=$(hostname) JOBID=$SLURM_JOB_ID START=$(date -Is)"

# High-rate log file (Alloy is already tailing /var/log/* in your config set)
LOG=/var/log/slurm-storm/storm.log
for i in $(seq 1 2000); do
  echo "$(date -Is) STORM job=$SLURM_JOB_ID host=$(hostname) i=$i msg='dashboard christmas tree test'" >> "$LOG"
done

# Also emit to stdout/stderr
echo "STDOUT storm complete"
echo "STDERR storm complete" >&2

echo "END=$(date -Is)"
