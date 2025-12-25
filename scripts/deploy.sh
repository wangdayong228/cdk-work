#!/bin/bash
set -xeuo pipefail
trap 'echo "🔴 deploy.sh 执行失败: 行 $LINENO, 错误信息: $BASH_COMMAND"; exit 1' ERR

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRYRUN=${DRYRUN:-false}
FORCE_DEPLOY_CDK=${FORCE_DEPLOY_CDK:-false}
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"


if [ ! -f "$SCRIPT_DIR"/params.template.yml ]; then
  echo "错误: params.template.yml 文件不存在"
  exit 1
fi

resolve_scripts_lib_dir() {
  YDYL_SCRIPTS_LIB_DIR="${YDYL_SCRIPTS_LIB_DIR:-$REPO_ROOT/ydyl-scripts-lib}"
  if [ ! -f "$YDYL_SCRIPTS_LIB_DIR/utils.sh" ]; then
    echo "错误: 未找到 ydyl-scripts-lib/utils.sh"
    echo "请设置 YDYL_SCRIPTS_LIB_DIR 指向脚本库目录，例如: export YDYL_SCRIPTS_LIB_DIR=\"$REPO_ROOT/ydyl-scripts-lib\""
    exit 1
  fi
  if [ ! -f "$YDYL_SCRIPTS_LIB_DIR/deploy_common.sh" ]; then
    echo "错误: 未找到 ydyl-scripts-lib/deploy_common.sh"
    echo "请设置 YDYL_SCRIPTS_LIB_DIR 指向脚本库目录，例如: export YDYL_SCRIPTS_LIB_DIR=\"$REPO_ROOT/ydyl-scripts-lib\""
    exit 1
  fi
}

load_utils() {
  # shellcheck source=/dev/null
  source "$YDYL_SCRIPTS_LIB_DIR/utils.sh"
}

require_tools() {
  require_command polycli
  require_command jq
  require_command awk
  require_command envsubst
  require_command cast
  require_command openssl
}

parse_args() {
  if [ $# -lt 1 ]; then
    echo "错误: 请提供网络名称参数"
    echo "用法: $0 <network_name>"
    echo "示例: $0 cdk-eth"
    exit 1
  fi

  ENCLAVE_NAME="$1"
  if [[ "$ENCLAVE_NAME" != cdk-* ]]; then
    echo "错误: enclave 名称必须以 cdk- 开头，例如 cdk-eth / cdk-cfx-dev / cdk-cfx-test"
    exit 1
  fi

  # 统一使用 "-" 风格的 network（用于文件名与公共库推导 enclave）
  NETWORK="${ENCLAVE_NAME#cdk-}"
}

require_env() {
  if [ -z "${L2_CHAIN_ID:-}" ]; then
    echo "错误: 请设置 L2_CHAIN_ID 环境变量"
    exit 1
  fi
  if [ -z "${L1_CHAIN_ID:-}" ] || [ -z "${L1_RPC_URL:-}" ] || [ -z "${KURTOSIS_L1_PREALLOCATED_MNEMONIC:-}" ]; then
    echo "错误: 请设置 L1_CHAIN_ID 和 L1_RPC_URL 和 KURTOSIS_L1_PREALLOCATED_MNEMONIC 环境变量"
    exit 1
  fi
}

prepare_paths() {
  mkdir -p "$SCRIPT_DIR/../output"

  TEMPLATE_FILE="$SCRIPT_DIR/params.template.yml"
  TEMP_CONFIG="$SCRIPT_DIR/params-${NETWORK}.yml"
  LOG_FILE="$SCRIPT_DIR/deploy-${NETWORK}.log"
  UPDATE_NGINX_SCRIPT="$SCRIPT_DIR/../update-nginx/update_nginx_ports.sh"
  DEPLOY_RESULT_FILE="$SCRIPT_DIR/../output/deploy-result-${NETWORK}.json"
}

prepare_cdk_env() {
  L2_CONFIG=$(polycli wallet inspect --mnemonic "$KURTOSIS_L1_PREALLOCATED_MNEMONIC" --addresses 13 | jq -r '.Addresses[1:][] | [.ETHAddress, .HexPrivateKey] | @tsv' | awk 'BEGIN{split("sequencer,aggregator,claimtxmanager,timelock,admin,loadtest,agglayer,dac,proofsigner,l1testing,claimsponsor,l1_panoptichain",roles,",")} {print "  # " roles[NR] "\n  zkevm_l2_" roles[NR] "_address: \"" $1 "\""; print "  zkevm_l2_" roles[NR] "_private_key: \"0x" $2 "\"\n"}')
  export L2_CONFIG
  [ -n "${L2_CONFIG:-}" ] || { echo "L2_CONFIG 为空"; exit 1; }

  L2_ADMIN_PRIVATE_KEY=$(cast wallet private-key --mnemonic "$KURTOSIS_L1_PREALLOCATED_MNEMONIC" --mnemonic-index 5)
  export L2_ADMIN_PRIVATE_KEY
  L2_ADMIN_ADDRESS=$(cast wallet address --private-key "$L2_ADMIN_PRIVATE_KEY")
  export L2_ADMIN_ADDRESS

  DEPLOY_PARAMETERS_SALT=0x$(openssl rand -hex 32)
  export DEPLOY_PARAMETERS_SALT
  [ -n "${DEPLOY_PARAMETERS_SALT:-}" ] || { echo "DEPLOY_PARAMETERS_SALT 为空"; exit 1; }
}

run_deploy() {
  export DEPLOY_L2_TYPE="cdk"
  export DEPLOY_NETWORK="$NETWORK"
  export DEPLOY_TEMPLATE_FILE="$TEMPLATE_FILE"
  export DEPLOY_RENDERED_ARGS_FILE="$TEMP_CONFIG"
  export DEPLOY_LOG_FILE="$LOG_FILE"
  export DEPLOY_PACKAGE_LOCATOR="github.com/Pana/kurtosis-cdk@aa5f6f39dd8fa6157abe5736d81a2c9eda1536fc"
  export DEPLOY_UPDATE_NGINX_SCRIPT="$UPDATE_NGINX_SCRIPT"
  export DEPLOY_DRYRUN="$DRYRUN"
  export DEPLOY_FORCE="$FORCE_DEPLOY_CDK"

  # shellcheck source=/dev/null
  source "$YDYL_SCRIPTS_LIB_DIR/deploy_common.sh"
  ydyl_kurtosis_deploy
}

export_results() {
  if [ "$DRYRUN" == "true" ]; then
    echo "[dry-run] exported contracts to: $DEPLOY_RESULT_FILE"
    echo "{ \"zkevm_l2_admin_private_key\": \"0x0000000000000000000000000000000000000000000000000000000000000000\", \"zkevm_l2_admin_address\": \"0x0000000000000000000000000000000000000000\", \"polygonZkEVMBridgeAddress\": \"0x0000000000000000000000000000000000000000\", \"polygonZkEVML2BridgeAddress\": \"0x0000000000000000000000000000000000000000\"}" > "$DEPLOY_RESULT_FILE"
    return 0
  fi

  if [ "${YDYL_DEPLOY_STATUS:-skipped}" == "ran" ]; then
    kurtosis service exec "$ENCLAVE_NAME" contracts-1 "jq '{polygonZkEVMBridgeAddress, polygonZkEVML2BridgeAddress}' /opt/zkevm/combined.json" >"$DEPLOY_RESULT_FILE"
    echo "exported contracts to: $DEPLOY_RESULT_FILE"
    jq --arg k "$L2_ADMIN_PRIVATE_KEY" --arg a "$L2_ADMIN_ADDRESS" '. + {zkevm_l2_admin_private_key: $k, zkevm_l2_admin_address: $a}' "$DEPLOY_RESULT_FILE" > "$DEPLOY_RESULT_FILE.tmp"
    mv "$DEPLOY_RESULT_FILE.tmp" "$DEPLOY_RESULT_FILE"
    echo "deployed kurtosis enclave: $ENCLAVE_NAME"
  else
    echo "skip export contracts because deployment was skipped: $ENCLAVE_NAME"
  fi
}

main() {
  resolve_scripts_lib_dir
  load_utils
  require_tools
  parse_args "$@"
  require_env
  prepare_paths
  prepare_cdk_env
  run_deploy
  export_results
}

main "$@"



# 给一直发交易的地址转账
# cast send --legacy --rpc-url $zkc_l2_rpc --private-key $zkc_l2_pk --value 1000ether 0x8943545177806ED17B9F23F0a21ee5948eCaa776