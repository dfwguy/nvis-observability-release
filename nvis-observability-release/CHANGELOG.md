# Changelog

All notable changes to NVIS Observability Suite.

Format: [Semantic Versioning](https://semver.org/)

---

## [2.1.0] — 2026-03-26

### Bug Fixes — setup.sh Installer

These bugs were discovered and fixed during production deployment validation against a 3-node BCM/Slurm GPU cluster.

#### Critical: `NODE_HOSTNAME` unbound variable (Alloy never deployed)
- **Root cause**: The Alloy config heredoc used `${NODE_HOSTNAME}` unescaped. The local ObsVM shell expanded it before sending to the remote node — but the variable is only set on the remote node. Under `set -euo pipefail` this silently killed the background deployment function before Alloy was installed.
- **Fix**: Escaped as `\${NODE_HOSTNAME}` so the local shell passes it through and the remote shell expands it correctly from the heredoc.

#### Critical: River syntax error — Alloy config invalid (Alloy crashed on start)
- **Root cause**: Alloy's River config language requires each attribute on its own line. The generated config used one-liner `rule { target_label = "x"  replacement = "y" }` syntax which River rejects with `expected TERMINATOR, got IDENT`.
- **Fix**: All `prometheus.relabel` rule blocks, `queue_config`, and `loki` endpoint blocks expanded to proper multi-line River syntax.

#### Critical: `ssh_node` exit code killed background function (UNKNOWN/SKIP matrix)
- **Root cause**: When any remote script returned non-zero (e.g. Alloy apt install failed, remote script had no metrics on final `curl | grep`), `ssh_node` returned non-zero. The `set -e` in the background subshell exited the function before writing results to `/tmp/nvis-deploy-results.txt`, causing the final matrix to show `UNKNOWN/SKIP` for all nodes.
- **Fix**: Added `|| true` to `ssh_node`'s SSH call so remote script failures are captured in the result variable rather than crashing the function.

#### Critical: `node_runtime` unbound variable (cAdvisor fallback always crashed)
- **Root cause**: `node_runtime="docker"` was only declared inside DCGM Phase D (fresh install path). When DCGM was already running (Phase A latch) or already in Docker (Phase B republish), Phase D never executed, leaving `node_runtime` unset. The cAdvisor `case "$node_runtime"` block (always reached since `cgroup_exporter.py` is absent) then hit `unbound variable` under `set -u`.
- **Fix**: Declared `local node_runtime="docker"` at the top of `install_on_node`, before any phase branching.

#### Critical: `OS_FAMILY` unbound when preflight phase skipped (Docker install crashed)
- **Root cause**: `OS_FAMILY` was set only inside `phase_preflight`. On resume (state file present), preflight was skipped, leaving `OS_FAMILY` unset. Docker install at phase 3 then hit `unbound variable`.
- **Fix**: Added unconditional `OS_FAMILY` detection from `/etc/os-release` at global scope, before any phase runs.

#### Critical: State files bundled in tar (fresh untar not fresh)
- **Root cause**: `.nvis-setup-state`, `.nvis-config`, `.nvis-creds`, `.nvis-nodes` were included in the tar. Untarring on a clean host immediately showed "Previous partial setup detected" and skipped phases.
- **Fix**: All `.nvis-*` files excluded from tar build.

#### DCGM republish: 0 metrics due to CSV mount failure and short timeout
- **Root cause**: Phase B (republish existing container) mounted `/tmp/nvis-dcgm-counters.csv` which only exists after a Phase D (fresh install). On republish after cleanup the file was absent, causing the container to fail silently. Additionally, `sleep 8` was insufficient — DCGM requires 30-60s to enumerate GPUs after container restart.
- **Fix**: Removed CSV volume mount from republish path (use DCGM's built-in defaults). Added retry loop: 4 × 15s checks (60s total).

#### cAdvisor container name conflict
- **Root cause**: If a previous `cadvisor` container existed from a prior run that was not cleaned up, `docker run --name cadvisor` failed with "name already in use".
- **Fix**: Added `docker rm -f cadvisor 2>/dev/null || true` before the `docker run` call.

---

## [2.0.0] — 2026-03-26

### Architecture

- **Push-based metrics collection**: GPU nodes now push via Alloy `remote_write` to ObsVM. Eliminates the need for inbound scrape firewall rules on GPU nodes.
- **Hardcoded hostname in Alloy relabeling**: `sys.env("HOSTNAME")` was unreliable under systemd (returned empty string). All Alloy configs now inject hostname at deploy time via `fix-alloy-labels.sh`. Eliminates `instance=localhost:9400` labels permanently.
- **`honor_timestamps = false` on DCGM scrape**: DCGM exporter embeds its own collection timestamps. When Alloy honored these, duplicate-sample warnings (`num_dropped=N`) appeared every scrape cycle. Setting `honor_timestamps = false` uses Alloy's scrape time, eliminating all drops.
- **All log traffic as `job="syslog"`**: Alloy ships `/var/log/syslog` as a single stream. Dashboards previously queried non-existent jobs (`kernel`, `slurmd`, `auth`, `nv-hostengine`). All log panels now use `job="syslog"` with content-based filters.

### New Dashboards

- **SuperPOD Command Center** (`nvis-superpod-cio.json`): CIO-level operational dashboard. Shows cluster-wide GPU utilization, power draw, temperature heatmap, job throughput, and availability SLA. Scales to 10,000+ GPUs via `avg by (instance)` aggregation.
- **Executive Intelligence Dashboard** (`nvis-executive.json`): Business-level metrics for leadership. GPU allocation efficiency, node availability trends, utilization vs capacity, cost metrics. Dynamic cluster name header.
- **Both added to Terraform deployment** and linked from NVIS Home navigation grid.

### Dashboard Fixes

#### All Dashboards
- `$cluster` variable fixed cluster-wide: was using `node_uname_info` (unreliable, shows stale hostnames) or bare `up{}` (returns all jobs). Now universally uses `label_values(up{job="node-exporter"}, cluster)`.
- `$node` variable: regex updated to `^(?!localhost).*` on all dashboards — excludes localhost entries from dropdown.
- `$node` variable added to dashboards where it was completely missing: `06_impact_analysis.json`, `07_security_audit.json`, `nvis-impact-analysis.json`.
- Hardcoded `uid: "nvis-prometheus"` datasource references replaced with `${datasource}` across all panel definitions.
- `vm_datasource` variable (regex `.*Victoria.*`) removed from `06_impact_analysis.json` — would never match a standard Prometheus datasource, breaking 6 panels.
- `node="$node"` (exact match) replaced with `node=~"$node"` (regex) throughout — required for multi-value variable support.

#### 06_impact_analysis.json
- Added missing `$node` variable (root cause: was never defined, so all `instance=~"$node"` expressions returned empty)
- Fixed `$cluster` source from `node_uname_info` to `up{job="node-exporter"}`
- Fixed 11 expressions: added `cluster=~"$cluster"` and `instance!~"localhost.*"` to all `$node`-based queries
- Removed `vm_datasource` variable; 17 panel datasource refs updated to `${datasource}`

#### 04_node_deep_dive.json
- Fixed log panels: `job="kernel"` → `job="syslog"` with GPU/error content filter; `job="slurmd"` → `job="syslog"` with Slurm content filter
- Added `cluster=~"$cluster"` to all 30 expressions that were missing cluster scoping
- Fixed `$cluster` variable source
- Added `$node` regex for localhost exclusion

#### 10_demo_home.json
- TCP Connections panel: removed undefined `$node` variable from query; uses `cluster=~"$cluster"` only
- Disk I/O panel: same fix
- Removed "OBS Stack Health" panel entirely (moved to Security Audit dashboard)
- Navigation grid: expanded from 4 to 5 columns; added SuperPOD Command Center and Executive Intelligence Dashboard cards
- Renamed cards: "CIO Dashboard" → "SuperPOD Command Center"; "Executive Dashboard" → "Executive Intelligence Dashboard"
- Stat panel row widths fixed to fill 24-column grid

#### 02_gpu_health.json
- GPU Error Log panel: `job=~"nv-hostengine|kernel"` → `job="syslog"` with NVRM/Xid/ECC content filter

#### 07_security_audit.json
- SSH Login Events: `job="auth"` → `job="syslog"` with sshd/pam_unix content filter
- Auth Failures: `job=~"auth|syslog"` → `job="syslog"` + added missing `cluster=~"$cluster"` filter

#### 08_live_topology.json
- Hardcoded `/api/datasources/proxy/uid/nvis-prometheus` URL in topology JS panel replaced with `/api/datasources/proxy/name/Prometheus/`

#### 09_log_explorer.json
- DCGM/NVML panels (×4): `filename="/var/log/nv-hostengine.log"` replaced with `job="syslog"` and GPU error content filter. (Alloy only ships `/var/log/syslog`; nv-hostengine.log is not shipped.)
- Added missing `$node` variable
- Storm Active / Storm Status panels: `container_cpu_usage_seconds_total{job="slurm-cgroup-exporter"}` (wrong metric) replaced with `node_cpu_seconds_total`

#### 03_single_job_stats.json
- Slurm Job Logs: added missing `cluster=~"$cluster"` filter; normalized `job=~"syslog|slurmd|slurm"` to `job="syslog"`

#### nvis-superpod-cio.json
- Removed hardcoded `$300M Infrastructure` header text; replaced with `${cluster}`
- Removed hardcoded spec strings: `2 × DGX A100`, `A100-PCIe-40GB`, `80 GB`, `~624 TFLOPS`
- GPU Allocation panel: `by (node)` aggregation replaced with `topk(50, avg by (instance)(...))` — correct label and scalable
- Added `instance!~"localhost.*"` to 19 expressions
- Fixed `$node` variable regex; fixed `$cluster` source

#### nvis-executive.json
- Dynamic cluster name header: removed hardcoded `TAMU DGX A100 SuperPOD · Krusty COD Cluster · 2-Node · 2× A100-PCIe-40GB`; replaced with `${cluster} GPU Cluster`
- Added `$node` variable with localhost exclusion
- Added `instance!~"localhost.*"` filter to 15 expressions
- Raw DCGM time-series panels wrapped in `avg by (instance)(...)` for scalability

#### nvis-live-topology.json (legacy)
- AirBCM references removed: `AirBCM` → `BCM Controller`; `NVIDIA Air · BCM` → `NVIDIA BCM`

#### All deployed dashboards
- `$cluster` variable fixed to `up{job="node-exporter"}` across all 27 files where it was broken
- Hardcoded `node001→node002` legend formats replaced with `{{instance}} traffic`

### Scripts

- **`fix-alloy-labels.sh`**: Added `honor_timestamps = false` to DCGM scrape block (both inline config and TMPL template)
- **`fix-alloy-labels.sh`**: Updated both the runtime config generator and the repo template to stay in sync
- **`fix-node-exporter.sh`**: Added — checks/installs node_exporter on all GPU nodes

### Infrastructure

- `terraform/terraform.tfvars`: Fixed `YOUR_OBSVM_IP` and `changeme` placeholders to actual values
- `terraform/main.tf`: Added `nvis-executive.json` and `nvis-superpod-cio.json` to deployed dashboard set

---

## [1.0.0] — 2026-03-23

### Initial Release

- Full observability stack: Prometheus, Loki, Grafana, Grafana Alloy
- 14 Grafana dashboards
- Interactive `setup.sh` with BCM auto-discovery
- Push-based Alloy agent template
- Slurm prolog/epilog hooks for per-job metric tagging
- 20+ Slurm simulation jobs for demo/validation
- BCM exporter for cluster manager metrics
- Slurm job exporter for queue/accounting metrics
- Terraform-managed dashboard provisioning
- Checkpoint/resume support in setup.sh
- Multi-OS support: Ubuntu 20/22/24, CentOS 9, RHEL 8/9, Rocky, AlmaLinux
