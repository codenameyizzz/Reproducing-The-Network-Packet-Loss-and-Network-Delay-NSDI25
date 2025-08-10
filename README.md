# Cassandra NetFault Experiment — Reproduction Guide

This README explains how to reproduce our **network fault injection** experiments on a 3‑node Cassandra cluster (Dockerized), run `cassandra-stress`, collect logs, and visualize throughput/latency. It includes machine requirements, one‑time setup, modified scripts with explanations, how to run each scenario (packet loss and delay), how to copy results off the box, and a debugging section.

> TL;DR flow: **start cluster → inject fault with `tc netem` via `run_netfault.sh` → run `cassandra-stress` for 60s → collect per‑scenario logs in `outputs/` → summarize with `tail_all.sh` → (optional) SCP to local + plot.**

---

## 1) Machine requirements

- **OS:** Linux host (Ubuntu 20.04/22.04 tested).  
- **Kernel:** Must support `tc`/`netem` (default on Ubuntu).  
- **CPU/RAM:** ≥ 4 vCPU, ≥ 8 GB RAM (16 GB recommended for smoother high‑loss runs).  
- **Disk:** ≥ 20 GB free (Docker images + logs).  
- **Network:** Internet access to pull Docker images.  
- **Tools:** Docker Engine + Docker Compose plugin, `tmux` (recommended), `awk`, `grep`.

> On Ubuntu:  
> ```bash
> sudo apt-get update
> sudo apt-get install -y docker.io docker-compose-plugin tmux
> sudo usermod -aG docker $USER   # log out/in after this
> ```

---

## 2) Repository layout

Create a working dir (e.g., `~/cassandra-demo`) that will contain:

```
cassandra-demo/
├── docker-compose.yml
├── run_netfault.sh
├── tail_all.sh
├── sweep_loss.sh              # optional convenience
├── outputs/                   # created at runtime
└── results/                   # (unused; you can ignore)
```

> Make scripts executable:
> ```bash
> chmod +x run_netfault.sh tail_all.sh sweep_loss.sh
> ```

---

## 3) Cluster definition (Docker Compose)

> **File:** `docker-compose.yml`

```yaml
version: "3.8"

services:
  cassandra_a:
    image: cassandra:3.11
    container_name: cassandra_a
    environment:
      - CASSANDRA_CLUSTER_NAME=TestCluster
      - CASSANDRA_NUM_TOKENS=256
      - CASSANDRA_SEEDS=cassandra_a
      - CASSANDRA_AUTO_BOOTSTRAP=false
      - JVM_OPTS=-Dcassandra.consistent.rangemovement=false
    cap_add:
      - NET_ADMIN
    expose:
      - "9042"
      - "7199"
    networks:
      cassandra_net:
        ipv4_address: 172.28.0.2

  cassandra_b:
    image: cassandra:3.11
    container_name: cassandra_b
    environment:
      - CASSANDRA_CLUSTER_NAME=TestCluster
      - CASSANDRA_NUM_TOKENS=256
      - CASSANDRA_SEEDS=cassandra_a
      - CASSANDRA_AUTO_BOOTSTRAP=false
      - JVM_OPTS=-Dcassandra.consistent.rangemovement=false
    cap_add:
      - NET_ADMIN
    expose:
      - "9042"
      - "7200"
    networks:
      cassandra_net:
        ipv4_address: 172.28.0.3

  cassandra_c:
    image: cassandra:3.11
    container_name: cassandra_c
    environment:
      - CASSANDRA_CLUSTER_NAME=TestCluster
      - CASSANDRA_NUM_TOKENS=256
      - CASSANDRA_SEEDS=cassandra_a
      - CASSANDRA_AUTO_BOOTSTRAP=false
      - JVM_OPTS=-Dcassandra.consistent.rangemovement=false
    cap_add:
      - NET_ADMIN
    expose:
      - "9042"
      - "7201"
    networks:
      cassandra_net:
        ipv4_address: 172.28.0.4

networks:
  cassandra_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
```

**Why these settings?**  
- Three nodes (`a`, `b`, `c`) in one DC; `NET_ADMIN` allows `tc netem`.  
- Static IPs simplify addressing.  
- Seeds point at `cassandra_a`; replication factor 3 is used in the stress tool.  
- We **expose** ports inside the bridge network; external publishing isn’t required.

---

## 4) Fault runner script

> **File:** `run_netfault.sh`  
> Purpose: apply a network fault (loss/delay) on specified nodes for one run, execute `cassandra-stress` for a fixed **duration**, and save logs in `outputs/<timestamp>_<label>/`.

```bash
#!/usr/bin/env bash
set -euo pipefail

MODE="$1"               # 'loss' or 'delay'
RAW_CONTAINERS="$2"     # e.g. "cassandra_b cassandra_c"
VALUE="$3"              # e.g. "40%" or "100ms"
DURATION="$4"           # in seconds
LABEL="$5"              # run label

# 1) Prepare output dir
TS=$(date +"%Y%m%d_%H%M%S")
OUTDIR="outputs/${TS}_${LABEL}"
mkdir -p "$OUTDIR"

echo "[INFO] Mode       : $MODE"
echo "[INFO] Targets    : $RAW_CONTAINERS"
echo "[INFO] Value      : $VALUE"
echo "[INFO] Duration   : ${DURATION}s"
echo "[INFO] Output dir : $OUTDIR"
echo

# 2) Inject netem if requested
if [[ -n "$RAW_CONTAINERS" ]]; then
  for C in $RAW_CONTAINERS; do
    echo "[INFO] Applying $MODE=$VALUE → $C"
    docker exec "$C" tc qdisc del dev eth0 root 2>/dev/null || true
    docker exec "$C" tc qdisc add dev eth0 root netem $MODE $VALUE
    echo "  $(docker exec "$C" tc qdisc show dev eth0)"
  done
  echo "[INFO] Settling 5s…"
  sleep 5
else
  echo "[INFO] No fault injection"
fi

# 3) Run cassandra‑stress (ensure Java 8 in cassandra_a)
LOGFILE="${LABEL}_cassandra-stress.log"
echo "[INFO] Running cassandra-stress for ${DURATION}s…"
docker exec cassandra_a bash -lc "
  apt-get update -qq &&
  apt-get install -y -qq openjdk-8-jre-headless &&
  exec /opt/cassandra/tools/bin/cassandra-stress write \
    duration=${DURATION}s \
    -node cassandra_a:9042,cassandra_b:9042,cassandra_c:9042 \
    -schema 'replication(factor=3)' \
    -mode native cql3 \
    -rate threads=50 \
    > /tmp/${LOGFILE} 2>&1
"

# 4) Copy out the stress log
docker cp cassandra_a:/tmp/${LOGFILE} "$OUTDIR/${LOGFILE}"
echo "[INFO] Stress log → $OUTDIR/${LOGFILE}"

# 5) Save metadata
{
  echo "mode=${MODE}"
  echo "value=${VALUE}"
  echo "duration=${DURATION}"
  date
} > "$OUTDIR/metadata.txt"
echo "[INFO] Metadata → $OUTDIR/metadata.txt"

# 6) Cleanup netem
if [[ -n "$RAW_CONTAINERS" ]]; then
  echo "[INFO] Removing netem…"
  for C in $RAW_CONTAINERS; do
    docker exec "$C" tc qdisc del dev eth0 root 2>/dev/null || true
  done
fi

echo "[SUCCESS] Results in $OUTDIR/"
```

**Notes:**  
- We install `openjdk-8-jre-headless` inside `cassandra_a` the first time to satisfy `cassandra-stress` on Cassandra 3.11 images.  
- `-rate threads=50` fixes client concurrency to make runs comparable.  
- The per‑second CSV lines start with `total,` and include ops/latency columns.

---

## 5) Tail helper

> **File:** `tail_all.sh`  
> Purpose: print a short summary for each run under `outputs/`.

```bash
#!/usr/bin/env bash
# tail_all.sh – show the last 15 lines of every stress log in outputs/
for run_dir in outputs/*; do
  LABEL="${run_dir##*_}"
  LOGFILE="$run_dir/${LABEL}_cassandra-stress.log"

  echo
  echo "=== Run: $LABEL ==="
  if [[ -f "$LOGFILE" ]]; then
    tail -n 15 "$LOGFILE"
  else
    echo "  ⚠️  No stress log found at $LOGFILE"
  fi
done
```

---

## 6) Start the cluster

```bash
docker compose up -d
# (optional) watch logs until "Startup complete":
docker logs -f cassandra_a | grep -m1 "Startup complete"
# Or check nodetool:
docker exec cassandra_a nodetool status
```

> **Tip: use tmux to avoid SSH timeouts**  
> ```bash
> tmux new -s cassandra-test
> # later: tmux attach -t cassandra-test  |  tmux kill-session -t cassandra-test
> ```

---

## 7) Run experiments

### Packet loss scenarios (flaky region)
Run each for 60 seconds; faults are applied to **b** and **c** (client on **a**).

```bash
# Baseline (no fault)
./run_netfault.sh loss "" "" 60 baseline

# Loss sweep
./run_netfault.sh loss "cassandra_b cassandra_c" "1%"  60 loss1p
./run_netfault.sh loss "cassandra_b cassandra_c" "5%"  60 loss5p
./run_netfault.sh loss "cassandra_b cassandra_c" "10%" 60 loss10p
./run_netfault.sh loss "cassandra_b cassandra_c" "15%" 60 loss15p
./run_netfault.sh loss "cassandra_b cassandra_c" "20%" 60 loss20p
./run_netfault.sh loss "cassandra_b cassandra_c" "25%" 60 loss25p
./run_netfault.sh loss "cassandra_b cassandra_c" "30%" 60 loss30p
./run_netfault.sh loss "cassandra_b cassandra_c" "35%" 60 loss35p
./run_netfault.sh loss "cassandra_b cassandra_c" "40%" 60 loss40p
./run_netfault.sh loss "cassandra_b cassandra_c" "45%" 60 loss45p
./run_netfault.sh loss "cassandra_b cassandra_c" "50%" 60 loss50p
./run_netfault.sh loss "cassandra_b cassandra_c" "70%" 60 loss70p
```

### Delay scenarios (optional)
```bash
./run_netfault.sh delay "cassandra_b cassandra_c" "100us" 60 delay100us
./run_netfault.sh delay "cassandra_b cassandra_c" "1ms"   60 delay1ms
./run_netfault.sh delay "cassandra_b cassandra_c" "10ms"  60 delay10ms
./run_netfault.sh delay "cassandra_b cassandra_c" "100ms" 60 delay100ms
./run_netfault.sh delay "cassandra_b cassandra_c" "1s"    60 delay1s
```

> **After runs:**  
> - Logs live under `outputs/<timestamp>_<label>/<label>_cassandra-stress.log`.  
> - Quickly summarize everything:
>   ```bash
>   ./tail_all.sh
>   ```

---

## 8) Parameter table + motivation (from the paper’s “flaky region”)

| Scenario | Type  | Targets                 | Value | Paper motivation (why we test it) |
|---------:|:-----:|-------------------------|:-----:|------------------------------------|
| baseline | none  | —                       |  —    | Establish the no‑fault performance floor. |
| loss1p   | loss  | cassandra_b, cassandra_c| 1%    | Start of flaky region; small loss can already trigger retries. |
| loss5p   | loss  | cassandra_b, cassandra_c| 5%    | Minor but visible degradation under realistic low loss. |
| loss10p  | loss  | cassandra_b, cassandra_c| 10%   | “Danger zone” where tail latency and throughput can swing. |
| loss15p  | loss  | cassandra_b, cassandra_c| 15%   | Sustained impact; more timeouts/backoffs show up. |
| loss20p  | loss  | cassandra_b, cassandra_c| 20%   | Still below partition threshold; sometimes appears near‑normal due to LOCAL_ONE success paths. |
| loss25p  | loss  | cassandra_b, cassandra_c| 25%   | Approaching near‑partition behavior on affected links. |
| loss30p  | loss  | cassandra_b, cassandra_c| 30%   | Severe degradation; many requests rely on single healthy path. |
| loss35p  | loss  | cassandra_b, cassandra_c| 35%   | High loss yet some success; tail latency spikes common. |
| loss40p  | loss  | cassandra_b, cassandra_c| 40%   | Just below effective partition; long stalls appear. |
| loss45p  | loss  | cassandra_b, cassandra_c| 45%   | Near‑partition threshold; frequent retries/timeouts. |
| loss50p  | loss  | cassandra_b, cassandra_c| 50%   | Effectively partition‑like; throughput collapses. |
| loss70p  | loss  | cassandra_b, cassandra_c| 70%   | Beyond threshold; cluster acts as if the nodes are down. |

> **Heads‑up:** Empirically, **20%** sometimes looks close to normal. That’s plausible because Consistency `LOCAL_ONE` can succeed through the still‑healthy replica, and client‑side retry/backoff masks loss for short intervals. Re‑running 20% (e.g., `loss20p-B`) is a good sanity check.

---

## 9) Copy results to your PC (Windows PowerShell)

```powershell
# Copy the entire outputs directory
scp -i "C:\apendable\yizzz-mj-trace.pem" -r cc@192.5.86.216:/home/cc/cassandra-demo/outputs "C:\Outputs\"
```

If you hit quoting issues, try:
```powershell
scp -i C:\apendable\yizzz-mj-trace.pem -r cc@192.5.86.216:/home/cc/cassandra-demo/outputs C:\Outputs\
```

---

## 10) Plot locally (optional)

Below are *minimal* Python snippets you can paste into a local notebook. They only read the `total,` lines and are robust to header noise.

**Bar charts (throughput + mean latency):**
```python
import os, pandas as pd, matplotlib.pyplot as plt
base_dir = r"C:\Outputs\outputs"

data = []
for run in sorted(os.listdir(base_dir)):
    path = os.path.join(base_dir, run)
    if not os.path.isdir(path): continue
    scenario = run.split("_")[-1]
    log = os.path.join(path, f"{scenario}_cassandra-stress.log")
    if not os.path.exists(log): continue

    last = None
    with open(log) as f:
        for line in f:
            if line.startswith("total,"):
                last = [p.strip() for p in line.split(",")]
    if not last: continue

    ops_per_s = float(last[1]) / 60.0   # total ops / 60s window
    mean_lat  = float(last[5])          # ms
    data.append((scenario, ops_per_s, mean_lat))

order = ["loss70p","loss50p","loss45p","loss40p","loss35p","loss30p",
         "loss25p","loss20p","loss15p","loss10p","loss5p","loss1p","baseline"]
df = (pd.DataFrame(data, columns=["scenario","throughput","mean_latency"])
        .set_index("scenario").reindex(order).dropna())

plt.figure(figsize=(8,3)); plt.bar(df.index, df.throughput); plt.yscale('log')
plt.title("Throughput (ops/s)"); plt.xticks(rotation=45, ha="right"); plt.tight_layout(); plt.show()

plt.figure(figsize=(8,3)); plt.bar(df.index, df.mean_latency)
plt.title("Mean Latency (ms)"); plt.xticks(rotation=45, ha="right"); plt.tight_layout(); plt.show()
```

**Trend lines (per‑second series):**
```python
import os, pandas as pd, matplotlib.pyplot as plt
base_dir = r"C:\Outputs\outputs"
scenarios = ["baseline","loss1p","loss5p","loss10p","loss15p","loss20p",
             "loss25p","loss30p","loss35p","loss40p","loss45p","loss50p","loss70p"]

ts = {}
for sc in scenarios:
    folders = [d for d in os.listdir(base_dir) if d.endswith(f"_{sc}")]
    if not folders: continue
    run_dir = os.path.join(base_dir, folders[-1])
    log = os.path.join(run_dir, f"{sc}_cassandra-stress.log")
    if not os.path.isfile(log): continue

    t, lat, thr = [], [], []
    with open(log) as f:
        i = 0
        for line in f:
            if line.startswith("total,"):
                parts = [p.strip() for p in line.split(",")]
                i += 1
                t.append(i)
                thr.append(float(parts[2]))
                lat.append(float(parts[5]))
    ts[sc] = pd.DataFrame({"time_s": t, "throughput": thr, "mean_lat": lat})

plt.figure(figsize=(10,8))
plt.subplot(2,1,1)
for sc, df in ts.items(): plt.plot(df.time_s, df.mean_lat, label=sc, linewidth=1.2)
plt.title("Latency over time"); plt.ylabel("ms"); plt.grid(True, ls='--', alpha=.4); plt.legend(fontsize=7)

plt.subplot(2,1,2)
for sc, df in ts.items(): plt.plot(df.time_s, df.throughput, label=sc, linewidth=1.2)
plt.title("Throughput over time"); plt.xlabel("time (s)"); plt.ylabel("ops/s")
plt.grid(True, ls='--', alpha=.4); plt.legend(fontsize=7)
plt.tight_layout(); plt.show()
```

---

## 11) Debugging & ensuring correctness

**A. Verify the fault really applied**
```bash
# After applying a fault, confirm netem on each target:
docker exec cassandra_b tc qdisc show dev eth0
docker exec cassandra_c tc qdisc show dev eth0
# Should show: netem ... loss X%   or   netem ... delay Y
```

**B. Clear any stale netem**
```bash
for c in cassandra_b cassandra_c; do
  docker exec "$c" tc qdisc del dev eth0 root || true
done
```

**C. Check cluster health**
```bash
docker exec cassandra_a nodetool status
docker exec cassandra_a nodetool gossipinfo | head
```

**D. Watch for expected stress warnings at high loss**
You may see lines like:
- `Timeout while setting keyspace ... (will be retried)`  
- `com.datastax.driver.core.exceptions.WriteTimeoutException ...`  

These indicate retries/timeouts as loss grows (especially ≥ 40–50%).

**E. If a run finishes “too quickly” or no log appears**
- Ensure `cassandra-stress` exists and Java 8 is present (the script installs it).  
- Re‑run the scenario; occasionally 20% loss looks near‑normal (**rerun as `loss20p-B`** to validate).  
- Ensure the label matches the log name pattern: `<label>_cassandra-stress.log`.  
- For SSH timeouts, always run experiments inside `tmux`.

**F. Restart everything cleanly (last resort)**
```bash
docker compose down -v
docker compose up -d
# optionally prune old networks/volumes if needed
```

---

## 12) Cleaning up

```bash
docker compose down -v
rm -rf outputs/*
```

---

## 13) FAQ — short explanations you can reuse

- **Why does 10% already look “severe”?**  
  Even modest loss can push the client into retries/backoffs and make tail latency explode; throughput may drop because successful paths get overloaded.

- **Why can 20% sometimes look close to baseline?**  
  With `LOCAL_ONE`, the client only needs one live replica; if one path is clean during the 60s window, measured throughput/mean latency can look normal. Re‑running 20% often shows variability (we keep a second run like `loss20p-B` to confirm).

- **Why do spikes appear toward the end of the run?**  
  As the run progresses, retries accumulate and the cluster settles into a “steady‑state under stress”, background tasks (e.g., compaction) and timeouts kick in, so the per‑second mean latency climbs and becomes more obvious near the end.

---

Happy experimenting!
