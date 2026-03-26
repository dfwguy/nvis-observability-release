# NVIS Observability Suite

> **Production-grade GPU cluster observability for NVIDIA SuperPOD, DGX, and BCM-managed HPC clusters.**
>
> One script. Full-stack. No hardcoding.

[![Version](https://img.shields.io/badge/version-2.1.0-green.svg)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Grafana](https://img.shields.io/badge/Grafana-11.x-orange)](https://grafana.com)
[![Prometheus](https://img.shields.io/badge/Prometheus-2.x-red)](https://prometheus.io)
[![Alloy](https://img.shields.io/badge/Grafana_Alloy-1.x-blue)](https://grafana.com/oss/alloy/)

---

## What Is This?

NVIS Observability gives you end-to-end visibility into GPU clusters — from hardware-level GPU metrics (DCGM) to Slurm job telemetry, network fabric health, log correlation, and executive-level dashboards — deployed in under 30 minutes.

**Stack:** Prometheus · Loki · Grafana · Grafana Alloy · DCGM Exporter · node_exporter · Terraform

**Target environments:** NVIDIA DGX SuperPOD · BCM-managed HPC clusters · Any GPU cluster with Slurm

---

## Dashboards (12 Production Dashboards)

| Dashboard | Purpose |
|---|---|
| **NVIS Demo Home** | Landing page — cluster-at-a-glance with nav links |
| **Cluster Overview** | Node health, GPU utilization, job counts |
| **GPU Health** | Per-GPU metrics: util, memory, temperature, XID errors, ECC |
| **Node Deep Dive** | Per-node CPU, memory, disk, network, logs |
| **Network Fabric** | InfiniBand / Ethernet throughput, errors |
| **Cross-Domain Impact Analysis** | Correlate job failures → GPU → network → storage |
| **Security Audit** | SSH events, auth failures, sudo, service changes |
| **Live Cluster Topology** | Real-time node-link diagram |
| **Log Explorer** | XID event analysis, NVLink errors, GPU error logs |
| **Single Job Stats** | Per-job GPU/CPU/memory metrics with Slurm integration |
| **SuperPOD Command Center** | CIO-level cluster health summary |
| **Executive Intelligence Dashboard** | Business metrics: utilization, availability, trends |

---

## Quick Start

```bash
# 1. Clone
git clone <repo-url> nvis-observability
cd nvis-observability

# 2. Run on your ObsVM (dedicated observability machine)
bash setup.sh

# 3. Open Grafana
#    http://<OBSVM_IP>:3000  →  admin / <your-password>
```

**That's it.** The installer handles Docker, Terraform, service startup, BCM node discovery, Alloy deployment to all GPU nodes, and Grafana dashboard provisioning automatically.

---

## Architecture

```
GPU Nodes (node001...nodeN)
  DCGM Exporter :9400  ──┐
  node_exporter  :9100  ──┼──► Grafana Alloy ──► remote_write ──┐
  Cgroup Exporter :9306 ──┘                                      │
  /var/log/syslog ──────────── Alloy Loki push ──────────────────┤
                                                                  ▼
BCM Head Node                                              ObsVM (this machine)
  BCM Exporter   :9401 ──────────────────────────────►  Prometheus :9090
  Slurm Exporter :9402 ──────────────────────────────►  Loki       :3100
                                                       ►  Grafana    :3000
                                                       ►  VictoriaMetrics :8428 (optional)
```

**Push-based design:** GPU nodes push to ObsVM via remote_write — no inbound firewall rules needed on GPU nodes.

---

## Requirements

- **ObsVM:** Ubuntu 20.04+ / RHEL 8+ · 16 GB RAM · 200 GB disk · 4 cores
- **GPU nodes:** Linux · DCGM exporter · node_exporter · SSH access from ObsVM
- **BCM:** BrightCluster Manager with REST API (for auto-discovery)
- **Network:** ObsVM reachable from GPU nodes (push-based)

---

## Setup Scenarios

```bash
# Fresh install (interactive)
bash setup.sh

# Resume after failure (auto-skips completed phases)
bash setup.sh

# Add new GPU nodes only
bash setup.sh --phase gpu_nodes

# Fix instance labels showing as localhost
bash fix-alloy-labels.sh

# Redeploy dashboards only
cd terraform && terraform apply -auto-approve

# BCM head node exporters
bash setup_bcm.sh <OBSVM_IP> <CLUSTER_NAME>
```

See `docs/DEPLOYMENT_GUIDE.md` for all scenarios, recovery procedures, and troubleshooting.

---

## Slurm Test Jobs

```bash
# Real GPU load (recommended for validation)
sbatch slurm/gpu_burn.sbatch
sbatch slurm/nvis_demo_10mins.sbatch

# Simulation jobs (for demo without hardware faults)
sbatch slurm/nvis_fault_demo.sbatch    # full fault cascade
sbatch slurm/xid_storm.sbatch          # XID error injection
sbatch slurm/nvlink_storm.sbatch       # NVLink fault simulation
```

---

## Documentation

| Doc | Contents |
|---|---|
| `docs/DEPLOYMENT_GUIDE.md` | Full deployment guide — all scenarios, recovery, troubleshooting |
| `docs/SETUP_INSTRUCTIONS.md` | ObsVM setup walkthrough |
| `docs/SETUP_BCM_INSTRUCTIONS.md` | BCM head node setup |
| `docs/DASHBOARD_INVENTORY.md` | Dashboard reference — panels, metrics, variables |

---

## What's New in v2.1

See `CHANGELOG.md` for full details. v2.1 is a stability release — all bugs discovered during production deployment validation on a 3-node BCM/Slurm cluster are fixed.

**v2.0 highlights:**
- Push-based Alloy architecture — no inbound scrape holes through firewalls
- Hardcoded hostname relabeling — eliminates `localhost:9400` instance labels
- `honor_timestamps = false` — stops DCGM duplicate-sample drops
- 12 production dashboards — CIO and Executive dashboards added
- Complete log panel overhaul — all panels match actual Alloy job labels

**v2.1 fixes:**
- River syntax error in generated Alloy config (Alloy crashed on start)
- `NODE_HOSTNAME` shell expansion caused Alloy to never deploy
- `ssh_node` exit code silently killed background deployment (UNKNOWN/SKIP matrix)
- `node_runtime` / `OS_FAMILY` unbound variables crashed Docker install and cAdvisor
- DCGM republish: 0 metrics due to missing CSV mount and insufficient startup time
- State files no longer bundled in tar — fresh untar is always a clean install

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Node matrix shows `UNKNOWN / SKIP` | Background deploy function exited early | Check `/tmp/nvis-node-IP.log`; re-run `bash setup.sh --phase gpu_nodes` |
| `ALLOY=FAIL`, Alloy in `failed` state | River config syntax error or unreachable remote_write | Check `journalctl -u alloy -n 50` on the node |
| `DCGM=FAIL` after republish | Container needs > 20s to enumerate GPUs | Re-run `--phase gpu_nodes`; retry loop now waits up to 60s |
| "Previous partial setup detected" on fresh untar | State files bundled in old tar | Delete `.nvis-*` files or use current tar (v2.1+) |
| `unbound variable` errors in setup | `OS_FAMILY` or `node_runtime` not set | Fixed in v2.1; update to current tar |
| GPU nodes show `node_exporter` ALREADY_RUNNING but metrics not in Prometheus | Alloy remote_write URL misconfigured | Run `bash fix-alloy-labels.sh` to re-push correct Alloy config |
| `num_dropped=2` in Alloy logs for DCGM | DCGM embeds timestamps, Alloy was honoring them | `honor_timestamps = false` in Alloy config — fixed in v2.0 |

---

## License

MIT — see `LICENSE`.
