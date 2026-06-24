#!/bin/bash
# Auto-update the iptables DNAT rule for cdk-node aggregator port 50081
# Run this after container restart to fix the port mapping

CONTAINER_NAME="cdk-node-1--8161a0b7ecb54fdfafe776c637967e93"
CONTAINER_IP=$(docker inspect "$CONTAINER_NAME" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

if [ -z "$CONTAINER_IP" ]; then
    echo "ERROR: Cannot find container $CONTAINER_NAME"
    exit 1
fi

echo "Container IP: $CONTAINER_IP"

# Remove old DNAT rule for port 50081 (ignore errors)
sudo iptables -t nat -D DOCKER -p tcp --dport 50081 -j DNAT --to-destination "${CONTAINER_IP}:50081" 2>/dev/null
# Also try to find and remove any stale rules
while sudo iptables -t nat -D DOCKER -p tcp --dport 50081 -j DNAT 2>/dev/null; do :; done

# Add new rule
sudo iptables -t nat -I DOCKER -p tcp --dport 50081 -j DNAT --to-destination "${CONTAINER_IP}:50081"

# Ensure ACCEPT rule exists
if ! sudo iptables -C DOCKER -p tcp -d "$CONTAINER_IP" --dport 50081 -j ACCEPT 2>/dev/null; then
    sudo iptables -I DOCKER -p tcp -d "$CONTAINER_IP" --dport 50081 -j ACCEPT
fi

echo "Fixed port 50081 -> $CONTAINER_IP:50081"

# Also show the current dynamic port
DYNAMIC_PORT=$(docker port "$CONTAINER_NAME" 50081/tcp 2>/dev/null | head -1 | cut -d: -f2)
echo "Current dynamic port: $DYNAMIC_PORT"
echo ""
echo "Prover can connect to:"
echo "  - 44.247.2.2:${DYNAMIC_PORT:-unknown} (dynamic, changes on restart)"
echo "  - 44.247.2.2:50081 (fixed via iptables)"
