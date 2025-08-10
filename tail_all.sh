#!/usr/bin/env bash
set -euo pipefail

for run_dir in outputs/*; do
  [[ -d "$run_dir" ]] || continue
  LABEL="${run_dir##*_}"
  LOGFILE="${run_dir}/${LABEL}_cassandra-stress.log"
  echo
  echo "=== Run: ${LABEL} ==="
  if [[ -f "${LOGFILE}" ]]; then
    tail -n 15 "${LOGFILE}"
  else
    echo "  ⚠️  No stress log found at ${LOGFILE}"
  fi
done
