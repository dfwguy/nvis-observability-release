# NVIS Observability Suite — Setup Guide

## What setup.sh does

`setup.sh` is a fully automated installer that runs on your ObsVM.
It discovers your environment, deploys all observability components, and configures everything without hardcoding anything.

Run it once. It asks questions. It does the rest.

---

## Before you run setup.sh

### What you need

| Requirement | Details |
|---|---|
| ObsVM | Ubuntu 20.04/22.04/24.04, CentOS 9, RHEL 8/9, Rocky 8/9, or AlmaLinux 8/9 |
| CPU/RAM/Disk | 4+ vCPU, 8GB RAM, 100GB disk |
| Internet access on ObsVM | To pull container images from docker.com, grafana.com, GitHub |
| BCM head node | Reachable via SSH from ObsVM |
| GPU nodes | Ubuntu, CentOS, or RHEL — NVIDIA drivers installed (`nvidia-smi` works), reachable from ObsVM |
| sudo access | On ObsVM and on each GPU node |

### Verify NVIDIA drivers on each GPU node before starting

```bash
nvidia-smi
```

If this fails, install NVIDIA drivers first. setup.sh cannot do this for you.

### Verify ObsVM can reach BCM

```bash
ssh YOUR_BCM_USER@YOUR_BCM_IP echo OK
```

### Verify ObsVM can reach GPU nodes

```bash
ping -c1 YOUR_NODE_IP
```

---

## Container runtime auto-detection

setup.sh detects the container runtime automatically on both ObsVM and each GPU node.
Priority order: **Enroot → Podman → Docker**

| Runtime | What happens |
|---|---|
| **Enroot found** | Used directly — no nvidia-ctk install, no Docker needed. GPU access is pre-configured. |
| **Podman found** | Used with `--device nvidia.com/gpu=all` — no Docker daemon needed |
| **Neither found** | Docker is installed automatically |

If you want to use Podman instead of Docker, install it before running setup.sh:
```bash
# RHEL / CentOS / Rocky
sudo dnf install -y podman podman-compose

# Ubuntu 22.04+
sudo apt-get install -y podman
```

## Running setup.sh

```bash
chmod +x setup.sh
bash setup.sh
```

The script saves its state. If it fails midway, fix the issue and re-run — it resumes from where it stopped.

---

## What setup.sh asks you (in order)

### 1. ObsVM IP
Auto-detected from `hostname -I`. Confirm or change it.
This IP is used in all Alloy configs on GPU nodes so they know where to send metrics.

### 2. Grafana admin password
Default: `NVIS_CBU`. Choose something secure for production.

### 3. Cluster name
Used as a label on every metric. Appears in all dashboard dropdowns.
Example: `lilly-superpod-01`, `prod-a100-cluster`
Do NOT use spaces or special characters.

### 4. BCM head node hostname or IP
The machine running BCM (Bright Cluster Manager). setup.sh SSHes here to run `cmsh device list`.

### 5. SSH username for BCM
Typically `ubuntu` or `root`.

### 6. SSH method
Two options:
- **Passwordless (recommended)** — setup.sh generates an SSH key and copies it to BCM and all GPU nodes. You are prompted for the BCM password once, then never again.
- **Password** — You type the SSH password. It is held in memory only and never written to disk.

### 7. UFM (optional)
If you have UFM Telemetry, UFM Enterprise, or UFM Cyber-AI:
- Enter the UFM IP
- Select the variant (Telemetry / Enterprise / Cyber-AI)
- setup.sh adds the appropriate scrape job to Prometheus

If you do not have UFM, answer `n`. All GPU and node metrics still work fully without UFM.

### 8. Run:ai (optional)
If you use Run:ai for job scheduling:
- Enter the Run:ai API endpoint
- setup.sh federates Run:ai's internal Prometheus into NVIS Prometheus
- Job owner usernames from SAML/LDAP appear in dashboards

### 9. PDU power monitoring (optional)
If you have SNMP-enabled PDUs (rack power distribution units):
- Select your vendor from the list (APC, Raritan, Vertiv, Eaton, Server Technology, Legrand, CPI, Panduit, Other)
- Enter the PDU IP range to scan
- setup.sh installs snmp_exporter and auto-discovers your PDUs

### 10. Weka storage (optional)
If you use Weka as your storage layer, setup.sh installs the Weka Prometheus exporter.

### 11. RAID (optional)
If you have RAID arrays, setup.sh configures mdadm metric collection via node_exporter's textfile collector.

### 12. Long-term storage (optional)
If you want metrics retained beyond 15 days:
- VictoriaMetrics is installed
- Enter retention period in months (default: 12)
- Prometheus remote_writes to VictoriaMetrics automatically
- VictoriaMetrics appears as a second datasource in Grafana

### 13. Alerting (optional)
Configure where alerts go:
- **Email** — enter SMTP server, username, password, recipient
- **Slack** — paste your Slack webhook URL
- **Webhook** — paste any webhook URL
- **PagerDuty** — paste your integration key

A guide to setting alert thresholds is saved to `docs/ALERT_THRESHOLDS.md` after setup.

### 14. SAML SSO (optional)
If your organization uses SAML for single sign-on:
- Enter your IDP Metadata XML URL
- setup.sh generates a SAML SP certificate and configures Grafana
- Users log in via your corporate SSO instead of username/password

---

## What setup.sh does automatically (no input needed)

### Node discovery
- SSHes to BCM, runs `cmsh device list`
- Categorizes every node: UP / DOWN / unallocated / powered-off
- Ping-verifies every UP node is actually reachable from ObsVM
- Shows you the full inventory table and asks you to confirm

### On each reachable GPU node (in parallel)

setup.sh first detects the container runtime on each node (Enroot → Podman → Docker), then:

1. **Enroot/Podman found** — skips nvidia-ctk entirely, starts DCGM/cAdvisor via detected runtime
2. **Docker only** — installs NVIDIA container toolkit if not present, configures Docker GPU runtime
3. Starts DCGM Exporter (GPU metrics on port 9400)
4. Installs node_exporter (CPU/memory/disk/network on port 9100)
5. Starts cAdvisor (Slurm cgroup/job metrics on port 9306)
6. Installs Grafana Alloy, writes config with your ObsVM IP and cluster name
7. Verifies metrics are flowing to Prometheus

### On ObsVM
1. Installs Docker if not present
2. Configures prometheus.yml with discovered node IPs
3. Patches all 10 dashboard JSONs to use your cluster name (removes hardcoded values)
4. Starts Prometheus, Loki, Grafana via docker-compose
5. Validates all services are healthy
6. Runs `terraform apply` to deploy all 10 dashboards into Grafana

---

## Deployment matrix

At the end, setup.sh prints a table showing exactly what was deployed to each node:

```
NODE          STATUS   DCGM   NODE_EXP   CADVISOR   ALLOY
10.141.0.1    SUCCESS  OK     OK         OK         OK
10.141.0.2    PARTIAL  OK     FAIL       OK         OK   ← blind spot
10.141.0.3    DOWN     -      -          -          -    ← not deployed
```

Nodes marked PARTIAL or FAIL are your blind spots — components missing there.
Logs for each failed node are saved to `/tmp/nvis-node-IP.log`.

---

## Re-running after failure

setup.sh is idempotent. If it fails at phase 7 (GPU node deployment), re-run it:

```bash
bash setup.sh
```

It skips phases 1–6 (already completed) and retries phase 7.

To start completely fresh:

```bash
rm .nvis-setup-state .nvis-config .nvis-nodes
bash setup.sh
```

---

## After setup completes

Open Grafana: `http://YOUR_OBSVM_IP:3000`
Login: `admin` / your chosen password

Go to Dashboards → NVIS Observability. You will see 10 dashboards.
Select your cluster name from the dropdown at the top of each dashboard.

---

## Troubleshooting

### "BCM not reachable"
setup.sh cannot SSH to BCM. Options:
1. Check BCM hostname/IP and SSH credentials
2. Run `setup_bcm.sh` directly on BCM — see `SETUP_BCM_INSTRUCTIONS.md`

### "No UP nodes found"
All nodes are DOWN or unallocated in BCM. Check:
```bash
# On BCM
sudo cmsh -c "device list"
```

### "DCGM FAIL on node X"
Check `/tmp/nvis-node-X.log` on ObsVM.
Common cause: NVIDIA container toolkit not installed or Docker runtime not configured.
Fix on the node:
```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --gpus all ubuntu nvidia-smi
```

### "Grafana shows No data"
- Check the cluster dropdown matches your cluster name
- Check Alloy is running on GPU nodes: `sudo systemctl status alloy`
- Check metrics in Prometheus: `http://OBSVM_IP:9090/targets`

### Service logs
```bash
cd ~/nvis-observability
docker compose logs prometheus  # or loki, grafana
```

---

## Files created by setup.sh

| File | Purpose |
|---|---|
| `.nvis-setup-state` | Tracks completed phases for resuming |
| `.nvis-config` | Saved non-sensitive configuration |
| `.nvis-nodes` | Discovered node list |
| `nvis-setup-report-TIMESTAMP.txt` | Full deployment report |
| `nvis-setup-debug-TIMESTAMP.log` | Full debug log |
| `docs/ALERT_THRESHOLDS.md` | Alert threshold reference |
