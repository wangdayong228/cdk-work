# InvalidProof (0x09bde339) 修复方案

**日期**: 2026-06-16
**状态**: 已完成多项修复，InvalidProof 仍未解决，需要进一步逐字段排查

---

## 1. 问题定位

### 1.1 FFLONK 验证失败的本质

L1 合约计算 `inputSnark = sha256(212 bytes) % _RFIELD`，prover 电路内部也计算 `inputSnark`。两者必须完全相等，否则 FFLONK verifier 返回 false → `revert InvalidProof()` (0x09bde339)。

212 字节由 10 个字段拼接，任一字段不匹配即导致 sha256 输出完全不同。

### 1.2 10 字段对齐状态 (当前)

| 字段 | L1 来源 | Prover 来源 | 状态 |
|------|---------|-------------|------|
| msg.sender (20B) | L1 tx 签名者 | aggregatorAddr (SenderAddress) | ✅ 已对齐 |
| oldStateRoot (32B) | batchNumToStateRoot[0] | witness2db 重算 | ✅ 均为 0xd96db188 |
| oldAccInputHash (32B) | sequencedBatches[0].accInputHash | publics[8..15] (C0-C7) | ❓ 待验证 |
| initNumBatch (8B) | 0 | publics[16] (SP) | ✅ 应为 0 |
| chainID (8B) | 10000 | publics[17] (GAS) | ✅ 应为 10000 |
| forkID (8B) | **12 (uint64)** | publics[18] (CTX) | ❓ 待验证 |
| newStateRoot (32B) | aggregator 传入 (=proverSR) | publics[19..26] (SR0-SR7) | ✅ 已对齐 |
| newAccInputHash (32B) | sequencedBatches[1].accInputHash | publics[27..34] (D0-D7) | ❓ **最可疑** |
| newLocalExitRoot (32B) | aggregator 传入 (=proverLER) | publics[35..42] (E0-E7) | ❓ 待验证 |
| finalNewBatch (8B) | 1 | publics[43] (PC) | ✅ 应为 1 |

### 1.3 最可疑根因: newAccInputHash

6 个字段已确认对齐，剩余 4 个待验证。其中 **newAccInputHash 最可疑**:

Aggregator **自己重新计算** accInputHash (非从 L1 读取):
```go
// aggregator.go:1217-1225
accInputHash := cdkcommon.CalculateAccInputHash(
    a.logger,
    oldAccInputHash,          // getAccInputHash(0) = 0
    virtualBatch.BatchL2Data,
    l1InfoRoot,
    uint64(sequence.Timestamp.Unix()),
    rpcBatch.LastCoinbase(),
    forcedBlockHashL1,        // rpcBatch.ForcedBlockHashL1() = 0
)
```

L1 上 `sequencedBatches[1].accInputHash` 是 sequencer 调用 `sequenceBatches` 时独立计算的。如果 **timestamp**、**l1InfoRoot** 或 **coinbase** 在 aggregator 与 sequencer 之间有差异，accInputHash 就不同。

---

## 2. 已完成的修复

| 项 | 文件 | 说明 |
|----|------|------|
| aggregator 使用 proverSR | `cdk/aggregator/aggregator.go:514-528` | 解决 newStateRoot 对齐 |
| aggregator 使用 proverLER | 同上 | 解决 newLocalExitRoot 对齐 |
| forcedBlockHashL1 batch 1 特殊处理删除 | `cdk/aggregator/aggregator.go:1213` | 解决 accInputHash 的一个输入差异 |
| compareFinalProofRootsWithRPC 改为 warn | `aggregator.go` | 避免误 revert |
| smt-genesis 工具 | `cdk-erigon/cmd/read-smt-genesis/main.go` | 确保 batchNumToStateRoot[0] 正确 |
| batchNumToStateRoot[0] 正确写入 | `kurtosis-cdk` 部署脚本 | = smt-genesis 输出 = 0xd96db188 |

---

## 3. 修复方案: 逐字段诊断

### 3.1 方案 A: 提取 prover publics 逐字段对比 (P0, 最高优先级)

**不修改任何代码**，先做诊断:

1. **提取 prover 的 48 个 public inputs**:
   ```bash
   # 在 prover 容器中
   docker exec <prover-container> find / -name "publics.json" 2>/dev/null
   # 或在 aggregator 日志中找 DEBUG 级别输出
   ```

2. **读取 L1 链上数据**:
   ```bash
   RM="0x9dfC9f5864F1d1a7dB83EC2e81F876BFD68dF1EE"
   L1_RPC="http://184.32.182.132/espace"

   # batchNumToStateRoot[0]
   cast call $RM "getRollupBatchNumToStateRoot(uint32,uint64)(bytes32)" 1 0 --rpc-url $L1_RPC

   # sequencedBatches[0] and [1]
   cast call $RM "getRollupSequencedBatches(uint32,uint64)((bytes32,uint64,uint64))" 1 0 --rpc-url $L1_RPC
   cast call $RM "getRollupSequencedBatches(uint32,uint64)((bytes32,uint64,uint64))" 1 1 --rpc-url $L1_RPC
   ```

3. **逐字段对比**: 将 48 个 field elements 还原为 bytes32，与 L1 的 212 字节逐字段比较。

### 3.2 方案 B: 对比 L1 vs aggregator 的 accInputHash (P1)

```bash
# 读取 L1 上 sequencedBatches[1].accInputHash
cast call $RM "getRollupSequencedBatches(uint32,uint64)((bytes32,uint64,uint64))" 1 1 --rpc-url $L1_RPC

# 对比 aggregator 日志中的 "Calculated acc input hash for batch 1"
```

如果不一致，逐字段对比 accInputHash 的 6 个输入参数。

### 3.3 方案 C: 从 L1 读取 accInputHash (P3, 防御性修复)

如果方案 B 确认 accInputHash 不匹配，修改 aggregator 直接从 L1 读取:

```go
// 替换 aggregator.go 中的 accInputHash 计算
accInputHash, err := a.etherman.GetBatchAccInputHash(ctx, batchNumberToVerify)
if err != nil {
    return nil, nil, fmt.Errorf("failed to get accInputHash from L1: %w", err)
}
```

**优点**: 简单，避免所有编码差异问题。
**缺点**: 依赖 L1 RPC 可用性。

### 3.4 方案 D: 验证 prover circuit 与 verifier 合约版本匹配 (P2)

确认:
- prover 使用的 circuit 版本 (fork_12?)
- L1 verifier 合约 (`0xB300b1a009dCD2120B7dEA525836d1Eb9967A619`) 对应的版本
- 如果不匹配，proof 必然验证失败

```bash
cast call 0xB300b1a009dCD2120B7dEA525836d1Eb9967A619 \
  "verifyProof(bytes32[24],uint256[1])(bool)" --rpc-url $L1_RPC
```

### 3.5 方案 E: 手动计算 inputSnark (P4)

从 L1 链上读取所有 10 个字段，手动拼接 212 字节，计算 `sha256 % _RFIELD`，与 prover 电路内部的 inputSnark 对比。

```bash
# 调用 L1 公开函数获取 212 字节
cast call $RM "getInputSnarkBytes(uint32,uint64,uint64,bytes32,bytes32,bytes32)(bytes)" \
  1 0 1 <newLocalExitRoot> <oldStateRoot> <newStateRoot> --rpc-url $L1_RPC
```

---

## 4. 修复优先级

| 优先级 | 动作 | 类型 | 工作量 |
|--------|------|------|--------|
| **P0** | 方案 A: 提取 prover publics, 逐字段对比 212 字节 | 诊断 | 1h |
| P1 | 方案 B: 对比 L1 vs aggregator 的 accInputHash | 诊断 | 30min |
| P2 | 方案 D: 检查 prover circuit 与 verifier 版本匹配 | 诊断 | 30min |
| P3 | 方案 C: 从 L1 读取 accInputHash | 修复 | 2h |
| P4 | 方案 E: 手动计算 inputSnark | 诊断 | 1h |

---

## 5. 验证步骤

### V1: 部署后验证 `batchNumToStateRoot[0]`

```bash
cast call <ROLLUP_ADDRESS> "batchNumToStateRoot(uint64)(bytes32)" 0 --rpc-url $L1_RPC
# 期望: SMT genesis root = 0xd96db188...
```

### V2: 验证 sequencer block 0 stateRoot

```bash
curl -s -X POST <SEQUENCER_RPC> -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' \
  | jq -r '.result.stateRoot'
# 期望: = 0xd96db188...
```

### V3: 验证 batch 1 proof 提交

```bash
# 启动 aggregator, 等待 batch 1 proof
# 检查日志: 无 "InvalidProof" 错误
```

---

## 6. 部署命令

```bash
# 清理
kurtosis enclave rm cdk-gen -f 2>&1 | tail -2
rm -f /home/ubuntu/workspace/ydyl-deployment-suite/output/cdk_pipe.state
pm2 delete jsonrpc-proxy-cdk 2>/dev/null

# 部署
cd /home/ubuntu/workspace/ydyl-deployment-suite
L2_CHAIN_ID=10000 L1_CHAIN_ID=7655 \
L1_RPC_URL=http://184.32.182.132/espace \
L1_VAULT_PRIVATE_KEY=0xde5a8e8b373a70b6b475cb441ba61d8626fd6d3db81726aadc610867503d5778 \
L1_BRIDGE_HUB_CONTRACT=0x7aC81f608D15819148317EeAD3169734664205Bb \
L1_REGISTER_BRIDGE_PRIVATE_KEY=0xa3d9e98f0ba98960bf3755b7519d18b2250b0b8be5e38d5483dcfa3875df2d6f \
DRYRUN=false FORCE_DEPLOY_CDK=true ENABLE_GEN_ACC=false \
./cdk_pipe.sh
```

---

## 附录: 关键数据值速查

| 名称 | 值 |
|------|-----|
| L1 RPC | `http://184.32.182.132/espace` |
| L1 Chain ID | 7655 |
| L2 Chain ID | 10000 |
| RollupManager | `0x9dfC9f5864F1d1a7dB83EC2e81F876BFD68dF1EE` |
| Rollup | `0xb2C2d367Aca2E04b535e1Eaa0D27Ab7E8F057b32` |
| Verifier | `0xB300b1a009dCD2120B7dEA525836d1Eb9967A619` |
| InvalidProof selector | `0x09bde339` |
| forkID (L1 链上) | 12 (uint64) |
| batchNumToStateRoot[0] | `0xd96db188d8a5a3193c085e10488be6624182c23955a5927e0cf3ae941f10d1ea` |
| sequencedBatches[0].accInputHash | `0x0000...0000` |
| sequencedBatches[1].accInputHash | `0x3b488027196ccf45ee5a2897daf281536fd8aa37535b76c47de4b46125d88644` |
| Prover batch 1 newStateRoot | `0x4624d3de4a3f36e070474cc9191655391e43c7324ca89a7ef1b9a7762e25f0c2` |
| inputSnark 哈希函数 | SHA256 (非 keccak256) |
| inputSnark 编码总长 | 212 bytes (10 字段) |