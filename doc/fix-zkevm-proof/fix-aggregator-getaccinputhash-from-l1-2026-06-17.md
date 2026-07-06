# Aggregator 从 L1 读取 accInputHash 改动原因与未完成项分析

**日期**: 2026-06-17
**状态**: 修改已写入 `cdk/aggregator/aggregator.go` 但未重新编译部署，本地 enclave 仍是改动前的镜像

---

## 1. 为什么改这里

### 1.1 原始症状

aggregator 多次调用 `verifyBatches` 都失败，错误 selector 为 `0x09bde339` (InvalidProof)。在 `prover` 真实生成证明并被 L1 合约接收后，最终依然在 FFLONK 验证步骤 revert。

### 1.2 之前定位到的可疑字段

[fix-plan-invalidProof.md](./fix-plan-invalidProof.md) 和 [fix-invalidProof-research.md](./fix-invalidProof-research.md) 都已经梳理过 212 字节 inputSnark 的 10 个字段。已确认对齐的字段有 6 个，未确认的有 4 个：

| L1 字段 | L1 来源 | Prover 来源 | 状态 |
|---|---|---|---|
| msg.sender | L1 tx 签名者 | aggregatorAddr | ✅ |
| oldStateRoot | batchNumToStateRoot[0] | witness2db 重算 | ✅ (0xd96db188) |
| initNumBatch | 0 | publics[16] | ✅ |
| chainID | 10000 | publics[17] | ✅ |
| newStateRoot | aggregator 传入 (=proverSR) | publics[19..26] | ✅ |
| finalNewBatch | 1 | publics[43] | ✅ |
| oldAccInputHash | sequencedBatches[0].accInputHash | publics[8..15] | ❓ |
| forkID | 12 (uint64) | publics[18] | ❓ |
| newAccInputHash | sequencedBatches[1].accInputHash | publics[27..34] | ❌ **最可疑** |
| newLocalExitRoot | aggregator 传入 (=proverLER) | publics[35..42] | ❓ |

**最可疑的字段是 `newAccInputHash`**，因为它由 aggregator 用 6 个输入参数**自己重新计算**，任何一个参数与 L1 sequencer 端不一致都会导致整个 sha256 输入哈希不同，进而 FFLONK 验证失败。

### 1.3 改动前的 aggregator 行为

```go
// 旧代码 (改动前, cdk/aggregator/aggregator.go:1217-1225)
forcedBlockHashL1 := rpcBatch.ForcedBlockHashL1()
l1Block, err := a.l1Syncr.GetL1BlockByNumber(ctx, virtualBatch.BlockNumber)  // 仅 batch 1
forcedBlockHashL1 = l1Block.ParentHash                                       // 仅 batch 1

accInputHash := cdkcommon.CalculateAccInputHash(
    a.logger,
    oldAccInputHash,
    virtualBatch.BatchL2Data,
    l1InfoRoot,
    uint64(sequence.Timestamp.Unix()),
    rpcBatch.LastCoinbase(),
    forcedBlockHashL1,
)
```

**核心风险**: aggregator 用本地拿到的 `sequence.Timestamp` / `virtualBatch.L1InfoRoot` / `rpcBatch.LastCoinbase()` 重新计算 accInputHash，而 L1 上 `sequencedBatches[n].accInputHash` 是 sequencer 调用 `sequenceBatches` 时**独立**计算的。两者只要在 6 个参数上有任何细微差异（典型：batch 1 时的 `forcedBlockHashL1`、sequencer 与 aggregator 看到的 timestamp 毫秒级误差、coinbase 大小写等），accInputHash 就不同。

### 1.4 改动方案 (方案 C, 防御性修复)

**根本思路**: 不再依赖本地 re-calculate，而是直接从 L1 合约读 sequencer 已经写入 `sequencedBatches[n].accInputHash` 的值。这从源头保证 aggregator 提交给 prover 的 `newAccInputHash` 与 L1 合约用于 `inputSnark` 计算的值**完全一致**。

**新代码** (改动后, `cdk/aggregator/aggregator.go:1213-1222`):
```go
// Read accInputHash directly from L1 to ensure it matches the value
// computed by the L1 sequenceBatches function, avoiding any encoding
// or parameter mismatch between aggregator and sequencer.
accInputHash, err := a.etherman.GetBatchAccInputHash(ctx, batchNumberToVerify)
if err != nil {
    return nil, nil, fmt.Errorf("failed to get accInputHash from L1 for batch %d: %w", batchNumberToVerify, err)
}
a.setAccInputHash(batchNumberToVerify, accInputHash)
```

`etherman.GetBatchAccInputHash` (`cdk/etherman/aggregator.go:69-80`) 直接 `eth_call` RollupManager 的 `getRollupSequencedBatches(rollupID, batchNumber)`，从返回值里取 `accInputHash`。**这是 L1 链上的权威值**。

### 1.5 改动的优点

| 优点 | 说明 |
|---|---|
| 100% 消除 accInputHash 字段不匹配 | aggregator 用 L1 写入的值，跟 L1 后续 `inputSnark` 计算用的是同一份数据 |
| 不依赖 L1 sequencer / RPC 的内部编码 | aggregator 不再假设 `CalculateAccInputHash` 的 6 个参数顺序/编码与 L1 合约 `sequenceBatches` 内的 keccak256 输入完全一致 |
| 代码更简单 | 删除了 forcedBlockHashL1 的 batch 1 特殊处理 |
| 与 `getVerifiedBatchAccInputHash` 行为一致 | 启动时初始化 `accInputHashes[lastVerifiedBatchNumber]` 用的是同一条路径 |

### 1.6 改动的副作用 / 已知问题

1. **依赖 L1 RPC 可用性**: 如果 L1 RPC 暂时不可用，aggregator 会卡住等 L1 同步。但这本来也是 aggregator 的正常路径（virtualBatch / sequence 都来自 L1），不引入新的依赖。
2. **不解决 L1 链上 sequencedBatches 数据本身的错误**: 如果 sequencer 当时写入 L1 的 accInputHash 本身就是错的（比如 sequenceBatches 函数内部有 bug），aggregator 拿到的就是错的值。这需要在后续 batch 的 sequencer 行为分析中确认。
3. **getVerifiedBatchAccInputHash 同样是从 L1 读**: 启动时 `accInputHashes[lastVerifiedBatchNumber]` 的初始化也是从 L1 读，所以新代码与启动逻辑完全一致。

---

## 2. 为什么单独改这一处可能不够 (来自 fix-plan 的反思)

`fix-plan-invalidProof.md` 给出 5 个诊断/修复方案 (A~E)。本次改的是 **方案 C**。但即便 C 修复了 `newAccInputHash` 字段不匹配，**仍可能存在**其他字段不匹配：

### 2.1 方案 A: 提取 prover publics 逐字段对比 (P0, 仍未做)

**目的**: 把 prover 写出的 48 个 Goldilocks field elements 还原为 8 个 bytes32，逐一与 L1 / aggregator 的预期值对比。

**为什么这次没改**:
- prover 是外部机器 (47.85.169.235)，不在本仓库。我们只能从 aggregator 日志或 `cdk/aggregator/aggregator.go:1361` 周围找 DEBUG 输出。
- aggregator 现在的 debug 日志 (1.4 节那段) 已经打印了 `OldAccInputHash` / `L1InfoRoot` / `TimestampLimit` / `LastCoinbase` / `ForcedBlockHashL1`，但不打印 **prover 实际返回的** `stateRoot` 和 `accInputHash`。

**需要补的改动**:
- 在 `tryGenerateBatchProof` 内把 prover 生成的 `proof.publicInputsExtended.{stateRoot, accInputHash}` 写到 log 里
- 同时在 `proveDirect` / `settleDirect` 之前打印 `newStateRoot` / `newLocalExitRoot` / `newAccInputHash` 用于提交的最终值

### 2.2 方案 D: 检查 prover circuit 与 verifier 合约版本匹配 (P2, 未做)

**目的**: 确认 `hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12` 生成的 proof 能否被 L1 verifier `0xB300b1a009dCD2120B7dEA525836d1Eb9967A619` 验证。

**为什么这次没改**:
- 这需要 L1 verifier 合约源代码与 prover circuit 常数对照表，超出单次改动的范围
- 通常通过 `cast call verifier verifyProof(...)` 用一个**已知正确的 proof** 来 smoke test，但本环境没有

**需要补的改动**:
- 临时对 `_verifyAndRewardBatches` 加一层 debug log：把 L1 算出的 `inputSnark = sha256(...) % _RFIELD` 打印出来
- 与 prover 内部 commit 阶段（如果有）写入文件的 `publics.json` 的 `last 8 field elements` 拼接 sha256 后比较
- 这需要在 L1 合约里加一个 view 函数返回 inputSnark，或者复现它的计算

### 2.3 方案 E: 手动计算 inputSnark (P4, 未做)

**目的**: 用 L1 链上数据自己手动拼 212 字节并算 `sha256 % _RFIELD`，看它跟 L1 revert 时的 inputSnark 是否一致。

**为什么这次没改**:
- 可以在 L1 合约 `getInputSnarkBytes` (如果存在) 或自己用 cast+python 完成
- 但要等 batch 1 提交后才有完整 L1 状态可查

**需要补的改动**:
- 本地写一个 `compute_input_snark.py`，从 L1 读取 10 个字段，调用 sha256 并 mod BN254 field prime
- 与 L1 revert 时的 inputSnark 对比

### 2.4 总结: 还需要做的事

| 优先级 | 任务 | 状态 |
|---|---|---|
| **P0** | 编译并重新部署 cdk-node-1 (本仓库 aggregator 镜像) | ⏳ 本次执行 |
| **P0** | 等待 batch 1 再次提交，观察 `0x09bde339` 是否消失 | ⏳ 部署后 |
| **P0** | 重新部署后再次调用 L1 RPC 验证 sequencedBatches[1].accInputHash 字段确实变化 | ⏳ 部署后 |
| **P1** | 实施方案 A: 在 aggregator 端打印 prover 的 stateRoot / accInputHash | 待办 |
| **P1** | 实施方案 D: 检查 verifier 合约版本与 prover circuit 匹配 | 待办 |
| **P2** | 实施方案 E: 手动计算 inputSnark 与 L1 比较 | 待办 |

---

## 3. 编译部署与执行计划

### 3.1 编译 cdk-node 镜像

`cdk-node-1` 的镜像 tag 是 `davidyoung2025/cdk:local` ([lauch-guide-for-debug-zkevm-issue.md L77-80](../cdk-work/doc/lauch-guide-for-debug-zkevm-issue.md))。本机只改了一个 `.go` 文件，没有改 `Dockerfile`，所以重新编译 cdk 即可。

```bash
cd /home/ubuntu/workspace/ydyl-deployment-suite/cdk
make build-docker
# 镜像名: davidyoung2025/cdk:local
```

### 3.2 重新部署 kurtosis enclave

```bash
kurtosis enclave rm cdk-gen -f 2>&1 | tail -2
rm -f /home/ubuntu/workspace/ydyl-deployment-suite/output/cdk_pipe.state
pm2 delete jsonrpc-proxy-cdk 2>/dev/null

cd /home/ubuntu/workspace/ydyl-deployment-suite
L2_CHAIN_ID=10000 L1_CHAIN_ID=7655 \
L1_RPC_URL=http://184.32.182.132/espace \
L1_VAULT_PRIVATE_KEY=0xde5a8e8b373a70b6b475cb441ba61d8626fd6d3db81726aadc610867503d5778 \
L1_BRIDGE_HUB_CONTRACT=0x7aC81f608D15819148317EeAD3169734664205Bb \
L1_REGISTER_BRIDGE_PRIVATE_KEY=0xa3d9e98f0ba98960bf3755b7519d18b2250b0b8be5e38d5483dcfa3875df2d6f \
DRYRUN=false FORCE_DEPLOY_CDK=true ENABLE_GEN_ACC=false \
./cdk_pipe.sh
```

### 3.3 重新部署后做的事

1. 等待 `cdk-node-1` 起来，端口 `33002`(RPC) / `33001`(REST) / `33000`(aggregator gRPC)
2. 等待 sequencer 跑出 batch 1 并 sequenceBatches 到 L1
3. 等待 aggregator 给 prover 发 GenBatchProof
4. 等待 prover 外部机器生成 proof
5. 等待 aggregator 提交 verifyBatches，看是否还 `0x09bde339`

如果仍然 `0x09bde339`:
- 实施方案 A (打印 prover stateRoot/accInputHash)
- 实施方案 D (verifier 版本检查)
- 实施方案 E (手动算 inputSnark)

### 3.4 同时可推进的旁线

- 调研 UnwindZkSMT 聚合连续性 (用户原话: "修复 SMT 根问题并确保 batch 1 被 L1 验证通过后，再调研")
- 验证 L1 上 `getInputSnarkBytes` / `_verifyAndRewardBatches` 是否有 view 接口供我们复现 inputSnark

---

## 4. 风险与回滚

- **风险 1**: L1 RPC 暂时不可用导致 aggregator 卡住 → 启动时已经初始化过 `accInputHashes[lastVerifiedBatchNumber]`，首次读 `batchNumberToVerify=1` 时如果 RPC 不通会 `fmt.Errorf` 包裹返回错误并触发重试，不会破坏状态
- **风险 2**: aggregator 镜像编译失败 → 回滚到 `git stash` 恢复原代码
- **风险 3**: 修改后 batch 1 仍然验证失败 → 新代码不引入新风险，因为新值来自 L1 (权威值)，最坏情况是 sequencer 写入的 accInputHash 本身就是错的，但那是 sequencer 的问题，与本次改动正交

---

## 5. 一致性检查

- [fix-plan-invalidProof.md](./fix-plan-invalidProof.md) 第 3.3 节明确给出了从 L1 读取 accInputHash 的修复方案，与本次改动一致
- [fix-invalidProof-research.md](./fix-invalidProof-research.md) 第 7.4 节明确指出 accInputHash 是最可疑字段
- aggregator 启动时初始化 `accInputHashes[lastVerifiedBatchNumber]` 用的是同一个 `getVerifiedBatchAccInputHash → GetBatchAccInputHash` 路径，所以本次改动与启动逻辑无冲突
- 测试 `cdk/aggregator/aggregator_test.go:97, 167` 已经为 `GetBatchAccInputHash` 写了 mock，可以 `go test ./cdk/aggregator/...` 验证基本编译/逻辑

---

## 6. AI Agent 后续修复 (2026-06-17)

### 6.1 发现 buildInputProver 中仍存在的 batch 1 特殊处理

用户修改了 `tryGetBatchToVerify` (L1213-1221) 中的 accInputHash 改为从 L1 读取，这确保了 `stateBatch.AccInputHash` 与 L1 一致。

但 **另一处关键代码** `buildInputProver` (原 L1541-1558) 中，batch 1 的特殊处理仍然存在，导致发送给 prover 的输入参数错误：

```go
// 原代码 (buildInputProver 函数内, else 分支)
if batchToVerify.BatchNumber == 1 {
    virtualBatch, err := a.l1Syncr.GetVirtualBatchByBatchNumber(ctx, batchToVerify.BatchNumber)
    l1Block, err := a.l1Syncr.GetL1BlockByNumber(ctx, virtualBatch.BlockNumber)
    forcedBlockhashL1 = l1Block.ParentHash    // ← 错误! L1 的 sequenceBatches 对非 forced batch 用 bytes32(0)
    l1InfoRoot = batchToVerify.GlobalExitRoot.Bytes()  // ← 可能不匹配 L1 实际使用的 l1InfoRoot
}
```

**问题**:
- `forcedBlockhashL1` 被设为 `l1Block.ParentHash` (非零值)，但 L1 `sequenceBatches` 对非 forced batch 使用 `bytes32(0)`
- `l1InfoRoot` 被覆盖为 `GlobalExitRoot`，可能不匹配 L1 sequencer 实际使用的 l1InfoRoot
- 这些错误值被发送给 prover 作为 `StatelessInputProver.PublicInputs.ForcedBlockhashL1` 和 `.L1InfoRoot`
- prover 电路用这些值计算内部的 `newAccInputHash`
- 结果: prover 的 `newAccInputHash` ≠ L1 的 `sequencedBatches[1].accInputHash` → inputSnark 不匹配 → InvalidProof

### 6.2 修复内容

**修改 1**: 删除 `buildInputProver` (cdk/aggregator/aggregator.go:1541-1558) 中 batch 1 的 forcedBlockhashL1 和 l1InfoRoot 覆盖。

修复后:
- `forcedBlockhashL1` 保持默认值 `common.Hash{}` (bytes32(0)) — 与 L1 `sequenceBatches` 对非 forced batch 的行为一致
- `l1InfoRoot` 保持 `batchToVerify.L1InfoRoot.Bytes()` (来自 virtualBatch.L1InfoRoot) — 这是 sequencer 在 L1 上 sequence 时实际使用的值

**修改 2**: 在 `sendFinalProof` (cdk/aggregator/aggregator.go:529) 中添加 debug 日志，打印提交给 L1 的关键值:
- newStateRoot, newLocalExitRoot, sender
- batchNum, lastVerifiedBatch

### 6.3 编译验证

`go build ./aggregator/...` 编译通过，无错误。

### 6.4 需要用户执行的操作

1. **重新编译 Docker 镜像**:
   ```bash
   cd /home/ubuntu/workspace/ydyl-deployment-suite/cdk
   make build-docker
   ```

2. **重新部署**:
   ```bash
   kurtosis enclave rm cdk-gen -f 2>&1 | tail -2
   rm -f /home/ubuntu/workspace/ydyl-deployment-suite/output/cdk_pipe.state
   pm2 delete jsonrpc-proxy-cdk 2>/dev/null
   cd /home/ubuntu/workspace/ydyl-deployment-suite
   L2_CHAIN_ID=10000 L1_CHAIN_ID=7655 \
   L1_RPC_URL=http://184.32.182.132/espace \
   L1_VAULT_PRIVATE_KEY=0xde5a8e8b373a70b6b475cb441ba61d8626fd6d3db81726aadc610867503d5778 \
   L1_BRIDGE_HUB_CONTRACT=0x7aC81f608D15819148317EeAD3169734664205Bb \
   L1_REGISTER_BRIDGE_PRIVATE_KEY=0xa3d9e98f0ba98960bf3755b7519d18b2250b0b8be5e38d5483dcfa3875df2d6f \
   DRYRUN=false FORCE_DEPLOY_CDK=true ENABLE_GEN_ACC=false \
   ./cdk_pipe.sh
   ```

3. **观察日志**:
   - 等待 aggregator 提交 batch 1 proof
   - 检查是否还有 `0x09bde339` (InvalidProof) 错误
   - 检查新添加的 debug 日志: "L1 submission values: newStateRoot=..."

4. **如果仍然失败**:
   - 从日志中提取 L1 submission values (newStateRoot, newLocalExitRoot)
   - 用 `cast call` 读取 L1 上 sequencedBatches[1].accInputHash
   - 对比 prover publics 与 L1 212 字节逐字段

### 6.5 本次修复的理论依据

修复前后对比:

| 字段 | 修复前 (发给 prover) | 修复后 (发给 prover) | L1 实际使用 |
|------|---------------------|---------------------|-------------|
| forcedBlockhashL1 | `l1Block.ParentHash` (非零) | `bytes32(0)` | `bytes32(0)` |
| l1InfoRoot | `GlobalExitRoot` | `virtualBatch.L1InfoRoot` | `l1InfoRoot` from sequenceBatches |
| accInputHash (stateBatch) | L1 读取 ✅ | L1 读取 ✅ | sequencedBatches[1].accInputHash |

修复后，prover 收到的 `forcedBlockhashL1` 和 `l1InfoRoot` 与 L1 sequencer 在 `sequenceBatches` 中使用的一致，prover 电路内部计算的 `newAccInputHash` 应该与 L1 `sequencedBatches[1].accInputHash` 匹配。

### 6.6 仍待验证 (如果本次修复不解决)

| 优先级 | 任务 | 状态 |
|--------|------|------|
| P0 | 等待部署后观察 InvalidProof 是否消失 | ⏳ 待执行 |
| P1 | 提取 prover publics 逐字段对比 212 字节 | 待办 |
| P2 | 检查 prover circuit 与 verifier 合约版本匹配 | 待办 |
| P3 | 手动计算 inputSnark 与 L1 比较 | 待办 |
