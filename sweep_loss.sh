#!/usr/bin/env bash
set -euo pipefail

LOSSES=("1%" "5%" "10%" "15%" "20%" "25%" "30%" "35%" "40%" "45%" "50%" "70%")
DUR="${1:-60}"

./run_netfault.sh loss "" "" "${DUR}" baseline

for L in "${LOSSES[@]}"; do
  LBL="loss${L/\%/p}"
  ./run_netfault.sh loss "cassandra_b cassandra_c" "${L}" "${DUR}" "${LBL}"
done
