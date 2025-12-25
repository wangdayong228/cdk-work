#!/bin/bash
set -xeuo pipefail
trap 'echo "🔴 deploy.sh 执行失败: 行 $LINENO, 错误信息: $BASH_COMMAND"; exit 1' ERR

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRYRUN=${DRYRUN:-false}
FORCE_DEPLOY_CDK=${FORCE_DEPLOY_CDK:-false}
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

resolve_scripts_lib_dir() {
  YDYL_SCRIPTS_LIB_DIR="${YDYL_SCRIPTS_LIB_DIR:-$REPO_ROOT/ydyl-scripts-lib}"
  if [ ! -f "$YDYL_SCRIPTS_LIB_DIR/utils.sh" ] || [ ! -f "$YDYL_SCRIPTS_LIB_DIR/deploy_common.sh" ]; then
    echo "错误: 未找到 ydyl-scripts-lib/utils.sh 或 ydyl-scripts-lib/deploy_common.sh"
    echo "请设置 YDYL_SCRIPTS_LIB_DIR 指向脚本库目录，例如: export YDYL_SCRIPTS_LIB_DIR=\"$REPO_ROOT/ydyl-scripts-lib\""
    exit 1
  fi
}

parse_args() {
  if [ $# -lt 1 ]; then
    echo "错误: 请提供网络名称参数"
    echo "用法: $0 cdk-<network_name>"
    echo "示例: $0 cdk-eth"
    exit 1
  fi
  ydyl_parse_enclave_and_network cdk "$1" || exit 1
}

require_env() {
  if [ -z "${L2_CHAIN_ID:-}" ] || [ -z "${L1_CHAIN_ID:-}" ] || [ -z "${L1_RPC_URL:-}" ] || [ -z "${KURTOSIS_L1_PREALLOCATED_MNEMONIC:-}" ]; then
    echo "错误: 请设置 L2_CHAIN_ID/L1_CHAIN_ID/L1_RPC_URL/KURTOSIS_L1_PREALLOCATED_MNEMONIC 环境变量"
    exit 1
  fi
}

prepare_paths() {
  ydyl_prepare_deploy_paths \
    "$SCRIPT_DIR" \
    "$NETWORK" \
    "$SCRIPT_DIR/../output" \
    "$SCRIPT_DIR/../update-nginx/update_nginx_ports.sh" || exit 1
}

prepare_cdk_env() {
  L2_CONFIG=$(polycli wallet inspect --mnemonic "$KURTOSIS_L1_PREALLOCATED_MNEMONIC" --addresses 13 | jq -r '.Addresses[1:][] | [.ETHAddress, .HexPrivateKey] | @tsv' | awk 'BEGIN{split("sequencer,aggregator,claimtxmanager,timelock,admin,loadtest,agglayer,dac,proofsigner,l1testing,claimsponsor,l1_panoptichain",roles,",")} {print "  # " roles[NR] "\n  zkevm_l2_" roles[NR] "_address: \"" $1 "\""; print "  zkevm_l2_" roles[NR] "_private_key: \"0x" $2 "\"\n"}')
  export L2_CONFIG

  L2_ADMIN_PRIVATE_KEY=$(cast wallet private-key --mnemonic "$KURTOSIS_L1_PREALLOCATED_MNEMONIC" --mnemonic-index 5)
  export L2_ADMIN_PRIVATE_KEY

  L2_ADMIN_ADDRESS=$(cast wallet address --private-key "$L2_ADMIN_PRIVATE_KEY")
  export L2_ADMIN_ADDRESS

  DEPLOY_PARAMETERS_SALT=0x$(openssl rand -hex 32)
  export DEPLOY_PARAMETERS_SALT
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
  # shellcheck source=../../ydyl-scripts-lib/deploy_common.sh
  source "$YDYL_SCRIPTS_LIB_DIR/deploy_common.sh"
  require_commands polycli jq awk envsubst cast openssl
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