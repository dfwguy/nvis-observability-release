#!/bin/bash
#SBATCH --job-name=lillypod-b300-sim
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=04:00:00
#SBATCH --output=/var/log/slurm/lillypod_b300_%j.log
#SBATCH --error=/var/log/slurm/lillypod_b300_%j.err
#SBATCH --comment="NVIS Demo: LillyPod B300 Cluster Simulation"

# =============================================================================
# NVIS Demo Job 4: LillyPod B300 Cluster Simulation
# Simulates a 127-node B300 SuperPOD cluster (Eli Lilly) with 1,016 GPUs.
# Select "lillypod-b300" from the cluster dropdown in any NVIS dashboard.
# Submit from BCM: sbatch job4_lillypod_b300_sim.sh
# =============================================================================

OBSVM_IP="${OBSVM_IP:-10.127.28.83}"
CLUSTER="lillypod-b300"
TEXTFILE="/var/lib/node_exporter/textfile/lillypod_b300.prom"
mkdir -p "$(dirname $TEXTFILE)"

echo "[$(date)] LillyPod B300 simulation starting on $(hostname)"
echo "[$(date)] Pushing metrics to ObsVM: $OBSVM_IP"
echo "[$(date)] Select 'lillypod-b300' from cluster dropdown in Grafana"

# Deploy topology dashboard to Grafana on first run
deploy_dashboard() {
  curl -sf -X POST \
    -H "Content-Type: application/json" \
    -u "admin:${GRAFANA_PASS:-NVIS_CBU}" \
    "http://${OBSVM_IP}:3000/api/dashboards/db" \
    -d '{
      "overwrite": true,
      "folderId": 0,
      "dashboard": {
        "title": "Live Topology — Multi-Cluster",
        "uid": "nvis-live-topology-v2",
        "tags": ["topology","b300","live"],
        "refresh": "10s",
        "timezone": "browser",
        "time": {"from": "now-30m", "to": "now"},
        "templating": {"list": [
          {"name":"datasource","type":"datasource","query":"prometheus","label":"Prometheus","hide":0,"refresh":1},
          {"name":"cluster","type":"query","label":"Cluster","hide":0,"refresh":2,"multi":false,"includeAll":false,
           "datasource":{"type":"prometheus","uid":"nvis-prometheus"},
           "definition":"label_values(nvis_cluster_total_nodes, cluster)",
           "query":{"query":"label_values(nvis_cluster_total_nodes, cluster)","refId":"A"}}
        ]},
        "panels": [
          {"type":"stat","title":"Total Nodes","gridPos":{"h":4,"w":4,"x":0,"y":0},
           "datasource":{"type":"prometheus","uid":"nvis-prometheus"},
           "targets":[{"expr":"nvis_cluster_total_nodes{cluster=\"$cluster\"}","refId":"A","legendFormat":"Nodes"}],
           "fieldConfig":{"defaults":{"color":{"mode":"thresholds"},"thresholds":{"steps":[{"color":"green","value":0}]}}}},
          {"type":"stat","title":"Allocated GPUs","gridPos":{"h":4,"w":4,"x":4,"y":0},
           "datasource":{"type":"prometheus","uid":"nvis-prometheus"},
           "targets":[{"expr":"nvis_cluster_allocated_gpus{cluster=\"$cluster\"}","refId":"A"}],
           "fieldConfig":{"defaults":{"color":{"mode":"thresholds"},"thresholds":{"steps":[{"color":"blue","value":0}]}}}},
          {"type":"stat","title":"Avg GPU Util","gridPos":{"h":4,"w":4,"x":8,"y":0},
           "datasource":{"type":"prometheus","uid":"nvis-prometheus"},
           "targets":[{"expr":"avg(DCGM_FI_DEV_GPU_UTIL{cluster=\"$cluster\"})","refId":"A"}],
           "fieldConfig":{"defaults":{"unit":"percent","thresholds":{"steps":[{"color":"green","value":0},{"color":"yellow","value":70},{"color":"red","value":90}]}}}},
          {"type":"stat","title":"Active Jobs","gridPos":{"h":4,"w":4,"x":12,"y":0},
           "datasource":{"type":"prometheus","uid":"nvis-prometheus"},
           "targets":[{"expr":"nvis_cluster_active_jobs{cluster=\"$cluster\"}","refId":"A"}],
           "fieldConfig":{"defaults":{"color":{"mode":"thresholds"},"thresholds":{"steps":[{"color":"blue","value":0}]}}}},
          {"type":"timeseries","title":"GPU Utilization by Node","gridPos":{"h":8,"w":12,"x":0,"y":4},
           "datasource":{"type":"prometheus","uid":"nvis-prometheus"},
           "fieldConfig":{"defaults":{"unit":"percent","min":0,"max":100}},
           "targets":[{"expr":"avg by (node) (DCGM_FI_DEV_GPU_UTIL{cluster=\"$cluster\"})","legendFormat":"{{node}}","refId":"A"}]},
          {"type":"timeseries","title":"GPU Memory Used","gridPos":{"h":8,"w":12,"x":12,"y":4},
           "datasource":{"type":"prometheus","uid":"nvis-prometheus"},
           "fieldConfig":{"defaults":{"unit":"bytes"}},
           "targets":[{"expr":"avg by (node) (DCGM_FI_DEV_FB_USED{cluster=\"$cluster\"} * 1024 * 1024)","legendFormat":"{{node}}","refId":"A"}]},
          {"type":"timeseries","title":"NVLink Bandwidth","gridPos":{"h":8,"w":12,"x":0,"y":12},
           "datasource":{"type":"prometheus","uid":"nvis-prometheus"},
           "fieldConfig":{"defaults":{"unit":"Bps"}},
           "targets":[{"expr":"sum by (node) (DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL{cluster=\"$cluster\"})","legendFormat":"{{node}}","refId":"A"}]},
          {"type":"timeseries","title":"GPU Temperature","gridPos":{"h":8,"w":12,"x":12,"y":12},
           "datasource":{"type":"prometheus","uid":"nvis-prometheus"},
           "fieldConfig":{"defaults":{"unit":"celsius","thresholds":{"steps":[{"color":"green","value":0},{"color":"yellow","value":70},{"color":"red","value":85}]}}},
           "targets":[{"expr":"avg by (node) (DCGM_FI_DEV_GPU_TEMP{cluster=\"$cluster\"})","legendFormat":"{{node}}","refId":"A"}]}
        ],
        "schemaVersion": 39
      }
    }' > /dev/null 2>&1 && echo "[$(date)] Dashboard deployed to Grafana" || echo "[$(date)] Dashboard already exists or deploy failed"
}

deploy_dashboard

# Run Python simulation inline
python3 - << 'PYEOF'
import time, math, random, os, sys
from datetime import datetime

OBSVM_IP = os.environ.get("OBSVM_IP", "10.127.28.83")
CLUSTER = "lillypod-b300"
ORG = "Eli-Lilly"
NUM_NODES = 127
GPUS_PER_NODE = 8
TOTAL_GPUS = NUM_NODES * GPUS_PER_NODE
TEXTFILE = "/var/lib/node_exporter/textfile/lillypod_b300.prom"
LOKI_URL = f"http://{OBSVM_IP}:3100/loki/api/v1/push"

ACTIVE_JOBS = [
    {"id":"100001","user":"dr.j.patel",    "org":"Eli-Lilly-Oncology",  "gpus":128,"nodes":16,"type":"LLM-Training"},
    {"id":"100002","user":"m.rodriguez",   "org":"Eli-Lilly-Genomics",  "gpus":64, "nodes":8, "type":"Molecular-Sim"},
    {"id":"100003","user":"dr.sarah.chen", "org":"NVIDIA-Research",     "gpus":256,"nodes":32,"type":"Foundation-Model"},
    {"id":"100004","user":"t.nakamura",    "org":"NVIDIA-DGX-Cloud",    "gpus":192,"nodes":24,"type":"Inference-Tuning"},
    {"id":"100005","user":"a.okonkwo",     "org":"Eli-Lilly-Chemistry", "gpus":32, "nodes":4, "type":"Drug-Discovery"},
]

def noise(v, pct=0.05):
    return v * (1 + random.uniform(-pct, pct))

def push_log(level, msg):
    import urllib.request, json
    ts = str(int(time.time() * 1e9))
    payload = json.dumps({"streams":[{"stream":{"job":"b300-sim","cluster":CLUSTER,"org":ORG,"level":level},"values":[[ts,msg]]}]}).encode()
    try:
        req = urllib.request.Request(LOKI_URL, data=payload, headers={"Content-Type":"application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=3)
    except Exception:
        pass

print(f"[{datetime.now():%H:%M:%S}] B300 sim: {NUM_NODES} nodes | {TOTAL_GPUS} GPUs | cluster={CLUSTER}")
push_log("INFO", f"LillyPod B300 online — {NUM_NODES} nodes {TOTAL_GPUS} GPUs {len(ACTIVE_JOBS)} active jobs")

t = 0
while True:
    lines = []
    allocated_gpus = sum(j["gpus"] for j in ACTIVE_JOBS)
    active_nodes = sum(j["nodes"] for j in ACTIVE_JOBS)

    # Assign jobs to nodes
    job_for_node = {}
    offset = 0
    for job in ACTIVE_JOBS:
        for ni in range(offset, min(offset + job["nodes"], NUM_NODES)):
            job_for_node[ni] = job
        offset += job["nodes"]

    for ni in range(NUM_NODES):
        node = f"b300-node{ni:03d}"
        ip = f"10.150.{ni//256}.{ni%256}"
        job = job_for_node.get(ni)
        base_lbl = f'cluster="{CLUSTER}",org="{ORG}",node="{node}",instance="{ip}:9400"'

        if job:
            phase = (t + ni * 7) * 0.1
            util = max(0, min(100, noise(92 + 5*math.sin(phase), 0.05)))
            temp = noise(72 + 8*math.sin(phase*0.7), 0.03)
            power = noise(720 + 50*math.sin(phase*0.5), 0.04)
            mem_used_frac = noise(0.78, 0.05)
        else:
            util = noise(random.uniform(0,8), 0.1)
            temp = noise(38, 0.05)
            power = noise(65, 0.05)
            mem_used_frac = noise(0.05, 0.1)

        gpu_mem_total = 192 * 1024  # MB, 192GB HBM3e
        lines.append(f'node_uname_info{{instance="{ip}:9100",nodename="{node}",{base_lbl}}} 1')

        for gpu in range(GPUS_PER_NODE):
            g_lbl = f'{base_lbl},gpu="{gpu}"'
            g_util = max(0, min(100, noise(util + random.uniform(-3,3), 0.03)))
            g_mem = int(gpu_mem_total * noise(mem_used_frac, 0.05))
            nvlink = noise(900*1024*1024*1024 if job else 0, 0.1)
            lines += [
                f'DCGM_FI_DEV_GPU_UTIL{{{g_lbl},job="dcgm-exporter"}} {g_util:.1f}',
                f'DCGM_FI_DEV_GPU_TEMP{{{g_lbl},job="dcgm-exporter"}} {noise(temp+gpu*0.5,0.02):.1f}',
                f'DCGM_FI_DEV_POWER_USAGE{{{g_lbl},job="dcgm-exporter"}} {noise(power+random.uniform(-20,20),0.03):.1f}',
                f'DCGM_FI_DEV_FB_USED{{{g_lbl},job="dcgm-exporter"}} {g_mem}',
                f'DCGM_FI_DEV_FB_FREE{{{g_lbl},job="dcgm-exporter"}} {gpu_mem_total - g_mem}',
                f'DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL{{{g_lbl},job="dcgm-exporter"}} {nvlink:.0f}',
                f'DCGM_FI_DEV_XID_ERRORS{{{g_lbl},job="dcgm-exporter"}} 0',
            ]
            if job:
                lines.append(f'DCGM_FI_DEV_GPU_UTIL{{{g_lbl},job_id="{job["id"]}",user="{job["user"]}",job="dcgm-exporter"}} {g_util:.1f}')

        net = noise(350*1024*1024*1024 if job else 1*1024*1024*1024, 0.1)
        lines += [
            f'node_network_receive_bytes_total{{device="ib0",instance="{ip}:9100",{base_lbl}}} {net:.0f}',
            f'node_network_transmit_bytes_total{{device="ib0",instance="{ip}:9100",{base_lbl}}} {noise(net,0.05):.0f}',
        ]

    # Cluster summary
    lines += [
        f'nvis_cluster_total_nodes{{cluster="{CLUSTER}",org="{ORG}"}} {NUM_NODES}',
        f'nvis_cluster_active_nodes{{cluster="{CLUSTER}",org="{ORG}"}} {active_nodes}',
        f'nvis_cluster_total_gpus{{cluster="{CLUSTER}",org="{ORG}"}} {TOTAL_GPUS}',
        f'nvis_cluster_allocated_gpus{{cluster="{CLUSTER}",org="{ORG}"}} {allocated_gpus}',
        f'nvis_cluster_gpu_utilization_avg{{cluster="{CLUSTER}",org="{ORG}"}} {noise(78,0.05):.1f}',
        f'nvis_cluster_active_jobs{{cluster="{CLUSTER}",org="{ORG}"}} {len(ACTIVE_JOBS)}',
    ]

    with open(TEXTFILE, "w") as f:
        f.write("\n".join(lines) + "\n")

    t += 15
    if t % 60 == 0:
        print(f"[{datetime.now():%H:%M:%S}] {len(lines)} metrics | {allocated_gpus}/{TOTAL_GPUS} GPUs allocated")
        push_log("INFO", f"B300 status: {len(ACTIVE_JOBS)} jobs {allocated_gpus}/{TOTAL_GPUS} GPUs")

    time.sleep(15)
PYEOF

# Cleanup on exit
rm -f "$TEXTFILE"
echo "[$(date)] B300 simulation ended"
