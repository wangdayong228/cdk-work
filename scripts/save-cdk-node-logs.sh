#!/bin/bash
set -uo pipefail

LOG_DIR="${LOG_DIR:-/tmp/cdk-node-logs}"
PREFIX="${1:-cdk-node-1}"

mkdir -p "$LOG_DIR"

log_file="$LOG_DIR/${PREFIX}-$(date +%Y%m%d-%H%M%S).log"

echo "Watching for container starting with '$PREFIX'..."
echo "Logs will be saved to: $log_file"

while true; do
    container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "^${PREFIX}" 2>/dev/null | head -1 || true)
    if [ -n "${container:-}" ]; then
        echo "[$(date -Iseconds)] Found container: $container, starting log capture"
        docker logs -f "$container" >> "$log_file" 2>&1 || true
        echo "[$(date -Iseconds)] Container $container exited, waiting..."
        sleep 5
    else
        sleep 5
    fi
done
