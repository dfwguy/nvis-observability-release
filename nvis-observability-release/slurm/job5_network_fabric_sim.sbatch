#!/bin/bash
#SBATCH --job-name=network-fabric-sim
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=04:00:00
#SBATCH --output=/var/log/slurm/network_fabric_%j.log
#SBATCH --error=/var/log/slurm/network_fabric_%j.err
#SBATCH --comment="NVIS Demo: Network Fabric — NVIDIA Air + SpectrumX NV72"

# =============================================================================
# NVIS Demo Job 5: Network Fabric Simulation
# Generates fabric metrics for:
#   - NVIDIA Air (Spectrum-3, current cluster)
#   - LillyPod B300 (SpectrumX 2.0 NV72 switches, 400GbE)
# Adds fabric dropdown to Network Fabric dashboard.
# Submit from BCM: sbatch job5_network_fabric_sim.sh
# =============================================================================

OBSVM_IP="${OBSVM_IP:-10.127.28.83}"
TEXTFILE="/var/lib/node_exporter/textfile/network_fabric.prom"
mkdir -p "$(dirname $TEXTFILE)"

echo "[$(date)] Network fabric simulation starting"
echo "[$(date)] Clusters: nvidia-air (Spectrum-3) + lillypod-b300 (SpectrumX NV72)"

python3 - << 'PYEOF'
import time, math, random, os
from datetime import datetime

OBSVM_IP = os.environ.get("OBSVM_IP", "10.127.28.83")
TEXTFILE = "/var/lib/node_exporter/textfile/network_fabric.prom"
LOKI_URL = f"http://{OBSVM_IP}:3100/loki/api/v1/push"

CLUSTERS = {
    "cod-a100-2node": {
        "label": "NVIDIA Air",
        "model": "Spectrum-3",
        "fabric": "nvidia-air",
        "topology": "fat-tree",
        "num_spine": 2,
        "num_leaf": 2,
        "link_gbps": 100,
        "base_util": 0.40,
    },
    "lillypod-b300": {
        "label": "LillyPod B300 SpectrumX NV72",
        "model": "Spectrum-X-NV72",
        "fabric": "spectrumx2",
        "topology": "rail-optimized",
        "num_spine": 9,
        "num_leaf": 9,
        "link_gbps": 400,
        "base_util": 0.82,
    },
}

def noise(v, pct=0.05):
    return v * (1 + random.uniform(-pct, pct))

def push_log(level, msg, cluster):
    import urllib.request, json
    ts = str(int(time.time() * 1e9))
    payload = json.dumps({"streams":[{"stream":{"job":"network-fabric","cluster":cluster,"level":level},"values":[[ts,msg]]}]}).encode()
    try:
        req = urllib.request.Request(LOKI_URL, data=payload, headers={"Content-Type":"application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=3)
    except Exception:
        pass

print(f"[{datetime.now():%H:%M:%S}] Fabric sim starting for {list(CLUSTERS.keys())}")

t = 0
while True:
    lines = []

    for cluster, cfg in CLUSTERS.items():
        lspeed = cfg["link_gbps"] * 1024 * 1024 * 1024 // 8

        # Spine switches
        for si in range(cfg["num_spine"]):
            sw = f"spine-{cluster}-{si:02d}"
            for port in range(16):
                phase = (t + si * 11 + port * 3) * 0.05
                util = max(0.02, min(0.99, noise(cfg["base_util"] + 0.12*math.sin(phase), 0.05)))
                rx = int(lspeed * util)
                tx = int(lspeed * util * 0.95)
                pfc = int(random.uniform(0,30)) if util > 0.80 else 0
                ecn = int(random.uniform(0,10)) if util > 0.88 else 0
                lbl = f'switch="{sw}",role="spine",port="{port}",cluster="{cluster}",fabric="{cfg["fabric"]}",model="{cfg["model"]}",topology="{cfg["topology"]}"'
                lines += [
                    f'nvis_fabric_port_rx_bytes_total{{{lbl}}} {rx}',
                    f'nvis_fabric_port_tx_bytes_total{{{lbl}}} {tx}',
                    f'nvis_fabric_port_util_ratio{{{lbl}}} {util:.4f}',
                    f'nvis_fabric_pfc_frames_total{{{lbl}}} {pfc}',
                    f'nvis_fabric_ecn_marked_total{{{lbl}}} {ecn}',
                    f'nvis_fabric_errors_total{{{lbl}}} 0',
                    f'nvis_fabric_link_speed_bps{{{lbl}}} {lspeed * 8}',
                ]

        # Leaf switches
        for li in range(cfg["num_leaf"]):
            sw = f"leaf-{cluster}-{li:02d}"
            for port in range(16):
                phase = (t + li * 7 + port * 5) * 0.04
                util = max(0.02, min(0.99, noise(cfg["base_util"] + 0.10*math.sin(phase), 0.06)))
                rx = int(lspeed * util)
                tx = int(lspeed * util * 0.93)
                pfc = int(random.uniform(0,50)) if util > 0.75 else 0
                ecn = int(random.uniform(0,20)) if util > 0.85 else 0
                errors = 0 if cfg["model"].startswith("Spectrum-X") else int(random.uniform(0,3))
                lbl = f'switch="{sw}",role="leaf",port="{port}",cluster="{cluster}",fabric="{cfg["fabric"]}",model="{cfg["model"]}",topology="{cfg["topology"]}"'
                lines += [
                    f'nvis_fabric_port_rx_bytes_total{{{lbl}}} {rx}',
                    f'nvis_fabric_port_tx_bytes_total{{{lbl}}} {tx}',
                    f'nvis_fabric_port_util_ratio{{{lbl}}} {util:.4f}',
                    f'nvis_fabric_pfc_frames_total{{{lbl}}} {pfc}',
                    f'nvis_fabric_ecn_marked_total{{{lbl}}} {ecn}',
                    f'nvis_fabric_errors_total{{{lbl}}} {errors}',
                    f'nvis_fabric_link_speed_bps{{{lbl}}} {lspeed * 8}',
                ]

        # Cluster-wide fabric summary
        avg_util = noise(cfg["base_util"], 0.04)
        lines += [
            f'nvis_fabric_cluster_avg_util{{cluster="{cluster}",fabric="{cfg["fabric"]}",model="{cfg["model"]}"}} {avg_util:.4f}',
            f'nvis_fabric_cluster_switches{{cluster="{cluster}",fabric="{cfg["fabric"]}",model="{cfg["model"]}"}} {cfg["num_spine"]+cfg["num_leaf"]}',
            f'nvis_fabric_cluster_link_speed_gbps{{cluster="{cluster}",fabric="{cfg["fabric"]}",model="{cfg["model"]}"}} {cfg["link_gbps"]}',
        ]

    with open(TEXTFILE, "w") as f:
        f.write("\n".join(lines) + "\n")

    t += 15
    if t % 120 == 0:
        print(f"[{datetime.now():%H:%M:%S}] {len(lines)} fabric metrics written")
        for cluster, cfg in CLUSTERS.items():
            push_log("INFO", f"Fabric telemetry: {cfg['label']} | {cfg['num_spine']+cfg['num_leaf']} switches | {cfg['link_gbps']}GbE", cluster)

    time.sleep(15)
PYEOF

rm -f "$TEXTFILE"
echo "[$(date)] Network fabric simulation ended"
