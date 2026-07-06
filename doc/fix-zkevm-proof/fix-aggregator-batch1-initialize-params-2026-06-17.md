# 修复 aggregator batch 1 输入参数以匹配 L1 initialize

## 问题背景

在 L1 合约验证 zkEVM batch 1 的证明时，出现 `InvalidProof()` 错误。

通过 `compare-invalidproof.py` 工具分析发现，prover 计算的 `newAccInputHash` 与 L1 合约存储的 `newAccInputHash` 不一致：

- Prover `newAccInputHash`: `0xbd166afaa9e03bc8c7ca65451261de40533b31dc566680a6f7d9e8f4345898fe`
- L1 `sequencedBatches[1].accInputHash`: `0x3b488027196ccf45ee5a2897daf281536fd8aa37535b76c47de4b46125d88644`

## 根因分析

### L1 合约中的 batch 1 accInputHash

对于 batch 1，L1 rollup 合约在 `initialize()` 函数中计算 `accInputHash`：

```solidity
newAccInputHash = keccak256(
    abi.encodePacked(
        bytes32(0),                    // oldAccInputHash
        keccak256(transactions),       // batchL2DataHash
        lastGlobalExitRoot,            // l1InfoRoot / forcedGlobalExitRoot
        currentTimestamp,              // timestampLimit
        sequencer,                     // sequencerAddr
        blockhash(block.number - 1)    // forcedBlockhashL1
    )
);
```

这与普通 batch 的公式不同，强制 batch 公式也略有不同。

### 原 aggregator 行为

`cdk/aggregator/aggregator.go` 中 `buildInputProver` 对 batch 1 的处理：

```go
if batchToVerify.BatchNumber == 1 || batchToVerify.ForcedBatchNum != nil {
    isForcedBatch = true
}
```

因此 batch 1 被当作 forced batch，输入参数为：
- `ForcedBlockhashL1 = common.Hash{}`（0x0）
- `L1InfoRoot = batchToVerify.L1InfoRoot`
- `TimestampLimit = batchToVerify.Timestamp`
- `SequencerAddr = batchToVerify.Coinbase`

这些参数与 L1 `initialize()` 实际使用的参数不一致，导致 prover 计算的 `newAccInputHash` 与 L1 不匹配。

### 实测分歧

通过解析 L1 `InitialSequenceBatches` 事件，得到 batch 1 的真实参数：

| 参数 | L1 initialize 真实值 | 原 aggregator 给 prover 的值 |
|---|---|---|
| transactions (batchL2Data) | 328 bytes | 一致（来自 virtual_batch） |
| lastGlobalExitRoot (L1InfoRoot) | `0xad3228b6...` | `0xad3228b6...`（一致） |
| sequencer | `0x747198C0...` | `0x747198C0...`（一致） |
| timestamp | `1781668923` | `0`（virtual_batch.batch_timestamp 为空） |
| blockhash(block.number - 1) | `0xe95302d0...` | `0x0` |

主要分歧点是 `TimestampLimit` 和 `ForcedBlockhashL1`。

## 修复方案

修改 `cdk/aggregator/aggregator.go` 的 `buildInputProver` 函数：

对 batch 1，从 L1 事件 `InitialSequenceBatches(bytes transactions, bytes32 lastGlobalExitRoot, address sequencer)` 解析真实参数，并从交易 receipt 所在 block 获取 timestamp 和 parent hash，然后用这些参数覆盖 inputProver 中的默认值。

### 新增代码

1. `interfaces.go`: 扩展 `Etherman` 接口，添加 `GetTransactionReceipt` 方法
2. `etherman/etherman.go`: 实现 `GetTransactionReceipt`
3. `aggregator.go`:
   - 添加 `batch1InitializeParams` 结构体
   - 添加 `parseInitialSequenceBatchesEvent` 函数解析事件
   - 添加 `getBatch1InitializeParams` 函数从 L1 获取参数
   - 在 `buildInputProver` 中 batch 1 时覆盖 inputProver 参数
4. `mocks/mock_etherman.go`: 添加对应 mock 方法

### 关键逻辑

```go
if batchToVerify.BatchNumber == 1 {
    virtualBatch, err := a.l1Syncr.GetVirtualBatchByBatchNumber(ctx, batchToVerify.BatchNumber)
    if err == nil && virtualBatch != nil {
        initParams, err := a.getBatch1InitializeParams(ctx, virtualBatch.VlogTxHash)
        if err == nil {
            inputProver.PublicInputs.BatchL2Data = initParams.transactions
            inputProver.PublicInputs.L1InfoRoot = initParams.lastGlobalExitRoot.Bytes()
            inputProver.PublicInputs.TimestampLimit = initParams.timestamp
            inputProver.PublicInputs.SequencerAddr = initParams.sequencer.String()
            inputProver.PublicInputs.ForcedBlockhashL1 = initParams.forcedBlockHash.Bytes()
        }
    }
}
```

## 当前部署的额外问题

当前 L1 部署还存在另一个问题：
- `InitialSequenceBatches` 事件发生在 rollup 合约 `0x6cc5f423f7ba87845cd2e61d45aaf33255358f62`
- 但 `RollupManager.rollupIDToRollupData(1)` 当前返回的 rollup 合约是 `0xb2C2d367Aca2E04b535e1Eaa0D27Ab7E8F057b32`
- 当前合约的 `batchNumToStateRoot[0]` 是 genesis MPT root，不是原始 SMT root

这会导致即使 `newAccInputHash` 匹配，`oldStateRoot` 仍然不匹配。因此**必须重新部署**才能完整验证修复。

## 验证步骤

1. 重新编译 aggregator Docker 镜像
2. 清理当前 enclave 和 L1 合约
3. 用修正后的自动部署脚本重新部署
4. 部署后运行 `compare-invalidproof.py` 确认：
   - `oldStateRoot` 匹配
   - `newAccInputHash` 匹配
   - L1 verify 不再 revert

## 相关文件

- `cdk/aggregator/aggregator.go`
- `cdk/aggregator/interfaces.go`
- `cdk/etherman/etherman.go`
- `cdk/aggregator/mocks/mock_etherman.go`
- `doc-report/newAccInputHash-analysis.md`
- `cdk-work/scripts/compare-invalidproof.py`
