# NVIS Observability Suite — Production Deployment Guide

> **Version:** 2.0 | **Updated:** 2026-03-26
> Full-stack GPU cluster observability: Prometheus · Loki · Grafana · Alloy · DCGM

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Quick Start (Fresh Cluster)](#3-quick-start-fresh-cluster)
4. [Setup Scenarios & Command Reference](#4-setup-scenarios--command-reference)
5. [ObsVM Manual Install](#5-obsvm-manual-install)
6. [BCM Head Node Direct Install](#6-bcm-head-node-direct-install)
7. [GPU Node Agent Deploy](#7-gpu-node-agent-deploy)
8. [Terraform Dashboard Deploy](#8-terraform-dashboard-deploy)
9. [Error Recovery & Checkpoint Resume](#9-error-recovery--checkpoint-resume)
10. [Post-Deploy Verification](#10-post-deploy-verification)
11. [Slurm Job Samples](#11-slurm-job-samples)
12. [Optional Integrations](#12-optional-integrations)
13. [Upgrading an Existing Deployment](#13-upgrading-an-existing-deployment)
14. [Troubleshooting Reference](#14-troubleshooting-reference)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    BCM Head Node (Slurm)                        │
│  ┌─────────────────┐  ┌──────────────────┐  ┌───────────────┐  │
│  │  BCM Exporter   │  │ Slurm Job Export │  │  prolog/epi   │  │
│  │  :9401 (REST)   │  │  :9402 (squeue)  │  │  log hooks    │  │
│  └────────┬────────┘  └────────┬─────────┘  └───────────────┘  │
└───────────┼─────────────────────┼───────────────────────────────┘
            │ remote_write         │ remote_write
┌───────────▼─────────────────────▼───────────────────────────────┐
│                      ObsVM (Dedicated VM)                        │
│  ┌──────────────┐  ┌──────────┐  ┌─────────┐  ┌─────────────┐  │
│  │  Prometheus  │  │   Loki   │  │ Grafana │  │VictoriaMetrc│  │
│  │  :9090       │  │  :3100   │  │  :3000  │  │ :8428 (opt) │  │
│  └──────────────┘  └──────────┘  └─────────┘  └─────────────┘  │
└─────────────────────────────────────────────────────────────────┘
            ▲ remote_write per node (push-based)
┌───────────┴─────────────────────────────────────────────────────┐
│                     GPU Nodes (node001…nodeN)                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ DCGM Exporter│  │node_exporter │  │ Cgroup Export│           │
│  │  :9400       │  │  :9100       │  │  :9306       │           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         └─────────────────┼──────────────────┘                  │
│                    ┌──────▼──────┐                               │
│                    │ Grafana Alloy│  (scrape + relabel + push)   │
│                    └─────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**
- **Push-based**: GPU nodes push to ObsVM via `remote_write` — no firewall holes needed inbound to nodes
- **Alloy relabeling**: Hostname injected at deploy time (`instance=node001`) — survives container restarts
- **`honor_timestamps = false`**: Alloy uses scrape time, not DCGM's embedded timestamps — prevents duplicate-sample drops
- **Loki**: All node logs shipped as `job="syslog"` — content filters differentiate kernel/slurm/auth events

---

## 2. Prerequisites

### ObsVM Requirements
| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 4 cores | 8 cores |
| RAM | 16 GB | 32 GB |
| Disk | 200 GB | 500 GB SSD |
| OS | Ubuntu 20.04+ / RHEL 8+ | Ubuntu 22.04 LTS |
| Network | Reachable from all GPU nodes | 10 GbE |
| Ports open inbound | 3000, 9090, 9100, 3100, 8428 | — |

### Software on ObsVM (auto-installed by setup.sh)
- Docker ≥ 24 or Podman ≥ 4
- Docker Compose plugin
- Terraform ≥ 1.6

### Access Requirements
- SSH access from ObsVM to BCM head node (direct or via jump host)
- SSH access from ObsVM to each GPU node (root or sudo, via BCM head as jump)
- BCM REST API reachable from ObsVM (port 443)
- `curl`, `jq`, `python3` on ObsVM

### Credentials Needed
- BCM admin username + password (for node discovery)
- Desired Grafana admin password
- SSH private key for GPU node access

---

## 3. Quick Start (Fresh Cluster)

```bash
# 1. Clone the repo onto ObsVM
git clone <your-gitlab-url>/nvis-observability.git
cd nvis-observability

# 2. Run the interactive installer
bash setup.sh

# 3. Follow the prompts — setup takes 15-30 minutes
#    It will ask for: ObsVM IP, cluster name, BCM host, Grafana password,
#    optional integrations (UFM, Run:ai, long-term storage, alerting, SAML)

# 4. Open Grafana when done
#    http://<OBSVM_IP>:3000   →  admin / <your-password>
#    NVIS Home:  http://<OBSVM_IP>:3000/d/nvis-demo-home
```

That's it for a standard deployment. The rest of this guide covers all variations.

---

## 4. Setup Scenarios & Command Reference

### 4.1 Standard Full Setup (Interactive)
```bash
bash setup.sh
```
Runs all phases: preflight → interview → install ObsVM stack → BCM discovery → start services → deploy dashboards → configure GPU nodes → optional integrations → final report.

**State is saved after each phase.** If it fails, re-run the same command — completed phases are skipped.

---

### 4.2 Resume After Failure
```bash
# Simply re-run. Completed phases auto-skip.
bash setup.sh
```
Checks `.nvis-setup-state` to know what completed. Safe to run repeatedly.

---

### 4.3 Re-deploy GPU Nodes Only (New Nodes Added)
```bash
# Re-discovers BCM inventory, deploys Alloy to new/failed nodes only
# Healthy nodes with current config are skipped
bash setup.sh --phase gpu_nodes
```

Use this when:
- New GPU nodes added to the cluster
- An existing node's Alloy config is broken
- You've updated `alloy/config.alloy` and want to push the new version

---

### 4.4 Fix Alloy Labels (Instance = hostname, not localhost)
```bash
# Dedicated script — faster than full --phase gpu_nodes
bash fix-alloy-labels.sh
```
Deploys hardcoded hostname to Alloy config on all nodes, restarts Alloy, verifies DCGM + node_exporter are scraping. Use this if dashboards show `localhost:9400` instead of node hostnames.

---

### 4.5 Re-deploy Dashboards Only (After Dashboard Changes)
```bash
cd terraform
terraform apply -auto-approve
```
Pushes updated JSON dashboards to Grafana via the Terraform Grafana provider. Run from ObsVM after any dashboard file edits.

---

### 4.6 Non-Interactive (Fully Automated / CI)
```bash
# Pre-create .nvis-config and .nvis-creds before running
cat > .nvis-config << EOF
OBSVM_IP="10.x.x.x"
CLUSTER_NAME="my-cluster"
BCM_HOST="10.x.x.x"
BCM_USER="root"
JUMP_HOST=""
HAS_UFM=false
HAS_RUNAI=false
HAS_SNMP_PDU=false
HAS_WEKA=false
HAS_RAID=false
HAS_LONGTERM=false
VICTORIA_RETENTION="12"
SETUP_ALERTS=false
SETUP_SAML=false
EOF

cat > .nvis-creds << EOF
GRAFANA_PASS="YourSecurePassword123"
BCM_API_PASS="your-bcm-password"
EOF

bash setup.sh   # reads config files, skips interview prompts
```

---

### 4.7 Jump Host / Bastion Configuration
```bash
# In .nvis-config:
JUMP_HOST="username@jumpbox.example.com"
BCM_HOST="10.x.x.x"   # internal IP, reachable via jump

# setup.sh builds SSH chains automatically:
# ObsVM → jumpbox → BCM head → GPU node
```

---

### 4.8 Single-Node or Small Lab (No BCM)
```bash
# Skip BCM phases — manually specify nodes
# After setup.sh completes ObsVM stack, run:
bash fix-alloy-labels.sh   # will prompt for node IPs if .nvis-nodes missing

# Or manually create .nvis-nodes:
cat > .nvis-nodes << EOF
node001:10.x.x.1
node002:10.x.x.2
EOF
bash fix-alloy-labels.sh
```

---

### 4.9 Air-gapped / Offline Clusters
```bash
# 1. On internet-connected machine, pull images:
docker pull grafana/grafana:latest
docker pull grafana/loki:latest
docker pull prom/prometheus:latest
docker pull grafana/alloy:latest
docker save grafana/grafana grafana/loki prom/prometheus grafana/alloy \
  | gzip > nvis-images.tar.gz

# 2. SCP images to ObsVM:
scp nvis-images.tar.gz obsvm:/tmp/

# 3. On ObsVM:
gunzip -c /tmp/nvis-images.tar.gz | docker load

# 4. Pre-download Terraform provider:
#    Copy terraform/.terraform/ directory to ObsVM before running setup.
#    Then: bash setup.sh   (docker pull step will skip, images already loaded)
```

---

### 4.10 Multi-Cluster (Multiple Pods)
Each pod gets its own ObsVM deployment. The `cluster` label differentiates them in Grafana. Grafana can federate multiple Prometheus sources via its datasource management.

```bash
# Cluster A — run on ObsVM-A:
CLUSTER_NAME="pod-a" bash setup.sh

# Cluster B — run on ObsVM-B:
CLUSTER_NAME="pod-b" bash setup.sh

# To federate: add both Prometheus as datasources in Grafana
# then use cluster=~"pod-a|pod-b" in dashboards
```

---

## 5. ObsVM Manual Install

Use this if `setup.sh` fails on the ObsVM stack phase and you need to recover manually.

### 5.1 Install Docker
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### 5.2 Install Docker Compose Plugin
```bash
sudo apt-get install -y docker-compose-plugin
# Or:
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

### 5.3 Configure and Start the Stack
```bash
cd nvis-observability

# Set your variables
export OBSVM_IP="10.x.x.x"
export GRAFANA_PASS="YourPassword"
export CLUSTER_NAME="my-cluster"

# Patch docker-compose.yml with your IP
sed -i "s/OBSVM_IP_PLACEHOLDER/${OBSVM_IP}/g" docker-compose.yml

# Start the stack
docker compose up -d

# Check status
docker compose ps
```

### 5.4 Verify Services
```bash
# Prometheus
curl -s http://localhost:9090/-/ready && echo "OK"

# Loki
curl -s http://localhost:3100/ready && echo "OK"

# Grafana
curl -s http://localhost:3000/api/health | python3 -m json.tool

# Check logs if any service is down
docker compose logs prometheus --tail 20
docker compose logs loki --tail 20
docker compose logs grafana --tail 20
```

### 5.5 Install Terraform
```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform
terraform -version
```

---

## 6. BCM Head Node Direct Install

Use `setup_bcm.sh` to install BCM-specific exporters directly on the head node.

### 6.1 What it Installs
- **BCM Exporter** (`scripts/bcm_exporter.py`) — exposes BCM REST API as Prometheus metrics on `:9401`
- **Slurm Job Exporter** (`scripts/slurm_job_exporter.py`) — exposes squeue/sacct as metrics on `:9402`
- Systemd service files for both
- Slurm prolog/epilog hooks for per-job metric tagging

### 6.2 Run
```bash
# From ObsVM, copy and run:
scp setup_bcm.sh root@<BCM_HOST>:/tmp/
ssh root@<BCM_HOST> "bash /tmp/setup_bcm.sh <OBSVM_IP> <CLUSTER_NAME>"

# Or with jump host:
scp -J user@jumpbox setup_bcm.sh root@<BCM_HOST>:/tmp/
ssh -J user@jumpbox root@<BCM_HOST> "bash /tmp/setup_bcm.sh <OBSVM_IP> <CLUSTER_NAME>"
```

### 6.3 Manual BCM Exporter Install
```bash
# On BCM head node:
pip3 install requests prometheus_client

# Copy exporter
cp scripts/bcm_exporter.py /usr/local/bin/
cp scripts/bcm-exporter.service /etc/systemd/system/

# Edit service to set BCM API credentials
vi /etc/systemd/system/bcm-exporter.service
# Set: Environment=BCM_USER=admin Environment=BCM_PASS=yourpass

systemctl daemon-reload
systemctl enable --now bcm-exporter

# Verify
curl http://localhost:9401/metrics | head -20
```

### 6.4 Slurm Prolog/Epilog Setup
```bash
# Copy hooks to slurm directories
cp slurm/prolog.sh /etc/slurm/prolog.d/nvis_prolog.sh
cp slurm/jobstats_prolog.sh /etc/slurm/prolog.d/nvis_jobstats.sh
cp slurm/jobstats_epilog.sh /etc/slurm/epilog.d/nvis_jobstats.sh
chmod +x /etc/slurm/prolog.d/nvis_*.sh /etc/slurm/epilog.d/nvis_*.sh

# Add to slurm.conf (if not already set):
echo 'PrologFlags=Alloc' >> /etc/slurm/slurm.conf
echo 'Prolog=/etc/slurm/prolog.d/nvis_prolog.sh' >> /etc/slurm/slurm.conf
systemctl restart slurmctld
```

---

## 7. GPU Node Agent Deploy

Grafana Alloy runs on each GPU node, scrapes DCGM + node_exporter + cgroup, and pushes to ObsVM.

### 7.1 Automated (Recommended)
```bash
# Deploy to all nodes discovered in BCM
bash fix-alloy-labels.sh

# Or as part of full setup:
bash setup.sh --phase gpu_nodes
```

### 7.2 Manual Single-Node Deploy
```bash
# From ObsVM, ssh to GPU node and install Alloy
NODE_IP="10.x.x.1"
NODE_HOSTNAME="node001"
OBSVM_IP="10.x.x.x"
CLUSTER_NAME="my-cluster"

ssh root@${NODE_IP} << ENDSSH
  # Install Alloy (Ubuntu)
  apt-get install -y gpg
  wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
  apt-get update -qq && apt-get install -y alloy

  # Write config (substitute actual values)
  cat > /etc/alloy/config.alloy << 'CONFIG'
prometheus.remote_write "obsvm" {
  endpoint { url = "http://${OBSVM_IP}:9090/api/v1/write" }
}
prometheus.scrape "dcgm" {
  targets          = [{ __address__ = "localhost:9400" }]
  scrape_interval  = "15s"
  honor_timestamps = false
  forward_to       = [prometheus.relabel.dcgm.receiver]
}
prometheus.relabel "dcgm" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule { target_label = "job"      replacement = "dcgm-exporter" }
  rule { target_label = "cluster"  replacement = "${CLUSTER_NAME}" }
  rule { target_label = "instance" replacement = "${NODE_HOSTNAME}" }
  rule { target_label = "node"     replacement = "${NODE_HOSTNAME}" }
}
prometheus.scrape "node_exporter" {
  targets         = [{ __address__ = "localhost:9100" }]
  scrape_interval = "15s"
  forward_to      = [prometheus.relabel.node_exporter.receiver]
}
prometheus.relabel "node_exporter" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule { target_label = "job"      replacement = "node-exporter" }
  rule { target_label = "cluster"  replacement = "${CLUSTER_NAME}" }
  rule { target_label = "instance" replacement = "${NODE_HOSTNAME}" }
  rule { target_label = "node"     replacement = "${NODE_HOSTNAME}" }
}
loki.write "obsvm" {
  endpoint { url = "http://${OBSVM_IP}:3100/loki/api/v1/push" }
}
local.file_match "syslog" {
  path_targets = [{ __path__ = "/var/log/syslog", job = "syslog", cluster = "${CLUSTER_NAME}", node = "${NODE_HOSTNAME}", instance = "${NODE_HOSTNAME}" }]
}
loki.source.file "syslog" {
  targets    = local.file_match.syslog.targets
  forward_to = [loki.write.obsvm.receiver]
}
CONFIG

  systemctl daemon-reload
  systemctl enable --now alloy
  sleep 5
  systemctl is-active alloy
ENDSSH
```

### 7.3 DCGM Exporter on GPU Nodes
```bash
# DCGM exporter runs as a Docker container on each GPU node:
ssh root@<NODE_IP> "docker ps | grep dcgm"

# If not running, start it:
ssh root@<NODE_IP> << 'EOF'
docker run -d \
  --name dcgm-exporter \
  --gpus all \
  --cap-add SYS_ADMIN \
  -p 9400:9400 \
  --restart unless-stopped \
  nvcr.io/nvidia/k8s/dcgm-exporter:latest
EOF

# Verify metrics
curl http://<NODE_IP>:9400/metrics | grep DCGM_FI_DEV | head -5
```

### 7.4 node_exporter on GPU Nodes
```bash
# Install node_exporter if missing (auto-done by setup.sh):
bash fix-node-exporter.sh

# Or manual:
ssh root@<NODE_IP> << 'EOF'
wget https://github.com/prometheus/node_exporter/releases/latest/download/node_exporter-*linux-amd64.tar.gz
tar xf node_exporter-*linux-amd64.tar.gz
cp node_exporter-*/node_exporter /usr/local/bin/
cat > /etc/systemd/system/node_exporter.service << 'SVC'
[Unit]
Description=Node Exporter
After=network.target
[Service]
ExecStart=/usr/local/bin/node_exporter
Restart=always
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable --now node_exporter
EOF
```

---

## 8. Terraform Dashboard Deploy

### 8.1 First-Time Setup
```bash
cd terraform

# Copy example config and fill in your values
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
# Set: grafana_url, grafana_auth

# Initialize (downloads provider)
terraform init

# Deploy all dashboards
terraform apply -auto-approve
```

### 8.2 terraform.tfvars Reference
```hcl
grafana_url  = "http://10.x.x.x:3000"
grafana_auth = "admin:YourGrafanaPassword"
```

### 8.3 Update Dashboards After Edits
```bash
cd terraform
terraform apply -auto-approve
```

### 8.4 What Gets Deployed
12 production dashboards (see `docs/DASHBOARD_INVENTORY.md` for full list):
- NVIS Demo Home (landing page)
- Cluster Overview
- GPU Health
- Node Deep Dive
- Network Fabric
- Cross-Domain Impact Analysis
- Security Audit
- Live Cluster Topology
- Log Explorer
- Single Job Stats
- SuperPOD Command Center (CIO)
- Executive Intelligence Dashboard

---

## 9. Error Recovery & Checkpoint Resume

### 9.1 Setup.sh State File
`setup.sh` writes completed phase names to `.nvis-setup-state`. Re-running skips completed phases.

```bash
# View current state
cat .nvis-setup-state

# Force re-run a specific phase (clear it from state):
sed -i '/phase_terraform/d' .nvis-setup-state
bash setup.sh   # now runs terraform phase again

# Force full re-run (clear all state):
rm .nvis-setup-state
bash setup.sh
```

### 9.2 Recover from ObsVM Stack Failure
```bash
# Check which containers are down
docker compose ps

# View container logs
docker compose logs <service_name> --tail 50

# Common fixes:
# Port already in use:
sudo ss -tlnp | grep 9090
sudo kill -9 <pid>
docker compose up -d prometheus

# Disk full:
df -h /var/lib/docker
docker system prune -f   # remove dangling images/volumes

# Permission error on data volumes:
sudo chown -R 65534:65534 ./prometheus-data/   # Prometheus runs as nobody
sudo chown -R 10001:10001 ./loki-data/          # Loki UID

# Restart everything cleanly:
docker compose down
docker compose up -d
```

### 9.3 Recover from GPU Node Deploy Failure
```bash
# See which nodes failed
cat nvis-setup-report-*.txt | tail -1

# Re-run just the GPU node phase
bash setup.sh --phase gpu_nodes

# Or use the dedicated script for faster iteration:
bash fix-alloy-labels.sh

# Debug a specific node:
NODE_IP="10.x.x.x"
ssh -J $JUMP_HOST root@$NODE_IP "systemctl status alloy; journalctl -u alloy -n 50"

# Check Alloy config on node:
ssh -J $JUMP_HOST root@$NODE_IP "cat /etc/alloy/config.alloy"

# Check that metrics are flowing:
ssh -J $JUMP_HOST root@$NODE_IP "curl -s http://localhost:9400/metrics | grep -c DCGM_FI"
```

### 9.4 Recover from Terraform Failure
```bash
cd terraform

# Check what Terraform state thinks is deployed
terraform state list

# Refresh state from actual Grafana
terraform refresh

# If provider auth fails: check tfvars
cat terraform.tfvars

# If dashboard JSON is invalid
python3 -c "import json,sys; json.load(open(sys.argv[1]))" dashboards/10_demo_home.json

# Re-apply specific dashboard only
terraform apply -target="grafana_dashboard.nvis[\"10_demo_home\"]" -auto-approve

# Nuclear option: wipe state and redeploy
terraform state rm $(terraform state list)
terraform apply -auto-approve
```

### 9.5 Recover from Loki Log Shipping Failure
```bash
# Check Alloy is tailing syslog
ssh root@<NODE_IP> "journalctl -u alloy -n 30 | grep loki"

# Check Loki is receiving:
curl -s "http://localhost:3100/loki/api/v1/labels" | python3 -m json.tool

# Test log ingestion manually:
curl -s -X POST http://localhost:3100/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{"streams":[{"stream":{"job":"test"},"values":[["'$(date +%s%N)'","test log line"]]}]}'

# View recent logs from Loki:
curl -sG "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="syslog"}' \
  --data-urlencode 'start='$(date -d '5 minutes ago' +%s%N) \
  --data-urlencode 'end='$(date +%s%N) | python3 -m json.tool | head -30
```

### 9.6 Common Error Messages

| Error | Likely Cause | Fix |
|---|---|---|
| `ALLOY_DEAD` | River syntax error in config | Check `journalctl -u alloy -n 20` for River parse error; fix config |
| `expected TERMINATOR, got IDENT` | Multiple attributes on one line in River | Split each attribute to its own line |
| `missing ',' in field list` | Array object literal missing commas | Add commas between fields in `{}` block |
| `num_dropped=N` from DCGM scrape | DCGM embedding timestamps + `honor_timestamps=true` | Already fixed: `honor_timestamps = false` in config |
| `instance=localhost:9400` in Grafana | `sys.env("HOSTNAME")` empty under systemd | Run `fix-alloy-labels.sh` to deploy hardcoded hostname |
| Grafana `No data` on all panels | Wrong datasource UID | Check `terraform.tfvars` grafana_auth; re-run `terraform apply` |
| `Error: 409 Conflict` in Terraform | Dashboard already exists with different UID | `terraform import` the existing dashboard or delete it in Grafana |
| Prometheus `TSDB out of order` | Clock skew between nodes | Install/sync `chrony` on all nodes |

---

## 10. Post-Deploy Verification

### 10.1 Quick Smoke Test
```bash
# Run from ObsVM:

echo "=== Prometheus ==="
curl -s "http://localhost:9090/api/v1/query?query=up" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['data']['result']:
  print(f\"  {r['metric'].get('job','?'):25} {r['metric'].get('instance','?'):20} up={r['value'][1]}\")
"

echo ""
echo "=== Loki labels ==="
curl -s "http://localhost:3100/loki/api/v1/labels" | python3 -m json.tool

echo ""
echo "=== Grafana datasources ==="
curl -s http://admin:${GRAFANA_PASS}@localhost:3000/api/datasources | python3 -c "
import json,sys
for ds in json.load(sys.stdin):
  print(f\"  {ds['name']:20} {ds['type']:15} {ds.get('url','?')}\")
"
```

### 10.2 GPU Metrics Verification
```bash
# Check DCGM metrics are flowing with correct labels
curl -s "http://localhost:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['data']['result']:
  inst = r['metric'].get('instance','?')
  val  = r['value'][1]
  print(f\"  GPU util on {inst}: {val}%\")
" 2>/dev/null || echo "No DCGM metrics yet — check Alloy on GPU nodes"

# Verify no localhost instances
LOCALHOST=$(curl -s "http://localhost:9090/api/v1/query?query=up" | python3 -c "
import json,sys
d=json.load(sys.stdin)
bad=[r['metric'].get('instance') for r in d['data']['result'] if 'localhost' in r['metric'].get('instance','')]
print(len(bad))
")
echo "localhost instances in Prometheus: $LOCALHOST (should be 0)"
```

### 10.3 Dashboard Health Check
```bash
# List all deployed dashboards
curl -s http://admin:${GRAFANA_PASS}@localhost:3000/api/search?type=dash-db | python3 -c "
import json,sys
for d in sorted(json.load(sys.stdin), key=lambda x: x['title']):
  print(f\"  {d['uid']:30} {d['title']}\")
"
```

### 10.4 Checklist
- [ ] Grafana opens at `http://<OBSVM_IP>:3000`
- [ ] NVIS Home dashboard shows correct node count
- [ ] Nodes Online stat shows all nodes (not just 1)
- [ ] Node dropdown shows `node001`, `node002`, ... (not `localhost`)
- [ ] GPU Utilization panels show values, no `localhost:9400`
- [ ] Cluster Overview → GPU Health shows all GPUs by node name
- [ ] Node Deep Dive → Kernel Errors log panel shows recent syslog
- [ ] Security Audit → SSH Login Events shows sshd activity
- [ ] No Alloy warnings about `num_dropped` in GPU node journals

---

## 11. Slurm Job Samples

Located in `slurm/`. Submit from the BCM head node.

### GPU Stress Jobs (Real Load)
```bash
# GPU burn — runs gpu-burn for 10 minutes, monitors all GPUs
sbatch slurm/gpu_burn.sbatch

# GPU tensor storm — mixed precision GEMM
sbatch slurm/gpu_tensor_storm.sbatch

# Combined 10-minute demo (recommended for demos)
sbatch slurm/nvis_demo_10mins.sbatch
```

### Simulation Jobs (Inject Synthetic Patterns)
> These inject log patterns and metrics to demonstrate dashboard capabilities without real hardware faults.

```bash
# XID error simulation (log injection only)
sbatch slurm/xid_storm.sbatch

# NVLink storm simulation
sbatch slurm/nvlink_storm.sbatch

# NCCL TCP connection storm
sbatch slurm/nccl_connection_storm.sbatch

# Network congestion simulation
sbatch slurm/network_congestion_storm.sbatch

# Storage RAID pressure simulation
sbatch slurm/storage_raid_storm.sbatch

# Full fault cascade demo (all layers)
sbatch slurm/nvis_fault_demo.sbatch
```

### Compliance / Audit Jobs
```bash
# Certificate expiry monitoring demo
sbatch slurm/cert_expiry_sim.sbatch

# Audit compliance simulation
sbatch slurm/job2_audit_compliance.sbatch
```

### Monitor Running Jobs
```bash
squeue -u $USER
watch -n5 squeue

# Cancel all your jobs:
scancel -u $USER
```

---

## 12. Optional Integrations

### 12.1 UFM (Unified Fabric Manager)
```bash
# Enable in .nvis-config:
HAS_UFM=true
UFM_IP="10.x.x.x"
UFM_TYPE="rest"   # or "snmp"

# Re-run UFM phase:
bash setup.sh --phase ufm   # not yet a standalone phase — run full setup
```

### 12.2 Run:ai
```bash
HAS_RUNAI=true
RUNAI_ENDPOINT="https://your-runai.example.com"
```

### 12.3 Long-Term Storage (VictoriaMetrics)
```bash
HAS_LONGTERM=true
VICTORIA_RETENTION="12"   # months

# VictoriaMetrics added to docker-compose automatically
# Accessible at http://<OBSVM_IP>:8428
```

### 12.4 SNMP PDU Monitoring
```bash
HAS_SNMP_PDU=true
PDU_VENDOR="raritan"   # or "apc", "vertiv"
PDU_IP_RANGE="10.x.x.0/24"
```

### 12.5 Alerting (Alertmanager)
```bash
SETUP_ALERTS=true
# Configures Alertmanager with default GPU/node alert rules
# Edit prometheus/alert_rules.yml after setup for custom thresholds
```

### 12.6 SAML SSO
```bash
SETUP_SAML=true
# Configures Grafana SAML provider
# You will be prompted for IdP metadata URL and certificates
```

---

## 13. Upgrading an Existing Deployment

### 13.1 Upgrade Dashboards Only
```bash
git pull
cd terraform && terraform apply -auto-approve
```

### 13.2 Upgrade Alloy Config
```bash
git pull
# Edit alloy/config.alloy if needed, then:
bash fix-alloy-labels.sh   # pushes new config to all nodes
```

### 13.3 Upgrade Full Stack
```bash
git pull

# Pull new container images
docker compose pull

# Recreate containers with new images (data volumes preserved)
docker compose up -d --force-recreate

# Re-apply dashboards
cd terraform && terraform apply -auto-approve
```

### 13.4 Rolling Alloy Upgrade (Zero Downtime)
```bash
# Alloy upgrade on one node at a time
for node_ip in $(cat .nvis-nodes | cut -d: -f2); do
  ssh -J $JUMP_HOST root@$node_ip "apt-get install -y alloy && systemctl restart alloy"
  sleep 10
  ssh -J $JUMP_HOST root@$node_ip "systemctl is-active alloy && echo OK || echo FAILED"
done
```

---

## 14. Troubleshooting Reference

### Grafana shows "No Data"
1. Check Prometheus has metrics: `curl http://localhost:9090/api/v1/query?query=up`
2. Check dashboard datasource variable (`$datasource`) points to correct Prometheus
3. Check `cluster` variable — must match the `CLUSTER_NAME` set in Alloy
4. Check `node` variable — must exclude `localhost` entries (regex: `^(?!localhost).*`)

### Dashboards show `localhost:9400` as instance
```bash
bash fix-alloy-labels.sh
```

### Log panels empty
All logs ship as `job="syslog"`. Verify:
```bash
curl -sG "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query={job="syslog"}' | python3 -m json.tool | grep -c stream
```
Should return > 0 streams. If 0, check Alloy on each node is running and `/var/log/syslog` exists.

### DCGM metrics missing
```bash
# On GPU node:
docker ps | grep dcgm           # container running?
curl http://localhost:9400/metrics | grep -c DCGM_FI  # >0 metrics?
journalctl -u alloy -n 30       # Alloy errors?
```

### Prometheus out of disk space
```bash
# Check retention config in docker-compose.yml
grep retention docker-compose.yml

# Default is 30d. Reduce if needed:
# command: --storage.tsdb.retention.time=15d

# Or prune manually (destructive!):
docker compose stop prometheus
sudo rm -rf prometheus-data/
docker compose up -d prometheus
```

### BCM Exporter not starting
```bash
systemctl status bcm-exporter
journalctl -u bcm-exporter -n 30

# Common: wrong BCM credentials
# Edit /etc/systemd/system/bcm-exporter.service
# Set correct BCM_USER and BCM_PASS environment vars
systemctl daemon-reload && systemctl restart bcm-exporter
```

---

*For issues, check the debug log: `nvis-setup-debug-<timestamp>.log`*
*Setup report: `nvis-setup-report-<timestamp>.txt`*
