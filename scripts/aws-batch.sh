#!/bin/bash
set -euo pipefail
set -x

# 参数检查
if [ $# -lt 1 ]; then
    echo "用法: $0 <数量> <远程命令>"
    exit 1
fi

COUNT=$1
shift
REMOTE_CMD="$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"; mkdir -p "$LOG_DIR"

# 配置（需要修改成你自己的参数）
AMI_ID="ami-0d5d4434d0110b7e1"        # 你要用的 AMI
INSTANCE_TYPE="c6a.xlarge"           # 实例类型
KEY_NAME="dayong-op-stack"                  # 已存在的 key pair
SECURITY_GROUP="sg-02452e70d9fe7e235" # 安全组
TAG="dy-op"
RUN_DURATION=50 # 运行时长，单位为分钟

# L1 配置
L1_CHAIN_ID=71
L1_RPC_URL="https://cfx-testnet-cdk-rpc-proxy.yidaiyilu0.site"

if [ ! -f $SCRIPT_DIR/l1-preallocated-mnemonics.sh ]; then
    echo "错误: l1-preallocated-mnemonics.sh 文件不存在"
    exit 1
fi
# 导入准备好的助记词文件
source $SCRIPT_DIR/l1-preallocated-mnemonics.sh

# 数组长度必须大于等于 COUNT
if [ ${#L1_PREALLOCATED_MNEMONICS[@]} -lt $COUNT ]; then
    echo "错误: L1_PREALLOCATED_MNEMONICS 数组长度必须大于等于 COUNT"
    exit 1
fi

echo "👉 正在启动 $COUNT 台 EC2 实例..."
INSTANCE_IDS=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count $COUNT \
    --instance-type $INSTANCE_TYPE \
    --instance-initiated-shutdown-behavior terminate \
    --key-name $KEY_NAME \
    --security-group-ids $SECURITY_GROUP \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG}]" \
    --query "Instances[*].InstanceId" \
    --output text)

# 逐台实例追加/覆盖 Name 标签为 TAG-0...TAG-(COUNT-1)
i=1
for id in $INSTANCE_IDS; do
  aws ec2 create-tags --resources "$id" \
    --tags "Key=Name,Value=${TAG}-${i}"
  i=$((i+1))
done

echo "实例ID: $INSTANCE_IDS"

echo "👉 等待实例进入 running 状态..."
# 等待实例 running 后，再等状态检查 2/2 通过
aws ec2 wait instance-running --instance-ids $INSTANCE_IDS
# aws ec2 wait instance-status-ok --instance-ids $INSTANCE_IDS

# ==================== 辅助函数 begin====================
# SSH 就绪探测函数（最多重试 ~3 分钟）
wait_ssh() {
  local ip="$1"
  for _ in {1..60}; do
    ssh -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes \
        -o BatchMode=yes -o ConnectTimeout=3 \
        -i "$HOME/.ssh/${KEY_NAME}.pem" ubuntu@"$ip" 'true' >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

# 把整数转为 64 位十六进制，前缀 0x
mk_pk() { printf "0x%064x" "$1"; }   # 把整数转为 64 位十六进制，前缀 0x
# ==================== 辅助函数 end====================

echo "👉 获取实例公网 IP..."
IPS=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_IDS \
    --query "Reservations[*].Instances[*].PublicIpAddress" \
    --output text)

echo "实例IP: $IPS"

# 执行前先确保每台主机可 SSH
for ip in $IPS; do
  echo "[$ip] 等待 SSH 就绪..."
  wait_ssh "$ip" || { echo "[$ip] SSH 一直未就绪"; exit 1; }
done

echo "👉 批量执行命令"

i=1 # 从 1 开始，因为 0x0000000000000000000000000000000000000000000000000000000000000000 是无效的私钥
pids=()
for ip in $IPS; do
  # 计算期望的标签，并在执行前设置到实例上
  name="${TAG}-${i}"
  inst_id=$(aws ec2 describe-instances --filters "Name=ip-address,Values=$ip" --query "Reservations[].Instances[].InstanceId" --output text)
  if [ -n "$inst_id" ]; then
    aws ec2 create-tags --resources "$inst_id" --tags "Key=Name,Value=${name}"
  fi
  {
    if [ -z "${REMOTE_CMD:-}" ]; then
        local l2_chain_id=$((i+10000))
        local l1_preallocated_mnemonic=${L1_PREALLOCATED_MNEMONICS[$i]}
        cmd="cd /home/ubuntu/cdk-work/scripts && L2_CHAIN_ID=$l2_chain_id L1_CHAIN_ID=$L1_CHAIN_ID L1_RPC_URL=$L1_RPC_URL L1_PREALLOCATED_MNEMONIC=$l1_preallocated_mnemonic ./deploy.sh cdk-gen"
    else
        cmd="$REMOTE_CMD"
    fi

    cmd="sudo -n shutdown -h +${RUN_DURATION} && $cmd"

    echo "[$ip] run: $cmd"
    # ssh -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i "$HOME/.ssh/${KEY_NAME}.pem" ubuntu@"$ip" "sudo -n shutdown -h +${RUN_DURATION}" \
    #   2>&1 | sed "s/^/[$ip][shutdown] /"
    ssh -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i "$HOME/.ssh/${KEY_NAME}.pem" ubuntu@"$ip" "$cmd" \
      2>&1 | sed "s/^/[$ip][cmd] /"
  } | tee -a "$LOG_DIR/${ip}-${name}.log" &
  pids+=($!)     # 注意：放在 & 之后
  i=$((i+1))
done

failed=0
for pid in "${pids[@]}"; do
  wait "$pid" || failed=1
done
[ $failed -eq 0 ] || { echo "有实例执行失败"; exit 1; }

echo "✅ 全部执行完成！"
