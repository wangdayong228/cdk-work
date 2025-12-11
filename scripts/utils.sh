run_with_retry() {
  local max_retries="$1"
  local delay_seconds="$2"
  shift 2

  local attempt=1
  while (( attempt <= max_retries )); do
    echo "尝试第 ${attempt}/${max_retries} 次执行: $*"
    "$@"
    local code=$?

    if [[ $code -eq 0 ]]; then
      echo "命令执行成功"
      return 0
    fi

    if (( attempt == max_retries )); then
      echo "命令连续 ${max_retries} 次失败 (最后一次退出码=${code})，放弃重试"
      return "$code"
    fi

    echo "命令执行失败 (退出码=${code})，${delay_seconds} 秒后重试..."
    sleep "$delay_seconds"
    ((attempt++))
  done
}