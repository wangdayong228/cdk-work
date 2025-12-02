#!/bin/bash
set -Eeuo pipefail

# 接受输入  L1_RPC_URL
if [ $# -lt 2 ]; then
  echo "错误: 请提供 L1_RPC_URL 和 ZK_CLAIM_SERVICE_PRIVATE_KEY 参数"
  echo "用法: $0 <L1_RPC_URL> <ZK_CLAIM_SERVICE_PRIVATE_KEY>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../output"
CONTRACTS_FILE="$OUT_DIR/contracts.json"

# 确保输出目录
mkdir -p "$OUT_DIR"

if [ ! -f "$CONTRACTS_FILE" ]; then
  echo "错误: $CONTRACTS_FILE 文件不存在"
  exit 1
fi

L1_RPC_URL="$1"
ZK_CLAIM_SERVICE_PRIVATE_KEY="$2"

# 读取合约地址（缺失则为空并告警）
polygonZkEVMBridgeAddress="$(jq -r '.polygonZkEVMBridgeAddress // empty' "$CONTRACTS_FILE")"
if [ -z "$polygonZkEVMBridgeAddress" ]; then
  echo "警告: contracts.json 缺少 polygonZkEVMBridgeAddress"
  exit 1
fi

polygonZkEVML2BridgeAddress="$(jq -r '.polygonZkEVML2BridgeAddress // empty' "$CONTRACTS_FILE")"
if [ -z "$polygonZkEVML2BridgeAddress" ]; then
  echo "警告: contracts.json 缺少 polygonZkEVML2BridgeAddress"
  exit 1
fi

# 导出变量供 envsubst 使用，并限定替换清单，避免替换无关环境变量
export PRIVATE_KEY L1_RPC_URL polygonZkEVMBridgeAddress polygonZkEVML2BridgeAddress

envsubst < "$SCRIPT_DIR/zk-claim-service-env.template" > "$OUT_DIR/zk-claim-service-env.env"