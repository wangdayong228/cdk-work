#!/bin/bash
set -euo pipefail

# Compatibility wrapper:
# Keep legacy debug entrypoint, but delegate iptables logic to
# cdk-work/update-nginx/fix_aggregator_port.sh to avoid duplication.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX_SCRIPT="${SCRIPT_DIR}/../../update-nginx/fix_aggregator_port.sh"

if [ ! -f "$FIX_SCRIPT" ]; then
  echo "ERROR: fix script not found: $FIX_SCRIPT"
  exit 1
fi

HOST_PORT="${HOST_PORT:-50081}" \
CONTAINER_PORT="${CONTAINER_PORT:-50081}" \
CONTAINER_PATTERN="${CONTAINER_PATTERN:-^cdk-node-1--}" \
bash "$FIX_SCRIPT"
