#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DNAT_FIX_SCRIPT="${SCRIPT_DIR}/fix_dnat_port.sh"

if [ ! -f "$DNAT_FIX_SCRIPT" ]; then
  echo "ERROR: fix script not found: $DNAT_FIX_SCRIPT"
  exit 1
fi

HOST_PORT="${HOST_PORT:-60600}" \
CONTAINER_PORT="${CONTAINER_PORT:-5432}" \
CONTAINER_PATTERN="${CONTAINER_PATTERN:-^postgres-1--}" \
SERVICE_NAME="${SERVICE_NAME:-postgres-1}" \
KURTOSIS_PORT_SPEC="${KURTOSIS_PORT_SPEC:-postgres}" \
SERVICE_LABEL="${SERVICE_LABEL:-postgres}" \
ENCLAVE_NAME="${ENCLAVE_NAME:-}" \
exec bash "$DNAT_FIX_SCRIPT"
