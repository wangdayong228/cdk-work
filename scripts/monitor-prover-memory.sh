#!/bin/bash
CONTAINER="${1:-real-prover}"
INTERVAL="${2:-2}"

echo "Monitoring $CONTAINER every ${INTERVAL}s..."

while true; do
    ts=$(date +%H:%M:%S)
    host_free=$(awk '/MemAvailable/{printf "%.0f", $2/1024/1024}' /proc/meminfo)

    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        stats=$(docker stats --no-stream --format '{{.MemUsage}}|{{.CPUPerc}}|{{.PIDs}}' "$CONTAINER")
        rss=$(echo "$stats" | cut -d'|' -f1 | awk '{print $1}')
        cpu=$(echo "$stats" | cut -d'|' -f2)
        pids=$(echo "$stats" | cut -d'|' -f3)
        printf "[%s] host_free=%sG | rss=%s | cpu=%s | pids=%s\n" "$ts" "$host_free" "$rss" "$cpu" "$pids"
    else
        printf "[%s] *** CONTAINER STOPPED ***\n" "$ts"
        exit 0
    fi
    sleep "$INTERVAL"
done
