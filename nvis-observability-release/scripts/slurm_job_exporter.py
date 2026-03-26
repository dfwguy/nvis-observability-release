#!/usr/bin/env python3
"""
NVIS Slurm Job Exporter
Runs on ObsVM. SSHes to the cluster head node (BCM/slurmctld) and collects
job data via squeue (live) and sacct (historical accounting). Exposes
Prometheus metrics on :9402/metrics.

Works with any username source: local, LDAP, SAML, AD — whatever Slurm sees.
"""

import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from datetime import datetime, timedelta

# ── Config (from environment) ─────────────────────────────────────────────
BCM_HOST        = os.environ.get("BCM_HOST", "")
BCM_USER        = os.environ.get("BCM_USER", "root")
BCM_JUMP        = os.environ.get("BCM_JUMP", "")
BCM_SSH_KEY     = os.environ.get("BCM_SSH_KEY", os.path.expanduser("~/.ssh/id_ed25519"))
BCM_SSH_PORT    = os.environ.get("BCM_SSH_PORT", "22")
BCM_TIMEOUT     = int(os.environ.get("BCM_TIMEOUT", "30"))
CLUSTER_NAME    = os.environ.get("CLUSTER_NAME", "nvis-cluster")
PORT            = int(os.environ.get("SLURM_PORT", "9402"))
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "30"))
SACCT_HOURS     = int(os.environ.get("SACCT_HOURS", "24"))    # rolling window for history

# ── SSH helper ────────────────────────────────────────────────────────────
def ssh_cmd(script: str) -> str:
    opts = [
        "-F", "/dev/null",   # ignore ~/.ssh/config (wrong owner when bind-mounted)
        "-i", BCM_SSH_KEY,
        "-p", BCM_SSH_PORT,
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={BCM_TIMEOUT}",
        "-o", "ServerAliveInterval=10",
        "-o", "ServerAliveCountMax=2",
    ]
    if BCM_JUMP:
        opts += ["-J", BCM_JUMP]
    cmd = ["ssh"] + opts + [f"{BCM_USER}@{BCM_HOST}", "bash -s"]
    try:
        r = subprocess.run(cmd, input=script.encode(), capture_output=True,
                           timeout=BCM_TIMEOUT + 2)
        return r.stdout.decode(errors="replace").strip()
    except Exception as e:
        print(f"[slurm-exporter] ssh error: {e}")
        return ""

# ── Fetch Slurm data ──────────────────────────────────────────────────────
COLLECT_SCRIPT = r"""
echo "===SQUEUE==="
squeue -h -o "%i|%u|%j|%T|%P|%D|%C" 2>/dev/null
echo "===SACCT==="
sacct -a -X --noheader --parsable2 \
  --format=JobID,User,State,Start,End,NCPUS,NNodes,Partition,ElapsedRaw,CPUTimeRAW,MaxRSS,AveRSS \
  --starttime=now-{SACCT_HOURS}hours 2>/dev/null
echo "===DONE==="
""".replace("{SACCT_HOURS}", str(SACCT_HOURS))

def collect():
    if not BCM_HOST:
        return {}, [], []
    raw = ssh_cmd(COLLECT_SCRIPT)
    squeue_lines, sacct_lines = [], []
    section = None
    for line in raw.splitlines():
        if line == "===SQUEUE===":
            section = "sq"
        elif line == "===SACCT===":
            section = "sa"
        elif line == "===DONE===":
            break
        elif section == "sq" and line.strip():
            squeue_lines.append(line.strip())
        elif section == "sa" and line.strip():
            sacct_lines.append(line.strip())
    return parse_squeue(squeue_lines), parse_sacct(sacct_lines)

def parse_squeue(lines):
    """Return list of dicts: {jobid, user, name, state, partition, nodes, cpus}"""
    jobs = []
    for line in lines:
        parts = line.split("|")
        if len(parts) < 7:
            continue
        jobs.append({
            "jobid":     parts[0],
            "user":      parts[1].lower(),   # normalize to lowercase
            "name":      parts[2],
            "state":     parts[3].upper(),
            "partition": parts[4],
            "nodes":     parts[5],
            "cpus":      parts[6],
        })
    return jobs

def _rss_to_bytes(s: str) -> float:
    """Convert sacct MaxRSS/AveRSS string (e.g. '512K', '2.5M', '1G', '1024') to bytes."""
    s = s.strip()
    if not s or s == "0":
        return 0.0
    try:
        mul = {"K": 1024, "M": 1024**2, "G": 1024**3}.get(s[-1].upper())
        if mul:
            return float(s[:-1]) * mul
        return float(s) * 1024   # sacct default unit is KB
    except (ValueError, IndexError):
        return 0.0

def parse_sacct(lines):
    """Return list of dicts: {jobid, user, state, start, end, ncpus, nnodes, partition,
                               elapsed_s, cpu_seconds, maxrss_bytes, averss_bytes}"""
    jobs = []
    for line in lines:
        parts = line.split("|")
        if len(parts) < 8:
            continue
        jobs.append({
            "jobid":        parts[0],
            "user":         parts[1].lower(),
            "state":        parts[2].split()[0].upper(),
            "start":        parts[3],
            "end":          parts[4],
            "ncpus":        parts[5],
            "nnodes":       parts[6],
            "partition":    parts[7],
            "elapsed_s":    parts[8]  if len(parts) > 8  else "0",
            "cpu_seconds":  parts[9]  if len(parts) > 9  else "0",
            "maxrss_bytes": _rss_to_bytes(parts[10]) if len(parts) > 10 else 0.0,
            "averss_bytes": _rss_to_bytes(parts[11]) if len(parts) > 11 else 0.0,
        })
    return jobs

# ── Metric store (thread-safe) ────────────────────────────────────────────
_lock   = threading.Lock()
_metrics_text = "# waiting for first collection\n"
_last_ok = 0.0

def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def labels(**kv) -> str:
    return "{" + ",".join(f'{k}="{escape(str(v))}"' for k, v in kv.items()) + "}"

def build_metrics(active_jobs, sacct_jobs):
    lines = []
    cluster = CLUSTER_NAME

    # ── squeue: active (RUNNING + PENDING) ──────────────────────────────
    running  = [j for j in active_jobs if j["state"] == "RUNNING"]
    pending  = [j for j in active_jobs if j["state"] == "PENDING"]
    all_active = running + pending

    active_users   = set(j["user"] for j in all_active if j["user"])
    running_users  = set(j["user"] for j in running if j["user"])

    lines += [
        "# HELP slurm_jobs_running_total Number of RUNNING Slurm jobs",
        "# TYPE slurm_jobs_running_total gauge",
        f'slurm_jobs_running_total{labels(cluster=cluster)} {len(running)}',
        "# HELP slurm_jobs_pending_total Number of PENDING Slurm jobs",
        "# TYPE slurm_jobs_pending_total gauge",
        f'slurm_jobs_pending_total{labels(cluster=cluster)} {len(pending)}',
        "# HELP slurm_jobs_active_total Running + Pending jobs",
        "# TYPE slurm_jobs_active_total gauge",
        f'slurm_jobs_active_total{labels(cluster=cluster)} {len(all_active)}',
        "# HELP slurm_users_active_total Unique users with running or pending jobs",
        "# TYPE slurm_users_active_total gauge",
        f'slurm_users_active_total{labels(cluster=cluster)} {len(active_users)}',
        "# HELP slurm_users_running_total Unique users with RUNNING jobs",
        "# TYPE slurm_users_running_total gauge",
        f'slurm_users_running_total{labels(cluster=cluster)} {len(running_users)}',
    ]

    # Per-user active job counts (for Jobs Per User panel)
    lines += [
        "# HELP slurm_jobs_active_by_user Active (running+pending) jobs per user",
        "# TYPE slurm_jobs_active_by_user gauge",
    ]
    user_active: dict = {}
    for j in all_active:
        u = j["user"]
        if u:
            user_active[u] = user_active.get(u, 0) + 1
    for user, cnt in user_active.items():
        lines.append(f'slurm_jobs_active_by_user{labels(cluster=cluster,user=user)} {cnt}')

    # Per-partition active job counts
    lines += [
        "# HELP slurm_jobs_active_by_partition Active jobs per partition",
        "# TYPE slurm_jobs_active_by_partition gauge",
    ]
    part_active: dict = {}
    for j in all_active:
        p = j["partition"]
        if p:
            part_active[p] = part_active.get(p, 0) + 1
    for part, cnt in part_active.items():
        lines.append(f'slurm_jobs_active_by_partition{labels(cluster=cluster,partition=part)} {cnt}')

    # ── sacct: historical window (last SACCT_HOURS hours) ───────────────
    # Aggregate by user + state
    lines += [
        f"# HELP slurm_jobs_recent_by_user_state Job count per user/state in last {SACCT_HOURS}h",
        "# TYPE slurm_jobs_recent_by_user_state gauge",
    ]
    recent: dict = {}
    for j in sacct_jobs:
        u = j["user"]
        s = j["state"]
        if u:
            key = (u, s)
            recent[key] = recent.get(key, 0) + 1
    for (user, state), cnt in sorted(recent.items()):
        lines.append(
            f'slurm_jobs_recent_by_user_state{labels(cluster=cluster,user=user,state=state)} {cnt}'
        )

    # Total recent jobs regardless of state
    lines += [
        f"# HELP slurm_jobs_recent_total Total jobs submitted in last {SACCT_HOURS}h",
        "# TYPE slurm_jobs_recent_total gauge",
        f'slurm_jobs_recent_total{labels(cluster=cluster)} {len(sacct_jobs)}',
    ]

    # Unique users who submitted jobs in the window
    recent_users = set(j["user"] for j in sacct_jobs if j["user"])
    lines += [
        f"# HELP slurm_users_recent_total Unique users who ran jobs in last {SACCT_HOURS}h",
        "# TYPE slurm_users_recent_total gauge",
        f'slurm_users_recent_total{labels(cluster=cluster)} {len(recent_users)}',
    ]

    # Per-user total jobs in window (all states)
    lines += [
        f"# HELP slurm_jobs_recent_by_user Jobs per user in last {SACCT_HOURS}h (all states)",
        "# TYPE slurm_jobs_recent_by_user gauge",
    ]
    user_recent: dict = {}
    for j in sacct_jobs:
        u = j["user"]
        if u:
            user_recent[u] = user_recent.get(u, 0) + 1
    for user, cnt in sorted(user_recent.items()):
        lines.append(f'slurm_jobs_recent_by_user{labels(cluster=cluster,user=user)} {cnt}')

    # ── Per-job resource accounting from sacct ──────────────────────────────
    lines += [
        "# HELP slurm_job_elapsed_seconds Wall-clock duration of completed job",
        "# TYPE slurm_job_elapsed_seconds gauge",
    ]
    for j in sacct_jobs:
        if j["jobid"] and j["user"]:
            try:
                val = float(j["elapsed_s"])
            except (ValueError, TypeError):
                val = 0.0
            lines.append(f'slurm_job_elapsed_seconds{labels(cluster=cluster,jobid=j["jobid"],user=j["user"])} {val:.0f}')

    lines += [
        "# HELP slurm_job_cpu_seconds Total CPU-seconds consumed by job",
        "# TYPE slurm_job_cpu_seconds gauge",
    ]
    for j in sacct_jobs:
        if j["jobid"] and j["user"]:
            try:
                val = float(j["cpu_seconds"])
            except (ValueError, TypeError):
                val = 0.0
            lines.append(f'slurm_job_cpu_seconds{labels(cluster=cluster,jobid=j["jobid"],user=j["user"])} {val:.0f}')

    lines += [
        "# HELP slurm_job_maxrss_bytes Peak memory (MaxRSS) of job in bytes",
        "# TYPE slurm_job_maxrss_bytes gauge",
    ]
    for j in sacct_jobs:
        if j["jobid"] and j["user"]:
            lines.append(f'slurm_job_maxrss_bytes{labels(cluster=cluster,jobid=j["jobid"],user=j["user"])} {j["maxrss_bytes"]:.0f}')

    lines += [
        "# HELP slurm_job_averss_bytes Average memory (AveRSS) of job in bytes",
        "# TYPE slurm_job_averss_bytes gauge",
    ]
    for j in sacct_jobs:
        if j["jobid"] and j["user"]:
            lines.append(f'slurm_job_averss_bytes{labels(cluster=cluster,jobid=j["jobid"],user=j["user"])} {j["averss_bytes"]:.0f}')

    lines += [
        "# HELP slurm_job_ncpus CPUs allocated to job",
        "# TYPE slurm_job_ncpus gauge",
    ]
    for j in sacct_jobs:
        if j["jobid"] and j["user"]:
            try:
                val = int(j["ncpus"])
            except (ValueError, TypeError):
                val = 0
            lines.append(f'slurm_job_ncpus{labels(cluster=cluster,jobid=j["jobid"],user=j["user"])} {val}')

    # ── Per-job info (label carrier for dropdown + table in single-job-stats) ─
    # Merge sacct history + active squeue jobs, dedup by jobid (squeue wins for state)
    seen: dict = {}
    for j in sacct_jobs:
        jid = j["jobid"]
        if jid:
            seen[jid] = {
                "jobid": jid, "user": j["user"], "state": j["state"],
                "partition": j["partition"], "nnodes": j["nnodes"], "ncpus": j["ncpus"],
            }
    for j in all_active:
        jid = j["jobid"]
        if jid:
            seen[jid] = {
                "jobid": jid, "user": j["user"], "state": j["state"],
                "partition": j["partition"], "nnodes": j["nodes"], "ncpus": j["cpus"],
            }
    lines += [
        "# HELP slurm_job_info Per-job accounting info (label carrier for job lookup)",
        "# TYPE slurm_job_info gauge",
    ]
    for info in seen.values():
        if info["user"]:
            lines.append(
                f'slurm_job_info{labels(cluster=cluster,jobid=info["jobid"],user=info["user"],state=info["state"],partition=info["partition"],nnodes=info["nnodes"],ncpus=info["ncpus"])} 1'
            )

    # Exporter health
    lines += [
        "# HELP slurm_exporter_last_success_timestamp Unix timestamp of last successful collect",
        "# TYPE slurm_exporter_last_success_timestamp gauge",
        f'slurm_exporter_last_success_timestamp{labels(cluster=cluster)} {time.time():.0f}',
        "# HELP up Exporter health",
        "# TYPE up gauge",
        f'up{labels(job="slurm-job-exporter",cluster=cluster,instance="slurm")} 1',
    ]

    return "\n".join(lines) + "\n"

def collector_loop():
    global _metrics_text, _last_ok
    print(f"[slurm-exporter] starting — BCM={BCM_HOST} cluster={CLUSTER_NAME} port={PORT}")
    while True:
        try:
            active, sacct = collect()
            text = build_metrics(active, sacct)
            with _lock:
                _metrics_text = text
                _last_ok = time.time()
            print(f"[slurm-exporter] collected: {len(active)} active jobs, "
                  f"{len(sacct)} sacct jobs in last {SACCT_HOURS}h")
        except Exception as e:
            print(f"[slurm-exporter] collect error: {e}")
            err = (
                '# HELP up Exporter health\n# TYPE up gauge\n'
                f'up{{job="slurm-job-exporter",cluster="{CLUSTER_NAME}",instance="slurm"}} 0\n'
            )
            with _lock:
                _metrics_text = err
        time.sleep(SCRAPE_INTERVAL)

# ── HTTP server ───────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/metrics", "/"):
            with _lock:
                body = _metrics_text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/health":
            ok = time.time() - _last_ok < SCRAPE_INTERVAL * 3
            self.send_response(200 if ok else 503)
            self.end_headers()
            self.wfile.write(b"ok" if ok else b"stale")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_):
        pass

if __name__ == "__main__":
    if not BCM_HOST:
        print("[slurm-exporter] WARNING: BCM_HOST not set — will export zeros")
    t = threading.Thread(target=collector_loop, daemon=True)
    t.start()
    server = HTTPServer(("", PORT), Handler)
    print(f"[slurm-exporter] serving on :{PORT}")
    server.serve_forever()
