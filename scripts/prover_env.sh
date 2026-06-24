#!/bin/bash

resolve_cdk_prover_env() {
  USE_REAL_PROVER="${USE_REAL_PROVER:-true}"

  case "$USE_REAL_PROVER" in
    true)
      USE_MOCK_PROVER="false"
      ;;
    false)
      USE_MOCK_PROVER="true"
      ;;
    *)
      echo "错误: USE_REAL_PROVER 只能设置为 true 或 false，当前值: $USE_REAL_PROVER" >&2
      return 1
      ;;
  esac

  export USE_REAL_PROVER USE_MOCK_PROVER
}
