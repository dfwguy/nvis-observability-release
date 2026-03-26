# Contributing to NVIS Observability Suite

Thank you for contributing. This guide covers the development workflow.

---

## Development Setup

```bash
git clone <repo-url> nvis-observability
cd nvis-observability
```

No build step required — this is shell scripts, Python, JSON dashboards, and HCL.

---

## Repository Structure

```
nvis-observability/
├── setup.sh                    # Main installer (bash, ~2500 lines)
├── setup_bcm.sh                # BCM head node exporter install
├── fix-alloy-labels.sh         # Alloy label fix / redeploy script
├── fix-node-exporter.sh        # node_exporter check/install
├── docker-compose.yml          # ObsVM stack (Prometheus, Loki, Grafana)
│
├── alloy/
│   └── config.alloy            # Alloy template (placeholders for deploy)
│
├── terraform/
│   ├── main.tf                 # Dashboard resource definitions
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── dashboards/             # 34 Grafana dashboard JSON files
│       ├── 10_demo_home.json   # NVIS Home (deployed)
│       ├── 01_cluster_overview.json  # (deployed)
│       └── ...                 # 10 more deployed + legacy files
│
├── prometheus/
│   └── prometheus.yml          # Prometheus scrape config (ObsVM-side)
│
├── loki/                       # Loki config
├── dcgm/
│   └── dcgm-counters.csv       # DCGM field collection config
│
├── slurm/                      # Slurm job scripts
│   ├── gpu_burn.sbatch
│   ├── nvis_demo_10mins.sbatch
│   └── ...                     # 20+ simulation jobs
│
├── scripts/
│   ├── bcm_exporter.py         # BCM REST → Prometheus metrics
│   ├── bcm-exporter.service    # Systemd unit
│   ├── slurm_job_exporter.py   # squeue/sacct → Prometheus metrics
│   └── slurm_job_exporter.service
│
├── certs/
│   └── bcm-ca.pem              # BCM TLS CA certificate
│
└── docs/
    ├── DEPLOYMENT_GUIDE.md     # Comprehensive deployment guide
    ├── SETUP_INSTRUCTIONS.md
    ├── SETUP_BCM_INSTRUCTIONS.md
    └── DASHBOARD_INVENTORY.md
```

---

## Dashboard Development

### Editing Dashboards

1. Edit the JSON in `terraform/dashboards/`
2. Validate JSON: `python3 -c "import json; json.load(open('terraform/dashboards/your.json'))"`
3. Deploy: `cd terraform && terraform apply -auto-approve`

### Adding a New Dashboard

1. Create `terraform/dashboards/your-dashboard.json`
2. Add to `terraform/main.tf`:
   ```hcl
   "your_dashboard" = "${path.module}/dashboards/your-dashboard.json"
   ```
3. `terraform apply -auto-approve`

### Dashboard JSON Conventions

- Use `${datasource}` for Prometheus panels (never hardcode UIDs)
- Use `${loki_datasource}` for Loki panels
- All cluster filters: `cluster=~"$cluster"` (regex, not exact)
- All node filters: `instance=~"$node"` (not `node=~"$node"` for Prometheus)
- Loki panels: always `job="syslog"` — never `job="kernel"`, `job="auth"`, etc.
- `$node` variable must have `regex: "^(?!localhost).*"` and `allValue: ".*"`
- `$cluster` query: `label_values(up{job="node-exporter"}, cluster)`
- DCGM expressions: always include `instance!~"localhost.*"` filter

### Checking Dashboard Health

```bash
python3 << 'EOF'
import json, glob, re

BASE = 'terraform/dashboards'
deployed = ['01_cluster_overview.json', '02_gpu_health.json', '03_single_job_stats.json',
            '04_node_deep_dive.json', '06_impact_analysis.json', '07_security_audit.json',
            '08_live_topology.json', '09_log_explorer.json', '10_demo_home.json',
            'nvis-superpod-cio.json', 'nvis-executive.json']

for fname in deployed:
    with open(f'{BASE}/{fname}') as f:
        d = json.load(f)
    raw = open(f'{BASE}/{fname}').read()
    issues = []
    if 'nvis-prometheus' in raw: issues.append('hardcoded datasource UID')
    if 'vm_datasource' in raw: issues.append('vm_datasource ref')
    if 'AirBCM' in raw: issues.append('AirBCM ref')
    vars_defined = {v['name'] for v in d.get('templating',{}).get('list',[])}
    uses_node = any('$node' in t.get('expr','') for p in d.get('panels',[]) for t in p.get('targets',[]))
    if uses_node and 'node' not in vars_defined: issues.append('missing $node variable')
    print(f"{'OK':4} {fname}" if not issues else f"FAIL {fname}: {', '.join(issues)}")
EOF
```

---

## Alloy Config Development

The template is `alloy/config.alloy`. Placeholders `<OBSVM_IP>`, `<CLUSTER_NAME>`, `<NODE_HOSTNAME>` are substituted at deploy time by `fix-alloy-labels.sh`.

**Critical River syntax rules:**
- Each block attribute on its own line (newline is the terminator)
- Object literals in arrays use commas: `[{ key = "val", key2 = "val2" }]`
- Test syntax: `alloy fmt config.alloy` (on a node with Alloy installed)

After editing `alloy/config.alloy`, run `bash fix-alloy-labels.sh` to push to all nodes.

---

## Versioning

We use [Semantic Versioning](https://semver.org/):
- **MAJOR**: Breaking changes to setup.sh CLI, config format, or dashboard structure
- **MINOR**: New dashboards, new integrations, new setup phases
- **PATCH**: Bug fixes, dashboard query corrections, label fixes

Update `CHANGELOG.md` with every PR.

---

## Pull Request Guidelines

1. One logical change per PR
2. Test with `terraform apply` if touching dashboards
3. Test `fix-alloy-labels.sh` on at least one real node if touching Alloy config
4. Update `CHANGELOG.md` under `[Unreleased]`
5. Do not commit: `.env`, `.nvis-creds`, `terraform.tfvars`, `terraform.tfstate*`, debug logs

---

## Security

- Never commit credentials, IPs, or customer data
- `terraform.tfvars` is in `.gitignore` — use `terraform.tfvars.example` for reference
- `.nvis-creds` and `.nvis-config` are in `.gitignore`
- Dashboard JSON must not contain hardcoded IPs, cluster names, or node names
- Check with: `grep -r "10\.\|192\.168\.\|TAMU\|customer" terraform/dashboards/`
