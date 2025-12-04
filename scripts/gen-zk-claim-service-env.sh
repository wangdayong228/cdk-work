#!/bin/bash
set -xEeuo pipefail

if [ $# -lt 1 ]; then
  echo "错误: 请提供网络名称参数"
  echo "用法: $0 <network_name>"
  echo "示例: $0 cdk-gen"
  exit 1
fi

# 接受输入  L1_RPC_URL
if [ -z "$L1_RPC_URL" ] || [ -z "$ZK_CLAIM_SERVICE_PRIVATE_KEY" ] || [ -z "$L1_BRIDGE_RELAY_CONTRACT" ] || [ -z "$L2_TYPE" ]; then
  echo "错误: 请提供 L1_RPC_URL 和 ZK_CLAIM_SERVICE_PRIVATE_KEY 和 L1_BRIDGE_RELAY_CONTRACT 和 L2_TYPE 环境变量"
  exit 1
fi

NETWORK=${1#cdk-}            # 移除 "cdk-" 前缀
NETWORK=${NETWORK//-/_} # 将 "-" 替换为 "_"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../output"
DEPLOY_RESULT_FILE="$OUT_DIR/deploy-result-$NETWORK.json"

# 读取合约地址（缺失则为空并告警）
polygonZkEVMBridgeAddress="$(jq -r '.polygonZkEVMBridgeAddress // empty' "$DEPLOY_RESULT_FILE")"
if [ -z "$polygonZkEVMBridgeAddress" ]; then
  echo "警告: deploy-result.json 缺少 polygonZkEVMBridgeAddress"
  exit 1
fi

polygonZkEVML2BridgeAddress="$(jq -r '.polygonZkEVML2BridgeAddress // empty' "$DEPLOY_RESULT_FILE")"
if [ -z "$polygonZkEVML2BridgeAddress" ]; then
  echo "警告: deploy-result.json 缺少 polygonZkEVML2BridgeAddress"
  exit 1
fi

# 导出变量供 envsubst 使用，并限定替换清单，避免替换无关环境变量
export PRIVATE_KEY L1_RPC_URL polygonZkEVMBridgeAddress polygonZkEVML2BridgeAddress L1_BRIDGE_RELAY_CONTRACT L2_TYPE

envsubst < "$SCRIPT_DIR/zk-claim-service-env.template" > "$OUT_DIR/zk-claim-service.env"