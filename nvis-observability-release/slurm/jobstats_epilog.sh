#!/bin/bash
cd /tmp || true
rm -f "/cm/shared/apps/slurm/jobinfo/job_${SLURM_JOB_ID}"
echo "jobstats_epilog: removed job_${SLURM_JOB_ID}"
exit 0
