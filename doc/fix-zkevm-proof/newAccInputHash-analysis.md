# newAccInputHash 组成结构与分歧点分析

## 1. accInputHash 计算公式

### 1.1 L1 合约中的计算（PolygonRollupBaseEtrog.sol）

#### 初始 batch（initialize 中计算）
```solidity
newAccInputHash = keccak256(
    abi.encodePacked(
        bytes32(0),                    // 初始值
        keccak256(transactions),       // genesis transactions
        lastGlobalExitRoot,            // global exit root
        currentTimestamp,              // block.timestamp
        sequencer,                     // sequencer address
        blockhash(block.number - 1)    // L1 parent block hash
    )
);
```

#### 普通 batch（sequenceBatches 中计算）
```solidity
currentAccInputHash = keccak256(
    abi.encodePacked(
        currentAccInputHash,           // 上一批次的 accInputHash
        keccak256(transactions),       // batchL2Data 的 keccak256
        l1InfoRoot,                    // L1 info tree root
        maxSequenceTimestamp,          // 时间戳上限
        l2Coinbase,                    // sequencer address
        bytes32(0)                     // forcedBlockHashL1 = 0
    )
);
```

#### 强制 batch（sequenceBatches 中计算）
```solidity
currentAccInputHash = keccak256(
    abi.encodePacked(
        currentAccInputHash,
        keccak256(transactions),
        currentBatch.forcedGlobalExitRoot,
        currentBatch.forcedTimestamp,
        l2Coinbase,
        currentBatch.forcedBlockHashL1
    )
);
```

### 1.2 关键字段说明

| 字段 | 来源 | 说明 |
|------|------|------|
| oldAccInputHash | 上一批次计算结果 | batch 0 时为 bytes32(0) |
| batchL2DataHash | keccak256(batchL2Data) | 交易数据的 keccak256 |
| l1InfoRoot / forcedGlobalExitRoot | L1 info tree 或 GER | 普通 batch 用 l1InfoRoot，强制 batch 用 forcedGlobalExitRoot |
| timestampLimit / forcedTimestamp | 时间戳 | 普通 batch 用 maxSequenceTimestamp，强制 batch 用 forcedTimestamp |
| sequencerAddr / l2Coinbase | sequencer 地址 | 接收 L2 手续费的地址 |
| forcedBlockhashL1 | L1 block hash | 普通 batch 为 bytes32(0)，强制 batch 为实际的 blockhash |

## 2. 当前系统各组件行为

### 2.1 Sequencer（cdk-erigon）
- 计算 expectedFinalAccInputHash 并发送 `sequenceBatches` 交易到 L1
- 将 batch 元数据（L1InfoRoot, Timestamp, BatchL2Data, Coinbase 等）存入本地数据库

### 2.2 L1 合约（PolygonRollupBaseEtrog）
- `sequenceBatches` 接收 batch 数据和 expectedFinalAccInputHash
- 按上述公式逐 batch 计算 accInputHash
- 最终检查 `currentAccInputHash == expectedFinalAccInputHash`
- 调用 `rollupManager.onSequenceBatches(batchesNum, currentAccInputHash)` 存储

### 2.3 Aggregator
- **旧逻辑**：自己本地计算 accInputHash，与 L1 可能不一致
- **新逻辑**（已修复）：直接从 L1 读取 `sequencedBatches[batchNum].accInputHash`
- `buildInputProver` 中给 prover 的输入包含：OldAccInputHash, L1InfoRoot, TimestampLimit, SequencerAddr, ForcedBlockhashL1, BatchL2Data

### 2.4 Prover（zkevm-prover）
- 接收 aggregator 的 inputProver
- 执行 ZK 电路，计算 newStateRoot 和 newAccInputHash
- newAccInputHash 出现在 proof public inputs 的 publics[27-34]

## 3. 当前发现的分歧点

### 3.1 Batch 1 的特殊性

**L1 合约行为**：
- Batch 1 的 accInputHash 是在 `initialize` 函数中计算的，不是通过 `sequenceBatches`
- 使用的参数是：`lastGlobalExitRoot`, `currentTimestamp`, `sequencer`, `blockhash(block.number - 1)`
- 计算公式与 forced batch 类似，但**不是**通过 forced batch 路径

**Aggregator 行为**：
- `buildInputProver` 中 `batchToVerify.BatchNumber == 1` 时，`isForcedBatch = true`
- 给 prover 的 `ForcedBlockhashL1` 设为 `common.Hash{}`（空哈希）
- 给 prover 的 `L1InfoRoot` 设为 `batchToVerify.L1InfoRoot`
- 给 prover 的 `TimestampLimit` 设为 `batchToVerify.Timestamp`

**潜在问题**：
- 如果 prover 电路对 batch 1 使用 forced batch 公式计算 accInputHash，那么 `ForcedBlockhashL1` 应该是 `blockhash(block.number - 1)`，但 aggregator 给的是空哈希
- 如果 prover 电路对 batch 1 使用普通 batch 公式，那么 `l1InfoRoot` 应该是 `lastGlobalExitRoot`（来自 initialize），但 aggregator 给的是 `batchToVerify.L1InfoRoot`
- **无论哪种情况，aggregator 给 prover 的 forcedBlockhashL1 = 空哈希，而 L1 实际使用的是 blockhash**

### 3.2 需要进一步验证的分歧

1. **batchL2Data**：prover 接收的 batchL2Data 是否与 L1 `initialize` 中的 transactions 完全一致？
2. **l1InfoRoot / globalExitRoot**：aggregator 给 prover 的 L1InfoRoot 是否等于 L1 `initialize` 中的 `lastGlobalExitRoot`？
3. **timestamp**：aggregator 给 prover 的 TimestampLimit 是否等于 L1 `initialize` 中的 `currentTimestamp`？
4. **forcedBlockhashL1**：这是最可疑的分歧点

## 4. 实测数据（2026-06-17）

通过扩展后的 `compare-invalidproof.py` 工具，对当前部署的 batch 1 进行实测：

### 4.1 Prover public inputs

```
oldStateRoot:     0xff7cd7c8c037b89df516b6a95becaaac73df6d82b1b039db8b12b6679048c4e1
oldAccInputHash:  0x0000000000000000000000000000000000000000000000000000000000000000
oldBatchNum:      0
chainID:          10000
forkID:           12
newStateRoot:     0xff7cd7c8c037b89df516b6a95becaaac73df6d82b1b039db8b12b6679048c4e1
newAccInputHash:  0xbd166afaa9e03bc8c7ca65451261de40533b31dc566680a6f7d9e8f4345898fe
newLocalExitRoot: 0x0000000000000000000000000000000000000000000000000000000000000000
newBatchNum:      1
```

### 4.2 L1 合约数据

```
oldStateRoot (batchNumToStateRoot[0]): 0xd96db188d8a5a3193c085e10488be6624182c23955a5927e0cf3ae941f10d1ea
newStateRoot (batchNumToStateRoot[1]): 0x0000000000000000000000000000000000000000000000000000000000000000
oldAccInputHash (sequencedBatches[0]): 0x0000000000000000000000000000000000000000000000000000000000000000
newAccInputHash (sequencedBatches[1]): 0x3b488027196ccf45ee5a2897daf281536fd8aa37535b76c47de4b46125d88644
chainID: 10000
forkID: 12
```

### 4.3 Aggregator Sync DB 中的 batch 元数据

```
virtual_batch.batch_num:        1
virtual_batch.fork_id:          12
virtual_batch.coinbase:         0x0000000000000000000000000000000000000000
virtual_batch.sequencer_addr:   0x747198C0F8fdedbFB5cf91DB833904EdD1093DD4
virtual_batch.l1_info_root:     0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5
virtual_batch.sequence_from:    1
virtual_batch.raw_txs_data:     328 bytes

sequenced_batches.block_num:    6637085
sequenced_batches.timestamp:    2026-06-17 04:02:03+00:00
sequenced_batches.l1_info_root: 0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5
sequenced_batches.source:       InitialSequenceBatches
```

### 4.4 L1 Rollup 合约参数

```
Rollup 合约地址:   0xb2C2d367Aca2E04b535e1Eaa0D27Ab7E8F057b32
trustedSequencer:  0xb3E2c2B0B0a6d877F3Ea34e218D6B919c2052d38
globalExitRootManager: 0xE2731877D11f9B370A525df849bCDA1B86dF591C
lastAccInputHash:  0xf5d835c0e6d986ddf652ef269d8fdd000b8de86f46658db956998d7b81f5d30e
lastGlobalExitRoot: 0x133e6a88627cda3e7df19f63db3be8dbaa691e860ee1ccec52eeaf54be5381cd
L1 initialize block: 6637085
L1 block.timestamp: 1781668923
L1 block.parentHash: 0xe95302d0d0915317b2c87d9454c0288a57f9bfc08de0a11078d762a00cbfac43
```

### 4.5 关键分歧点（已确认）

| 参数 | Prover / Aggregator 使用 | L1 initialize 实际使用 | 是否匹配 |
|------|--------------------------|------------------------|----------|
| L1InfoRoot | 0xad3228b6... | 0x133e6a88... (lastGlobalExitRoot) | **不匹配** |
| SequencerAddr | 0x747198C0... | 0xb3E2c2B0... (trustedSequencer) | **不匹配** |
| TimestampLimit | 0 (input_prover 缺失，默认值) | 1781668923 (block.timestamp) | **不匹配** |
| ForcedBlockhashL1 | 0x0 | 0xe95302d0... (blockhash(block.number-1)) | **不匹配** |
| batchL2DataHash | 0x5f66fe2f... (keccak256(raw_txs_data)) | 待确认（generateInitializeTransaction 输出） | **待确认** |

**结论**：Aggregator 给 prover 的 batch 1 输入参数与 L1 `initialize` 实际使用的参数几乎全不匹配，这是导致 newAccInputHash 不一致的直接原因。

## 5. 根本原因分析

### 5.1 L1InfoRoot 不匹配

Aggregator 从 `virtual_batch` 读取的 `l1_info_root` 是 `0xad3228b6...`，这可能是 L1 Info Tree 的某个 leaf/root，而不是 L1 `initialize` 中使用的 `lastGlobalExitRoot` (`0x133e6a88...`)。

根据代码，L1 `initialize` 中使用的是：
```solidity
bytes32 lastGlobalExitRoot = globalExitRootManager.getLastGlobalExitRoot();
```

而 aggregator 给 prover 用的是 `batchToVerify.L1InfoRoot`（来自 virtual_batch 表）。

### 5.2 SequencerAddr 不匹配

`virtual_batch.sequencer_addr` (`0x747198C0...`) 是部署时传入的 sequencer 地址，但 L1 合约的 `trustedSequencer` 被设置成了 `0xb3E2c2B0...`。

这说明在 `attachAggchainToAL` 调用中传入的 `sequencer` 参数是 `0x747198C0...`，但合约初始化后 `trustedSequencer` 可能被修改过，或者部署脚本传入的 sequencer 与实际运行 sequencer 不一致。

### 5.3 TimestampLimit 不匹配

Aggregator 给 prover 的 `TimestampLimit` 为 0（因为 input_prover 缺失，且 virtual_batch.batch_timestamp 为空），但 L1 `initialize` 中使用的是 `block.timestamp = 1781668923`。

### 5.4 ForcedBlockhashL1 不匹配

Aggregator 给 prover 的 `ForcedBlockhashL1` 是 `0x0`，但 L1 `initialize` 中使用的是 `blockhash(block.number - 1) = 0xe95302d0...`。

## 6. 修复方向

要让 prover 生成的 newAccInputHash 与 L1 一致，必须让 aggregator 给 prover 的输入参数与 L1 `initialize` 实际使用的参数完全一致。

对于 batch 1，aggregator 应该：
1. `L1InfoRoot` 使用 `lastGlobalExitRoot`（通过调用 globalExitRootManager.getLastGlobalExitRoot() 或在部署时记录）
2. `SequencerAddr` 使用 L1 合约的 `trustedSequencer`
3. `TimestampLimit` 使用 L1 initialize 交易的 block.timestamp
4. `ForcedBlockhashL1` 使用 L1 initialize 交易的 blockhash(block.number - 1)
5. `BatchL2Data` 使用 L1 initialize 中生成的 transaction（即 generateInitializeTransaction 的输出）

## 7. 重大发现：Rollup 合约地址被修改

通过解析 `attachAggchainToAL` 交易 `0x2d3c8df1...` 的 receipt logs，发现：

- `CreateNewRollup` 事件创建的原始 rollup 合约地址是 `0x6cc5f423f7ba87845cd2e61d45aaf33255358f62`
- `InitialSequenceBatches` 事件也来自该原始 rollup 合约
- 该原始合约的 `trustedSequencer` 为 `0x747198C0F8fdedbFB5cf91DB833904EdD1093DD4`，与 `virtual_batch.sequencer_addr` 一致
- 但当前 `RollupManager.rollupIDToRollupData(1)` 返回的 rollup 合约地址是 `0xb2C2d367Aca2E04b535e1Eaa0D27Ab7E8F057b32`
- 当前合约 `0xb2C2d367...` 的 `trustedSequencer` 是 `0xb3E2c2B0B0a6d877F3Ea34e218D6B919c2052d38`

这意味着 RollupManager 中的 rollupID=1 在创建后被修改/替换过，导致：
1. `sequencedBatches[1].accInputHash` 仍来自原始合约的初始化（`0x3b4880...`）
2. 但 `batchNumToStateRoot[0]` 来自当前合约 `0xb2C2d367...`，其值为 rollupType.genesis（MPT 根 `0xd96db1...`）
3. 因此 L1 verify 时使用的 `oldStateRoot` 与 prover 实际计算的 `oldStateRoot` 不匹配

**结论**：当前部署的 L1 合约状态本身已损坏/不一致。即使 aggregator 给 prover 的输入参数完全正确，L1 合约当前的 `batchNumToStateRoot[0]` 与原始 initialize 时的状态不一致，也会导致 InvalidProof。

## 8. 修复方案

### 8.1 短期修复（当前已损坏部署）

由于当前 L1 合约状态已损坏，最可靠的修复是：
1. 删除当前 enclave 和 L1 合约
2. 使用修正后的自动部署脚本重新部署

### 8.2 长期修复（自动部署脚本）

确保新部署不会出现同样问题：
1. **Rollup 合约一致性**：部署后确认 `RollupManager.rollupIDToRollupData(rollupID).rollupContract` 与 `InitialSequenceBatches` 事件中的 rollup 合约地址一致，未被意外修改
2. **batchNumToStateRoot[0] 正确写入**：确保 L1 合约的 `batchNumToStateRoot[0]` 写入 sequencer block 0 执行后的真实 SMT root，而不是 genesis MPT root
3. **Aggregator batch 1 输入参数**：修改 aggregator 的 `buildInputProver`，对 batch 1 使用 L1 `initialize` 的真实参数：
   - `L1InfoRoot` = `globalExitRootManager.getLastGlobalExitRoot()`
   - `SequencerAddr` = L1 rollup 合约的 `trustedSequencer`
   - `TimestampLimit` = L1 initialize 交易的 `block.timestamp`
   - `ForcedBlockhashL1` = L1 initialize 交易的 `blockhash(block.number - 1)`
   - `BatchL2Data` = L1 initialize 中生成的 transaction

### 8.3 aggregator 代码修改点

文件：`cdk/aggregator/aggregator.go` 中 `buildInputProver` 函数

当前 batch 1 的处理逻辑：
- `isForcedBatch = true`
- `ForcedBlockhashL1 = common.Hash{}`
- `L1InfoRoot = batchToVerify.L1InfoRoot`
- `TimestampLimit = uint64(batchToVerify.Timestamp.Unix())`

应改为：
- 从 L1 读取原始 initialize 交易中的真实参数
- 或从部署脚本生成时记录这些参数并持久化到 aggregator 配置/数据库

## 9. 下一步

1. 在自动部署脚本中加入检查：部署后验证 `RollupManager` 指向的 rollup 合约与 `InitialSequenceBatches` 事件中的地址一致
2. 修改 aggregator 代码，使 batch 1 的 inputProver 使用 L1 initialize 的真实参数
3. 重新部署完整 enclave，验证 batch 1 proof 被 L1 接受
4. 继续调研 UnwindZkSMT 的聚合连续性问题，确保后续 batch 也能验证通过
