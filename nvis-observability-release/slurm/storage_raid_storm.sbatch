#!/bin/bash
#SBATCH --job-name=storage_raid_storm
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:15:00
#SBATCH --output=/tmp/storage_raid_%j.log
echo "[$(date)] STORAGE STORM on $(hostname)"
for i in 1 2 3 4; do
  dd if=/dev/zero of=/tmp/raid_test_${i}_$$.dat bs=1M count=1024 oflag=direct conv=fdatasync 2>/dev/null &
done
wait
mkdir -p /var/lib/node_exporter/textfile
cat > /var/lib/node_exporter/textfile/nvis_storage.prom << PROM
# HELP nvis_disk_latency_ms Disk latency ms
# TYPE nvis_disk_latency_ms gauge
nvis_disk_latency_ms{node="$(hostname)",device="vda",cluster="cod-a100-2node"} 485.3
# HELP nvis_disk_queue_depth Disk queue depth
# TYPE nvis_disk_queue_depth gauge
nvis_disk_queue_depth{node="$(hostname)",device="vda",cluster="cod-a100-2node"} 128
# HELP nvis_raid_degraded RAID degraded
# TYPE nvis_raid_degraded gauge
nvis_raid_degraded{node="$(hostname)",cluster="cod-a100-2node"} 1
PROM
logger -t "mdadm" -p kern.error "RAID degraded on $(hostname) — disk latency 485ms, queue depth 128"
logger -t "slurmd" -p daemon.warning "WARNING: Job IOWait >60% on $(hostname) — storage bottleneck detected"
sleep 300
rm -f /tmp/raid_test_*_$$.dat /var/lib/node_exporter/textfile/nvis_storage.prom

