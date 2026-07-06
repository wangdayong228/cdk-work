#!/bin/bash
set -euo pipefail

HOST_PORT="${HOST_PORT:-60500}"
CONTAINER_PORT="${CONTAINER_PORT:-50081}"
CONTAINER_PATTERN="${CONTAINER_PATTERN:-^cdk-node-1--}"
SERVICE_NAME="${SERVICE_NAME:-cdk-node-1}"
KURTOSIS_PORT_SPEC="${KURTOSIS_PORT_SPEC:-aggregator}"
SERVICE_LABEL="${SERVICE_LABEL:-service}"
ENCLAVE_NAME="${ENCLAVE_NAME:-}"

resolve_container_by_enclave() {
  if [ -z "$ENCLAVE_NAME" ]; then
    return 1
  fi

  if ! command -v kurtosis >/dev/null 2>&1; then
    return 1
  fi

  local endpoint dynamic_port container_name
  endpoint=$(kurtosis port print "$ENCLAVE_NAME" "$SERVICE_NAME" "$KURTOSIS_PORT_SPEC" 2>/dev/null || true)
  if [ -z "$endpoint" ]; then
    return 1
  fi

  dynamic_port="${endpoint##*:}"
  if ! [[ "$dynamic_port" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  while IFS= read -r container_name; do
    if docker port "$container_name" "${CONTAINER_PORT}/tcp" 2>/dev/null | grep -Eq ":${dynamic_port}$"; then
      echo "$container_name"
      return 0
    fi
  done < <(docker ps --format '{{.Names}}' | grep -E "$CONTAINER_PATTERN" || true)

  return 1
}

CONTAINER_NAME="$(resolve_container_by_enclave || true)"
if [ -z "${CONTAINER_NAME}" ]; then
  CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep -E -m 1 "$CONTAINER_PATTERN" || true)
fi
if [ -z "${CONTAINER_NAME}" ]; then
  if [ -n "$ENCLAVE_NAME" ]; then
    echo "WARN: 未找到匹配容器（service=${SERVICE_LABEL}, enclave=${ENCLAVE_NAME}, pattern=${CONTAINER_PATTERN}），跳过 DNAT 配置。"
  else
    echo "WARN: 未找到匹配容器（service=${SERVICE_LABEL}, pattern=${CONTAINER_PATTERN}），跳过 DNAT 配置。"
  fi
  exit 0
fi

CONTAINER_IP=$(docker inspect "$CONTAINER_NAME" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || true)
if [ -z "${CONTAINER_IP}" ]; then
  echo "ERROR: 无法获取容器 IP (${SERVICE_LABEL}): ${CONTAINER_NAME}"
  exit 1
fi

echo "${SERVICE_LABEL} 容器: ${CONTAINER_NAME} (${CONTAINER_IP}:${CONTAINER_PORT})"

# 清理旧规则（幂等）
sudo iptables -t nat -D DOCKER -p tcp --dport "$HOST_PORT" -j DNAT --to-destination "${CONTAINER_IP}:${CONTAINER_PORT}" 2>/dev/null || true
while sudo iptables -t nat -D DOCKER -p tcp --dport "$HOST_PORT" -j DNAT 2>/dev/null; do :; done

# 添加当前 DNAT 规则
sudo iptables -t nat -I DOCKER -p tcp --dport "$HOST_PORT" -j DNAT --to-destination "${CONTAINER_IP}:${CONTAINER_PORT}"

# 确保 DOCKER 链允许转发到容器
if ! sudo iptables -C DOCKER -p tcp -d "$CONTAINER_IP" --dport "$CONTAINER_PORT" -j ACCEPT 2>/dev/null; then
  sudo iptables -I DOCKER -p tcp -d "$CONTAINER_IP" --dport "$CONTAINER_PORT" -j ACCEPT
fi

echo "Fixed ${SERVICE_LABEL} port ${HOST_PORT} -> ${CONTAINER_IP}:${CONTAINER_PORT}"
