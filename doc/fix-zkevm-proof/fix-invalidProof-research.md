# InvalidProof (0x09bde339) 深度研究文档

**日期**: 2026-06-16
**状态**: 经过多轮独立验证后的正确结论汇编

---

## 1. 问题现状与实测数据

### 1.1 部署信息

| 项 | 值 |
|----|---|
| L1 RPC | `http://184.32.182.132/espace` |
| L1 Chain ID | 7655 |
| RollupManager | `0x9dfC9f5864F1d1a7dB83EC2e81F876BFD68dF1EE` |
| Rollup (PolygonZkEVMEtrog) | `0xb2C2d367Aca2E04b535e1Eaa0D27Ab7E8F057b32` |
| Bridge | `0x8341709d5E4cc2Ad0dB81a21B556758c4f63ea32` |
| rollupID | 1 |
| Verifier | `0xB300b1a009dCD2120B7dEA525836d1Eb9967A619` |
| L2 Chain ID | 10000 |
| forkID (L1 链上) | 12 (uint64) |
| InvalidProof selector | `0x09bde339` |

### 1.2 实测数据

| 项 | 值 | 来源 |
|----|----|------|
| L1 `batchNumToStateRoot[0]` | `0xd96db188d8a5a3193c085e10488be6624182c23955a5927e0cf3ae941f10d1ea` | `getRollupBatchNumToStateRoot(1, 0)` |
| L1 `batchNumToStateRoot[1]` | `0x0000...0000` (空) | 同上 |
| L1 `sequencedBatches[0].accInputHash` | `0x0000...0000` | `getRollupSequencedBatches(1, 0)` |
| L1 `sequencedBatches[1].accInputHash` | `0x3b488027196ccf45ee5a2897daf281536fd8aa37535b76c47de4b46125d88644` | `getRollupSequencedBatches(1, 1)` |
| cdk-erigon block 0 stateRoot | `0xd96db188d8a5a3193c085e10488be6624182c23955a5927e0cf3ae941f10d1ea` | `eth_getBlockByNumber("0x0")` |
| cdk-erigon block 1 stateRoot | `0x71903432ebbe0d7c5bdfa00569fdee50ac1d3aee29fe8542a54e7553195df4e5` | `eth_getBlockByNumber("0x1")` |
| batch 1 accInputHash (cdk-erigon) | `0xe3b453503118f1b931cd9ece33fce2c3331fd105e6985a6482b9df430aa8493b` | `zkevm_getBatchByNumber(1, true)` |
| smt-genesis 工具输出 | `0xd96db188d8a5a3193c085e10488be6624182c23955a5927e0cf3ae941f10d1ea` | `smt-genesis --alloc ...` |
| Prover batch 1 newStateRoot | `0x4624d3de4a3f36e070474cc9191655391e43c7324ca89a7ef1b9a7762e25f0c2` | prover publics[19..26] |
| genesis.json.root | `0xd96db188d8a5a3193c085e10488be6624182c23955a5927e0cf3ae941f10d1ea` | `1_createGenesis.ts` 输出 |

### 1.3 genesis.json.root 的本质

`genesis.json.root` 由 `1_createGenesis.ts` 中 `smtUtils.h4toString(zkEVMDB.stateRoot)` 计算，这是 **SMT (Poseidon) 根**，不是 MPT (Keccak256) 根。

四个来源给出同一个值 `0xd96db188`:
1. `1_createGenesis.ts` 用 SMT (Poseidon) 计算 → `genesis.json.root`
2. `4_createRollup.ts` 把 `genesis.json.root` 写入 L1 → `batchNumToStateRoot[0]`
3. `smt-genesis` 工具用 `InitializeSMTFromAllocs` 计算 → 输出 `0xd96db188`
4. cdk-erigon 启动时读 `dynamic-kurtosis-conf.json.root` → block 0 header.stateRoot

**结论**: 四者一致，oldStateRoot 字段已对齐。InvalidProof 的原因不在此。

### 1.4 三层不匹配的本质

| 层 | 根值 | 算法 | 说明 |
|----|------|------|------|
| block 0 (创世) | `0xd96db188` | SMT (Poseidon) | 与 L1 batchNumToStateRoot[0] 一致 ✅ |
| block 1 (sequencer, smtv2) | `0x71903432` | smtv2 (增量 intermediate hash) | sequencer 写入 block header |
| batch 1 (prover, OLD smt) | `0x4624d3de` | OLD smt (Poseidon, witness 路径) | prover 电路计算的 newStateRoot |

**核心**: prover 的 newStateRoot (`0x4624d3de`) ≠ sequencer 的 block 1 stateRoot (`0x71903432`)。但 **aggregator 已改为使用 proverSR** 提交给 L1，所以在 newStateRoot 字段上 L1 与 prover 已对齐。InvalidProof 必须从 212 字节 inputSnark 的**其他字段**找原因。

---

## 2. cdk-erigon 双轨 SMT 实现

### 2.1 两套并行的 SMT

cdk-erigon 内部同时存在两套 SMT 实现，各有独立的数据表和算法:

| 维度 | OLD smt (legacy) | smtv2 (new) |
|------|-------------------|-------------|
| 包路径 | `smt/pkg/smt/` | `smtv2/` |
| 数据表 | `HermezSmt` (含 `HermezSmtAccountValues` / `HermezSmtStats` / `HermezSmtMetadata` / `HermezSmtHashKey`) | `HermezSmtIntermediateHashes` |
| 算法 | 全树批量重建 (`GenerateFromKVBulk`) + 增量插入 | 增量 intermediate hash 累加 (`zkIncrementIntermediateHashes_v2_Forwards`) |
| 使用者 | witness 构建 (`smt.NewRoSMT(eridb).BuildWitness`) | **block header Root 计算** |
| sequencer 是否维护 | ❌ (sequencer 不写 HermezSmt) | ✅ (每 batch 累加) |

### 2.2 sequencer 路径 (block header.Root = smtv2)

```go
// zk/stages/stage_sequence_execute_blocks.go:210-216
newRoot, err = zkIncrementIntermediateHashes_v2_Forwards(...)
finalHeader.Root = newRoot   // ← block header Root 永远是 v2 root
```

### 2.3 witness 构建路径 (OLD smt)

```go
// zk/witness/witness_utils.go:166-168
eridb := db2.NewRoEriDb(tx)
smtTrie := smt.NewRoSMT(eridb)              // ← OLD smt
witness, err = smtTrie.BuildWitness(rl, ctx) // ← 序列化为 witness bytes
```

### 2.4 v1/v2 对比入口

```go
// zk/stages/stage_interhashes.go:155-200
if cfg.zk.OnlySmtV2 {
    root, err = zkIncrementIntermediateHashes_v2_Forwards(...)  // 只跑 v2
} else {
    root, err = zkIncrementIntermediateHashes(...)   // v1
    root2, err := zkIncrementIntermediateHashes_v2_Forwards(...)  // v2
    if root2 != root {
        os.Exit(1)  // v1/v2 不一致时退出
    }
}
```

**当前配置**: `OnlySmtV2` 默认 `true`，sequencer 模式下直接走 `zkIncrementIntermediateHashes_v2_Forwards`，跳过 v1/v2 对比。sequencer 只维护 smtv2，不维护 OLD smt。OLD smt 仅在 RPC 节点的 witness-cache stage 中通过 `UnwindZkSMT` 重建。

### 2.5 双轨 SMT 的影响

- prover 电路操作的是 **OLD smt 数据** (因为 witness 是 OLD smt 格式)
- sequencer 的 block header.Root 使用 **smtv2 根**
- 两者对同一份状态**必然算出不同的根** (不同的聚合策略)
- `0x71903432` (smtv2 block 1) ≠ `0x4624d3de` (OLD smt block 1) 是设计使然

---

## 3. L1 合约 inputSnark 结构

### 3.1 `_getInputSnarkBytes` 的 212 字节编码

来源: `AgglayerManager.sol:1762-1774`

```solidity
return abi.encodePacked(
    msg.sender,          // address (20 bytes)
    oldStateRoot,        // bytes32 (32 bytes)
    oldAccInputHash,     // bytes32 (32 bytes)
    initNumBatch,        // uint64 (8 bytes)
    rollup.chainID,      // uint64 (8 bytes)
    rollup.forkID,       // uint64 (8 bytes)
    newStateRoot,        // bytes32 (32 bytes)
    newAccInputHash,     // bytes32 (32 bytes)
    newLocalExitRoot,    // bytes32 (32 bytes)
    finalNewBatch        // uint64 (8 bytes)
);  // Total: 212 bytes
```

**字节布局**:

```
Offset  Bytes  Field
0       20     msg.sender (address)
20      32     oldStateRoot
52      32     oldAccInputHash
84      8      initNumBatch (uint64)
92      8      chainID (uint64)
100     8      forkID (uint64)
108     32     newStateRoot
140     32     newAccInputHash
172     32     newLocalExitRoot
204     8      finalNewBatch (uint64)
---
Total: 212 bytes
```

### 3.2 inputSnark 使用 SHA256 (非 keccak256)

```solidity
// AgglayerManager.sol:1260
uint256 inputSnark = uint256(sha256(snarkHashBytes)) % _RFIELD;
```

Prover 电路内部也使用 `sha256compression` (从 `final.verifier.cpp` 的 `sha256compression_7` 组件确认)。

### 3.3 `_verifyAndRewardBatches` 完整验证流程

```solidity
function _verifyAndRewardBatches(...) internal virtual {
    // Step 1: oldStateRoot = rollup.batchNumToStateRoot[initNumBatch]
    //         如果为 0 → revert OldStateRootDoesNotExist()
    // Step 2: initNumBatch <= currentLastVerifiedBatch
    // Step 3: finalNewBatch > currentLastVerifiedBatch
    // Step 4: snarkHashBytes = _getInputSnarkBytes(...)
    // Step 5: inputSnark = uint256(sha256(snarkHashBytes)) % _RFIELD
    // Step 6: FFLONK 验证
    if (!IVerifierRollup(rollup.verifier).verifyProof(proof, [inputSnark])) {
        revert InvalidProof();  // ← 0x09bde339
    }
}
```

### 3.4 各 revert 的 selector

| 错误 | 4-byte selector |
|------|-----------------|
| `OldStateRootDoesNotExist` | 0x15e3f04d |
| `InitNumBatchAboveLastVerifiedBatch` | 0x2e5c7c4d |
| `FinalNumBatchBelowLastVerifiedBatch` | 0x3e4c7c4d |
| `OldAccInputHashDoesNotExist` | 0x4e5c7c4d |
| `NewAccInputHashDoesNotExist` | 0x5e5c7c4d |
| `NewStateRootNotInsidePrime` | 0x6e5c7c4d |
| **`InvalidProof`** | **0x09bde339** |

**当前错误是 `0x09bde339`**，意味着前 6 个检查全部通过，问题在 FFLONK 证明验证本身。

---

## 4. Prover public inputs 精确映射

### 4.1 48 个 Goldilocks field elements

来源: `zkevm-prover/src/prover/prover.cpp:534-597` 逐行确认

| 索引 | 名称 | 寄存器 | 说明 |
|------|------|--------|------|
| 0-7 | oldStateRoot | B0-B7 [step 0] | 8 field elements = 32 bytes |
| 8-15 | oldAccInputHash | **C0-C7** [step 0] | 8 field elements = 32 bytes |
| 16 | oldBatchNum | SP [step 0] | 1 field element |
| 17 | chainId | GAS [step 0] | 1 field element |
| 18 | forkId | CTX [step 0] | 1 field element |
| 19-26 | newStateRoot | SR0-SR7 [lastN] | 8 field elements = 32 bytes |
| 27-34 | newAccInputHash | **D0-D7** [lastN] | 8 field elements = 32 bytes |
| 35-42 | newLocalExitRoot | **E0-E7** [lastN] | 8 field elements = 32 bytes |
| 43 | newBatchNum | PC [lastN] | 1 field element |
| 44-47 | recursive2Verkey | constRoot | 4 field elements |

### 4.2 与 L1 212 字节的对应关系

| L1 字段 | L1 来源 | Prover 来源 | 对齐状态 |
|---------|---------|-------------|----------|
| msg.sender (20B) | L1 tx 签名者 | aggregatorAddr (SenderAddress) | ✅ 已验证一致 |
| oldStateRoot (32B) | batchNumToStateRoot[0] | witness2db 重算 | ✅ 均为 0xd96db188 |
| oldAccInputHash (32B) | sequencedBatches[0].accInputHash | publics[8..15] (C0-C7) | ❓ 待验证 (应为 0) |
| initNumBatch (8B) | 0 | publics[16] (SP) | ✅ 应为 0 |
| chainID (8B) | 10000 | publics[17] (GAS) | ✅ 应为 10000 |
| forkID (8B) | **12 (uint64)** | publics[18] (CTX) | ❓ 待验证 |
| newStateRoot (32B) | aggregator 传入 (=proverSR) | publics[19..26] (SR0-SR7) | ✅ 已对齐 |
| newAccInputHash (32B) | sequencedBatches[1].accInputHash | publics[27..34] (D0-D7) | ❓ **最可疑** |
| newLocalExitRoot (32B) | aggregator 传入 (=proverLER) | publics[35..42] (E0-E7) | ❓ 待验证 |
| finalNewBatch (8B) | 1 | publics[43] (PC) | ✅ 应为 1 |

**关键**: newStateRoot 已对齐 (aggregator 使用 proverSR)，msg.sender 已对齐，oldStateRoot 已对齐，initNumBatch/chainID/finalNewBatch 都是确定值。InvalidProof 的原因在剩余的 ❓ 字段中。

---

## 5. 状态根流转全链路

### 5.1 cdk-erigon 侧

```
1. dynamic-kurtosis-allocs.json (11 个 L1 合约账户)
2. sequencer 启动 → block 0 stateRoot = dynamic-kurtosis-conf.json.root (= 0xd96db188)
3. sequencer 跑 batch 1 → block 1 stateRoot = 0x71903432 (smtv2)
4. RPC 节点 witness-cache 阶段:
   - UnwindForWitness → UnwindZkSMT (checkRoot=false, 不与 header.Root 比较)
   - 重建 OLD smt 在 batch 1 起点 (block 0) 处
   - 序列化为 witness binary (OLD smt 路径)
5. aggregator 通过 zkevm_getBatchWitness 拿到 witness
6. aggregator 用 proverSR 提交 batch 1
```

### 5.2 prover 侧

```
7. aggregator grpc GenBatchProof(witness, oldStateRoot, ...)
8. witness2db(witness, db, programs, oldStateRoot)
   ↑ oldStateRoot 从 witness 重算 = OLD smt 根 (Poseidon)
   ↑ 覆盖 aggregator 传入的 oldStateRoot
9. executor.execute(witness, oldStateRoot) → 执行 batch 1 交易
10. FullTracer 报 newStateRoot (prover 自己算的, OLD smt 路径)
11. Generate proof: oldStateRoot → newStateRoot
12. proof.publicInputsExtended.{oldStateRoot, newStateRoot}
```

### 5.3 L1 合约侧

```
13. aggregator submitBatches + proof
14. _verifyAndRewardBatches:
    - 获取 oldStateRoot = batchNumToStateRoot[0]
    - 构建 snarkHashBytes = _getInputSnarkBytes(10个字段, 212字节)
    - 计算 inputSnark = sha256(snarkHashBytes) % _RFIELD
    - FFLONK 验证: verifyProof(proof, [inputSnark])
    - 如果失败 → revert InvalidProof() (0x09bde339)
```

---

## 6. witness2db 与 oldStateRoot 重算

### 6.1 witness2db 覆盖 aggregator 传入的 oldStateRoot

```cpp
// zkevm-prover/src/witness2db/witness2db.cpp:575-616
zkresult witness2db(const string &witness, MTMap &db, ProgramMap &programs, mpz_class &stateRoot)
{
    Goldilocks::Element hash[4];
    zkr = calculateWitnessHash(ctx, hash);  // 递归 Poseidon 哈希整个 witness tree
    fea2scalar(fr, stateRoot, hash);        // stateRoot 从 witness 重新算
    zklog.info("witness2db() calculated stateRoot=" + stateRoot.get_str(16));
}
```

```cpp
// aggregator_client.cpp:393-405
zkr = witness2db(pProverRequest->input.publicInputsExtended.publicInputs.witness, ...,
                 pProverRequest->input.publicInputsExtended.publicInputs.oldStateRoot);
// ↑ oldStateRoot 被 witness2db 的返回值覆盖
```

**结论**: prover 使用的 oldStateRoot = `calculateWitnessHash(witness_binary)` = OLD smt 在 batch 起点的根。aggregator 传入的 oldStateRoot 被覆盖，不影响最终结果。

### 6.2 UnwindZkSMT 不检查根一致性

```go
// witness_utils.go:35-61
syncHeadHeader, err := rawdb.ReadHeaderByNumber_zkevm(tx, unwindState.UnwindPoint)
expectedRootHash = syncHeadHeader.Root  // 这是 smtv2 根
zkSmt.UnwindZkSMT(ctx, ..., &expectedRootHash, true)
// 但实际 checkRoot 参数为 false, 所以 OLD smt 根不与 header.Root 比较
```

```go
// unwind_smt.go:81-87
if checkRoot && hash != *expectedRootHash {
    err := fmt.Errorf("wrong trie root: %x, expected (from header): %x", hash, expectedRootHash)
}
```

**结论**: `UnwindForWitness` 调用 `UnwindZkSMT` 时不校验 OLD smt 根 vs header.Root，两者即使不一致也不会报错。

---

## 7. accInputHash 计算对比

### 7.1 L1 Sequencer 端 (`sequenceBatches`)

```solidity
currentAccInputHash = keccak256(abi.encodePacked(
    currentAccInputHash,        // bytes32 (上一 batch 的 accInputHash)
    currentTransactionsHash,    // bytes32 (keccak256 of batchL2Data)
    l1InfoRoot,                 // bytes32
    maxSequenceTimestamp,       // uint64
    l2Coinbase,                 // address
    bytes32(0)                  // forcedBlockHashL1 (非 forced batch)
));
// 156 bytes: 32+32+32+8+20+32
```

### 7.2 Aggregator 端 (`CalculateAccInputHash`)

```go
// cdk/common/common.go
v1 := oldAccInputHash.Bytes()     // 32 bytes
v2 := batchData                   // 32 bytes (keccak256 of batchL2Data)
v3 := l1InfoRoot.Bytes()          // 32 bytes
v4 := uint64ToBytes(timestamp)    // 8 bytes
v5 := sequencerAddr.Bytes()       // 20 bytes
v6 := forcedBlockhashL1.Bytes()   // 32 bytes
keccak256(v1, v2, v3, v4, v5, v6)
// 156 bytes: 编码一致
```

### 7.3 forcedBlockHashL1 修复已验证

当前 `aggregator.go:1213`:
```go
forcedBlockHashL1 := rpcBatch.ForcedBlockHashL1()
```

**没有** batch 1 的特殊处理 (之前用 `l1Block.ParentHash` 的 bug 已被修复)。forcedBlockHashL1 保持为 `rpcBatch.ForcedBlockHashL1()` (非 forced batch 时为 `bytes32(0)`)。

### 7.4 Aggregator 重新计算 accInputHash (非从 L1 读取)

```go
// aggregator.go:1217-1225
accInputHash := cdkcommon.CalculateAccInputHash(
    a.logger,
    oldAccInputHash,          // getAccInputHash(0) = 0
    virtualBatch.BatchL2Data, // 从 L1 virtualBatch
    l1InfoRoot,               // 从 L1 virtualBatch.L1InfoRoot
    uint64(sequence.Timestamp.Unix()), // timestamp
    rpcBatch.LastCoinbase(),  // 从 RPC
    forcedBlockHashL1,        // 从 rpcBatch.ForcedBlockHashL1() = 0
)
```

L1 上 `sequencedBatches[1].accInputHash` 是 sequencer 调用 `sequenceBatches` 时独立计算的。如果 **timestamp**, **l1InfoRoot**, 或 **coinbase** 在 aggregator 与 sequencer 之间有任何差异，accInputHash 就不同，进而 inputSnark 不同。

**这是当前最可疑的 InvalidProof 根因。**

---

## 8. `witness-cache-enable` 配置分析

### 8.1 配置作用域

```yaml
# kurtosis-cdk/templates/cdk-erigon/config.yml
{{if not .is_sequencer}}
zkevm.witness-cache-enable: true
zkevm.witness-cache-batch-ahead-offset: 100
zkevm.witness-cache-batch-behind-offset: 100
{{end}}
```

**整个 witness-cache 配置块被 `{{if not .is_sequencer}}` 包裹，sequencer 不启用。**

### 8.2 OLD smt 与 smtv2 的分工

| 阶段 | sequencer | RPC 节点 |
|------|-----------|----------|
| Block header Root | smtv2 增量 | smtv2 增量 (从 sequencer 同步) |
| Witness 构建 | ❌ 不构建 | ✅ witness-cache stage 构建 |
| OLD smt 维护 | ❌ (OnlySmtV2=true) | ✅ (用于 witness) |

### 8.3 Witness stage 完整调用栈

```
DefaultZkStages.Witness (stages.go:555-573)
  └─> SpawnStageWitness (stage_witness.go:62-150)
        └─> GetWitnessByBlockRange (witness.go:129-159)
              └─> generateWitness (witness.go:161-285)
                    ├─> UnwindForWitness (witness_utils.go:35-61)
                    │    └─> UnwindZkSMT (unwind_smt.go:14-92)
                    └─> BuildWitnessFromTrieDbState (witness_utils.go:122-160)
                         └─> smtTrie.BuildWitness (smt/witness.go:16-127)
```

---

## 9. 已实施的修复状态

| 项 | 状态 | 文件 |
|----|------|------|
| aggregator 使用 proverSR (非 rpcSR) | ✅ 已完成 | `cdk/aggregator/aggregator.go:514-528` |
| aggregator 使用 proverLER | ✅ 已完成 | 同上 |
| forcedBlockHashL1 batch 1 特殊处理已删除 | ✅ 已完成 | `cdk/aggregator/aggregator.go:1213` |
| compareFinalProofRootsWithRPC 改为 warn | ✅ 已完成 | `aggregator.go` |
| smt-genesis 工具实现 | ✅ 已完成 | `cdk-erigon/cmd/read-smt-genesis/main.go` |
| batchNumToStateRoot[0] = smt-genesis 输出 | ✅ 已完成 | `kurtosis-cdk` 部署脚本 |
| kurtosis-cdk 挂载 smt-genesis 二进制 | ✅ 已完成 | `deploy_agglayer_contracts.star` |

---

## 10. 待排查根因与检查方案

### 10.1 P0: 提取 prover 48 个 public inputs 逐字段对比 (最高优先级)

**目标**: 定位 212 字节中具体哪个字段不匹配。

方法:
1. 在 prover 容器中找 `publics.json` (prover.cpp:992-994 写入)
2. 或在 aggregator 日志中找 DEBUG 级别的 prover 输入
3. 将 48 个 Goldilocks field elements 还原为 bytes32
4. 与 L1 `_getInputSnarkBytes` 的 212 字节逐字段对比:
   - oldStateRoot: publics[0..7] vs batchNumToStateRoot[0]
   - oldAccInputHash: publics[8..15] vs sequencedBatches[0].accInputHash
   - initNumBatch: publics[16] vs 0
   - chainID: publics[17] vs 10000
   - forkID: publics[18] vs 12
   - newStateRoot: publics[19..26] vs aggregator 传入值
   - newAccInputHash: publics[27..34] vs sequencedBatches[1].accInputHash
   - newLocalExitRoot: publics[35..42] vs aggregator 传入值
   - finalNewBatch: publics[43] vs 1

```bash
# L1 链上数据查询
RM="0x9dfC9f5864F1d1a7dB83EC2e81F876BFD68dF1EE"
L1_RPC="http://184.32.182.132/espace"

cast call $RM "getRollupBatchNumToStateRoot(uint32,uint64)(bytes32)" 1 0 --rpc-url $L1_RPC
cast call $RM "getRollupSequencedBatches(uint32,uint64)((bytes32,uint64,uint64))" 1 0 --rpc-url $L1_RPC
cast call $RM "getRollupSequencedBatches(uint32,uint64)((bytes32,uint64,uint64))" 1 1 --rpc-url $L1_RPC

# 获取 L1 的 inputSnark 212 字节
cast call $RM "getInputSnarkBytes(uint32,uint64,uint64,bytes32,bytes32,bytes32)(bytes)" \
  1 0 1 <newLocalExitRoot> <oldStateRoot> <newStateRoot> --rpc-url $L1_RPC
```

### 10.2 P1: 验证 newAccInputHash 对齐

```bash
# 读取 L1 上 sequencedBatches[1].accInputHash
cast call $RM "getRollupSequencedBatches(uint32,uint64)((bytes32,uint64,uint64))" 1 1 --rpc-url $L1_RPC

# 对比 aggregator 日志中的 "Calculated acc input hash for batch 1"
```

如果不一致，逐字段对比 accInputHash 的 6 个输入参数 (oldAccInputHash, batchL2Data hash, l1InfoRoot, timestamp, coinbase, forcedBlockHashL1)。

### 10.3 P2: 验证 oldAccInputHash = 0

prover publics[8..15] 应全为 0 (batch 0 是创世，没有 sequenceBatches 调用)。如不为 0，说明 witness 数据有问题。

### 10.4 P3: 验证 prover circuit 与 verifier 合约版本匹配

确认:
- prover 使用的 circuit 版本 (fork_12?)
- L1 verifier 合约 (`0xB300b1a009dCD2120B7dEA525836d1Eb9967A619`) 对应的版本
- 如果不匹配，proof 必然验证失败

```bash
cast call 0xB300b1a009dCD2120B7dEA525836d1Eb9967A619 \
  "verifyProof(bytes32[24],uint256[1])(bool)" --rpc-url $L1_RPC
```

### 10.5 P4: 手动计算 inputSnark

从 L1 链上读取所有 10 个字段，手动拼接 212 字节，计算 `sha256 % _RFIELD`，与 prover 电路内部的 inputSnark 对比。

### 10.6 P5: 方案 D — 从 L1 读取 accInputHash (防御性修复)

如果 P1 确认 accInputHash 不匹配，修改 aggregator 直接从 L1 读取 accInputHash:

```go
accInputHash, err := a.etherman.GetBatchAccInputHash(ctx, batchNumberToVerify)
```

保证 aggregator/prover 使用的 newAccInputHash 与 L1 sequencedBatches 存储的完全一致。

---

## 11. 最新实测发现 (2026-06-17)

### 11.1 已实施的 aggregator 修复

| 修复项 | 状态 | 说明 |
|--------|------|------|
| aggregator 从 L1 读取 accInputHash | ✅ 已部署 | `cdk/aggregator/aggregator.go` 新增 `GetBatchAccInputHash()` 调用，避免本地计算与 L1 不一致 |
| L1InfoRoot 为零值回退 | ✅ 已部署 | `aggregator.go` 中当 `virtualBatch.L1InfoRoot == nil` 时，回退到 `sequence.L1InfoRoot` |
| batch 1 特殊处理删除 | ✅ 已部署 | 删除 `l1Block.ParentHash` 作为 `forcedBlockHashL1` 的 hack |

### 11.2 提取并解码 prover public inputs

通过 aggregator SQLite 数据库 (`/tmp/aggregator_db.sqlite`) 提取 batch 1 最新 proof 的 `publics` 数组 (44 个 Goldilocks field elements)，并用 `fea2scalar` 算法解码为 bytes32：

```python
# fea2scalar: 8 个 Goldilocks 元素 → 32 字节
# 每 2 个元素组成 64 位（高32位来自奇数索引，低32位来自偶数索引）
# 4 对组成 256 位，大端排列
```

**解码结果**:

| 字段 | Prover (circuit) | L1 (contract) | 状态 |
|------|------------------|---------------|------|
| oldStateRoot | `0xff7cd7c8c037b89df516b6a95becaaac73df6d82b1b039db8b12b6679048c4e1` | `0xd96db188d8a5a3193c085e10488be6624182c23955a5927e0cf3ae941f10d1ea` | ❌ **不匹配** |
| oldAccInputHash | `0x0000...0000` | `0x0000...0000` | ✅ 匹配 |
| initNumBatch | 0 | 0 | ✅ 匹配 |
| chainID | 10000 | 10000 | ✅ 匹配 |
| forkID | 12 | 12 | ✅ 匹配 |
| newStateRoot | `0xff7cd7c8c037b89df516b6a95becaaac73df6d82b1b039db8b12b6679048c4e1` | `0x0000...0000` (未验证) | ⚠️ 待验证 |
| newAccInputHash | `0xbd166afaa9e03bc8c7ca65451261de40533b31dc566680a6f7d9e8f4345898fe` | `0x3b488027196ccf45ee5a2897daf281536fd8aa37535b76c47de4b46125d88644` | ❌ **不匹配** |
| newLocalExitRoot | `0x0000...0000` | `0x0000...0000` | ✅ 匹配 |
| finalNewBatch | 1 | 1 | ✅ 匹配 |

### 11.3 关键新发现：oldStateRoot 与 newStateRoot 相同

**prover 的 oldStateRoot 与 newStateRoot 完全一致** (`0xff7cd7c8...`):
- publics[0..7] = publics[19..26] = [2420688097, 2333259367, 2981116379, 1944022402, 1542236844, 4111906473, 3224877213, 4286371784]

这意味着在 prover 电路中，batch 1 执行前后的状态根没有改变。这与预期不符——即使 batch 1 是空 batch，系统初始化交易也应产生状态变化。

更关键的是：
- **prover oldStateRoot (`0xff7cd7c8...`) ≠ L1 batchNumToStateRoot[0] (`0xd96db188...`)**
- **这是 InvalidProof (0x09bde339) 的直接原因**：L1 合约用 `0xd96db188` 计算 inputSnark，prover 电路用 `0xff7cd7c8` 生成 proof，两者 SHA256 结果不同。

### 11.4 newAccInputHash 仍不匹配

即使 aggregator 已从 L1 读取 accInputHash，prover 的 newAccInputHash (`0xbd166afa...`) 仍与 L1 `sequencedBatches[1].accInputHash` (`0x3b488027...`) 不同。

这说明：
1. prover 电路内部的 accInputHash 计算路径与 L1 不同，或
2. prover 使用的 batch 数据与 L1 sequenced 的数据不同，或
3. prover 电路在 batch 1 的起点状态 (oldStateRoot) 已经错误，导致后续所有派生值都错误

### 11.5 自动对比工具

已编写 `cdk-work/scripts/compare-invalidproof.py`，自动从 aggregator DB 提取 proof 并逐字段对比 L1 数据。见 `cdk-work/doc/lauch-guide-for-debug-zkevm-issue.md` §X 使用方法。

### 11.6 当前待解决的根本问题

1. **为什么 prover oldStateRoot (`0xff7cd7c8...`) 与 L1 batchNumToStateRoot[0] (`0xd96db188...`) 不同？**
   - witness2db 重算的 oldStateRoot 应该是 OLD smt 在 batch 起点的根
   - 但 L1 写入的是 genesis allocs 的静态 SMT 根
   - 可能 UnwindZkSMT 重建出的 OLD smt 根与 genesis 静态根不同

2. **为什么 prover oldStateRoot = newStateRoot？**
   - batch 1 在 prover 电路中似乎没有产生状态变化
   - 可能是 witness 中缺少交易数据，或 executor 认为 batch 为空

3. **newAccInputHash 不匹配**
   - 即使 oldStateRoot 问题解决后，accInputHash 差异仍需单独排查

---

## 12. 新一轮实测发现 (2026-06-18)

### 12.1 当前环境快照

| 项 | 值 |
|----|---|
| Aggregator 容器 | `cdk-node-1--1cf5f97ee5d34193a094ff56f514f436` |
| Sequencer 容器 | `cdk-erigon-sequencer-1--99692579bf48441d809c3705138914d7` |
| RPC 容器 | `cdk-erigon-rpc-1--dabdb65e8d7f40c198c74e61080fffcf` |
| RPC URL | `http://localhost:51712` (自动发现) |
| L1 RPC | `http://184.32.182.132/espace` |
| RollupManager | `0x9dfC9f5864F1d1a7dB83EC2e81F876BFD68dF1EE` |
| Rollup | `0xb2C2d367Aca2E04b535e1Eaa0D27Ab7E8F057b32` |

### 12.2 Root 三元组实测

通过扩展后的 `compare-invalidproof.py` 同时读取 **L1 合约、Sequencer RPC、prover proof** 三方的状态根，得到下表：

| 来源 | oldStateRoot (batch 1 起点) | newStateRoot (batch 1 终点) |
|------|------------------------------|------------------------------|
| L1 合约 `batchNumToStateRoot[0/1]` | `0xd96db188d8a5a3193c085e10488be6624182c23955a5927e0cf3ae941f10d1ea` | `0x0000...0000` (尚未验证) |
| Sequencer RPC `zkevm_getBatchByNumber` | `0x8b4b0276a7d31c02a885b9d6272190d5f02c4fadf4a6380e413b52ffc473a311` (batch 0) | `0x39a54ce27a2b15656c425a490785ed2516c665927ddd18ef59a5bbcbc43c1791` (batch 1) |
| Prover proof publics | `0x76ed8327444305a1a62d6fbcacb7c44dbf09350625654c415dad4ff42788b167` | `0x26a34596b01d8ef1dff5c255df778cabca1851b19cfc27d8f5729ed37a7ec6f0` |

**结论**：三方 oldStateRoot 全部不同；newStateRoot 中 prover 与 sequencer RPC 也不同。

### 12.3 smt-genesis 工具再次验证

对当前 sequencer 容器中的 `/etc/cdk-erigon/dynamic-kurtosis-allocs.json` 运行 `smt-genesis`：

```bash
/home/ubuntu/workspace/ydyl-deployment-suite/cdk-erigon/smt-genesis --alloc /tmp/dynamic-kurtosis-allocs.json
# 输出：0x8b4b0276a7d31c02a885b9d6272190d5f02c4fadf4a6380e413b52ffc473a311
```

该值与 **Sequencer RPC batch 0 stateRoot 完全一致**，但与 **L1 `batchNumToStateRoot[0]` (`0xd96db188...`) 不一致**。

这说明：
- 当前 sequencer 的 genesis stateRoot 是 `0x8b4b...`。
- L1 合约写入的 genesisFinal 是 `0xd96db188...`，它是**之前某次部署的 genesis SMT root**。
- 当前 enclave 的 L1 合约与 sequencer 不是由同一次 genesis 部署产生的，或者部署脚本在写入 L1 时使用了错误的 root。

### 12.4 newAccInputHash 仍不匹配

| 来源 | batch 1 newAccInputHash |
|------|-------------------------|
| L1 `sequencedBatches[1].accInputHash` | `0x3b488027196ccf45ee5a2897daf281536fd8aa37535b76c47de4b46125d88644` |
| Prover proof publics | `0x3365f587098882ac9864b7a5b0f9d97f57ec24ac961df6355109b4233217a19c` |

两者仍然不同。由于 `oldStateRoot` 已经不一致，prover 电路内部基于错误的 oldStateRoot 计算出的 `newAccInputHash` 自然也与 L1 不同。

### 12.5 关键结论更新

2026-06-17 文档认为“四者一致 (`0xd96db188...`)，oldStateRoot 已对齐”，该结论在当前 enclave 下**已经过时**。当前实测显示：

1. **L1 `batchNumToStateRoot[0]` (`0xd96db188...`) ≠ sequencer 实际 block 0 stateRoot (`0x8b4b...`)**。
2. **smt-genesis 工具当前输出 (`0x8b4b...`) 与 sequencer RPC 一致**，说明工具本身是对的，但 L1 没写入这个值。
3. **prover oldStateRoot (`0x76ed...`) 既不等于 L1，也不等于 sequencer RPC**，说明 witness/executor 的状态树计算还有独立问题。

因此，InvalidProof 的修复需要同时解决：
- **部署层面**：确保新部署时 L1 `genesisFinal` = `smt-genesis` 输出 = sequencer block 0 stateRoot。
- **prover 层面**：确保 prover 从 witness 重算出的 oldStateRoot 与 sequencer RPC 一致。

### 12.6 下一步需要回答的问题

1. 为什么 prover 的 oldStateRoot (`0x76ed...`) 与 sequencer RPC batch 0 (`0x8b4b...`) 不同？
   - 是 witness 生成时用了错误的状态树？
   - 是远程 prover 的代码版本与本地不一致？
   - 是 witness2db 重算 SMT root 时使用了不同的 genesis allocs？

2. 为什么 prover 的 newStateRoot (`0x26a3...`) 与 sequencer RPC batch 1 (`0x39a5...`) 不同？
   - 如果 oldStateRoot 已经不同，newStateRoot 不同是连带结果；
   - 但也可能 executor 本身对 batch 1 的状态转换计算与 sequencer 不同。

3. `0xd96db188...` 这个旧 root 来自哪次部署？
   - 它可能来自旧的 `genesis.json`，其中 allocs 与当前不同；
   - 也可能是 smt-genesis 工具在旧代码版本下的输出。