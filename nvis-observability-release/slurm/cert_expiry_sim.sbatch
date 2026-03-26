#!/bin/bash
#SBATCH --job-name=cert_expiry_sim
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:05:00
#SBATCH --output=/tmp/cert_sim_%j.log
echo "[$(date)] CERTIFICATE EXPIRY SIMULATION"
logger -t "DMS-TLS" -p daemon.error "CRITICAL: Certificate dms-roce-config expires in 2 days (30-day cert bug #4931377)"
logger -t "DMS-TLS" -p daemon.warning "WARNING: RoCE QoS config failed — TLS cert validation error"
logger -t "spectrum-x" -p daemon.error "ERROR: Spectrum-X daemon restart failed — cert CN=dms-config expired"
logger -t "rdma-config" -p daemon.warning "WARNING: RoCE congestion control NOT applied — expired cert"
logger -t "security-audit" -p auth.notice "NOTICE: SSH login 10.63.85.142 user hlakshminara"
logger -t "security-audit" -p auth.warning "WARNING: Certificate ufm-telemetry expired 0 days ago — service down"
logger -t "DMS-TLS" -p daemon.error "ERROR: generate_cert.sh missing -days — defaulted to 30 days"
mkdir -p /var/lib/node_exporter/textfile
cat > /var/lib/node_exporter/textfile/nvis_certs.prom << PROM
# HELP nvis_cert_days_remaining Days until cert expiry
# TYPE nvis_cert_days_remaining gauge
nvis_cert_days_remaining{service="dms-roce-config",node="$(hostname)",cluster="cod-a100-2node"} 2
nvis_cert_days_remaining{service="ufm-telemetry",node="$(hostname)",cluster="cod-a100-2node"} 0
nvis_cert_days_remaining{service="webInterface",node="$(hostname)",cluster="cod-a100-2node"} 36158
nvis_cert_days_remaining{service="slurm",node="$(hostname)",cluster="cod-a100-2node"} 36158
# HELP nvis_cert_expired Certificate expired flag
# TYPE nvis_cert_expired gauge
nvis_cert_expired{service="ufm-telemetry",node="$(hostname)",cluster="cod-a100-2node"} 1
nvis_cert_expired{service="dms-roce-config",node="$(hostname)",cluster="cod-a100-2node"} 0
PROM
echo "[$(date)] Cert metrics injected — check Security Audit dashboard"
sleep 240
rm -f /var/lib/node_exporter/textfile/nvis_certs.prom

