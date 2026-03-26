#!/bin/bash
#SBATCH --job-name=nvis-demo-blast
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:1
#SBATCH --time=00:30:00
#SBATCH --output=/tmp/nvis-demo-blast-%j.log
#SBATCH --error=/tmp/nvis-demo-blast-%j.err

echo "=== NVIS Demo Blast Started at $(date) ==="
echo "Nodes: $SLURM_NODELIST"

# ── 1. ECC + XID synthetic log injection (both nodes)
srun --ntasks=2 --ntasks-per-node=1 bash -c '
  NODE=$(hostname)
  for i in $(seq 1 20); do
    logger -t "nvrm" "NVRM: Xid (PCI:0000:01:00): 48, pid=All, mem 00000000 00000000"
    logger -t "nvrm" "NVRM: GPU-00000000:01:00.0: ECC DBE error count: $i (node: $NODE)"
    logger -t "nvrm" "NVRM: ECC SBE error detected on GPU at PCI:0000:01:00 count=$i"
    logger -t "nvidia-smi" "Power violation detected on GPU 0: current=280W limit=250W node=$NODE"
    logger -t "dcgm" "XID 79 received - GPU reset required on $NODE gpu=0"
    sleep 8
  done
' &

# ── 2. Force power cap low on node001 only
NODE1=$(scontrol show hostnames $SLURM_NODELIST | head -1)
srun --ntasks=1 --nodelist=$NODE1 bash -c 'nvidia-smi -pl 50 2>/dev/null; echo "Power cap set to 50W on $(hostname)"'

# ── 3. GPU compute + thermal stress (both nodes)
srun --ntasks=2 --ntasks-per-node=1 bash -c '
  NODE=$(hostname)
  nvidia-smi --auto-boost-default=0 2>/dev/null || true
  nvidia-smi -ac 1215,1410 2>/dev/null || true
  python3 - << PYEOF
import time, os, subprocess
node = os.uname().nodename
try:
    import torch
    device = "cuda" if torch.cuda.is_available() else "cpu"
    a = torch.randn(8192, 8192, device=device)
    b = torch.randn(8192, 8192, device=device)
    t0 = time.time()
    i = 0
    while time.time() - t0 < 1500:
        c = torch.mm(a, b)
        a = c / c.norm()
        i += 1
        if i % 100 == 0:
            r = subprocess.run(["nvidia-smi","--query-gpu=temperature.gpu,power.draw,utilization.gpu","--format=csv,noheader"], capture_output=True, text=True)
            print(f"[{node}] t={int(time.time()-t0)}s {r.stdout.strip()}")
            subprocess.run(["logger","-t","nvidia-smi",f"GPU stats on {node}: {r.stdout.strip()}"])
except ImportError:
    time.sleep(1500)
PYEOF
' &

# ── 4. Memory pressure (both nodes)
srun --ntasks=2 --ntasks-per-node=1 bash -c '
  python3 - << PYEOF
import time, os
node = os.uname().nodename
try:
    import torch
    tensors = []
    for i in range(30):
        tensors.append(torch.zeros(1024, 1024, 1024, device="cuda", dtype=torch.float32))
        print(f"[{node}] VRAM: {i+1}GB allocated")
        time.sleep(3)
    print(f"[{node}] Holding VRAM pressure")
    time.sleep(1200)
except Exception as e:
    print(f"[{node}] VRAM error: {e}")
    time.sleep(1200)
PYEOF
' &

echo "All stressors launched. Monitoring: http://10.127.28.83:3000"
wait

# Restore
srun --ntasks=2 --ntasks-per-node=1 bash -c '
  nvidia-smi -pl 250 2>/dev/null || true
  nvidia-smi --auto-boost-default=1 2>/dev/null || true
  echo "Restored on $(hostname)"
'
echo "=== Done at $(date) ==="
