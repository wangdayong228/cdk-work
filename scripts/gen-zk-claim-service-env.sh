#!/bin/bash
set -xEueo pipefail
trap 'echo "命令失败: 行 $LINENO"; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
YDYL_SCRIPTS_LIB_DIR="${YDYL_SCRIPTS_LIB_DIR:-$REPO_ROOT/ydyl-scripts-lib}"
if [ ! -f "$YDYL_SCRIPTS_LIB_DIR/utils.sh" ]; then
  echo "错误: 未找到 ydyl-scripts-lib/utils.sh"
  echo "请设置 YDYL_SCRIPTS_LIB_DIR 指向脚本库目录，例如: export YDYL_SCRIPTS_LIB_DIR=\"$REPO_ROOT/ydyl-scripts-lib\""
  exit 1
fi
# shellcheck source=/dev/null
source "$YDYL_SCRIPTS_LIB_DIR/utils.sh"

if [ $# -lt 1 ]; then
  echo "错误: 请提供网络名称参数"
  echo "用法: $0 <network_name>"
  echo "示例: $0 cdk-gen"
  exit 1
fi

# 接受输入  L1_RPC_URL
# 说明：L2_PRIVATE_KEY 用于在 L2 上部署 Counter 合约（bridge 注册流程依赖），并会被写入 counter-bridge-register.env。
if [ -z "$L1_RPC_URL" ] || [ -z "$CLAIM_SERVICE_PRIVATE_KEY" ] || [ -z "$L1_BRIDGE_HUB_CONTRACT" ] || [ -z "$L1_REGISTER_BRIDGE_PRIVATE_KEY" ] || [ -z "$L2_TYPE" ] || [ -z "$L2_PRIVATE_KEY" ]; then
  echo "错误: 请提供 L1_RPC_URL 和 CLAIM_SERVICE_PRIVATE_KEY 和 L1_BRIDGE_HUB_CONTRACT 和 L1_REGISTER_BRIDGE_PRIVATE_KEY 和 L2_TYPE 和 L2_PRIVATE_KEY 环境变量"
  exit 1
fi

NETWORK=${1#cdk-}            # 移除 "cdk-" 前缀
NETWORK=${NETWORK//-/_} # 将 "-" 替换为 "_"

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

# 创建一个助记词同时用于 L2->L1 和 L1->L2 跨链交易
ZK_CLAIM_SERVICE_MNEMONIC=$(cast wallet new-mnemonic --json | jq -r '.mnemonic')

# 导出变量供 envsubst 使用，并限定替换清单，避免替换无关环境变量
# 说明：L2_PRIVATE_KEY 会进入 counter-bridge-register.env，供 zk-claim-service 的部署/注册脚本读取以部署 L2 Counter 合约。
export PRIVATE_KEY L1_RPC_URL polygonZkEVMBridgeAddress polygonZkEVML2BridgeAddress L1_BRIDGE_HUB_CONTRACT L2_TYPE L2_PRIVATE_KEY ZK_CLAIM_SERVICE_MNEMONIC

OUT_DIR_ZK_CLAIM_SERVICE_ENV="$OUT_DIR/zk-claim-service.env"
envsubst < "$SCRIPT_DIR/../templates/zk-claim-service-env.template" > "$OUT_DIR_ZK_CLAIM_SERVICE_ENV"
check_template_substitution "$OUT_DIR_ZK_CLAIM_SERVICE_ENV"
echo "zk-claim-service.env 文件已生成: $OUT_DIR_ZK_CLAIM_SERVICE_ENV"

OUT_DIR_COUNTER_BRIDGE_REGISTER_ENV="$OUT_DIR/counter-bridge-register.env"
envsubst < "$SCRIPT_DIR/../templates/counter-bridge-register-env.template" > "$OUT_DIR_COUNTER_BRIDGE_REGISTER_ENV"
check_template_substitution "$OUT_DIR_COUNTER_BRIDGE_REGISTER_ENV"
echo "counter-bridge-register.env 文件已生成: $OUT_DIR_COUNTER_BRIDGE_REGISTER_ENV"