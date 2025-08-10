#!/bin/bash

# Usage:
# ./run_netdelay.sh "cassandra_b cassandra_c" "2000ms" 60 delay2000ms_atstart

set -euo pipefail

RAW_CONTAINERS="$1"    # "cassandra_b cassandra_c"
DELAY_VALUE="$2"       # "2000ms"
DURATION="$3"          # 60
RESULT_DIR="$4"        # "delay2000ms_atstart"

TARGET_CONTAINERS=""
for C in $RAW_CONTAINERS; do
  TARGET_CONTAINERS="$TARGET_CONTAINERS $C"
done

echo "[INFO] Target containers     : $TARGET_CONTAINERS"
echo "[INFO] Delay value           : $DELAY_VALUE"
echo "[INFO] Total duration        : $DURATION seconds"
echo "[INFO] Result directory      : $RESULT_DIR"

mkdir -p "results/$RESULT_DIR"

# Step 1: Inject delay to target containers
for CONTAINER in $TARGET_CONTAINERS; do
  echo "[INFO] Injecting delay to $CONTAINER..."
  docker exec "$CONTAINER" bash -c "
    tc qdisc del dev eth0 root || true
    tc qdisc add dev eth0 root netem delay $DELAY_VALUE
  "
done

echo "[INFO] Waiting 3s to settle delay..."
sleep 3

# Step 2: Start cassandra-stress workload in foreground
echo "[INFO] Running cassandra-stress workload..."
docker exec cassandra_a bash -lc "
  /opt/cassandra/tools/bin/cassandra-stress write cl=LOCAL_ONE duration=${DURATION}s \
    -node cassandra_a:9042,cassandra_b:9042,cassandra_c:9042 \
    -mode native cql3 -rate threads=50 \
    -col n=FIXED\\(1\\) -schema replication\\(factor=3\\) \
    -log level=VERBOSE > /tmp/stress-output.log 2>&1
"

# Step 3: Copy stress output log
echo "[INFO] Copying stress log..."
docker cp cassandra_a:/tmp/stress-output.log "results/$RESULT_DIR/stress-output.log"

# Step 4: Copy Cassandra system logs for all containers
echo "[INFO] Copying Cassandra system.log for timeout analysis..."
for CONTAINER in cassandra_a cassandra_b cassandra_c; do
  docker cp "$CONTAINER":/var/log/cassandra/system.log "results/$RESULT_DIR/system-$CONTAINER.log" || true
done

# Step 5: Save metadata
echo "[INFO] Delay $DELAY_VALUE injected before workload to $TARGET_CONTAINERS" > "results/$RESULT_DIR/metadata.txt"
date > "results/$RESULT_DIR/timestamp.txt"

# Step 6: Cleanup
for CONTAINER in $TARGET_CONTAINERS; do
  echo "[INFO] Removing delay from $CONTAINER..."
  docker exec "$CONTAINER" tc qdisc del dev eth0 root || true
done

echo "[SUCCESS] Experiment done. Results in results/$RESULT_DIR"