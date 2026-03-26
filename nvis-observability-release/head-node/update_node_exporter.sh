#!/usr/bin/env bash
# Run from Krusty BCM head node: bash update_node_exporter.sh
set -euo pipefail
OBSVM="10.127.28.83"

for node in node001 node002; do
  echo "Updating ${node}..."
  ssh $node 'cat > /etc/systemd/system/node_exporter.service << '\''EOF'\''
[Unit]
Description=Node Exporter NVIS Enhanced
After=network.target
[Service]
ExecStart=/usr/local/bin/node_exporter \
  --collector.textfile.directory=/var/lib/node_exporter/textfile \
  --web.listen-address=:9100 \
  --collector.cpu.info \
  --collector.diskstats \
  --collector.filesystem \
  --collector.netstat \
  --collector.netstat.fields=TcpExt:.*|Tcp:.*|Udp:.*|UdpLite:.* \
  --collector.sockstat \
  --collector.meminfo \
  --collector.processes \
  --collector.uname \
  --collector.os \
  --collector.dmi \
  --collector.systemd
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl restart node_exporter && echo "done $(hostname)"'
done

echo "Waiting 20s..."
sleep 20

echo "=== CPU model ==="
curl -s "http://${OBSVM}:9090/api/v1/query?query=node_cpu_info" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['data']['result'][:2]:
    print(r['metric'].get('model_name','?'), '-', r['metric'].get('instance','?'))
" 2>/dev/null || echo "not yet"

echo "=== TCP connections ==="
curl -s "http://${OBSVM}:9090/api/v1/query?query=node_netstat_Tcp_CurrEstab" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['data']['result']:
    print(r['metric'].get('instance','?'), ':', r['value'][1], 'established TCP')
" 2>/dev/null
