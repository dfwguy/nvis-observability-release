#!/usr/bin/env bash
set -euo pipefail
NODES=("node001" "node002")

for n in "${NODES[@]}"; do
  echo
  echo "=============================="
  echo "== Restoring $n"
  echo "=============================="
  ssh -o StrictHostKeyChecking=no root@"$n" 'bash -s' <<'EOF'
set -euo pipefail

echo "[1] Ensure /mnt/docker mounted"
mkdir -p /mnt/docker
mountpoint -q /mnt/docker || mount /dev/vdc1 /mnt/docker || true

echo "[2] Ensure fstab entry for /dev/vdc1"
grep -q vdc1 /etc/fstab || echo "/dev/vdc1 /mnt/docker ext4 defaults,nofail 0 2" >> /etc/fstab

echo "[3] Install Docker if missing"
which docker >/dev/null 2>&1 || (
  apt-get update -qq &&
  apt-get install -y docker.io
)

echo "[4] Configure Docker data-root to /mnt/docker/docker"
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'JSON'
{
  "data-root": "/mnt/docker/docker"
}
JSON
systemctl daemon-reload || true
systemctl enable --now docker
echo -n "DockerRoot="; docker info | awk -F": " '/Docker Root Dir/ {print $2}'
df -h /mnt/docker | tail -n 1

echo "[5] Install nvidia-container-toolkit if missing"
if ! dpkg -l | grep -q nvidia-container-toolkit; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

echo "[6] (Re)deploy cAdvisor on port 9306"
docker rm -f cgroup_exporter 2>/dev/null || true
docker run -d --name cgroup_exporter --restart unless-stopped \
  -p 9306:8080 \
  --privileged \
  -v /:/rootfs:ro \
  -v /var/run:/var/run:ro \
  -v /sys:/sys:ro \
  -v /var/lib/docker:/var/lib/docker:ro \
  ghcr.io/google/cadvisor:latest

echo "[7] Deploy DCGM exporter on port 9400"
docker rm -f dcgm-exporter 2>/dev/null || true
docker run -d --name dcgm-exporter --restart unless-stopped \
  --gpus all \
  --cap-add SYS_ADMIN \
  -p 9400:9400 \
  nvcr.io/nvidia/k8s/dcgm-exporter:latest

echo "[8] Write Alloy config (logs + metrics remote_write)"
mkdir -p /etc/alloy
cat >/etc/alloy/config.alloy <<'ALLOYEOF'
// ── Logs ──────────────────────────────────────────────────────────────────
local.file_match "varlog" {
  path_targets = [
    {__path__ = "/var/log/syslog",            job = "syslog",        log_type = "syslog"},
    {__path__ = "/var/log/kern.log",           job = "kernel",        log_type = "kernel"},
    {__path__ = "/var/log/auth.log",           job = "auth",          log_type = "auth"},
    {__path__ = "/var/log/nv-hostengine.log",  job = "nv-hostengine", log_type = "dcgm"},
    {__path__ = "/var/log/slurmd",             job = "slurmd",        log_type = "slurm"},
  ]
}

loki.source.file "logfiles" {
  targets    = local.file_match.varlog.targets
  forward_to = [loki.write.obsvm.receiver]
}

loki.write "obsvm" {
  endpoint {
    url = "http://10.127.28.83:3100/loki/api/v1/push"
  }
  external_labels = {
    cluster = sys.env("NVIS_CLUSTER"),
    node    = sys.env("HOSTNAME"),
  }
}

// ── Metrics: DCGM exporter ────────────────────────────────────────────────
prometheus.scrape "dcgm" {
  targets         = [{"__address__" = "localhost:9400"}]
  forward_to      = [prometheus.relabel.add_labels.receiver]
  scrape_interval = "15s"
}

// ── Metrics: cAdvisor (cgroup/job metrics) ────────────────────────────────
prometheus.scrape "cadvisor" {
  targets         = [{"__address__" = "localhost:9306"}]
  forward_to      = [prometheus.relabel.add_labels.receiver]
  scrape_interval = "15s"
}

// ── Relabel: add node + cluster labels ───────────────────────────────────
prometheus.relabel "add_labels" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule {
    target_label = "instance"
    replacement  = sys.env("HOSTNAME")
  }
  rule {
    target_label = "cluster"
    replacement  = sys.env("NVIS_CLUSTER")
  }
}

// ── Remote write to Prometheus on ObsVM ──────────────────────────────────
prometheus.remote_write "obsvm" {
  endpoint {
    url = "http://10.127.28.83:9090/api/v1/write"
  }
}
ALLOYEOF

echo "[9] Deploy Alloy container"
docker rm -f alloy 2>/dev/null || true
docker run -d --name alloy --restart unless-stopped \
  -v /etc/alloy:/etc/alloy:ro \
  -v /var/log:/var/log:ro \
  -e HOSTNAME=$(hostname) \
  --hostname $(hostname) \
  -p 12345:12345 \
  grafana/alloy:latest \
    run --server.http.listen-addr=0.0.0.0:12345 \
    /etc/alloy/config.alloy

echo "[10] Quick local checks"
sleep 5
curl -fsS http://localhost:9306/metrics >/dev/null && echo "OK: cadvisor on 9306" || echo "WARN: cadvisor not ready yet"
curl -fsS http://localhost:9400/metrics | head -n 2 || echo "WARN: dcgm not ready yet"
docker ps --filter name=alloy --format "Alloy: {{.Status}}"
nvidia-smi -L || true
EOF
done

echo
echo "=============================="
echo "== Cross-node checks from head"
echo "=============================="
for n in "${NODES[@]}"; do
  echo "--- $n cAdvisor :9306"
  curl -fsS "http://${n}:9306/metrics" | head -n 3 || echo "FAIL: ${n}:9306"
  echo "--- $n DCGM :9400"
  curl -fsS "http://${n}:9400/metrics" | head -n 2 || echo "WARN: ${n}:9400 not ready yet"
done

echo
echo "=============================="
echo "== Done. Verify ObsVM:"
echo "   curl -s 'http://10.127.28.83:9090/api/v1/query?query=DCGM_FI_DEV_GPU_TEMP' | python3 -m json.tool"
echo "   curl -s 'http://10.127.28.83:9090/api/v1/query?query=cgroup_info' | python3 -m json.tool | grep -c jobid"
echo "=============================="
