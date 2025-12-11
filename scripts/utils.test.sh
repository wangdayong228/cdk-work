#!/bin/bash
set -euo pipefail

# 引入 utils.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTILS_PATH="$SCRIPT_DIR/utils.sh"
if [ ! -f "$UTILS_PATH" ]; then
  echo "找不到 utils.sh 文件"
  exit 1
fi
source "$UTILS_PATH"

# 用于模拟会失败的命令
fail_count=0
max_fail=3

fake_cmd() {
  if [ $fail_count -lt $max_fail ]; then
    ((fail_count++))
    echo "模拟失败 ($fail_count/$max_fail)"
    return 1
  else
    echo "模拟成功 ($fail_count/$max_fail)"
    return 0
  fi
}

echo "===== 测试 run_with_retry 成功情况 ====="
fail_count=0
if run_with_retry 5 1 fake_cmd; then
  echo "✅ 测试通过: 成功重试后命令执行通过"
else
  echo "❌ 测试失败: 命令应该成功但最终执行失败"
  exit 1
fi

echo "===== 测试 run_with_retry 达到最大重试次数仍然失败 ====="
fail_count=0
max_fail=10
if run_with_retry 5 1 fake_cmd; then
  echo "❌ 测试失败: 命令应该失败但返回成功"
  exit 1
else
  echo "✅ 测试通过: 重试超限后命令失败"
fi

echo "全部 run_with_retry 测试用例通过"

