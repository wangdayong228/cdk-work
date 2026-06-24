#!/bin/bash
# 持续向 L2 发送简单转账交易，用于触发 sequencer 关闭 batch，从而驱动后续 proof 生成。
# 用法：
#   ./send-l2-txs.sh
# 或自定义参数：
#   L2_RPC_URL=http://127.0.0.1/l2rpc L2_PRIVATE_KEY=0x... INTERVAL=30 COUNT=100 ./send-l2-txs.sh

set -euo pipefail

STATE_FILE="${STATE_FILE:-/home/ubuntu/workspace/ydyl-deployment-suite/output/cdk_pipe.state}"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
fi

L2_RPC_URL="${L2_RPC_URL:-http://127.0.0.1/l2rpc}"
L2_PRIVATE_KEY="${L2_PRIVATE_KEY:-}"
RECIPIENT="${RECIPIENT:-0x000000000000000000000000000000000000dEaD}"
AMOUNT="${AMOUNT:-1wei}"
INTERVAL="${INTERVAL:-30}"
COUNT="${COUNT:-0}"

if [[ -z "$L2_PRIVATE_KEY" ]]; then
  echo "错误: 未设置 L2_PRIVATE_KEY" >&2
  exit 1
fi

if ! command -v cast >/dev/null 2>&1; then
  echo "错误: 未找到 cast 命令" >&2
  exit 1
fi

SENDER=$(cast wallet address --private-key "$L2_PRIVATE_KEY")
echo "开始从 $SENDER 向 $RECIPIENT 发送 L2 转账交易"
echo "RPC: $L2_RPC_URL"
echo "间隔: ${INTERVAL}s"
if [[ "$COUNT" -gt 0 ]]; then
  echo "计划发送: $COUNT 笔"
fi

i=1
while true; do
  if [[ "$COUNT" -gt 0 && "$i" -gt "$COUNT" ]]; then
    echo "已完成 $COUNT 笔交易"
    exit 0
  fi

  echo "[$i] $(date -Iseconds) sending ${AMOUNT} to ${RECIPIENT} ..."
  cast send "$RECIPIENT" \
    --value "$AMOUNT" \
    --private-key "$L2_PRIVATE_KEY" \
    --rpc-url "$L2_RPC_URL" \
    --legacy \
    --gas-price 1000000000 \
    --rpc-timeout 60 \
    2>&1 | grep -E 'blockHash|transactionHash|status' || true

  i=$((i + 1))
  sleep "$INTERVAL"
done
