#!/bin/bash
set -xeuo pipefail
trap 'echo "命令失败: 行 $LINENO"; exit 1' ERR

# 确保可执行存在
command -v polycli >/dev/null 2>&1 || { echo "未找到 polycli"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "未找到 jq"; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "未找到 awk"; exit 1; }

# # 转换参数格式
# network_name=${1#cdk-}          # 移除 "cdk-" 前缀
# network_name=${network_name//-/_}  # 将 "-" 替换为 "_"

# if kurtosis enclave ls | grep -q "$1"; then
#     kurtosis enclave rm -f $1
# fi

# sh ./update-salt.sh
# kurtosis run --cli-log-level debug -v EXECUTABLE --enclave $1 --args-file ./params_$network_name.yml ../../kurtosis-cdk 2>&1 > ./deploy-$1.log

# echo "Remenber send eth to 0x8943545177806ED17B9F23F0a21ee5948eCaa776 on zkc_l2_rpc"
# # 给一直发交易的地址转账
# cast send --legacy --rpc-url $zkc_l2_rpc --private-key $zkc_l2_pk --value 1000ether 0x8943545177806ED17B9F23F0a21ee5948eCaa776

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

if kurtosis enclave ls | grep -q "$1"; then
  kurtosis enclave rm -f $1
  echo "删除旧的 enclave $1"
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

if [ ! -f params.template.yml ]; then
  echo "错误: params.template.yml 文件不存在"
  exit 1
fi

# sleep 5

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 创建临时配置文件
TEMP_CONFIG="$SCRIPT_DIR/params_$NETWORK.yml"
LOG_FILE="$SCRIPT_DIR/deploy-$NETWORK.log"
UPDATE_NGINX_SCRIPT="$SCRIPT_DIR/../update-nginx/update_nginx_ports.sh"
CONTRACTS_FILE="$SCRIPT_DIR/output/contracts-$NETWORK.json"

export L2_CONFIG=$(polycli wallet create --addresses 12 | jq -r '.Addresses[] | [.ETHAddress, .HexPrivateKey] | @tsv' | awk 'BEGIN{split("sequencer,aggregator,claimtxmanager,timelock,admin,loadtest,agglayer,dac,proofsigner,l1testing,claimsponsor,l1_panoptichain",roles,",")} {print "  # " roles[NR] "\n  zkevm_l2_" roles[NR] "_address: \"" $1 "\""; print "  zkevm_l2_" roles[NR] "_private_key: \"0x" $2 "\"\n"}')
[ -n "${L2_CONFIG:-}" ] || { echo "L2_CONFIG 为空"; exit 1; }
export DEPLOY_PARAMETERS_SALT=0x$(openssl rand -hex 32)
[ -n "${DEPLOY_PARAMETERS_SALT:-}" ] || { echo "DEPLOY_PARAMETERS_SALT 为空"; exit 1; }


# 替换模板中的环境变量
# sed "s/{{PRIVATE_KEY}}/$PRIVATE_KEY/g ; s/{{L2_CHAIN_ID}}/$L2_CHAIN_ID/g ; s/{{DEPLOY_PARAMETERS_SALT}}/$DEPLOY_PARAMETERS_SALT/g" params.template.yml > "$TEMP_CONFIG"
# echo $L2_CONFIG >> $TEMP_CONFIG

envsubst <params.template.yml >$TEMP_CONFIG

echo "generated $TEMP_CONFIG"

# 运行 kurtosis
# kurtosis run --cli-log-level debug -v EXECUTABLE --enclave op-eth github.com/wangdayong228/optimism-package@8d97b22f5bce73106fea4d3cc063486cca359928 --args-file "$TEMP_CONFIG" 2>&1 > "$LOG_FILE"
kurtosis run --cli-log-level debug -v EXECUTABLE --enclave $1 --args-file $TEMP_CONFIG github.com/Pana/kurtosis-cdk@aa5f6f39dd8fa6157abe5736d81a2c9eda1536fc 2>&1 >$LOG_FILE

# 设置 nginx
bash "$UPDATE_NGINX_SCRIPT" $1

# 导出合约地址
kurtosis service exec $1 contracts-1 "cat /opt/zkevm/combined.json |jq {polygonZkEVMBridgeAddress:.polygonZkEVMBridgeAddress, polygonZkEVML2BridgeAddress:.polygonZkEVML2BridgeAddress}" >$CONTRACTS_FILE

# 给一直发交易的地址转账
# cast send --legacy --rpc-url $zkc_l2_rpc --private-key $zkc_l2_pk --value 1000ether 0x8943545177806ED17B9F23F0a21ee5948eCaa776