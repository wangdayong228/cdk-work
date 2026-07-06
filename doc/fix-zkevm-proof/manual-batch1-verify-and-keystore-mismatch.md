# Batch 1 手动验证成功与自动提交失败根因

日期：2026-06-18

## 关键结论

Batch 1 的 proof 本身是**有效**的。使用正确的发送地址手动提交后，L1 合约成功验证 batch 1。

```
lastVerifiedBatch = 1  (rollupIDToRollupData)
```

之前 aggregator 自动提交失败的根本原因不是 proof 数据错误，而是 **cdk-node 配置中的签名 keystore 与 `SenderProofToL1Addr` 不匹配**：

- `SenderProofToL1Addr = 0x63c1eb6738EaAC638Fe5e3ff64796C53ADaf58fa`（agglayer 地址）
- `AggregatorPrivateKeyPath = /etc/cdk/aggregator.keystore`（里面存放的是 aggregator 地址 `0x2E108a36803f0507c3Da58851321a4E2429C3700` 的私钥）

结果 aggregator 用 aggregator 地址的私钥签名交易，但 L1 合约检查的是 `msg.sender` 是否有 `TRUSTED_AGGREGATOR_ROLE`。`0x2E10...` 没有该 role，只有 `0x63c1...` 有，所以 `trustedVerifyBatchesToConsensus` 在 `_verifyAndRewardBatches` 之前（或之中）就 revert，表现为 `failed to estimate gas: execution reverted: revert: (0x09bde339)`。

## 证据

### 1. 手动提交成功

交易哈希：`0xb2523635cb119a3eea47de494a2fda3b728472fe5c930e71612a0d52b25bec17`

```bash
PK_AGG=0x74262e55fe39342452c2326cbbed451e0c82111253e75ae7b955a9126f6be35f
TARGET=0xDF9b97b40b90B7fdd2a2EDC5dd7ec7b107C763F5
DATA=0x1489ed10...  # 与 aggregator 日志中生成的 calldata 完全一致
cast mktx $TARGET $DATA --private-key $PK_AGG --rpc-url $RPC --nonce $NONCE --gas-limit 10000000 --legacy
cast publish <rawtx> --rpc-url $RPC
```

返回 `status: 0x1`，无 `txExecErrorMsg`。

### 2. 错误地址提交失败

用 `/etc/cdk/aggregator.keystore` 解出的私钥（对应 `0x2E10...`）签名并发布同一 calldata，交易 `status: 0x0`，`txExecErrorMsg: Vm reverted`。证明 calldata 本身无问题，问题是发送地址无 role。

### 3. Role 检查

```bash
cast call 0xDF9b97b40b90B7fdd2a2EDC5dd7ec7b107C763F5 \
  "hasRole(bytes32,address)(bool)" \
  0x084e94f375e9d647f87f5b2ceffba1e062c70f6009fdbcf80291e803b5c9edd4 \
  0x63c1eb6738EaAC638Fe5e3ff64796C53ADaf58fa
# => true

cast call ... 0x2E108a36803f0507c3Da58851321a4E2429C3700
# => false
```

## 配置与代码定位

- `kurtosis-cdk/templates/trusted-node/cdk-node-config.toml` 第 27-29 行：
  ```toml
  AggregatorPrivateKeyPath = "{{or .zkevm_l2_aggregator_keystore_file "/etc/cdk/aggregator.keystore"}}"
  AggregatorPrivateKeyPassword  = "{{.zkevm_l2_keystore_password}}"
  SenderProofToL1Addr = "{{.zkevm_l2_agglayer_address}}"
  ```
- `kurtosis-cdk/lib/cdk_node.star` 第 20-30 行：挂载到 cdk-node 容器的 keystore 只有 `aggregator`、`sequencer`、`claim_sponsor`，没有 `agglayer`。
- `kurtosis-cdk/cdk_central_environment.star` 第 147-179 行：`get_keystores_artifacts` 只返回了 `sequencer/aggregator/proofsigner/dac/claim_sponsor`，没有 `agglayer`。
- `kurtosis-cdk/templates/contract-deploy/create-keystores.sh` 第 25 行：已经正确生成了 `agglayer.keystore`。

## 修复方案

让 cdk-node 容器能访问 `agglayer.keystore`，并把 `AggregatorPrivateKeyPath` 指向它。这样 `SenderProofToL1Addr` 与签名私钥匹配，自动提交即可成功。

具体修改：

1. `kurtosis-cdk/cdk_central_environment.star`
   - `get_keystores_artifacts()` 中增加 `agglayer_keystore_artifact`，读取 `/opt/zkevm/agglayer.keystore`。
   - 返回的 struct 增加 `agglayer` 字段。

2. `kurtosis-cdk/lib/cdk_node.star`
   - `create_cdk_node_service_config()` 中 `/etc/cdk` 目录挂载增加 `keystore_artifact.agglayer`。

3. `kurtosis-cdk/templates/trusted-node/cdk-node-config.toml`
   - `AggregatorPrivateKeyPath = "/etc/cdk/agglayer.keystore"`（与 `SenderProofToL1Addr` 的 agglayer 地址匹配）。
   - 保持 `SenderProofToL1Addr = "{{.zkevm_l2_agglayer_address}}"` 不变。

## 验证计划

1. 修改上述三处代码。
2. 删除现有 enclave，使用 `cdk-work/doc/lauch-guide-for-debug-zkevm-issue.md` 中的命令重新部署。
3. 部署完成后检查 `/etc/cdk/cdk-node-config.toml` 中 `AggregatorPrivateKeyPath` 是否为 `/etc/cdk/agglayer.keystore`。
4. 等待 batch 1 proof 生成，观察 aggregator 日志，确认不再出现 `0x09bde339` 且 `lastVerifiedBatch` 自动递增。
5. 继续使用 compare-invalidproof.py 检查后续 batch 的 proof 数据一致性，确认 UnwindZkSMT 连续性。
