#!/bin/bash
#SBATCH --job-name=nccl_conn_storm
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --time=00:10:00
#SBATCH --output=/tmp/nccl_%j.log
echo "[$(date)] NCCL CONNECTION STORM on $(hostname)"
mkdir -p /var/lib/node_exporter/textfile
cat > /var/lib/node_exporter/textfile/nvis_nccl.prom << PROM
# HELP nvis_nccl_connections Active NCCL TCP connections
# TYPE nvis_nccl_connections gauge
nvis_nccl_connections{node="$(hostname)",cluster="cod-a100-2node"} 847
# HELP nvis_nccl_bandwidth_bytes NCCL allreduce bandwidth
# TYPE nvis_nccl_bandwidth_bytes gauge
nvis_nccl_bandwidth_bytes{node="$(hostname)",cluster="cod-a100-2node"} 24576000000
# HELP nvis_nccl_latency_us NCCL latency microseconds
# TYPE nvis_nccl_latency_us gauge
nvis_nccl_latency_us{node="$(hostname)",cluster="cod-a100-2node"} 285
PROM
logger -t "nccl-monitor" -p daemon.info "INFO: NCCL allreduce init — 847 connections opened for ring-allreduce on $(hostname)"
logger -t "nccl-monitor" -p daemon.warning "WARNING: NCCL bandwidth degraded 24.5GB/s vs expected 200GB/s — fabric congestion"
# Generate TCP connections
python3 -c "
import socket,time,threading
s=[]
for i in range(200):
    try:
        x=socket.socket()
        x.connect(('127.0.0.1',22))
        s.append(x)
    except: pass
print(f'Opened {len(s)} connections')
time.sleep(300)
[x.close() for x in s]
" 2>/dev/null || sleep 300
rm -f /var/lib/node_exporter/textfile/nvis_nccl.prom

