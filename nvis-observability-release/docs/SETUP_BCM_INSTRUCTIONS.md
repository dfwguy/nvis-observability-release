# NVIS Observability Suite — BCM Fallback Setup Guide

## When to use setup_bcm.sh

Use `setup_bcm.sh` when:
- Your ObsVM **cannot reach BCM** via SSH
- You prefer to push agents to GPU nodes **from BCM** using BCM's internal network
- You are running setup on a cluster where ObsVM is not on the same management network as BCM

If `setup.sh` on ObsVM can reach BCM, use that instead. `setup_bcm.sh` is the fallback.

---

## What setup_bcm.sh does

Runs directly on the BCM head node. Uses BCM's existing SSH trust to push the following to every UP GPU node:

- `node_exporter` (CPU, memory, disk, network metrics)
- Grafana Alloy (ships metrics and logs to ObsVM)

**Note:** DCGM Exporter and cAdvisor require Docker with NVIDIA runtime. If Docker is not set up on GPU nodes, install it first or run `setup.sh` from ObsVM which handles the full Docker setup.

---

## Before you run setup_bcm.sh

### 1. Copy setup_bcm.sh to BCM

From your Mac or ObsVM:

```bash
scp setup_bcm.sh YOUR_BCM_USER@YOUR_BCM_IP:~/
```

### 2. Verify BCM can reach GPU nodes

```bash
# On BCM
ssh root@node001 echo OK
ssh root@node002 echo OK
```

BCM typically has passwordless SSH to all managed nodes as root. If not, set it up via:

```bash
# On BCM
cmsh -c "device foreach (ssh-keyscan -H %hostname >> ~/.ssh/known_hosts)"
```

### 3. Verify ObsVM IP and ports are reachable from GPU nodes

From a GPU node, test:

```bash
nc -zv YOUR_OBSVM_IP 9090   # Prometheus
nc -zv YOUR_OBSVM_IP 3100   # Loki
```

If these fail, open firewall rules on ObsVM before deploying Alloy.

---

## Running setup_bcm.sh

```bash
# On BCM head node
chmod +x setup_bcm.sh
bash setup_bcm.sh --obsvm YOUR_OBSVM_IP --cluster YOUR_CLUSTER_NAME
```

If you omit the flags, it prompts you:

```bash
bash setup_bcm.sh
# Prompts: ObsVM IP, Cluster name
```

---

## What it asks

### ObsVM IP
The IP of the machine running Prometheus and Loki.
Alloy on each GPU node will push metrics and logs to this IP.

### Cluster name
Used as a label on all metrics. Must match what you used in `setup.sh` on ObsVM.
Example: `lilly-superpod-01`

---

## What setup_bcm.sh does automatically

1. Runs `cmsh device list` to discover all UP nodes
2. For each UP node via SSH:
   - Installs `node_exporter` if not present
   - Installs Grafana Alloy if not present
   - Writes Alloy config with your ObsVM IP and cluster name
   - Starts and enables both services
3. Reports success/fail per node

---

## Output

```
[10:23:01] Discovering nodes via cmsh...
Found 8 UP nodes

Deploying to 10.141.0.1...
✅ 10.141.0.1
Deploying to 10.141.0.2...
✅ 10.141.0.2
Deploying to 10.141.0.3...
❌ 10.141.0.3 — check /tmp/nvis-node-10.141.0.3.log

BCM deployment complete: 7 success, 1 failed
Return to ObsVM and continue with: bash setup.sh
```

Failed node logs are saved to `/tmp/nvis-node-IP.log` on BCM.

---

## After setup_bcm.sh completes

Return to ObsVM and run `setup.sh` to:
- Start Prometheus, Loki, Grafana
- Deploy dashboards via Terraform
- Configure any optional integrations (UFM, PDU, alerting, etc.)

setup.sh detects that GPU nodes already have Alloy installed and skips the node deployment phase.

---

## Slurm prolog/epilog for job tracking

The Single Job Stats dashboard requires Slurm to stamp `jobid` metadata when jobs start and stop.
This is done via Slurm prolog and epilog scripts on BCM.

Check if they are configured:

```bash
# On BCM
grep -E "Prolog|Epilog" /etc/slurm/slurm.conf
```

If not configured, add them:

```bash
# On BCM
echo 'Prolog=/etc/slurm/prolog.sh' >> /etc/slurm/slurm.conf
echo 'Epilog=/etc/slurm/epilog.sh' >> /etc/slurm/slurm.conf
```

Create `/etc/slurm/prolog.sh`:

```bash
cat > /etc/slurm/prolog.sh << 'EOF'
#!/bin/bash
# Write job metadata to textfile for node_exporter
mkdir -p /var/lib/node_exporter/textfile
cat > /var/lib/node_exporter/textfile/slurm_job.prom << PROM
# HELP slurm_job_active Active Slurm job on this node
# TYPE slurm_job_active gauge
slurm_job_active{jobid="${SLURM_JOB_ID}",user="${SLURM_JOB_USER}",partition="${SLURM_JOB_PARTITION}"} 1
PROM
EOF
chmod +x /etc/slurm/prolog.sh
```

Create `/etc/slurm/epilog.sh`:

```bash
cat > /etc/slurm/epilog.sh << 'EOF'
#!/bin/bash
# Remove job metadata when job ends
rm -f /var/lib/node_exporter/textfile/slurm_job.prom
EOF
chmod +x /etc/slurm/epilog.sh
```

Restart Slurm to pick up the changes:

```bash
systemctl restart slurmctld
```

---

## Troubleshooting

### "cmsh: command not found"
Add cmsh to PATH:
```bash
export PATH=$PATH:/cm/local/apps/cmd/bin
cmsh -c "device list"
```

### SSH to GPU node fails
BCM manages nodes via its internal network. Check:
```bash
cmsh -c "device use node001; show" | grep ip
ping NODE_IP
```

### Alloy not starting on a node
Check the log:
```bash
ssh root@NODE_IP "journalctl -u alloy -n 30"
```

Common cause: ObsVM not reachable on port 9090 from the node.

### node_exporter not starting
```bash
ssh root@NODE_IP "systemctl status node_exporter"
ssh root@NODE_IP "journalctl -u node_exporter -n 20"
```
