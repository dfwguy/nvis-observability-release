#!/bin/bash
cd /tmp || true
JOBINFO_DIR="/cm/shared/apps/slurm/jobinfo"
mkdir -p "$JOBINFO_DIR"

cat > "${JOBINFO_DIR}/job_${SLURM_JOB_ID}" << JOBEOF
jobid=${SLURM_JOB_ID}
user=${SLURM_JOB_USER}
account=${SLURM_JOB_ACCOUNT}
nodes=${SLURM_JOB_NODELIST}
ncpus=${SLURM_JOB_CPUS_PER_NODE}
JOBEOF

chmod 644 "${JOBINFO_DIR}/job_${SLURM_JOB_ID}"
echo "jobstats_prolog: wrote ${JOBINFO_DIR}/job_${SLURM_JOB_ID}"
exit 0
