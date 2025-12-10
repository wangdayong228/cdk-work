#!/bin/bash
set -xeuo pipefail
trap 'echo "🔴 deploy.sh 执行失败: 行 $LINENO, 错误信息: $BASH_COMMAND"; exit 1' ERR

DRYRUN=${DRYRUN:-false}
FORCE_DEPLOY_CDK=${FORCE_DEPLOY_CDK:-false}

# DRYRUN=TRUE 不部署cdk
# DRYRUN=FALSE，FORCE_DEPLOY_CDK=TRUE 无论 CDK 是否存在，都强制部署
# DRYRUN=FALSE，FORCE_DEPLOY_CDK=FALSE 如果 CDK 已经存在，则不部署
NEED_DEPLOY_CDK=false

# 根据注释说明当前部署模式
if [ "$DRYRUN" == "true" ]; then
  echo "DRYRUN 模式: $DRYRUN"
  echo "DRYRUN 模式下，不执行实际部署，只打印部署命令和检查参数是否正确"
elif [ "$FORCE_DEPLOY_CDK" == "true" ]; then
  echo "FORCE_DEPLOY_CDK 模式: $FORCE_DEPLOY_CDK"
  echo "FORCE_DEPLOY_CDK 模式下，且非 DRYRUN 模式下，无论 CDK 是否存在，都强制部署"
  NEED_DEPLOY_CDK=true
else
  echo "普通部署模式: DRYRUN=false, FORCE_DEPLOY_CDK=false"
  echo "普通部署模式下，如果 CDK 已经存在，可以选择不重新部署"
  if kurtosis enclave ls | grep -q "$1"; then
    echo "检测到已存在的 enclave: $1，保持 NEED_DEPLOY_CDK=false，不重新部署"
  else
    echo "未检测到已有 enclave: $1，设置 NEED_DEPLOY_CDK=true"
    NEED_DEPLOY_CDK=true
  fi 
fi

# 确保可执行存在
command -v polycli >/dev/null 2>&1 || { echo "未找到 polycli"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "未找到 jq"; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "未找到 awk"; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "未找到 envsubst"; exit 1; }
command -v cast >/dev/null 2>&1 || { echo "未找到 cast"; exit 1; }

# 提权为 root
if [ "$EUID" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

# 至少需要一个参数
if [ $# -lt 1 ]; then
  echo "错误: 请提供网络名称参数"
  echo "用法: $0 <network_name>"
  echo "示例: $0 cdk-eth"
  exit 1
fi

NETWORK=${1#cdk-}            # 移除 "cdk-" 前缀
NETWORK=${NETWORK//-/_} # 将 "-" 替换为 "_"

if [ "$NEED_DEPLOY_CDK" == "true" ]; then
  if kurtosis enclave ls | grep -q "$1"; then
    kurtosis enclave rm -f $1
    echo "删除旧的 enclave $1"
  fi
fi

# 检查环境变量
if [ -z "$L2_CHAIN_ID" ]; then
  echo "错误: 请设置 L2_CHAIN_ID 环境变量"
  exit 1
fi

if [ -z "$L1_CHAIN_ID" ] || [ -z "$L1_RPC_URL" ] || [ -z "$L1_PREALLOCATED_MNEMONIC" ]; then
  echo "错误: 请设置 L1_CHAIN_ID 和 L1_RPC_URL 和 L1_PREALLOCATED_MNEMONIC 环境变量"
  exit 1
fi

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f $SCRIPT_DIR/params.template.yml ]; then
  echo "错误: params.template.yml 文件不存在"
  exit 1
fi
mkdir -p $SCRIPT_DIR/../output

# 创建临时配置文件
TEMPLATE_FILE="$SCRIPT_DIR/params.template.yml"
TEMP_CONFIG="$SCRIPT_DIR/params_$NETWORK.yml"
LOG_FILE="$SCRIPT_DIR/deploy-$NETWORK.log"
UPDATE_NGINX_SCRIPT="$SCRIPT_DIR/../update-nginx/update_nginx_ports.sh"
DEPLOY_RESULT_FILE="$SCRIPT_DIR/../output/deploy-result-$NETWORK.json"

export L2_CONFIG=$(polycli wallet inspect --mnemonic "$L1_PREALLOCATED_MNEMONIC" --addresses 13 | jq -r '.Addresses[1:][] | [.ETHAddress, .HexPrivateKey] | @tsv' | awk 'BEGIN{split("sequencer,aggregator,claimtxmanager,timelock,admin,loadtest,agglayer,dac,proofsigner,l1testing,claimsponsor,l1_panoptichain",roles,",")} {print "  # " roles[NR] "\n  zkevm_l2_" roles[NR] "_address: \"" $1 "\""; print "  zkevm_l2_" roles[NR] "_private_key: \"0x" $2 "\"\n"}')
[ -n "${L2_CONFIG:-}" ] || { echo "L2_CONFIG 为空"; exit 1; }

export L2_ADMIN_PRIVATE_KEY=$(cast wallet private-key --mnemonic "$L1_PREALLOCATED_MNEMONIC" --mnemonic-index 5)
export L2_ADMIN_ADDRESS=$(cast wallet address --private-key "$L2_ADMIN_PRIVATE_KEY")

export DEPLOY_PARAMETERS_SALT=0x$(openssl rand -hex 32)
[ -n "${DEPLOY_PARAMETERS_SALT:-}" ] || { echo "DEPLOY_PARAMETERS_SALT 为空"; exit 1; }

# 运行 kurtosis
if [ "$DRYRUN" == "true" ]; then
  echo "[dry-run] envsubst <params.template.yml >$TEMP_CONFIG"
  echo "[dry-run] kurtosis run --cli-log-level debug -v EXECUTABLE --enclave $1 --args-file $TEMP_CONFIG github.com/Pana/kurtosis-cdk@aa5f6f39dd8fa6157abe5736d81a2c9eda1536fc 2>&1 >$LOG_FILE"
  echo "[dry-run] set nginx for $1"
  echo "[dry-run] exported contracts to: $DEPLOY_RESULT_FILE"
  echo "{ \"zkevm_l2_admin_private_key\": \"0x0000000000000000000000000000000000000000000000000000000000000000\", \"zkevm_l2_admin_address\": \"0x0000000000000000000000000000000000000000\", \"polygonZkEVMBridgeAddress\": \"0x0000000000000000000000000000000000000000\", \"polygonZkEVML2BridgeAddress\": \"0x0000000000000000000000000000000000000000\"}" > $DEPLOY_RESULT_FILE
else
  # kurtosis run --cli-log-level debug -v EXECUTABLE --enclave op-eth github.com/wangdayong228/optimism-package@8d97b22f5bce73106fea4d3cc063486cca359928 --args-file "$TEMP_CONFIG" 2>&1 > "$LOG_FILE"
  if [ "$NEED_DEPLOY_CDK" == "true" ]; then
    envsubst <$TEMPLATE_FILE >$TEMP_CONFIG
    echo "generated params file: $TEMP_CONFIG"
    kurtosis run --cli-log-level debug -v EXECUTABLE --enclave $1 --args-file $TEMP_CONFIG github.com/Pana/kurtosis-cdk@aa5f6f39dd8fa6157abe5736d81a2c9eda1536fc 2>&1 >$LOG_FILE

    # 设置 nginx
    bash "$UPDATE_NGINX_SCRIPT" $1
    echo "set nginx for $1"
    # 导出合约地址
    kurtosis service exec "$1" contracts-1 "jq '{polygonZkEVMBridgeAddress, polygonZkEVML2BridgeAddress}' /opt/zkevm/combined.json" >"$DEPLOY_RESULT_FILE"
    echo "exported contracts to: $DEPLOY_RESULT_FILE"
    # 导出 l2_admin_private_key
    jq --arg k "$L2_ADMIN_PRIVATE_KEY" --arg a "$L2_ADMIN_ADDRESS" '. + {zkevm_l2_admin_private_key: $k, zkevm_l2_admin_address: $a}' "$DEPLOY_RESULT_FILE" > "$DEPLOY_RESULT_FILE.tmp"
    mv $DEPLOY_RESULT_FILE.tmp $DEPLOY_RESULT_FILE
    echo "deployed kurtosis enclave: $1"
  else
    echo "skip deployment kurtosis enclave: $1"
  fi

fi

# 给一直发交易的地址转账
# cast send --legacy --rpc-url $zkc_l2_rpc --private-key $zkc_l2_pk --value 1000ether 0x8943545177806ED17B9F23F0a21ee5948eCaa776