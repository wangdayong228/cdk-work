# Polygon cdk l2 batch sequence issue

使用 kurtosis-cdk 在 conflux  espace 部署了一个 zkevm 的 L2, L2 本身已经可以正常运转, 但是 l2 的 batch 没有正常发送到 L1 的智能合约中.

## 表现

```sh
rpc_url=$(kurtosis port print cdk cdk-erigon-rpc-001 rpc)
export ETH_RPC_URL="$(kurtosis port print cdk cdk-erigon-rpc-001 rpc)"

cast rpc --rpc-url $rpc_url zkevm_batchNumber
cast rpc --rpc-url $rpc_url zkevm_virtualBatchNumber
cast rpc --rpc-url $rpc_url zkevm_verifiedBatchNumber
```

batchNumber 正常增长, 但是 virtualBatchNumber 和 verifiedBatchNumber 保持 1 和 0 不变.

## misc

1. cdk 的 sequencesender 模块负责发送 batch sequence 交易
2. 涉及的合约为 [PolygonZkEVMEtrog.sol](https://docs.polygon.technology/zkEVM/architecture/high-level/smart-contracts/#consensus), 对应到 kurtosis-cdk 部署的合约(combined.json)里的 rollupAddress
3. sequencing 流程文档: https://docs.polygon.technology/zkEVM/architecture/high-level/smart-contracts/sequencing/

## 主要涉及模块 cdk

日志里观察到的主要错误

rpc not compatible issue

```sh
[cdk-node-001] 2025-02-07T08:15:18.817Z	INFO	sync/evmdownloader.go:295	there has been a block hash change between the event query and the block query for block 204985200: 0x0ee09615efa0ae00fcb2d22df4eba7805f50c78f54579266a921586a03ea74d9 vs 0x37f634221b498164013d0d82d428e5465438dbb1918c922fbc4f26a4e857fd13. Retrying.{"pid": 9, "version": "v0.5.1", "syncer": "l1infotreesync"}
```

block not processed issue

```sh
[cdk-node-001] 2025-02-07T08:16:33.599Z	INFO	rpc/batch.go:47	Getting batch 499 from RPC	{"pid": 9, "version": "v0.5.1"}
[cdk-node-001] 2025-02-07T08:16:33.599Z	INFO	sequencesender/sequencesender.go:282	updating virtual batch	{"pid": 9, "version": "v0.5.1", "module": "sequence-sender"}
[cdk-node-001] 2025-02-07T08:16:33.600Z	INFO	rpc/batch.go:94	Getting l2 block timestamp from RPC. Block hash: 0xe396a1dc443da5bdcd6ccd8dd014fed76388bdcc8073d02a5c0182e86e435a6a	{"pid": 9, "version": "v0.5.1"}
[cdk-node-001] 2025-02-07T08:16:33.601Z	INFO	sequencesender/sequencesender.go:187	batch 499 is not closed yet	{"pid": 9, "version": "v0.5.1", "module": "sequence-sender"}
[cdk-node-001] 2025-02-07T08:16:33.647Z	INFO	sequencesender/sequencesender.go:523	latest virtual batch is 1	{"pid": 9, "version": "v0.5.1", "module": "sequence-sender"}
[cdk-node-001] 2025-02-07T08:16:33.647Z	INFO	sequencesender/sequencesender.go:295	updating tx results	{"pid": 9, "version": "v0.5.1", "module": "sequence-sender"}
[cdk-node-001] 2025-02-07T08:16:33.647Z	INFO	sequencesender/ethtx.go:201	0 tx results synchronized (0 in pending state)	{"pid": 9, "version": "v0.5.1"}
[cdk-node-001] 2025-02-07T08:16:33.647Z	INFO	sequencesender/sequencesender.go:308	getting sequences to send	{"pid": 9, "version": "v0.5.1", "module": "sequence-sender"}
[cdk-node-001] 2025-02-07T08:16:33.694Z	ERROR	txbuilder/banana_base.go:152	error getting CounterL1InfoRoot: error calling GetLatestInfoUntilBlock with block num 204996420: given block(s) have not been processed yet%!(EXTRA string=
[cdk-node-001] /go/src/github.com/0xPolygon/cdk/log/log.go:148 github.com/0xPolygon/cdk/log.appendStackTraceMaybeArgs()
[cdk-node-001] /go/src/github.com/0xPolygon/cdk/log/log.go:257 github.com/0xPolygon/cdk/log.Errorf()
[cdk-node-001] /go/src/github.com/0xPolygon/cdk/sequencesender/txbuilder/banana_base.go:152 github.com/0xPolygon/cdk/sequencesender/txbuilder.(*TxBuilderBananaBase).NewSequence()
[cdk-node-001] /go/src/github.com/0xPolygon/cdk/sequencesender/txbuilder/zkevm_cond_max_size.go:37 github.com/0xPolygon/cdk/sequencesender/txbuilder.(*ConditionalNewSequenceMaxSize).NewSequenceIfWorthToSend()
[cdk-node-001] /go/src/github.com/0xPolygon/cdk/sequencesender/txbuilder/banana_zkevm.go:61 github.com/0xPolygon/cdk/sequencesender/txbuilder.(*TxBuilderBananaZKEVM).NewSequenceIfWorthToSend()
[cdk-node-001] /go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:479 github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).getSequencesToSend()
[cdk-node-001] /go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:309 github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).tryToSendSequence()
[cdk-node-001] /go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:243 github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).sequenceSending()
[cdk-node-001] )	{"pid": 9, "version": "v0.5.1"}
[cdk-node-001] github.com/0xPolygon/cdk/sequencesender/txbuilder.(*TxBuilderBananaBase).NewSequence
[cdk-node-001] 	/go/src/github.com/0xPolygon/cdk/sequencesender/txbuilder/banana_base.go:152
[cdk-node-001] github.com/0xPolygon/cdk/sequencesender/txbuilder.(*ConditionalNewSequenceMaxSize).NewSequenceIfWorthToSend
[cdk-node-001] 	/go/src/github.com/0xPolygon/cdk/sequencesender/txbuilder/zkevm_cond_max_size.go:37
[cdk-node-001] github.com/0xPolygon/cdk/sequencesender/txbuilder.(*TxBuilderBananaZKEVM).NewSequenceIfWorthToSend
[cdk-node-001] 	/go/src/github.com/0xPolygon/cdk/sequencesender/txbuilder/banana_zkevm.go:61
[cdk-node-001] github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).getSequencesToSend
[cdk-node-001] 	/go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:479
[cdk-node-001] github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).tryToSendSequence
[cdk-node-001] 	/go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:309
[cdk-node-001] github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).sequenceSending
[cdk-node-001] 	/go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:243
[cdk-node-001] 2025-02-07T08:16:33.694Z	ERROR	sequencesender/sequencesender.go:312	error getting sequences: error calling GetLatestInfoUntilBlock with block num 204996420: given block(s) have not been processed yet	{"pid": 9, "version": "v0.5.1", "module": "sequence-sender"}
[cdk-node-001] github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).tryToSendSequence
[cdk-node-001] 	/go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:312
[cdk-node-001] github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).sequenceSending
[cdk-node-001] 	/go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:243
```

通过翻看 cdk 具体代码(go 代码), 发现第二个错误是由于 sync 模块数据同步异常导致的, 也就是第一个问题.

而第一个问题通过 json-rpc proxy 查看请求响应数据, 最终确定是由于 rpc 不兼容导致. 具体不兼容的方面为:

cdk 使用 go-ethereum 的 ethClient 来访问 L1 RPC, 该 client 的 GetBlockHeader 方法返回的 Header 数据中未直接使用 rpc 返回的 block hash 字段, 而是自行使用 header 的各个字段数据计算而来, 但由于一些原因, 计算出来的 hash 与 区块的 hash 不一致, 导致不断重试, 并且产生大量的 log.

通过临时修改代码, 直接使用 rpc 返回的 hash 而非自行计算, 来绕过此问题. 从而解决了此问题

## sequence 交易卡主问题

batch sequence 交易在 conflux 网络会因为 gasPrice 低的原因卡主, 目前 cdk 服务没有提高并重试逻辑

需要做简单的修改, 增加提高 gasPrice 重发的逻辑

**已解决：**
模块 ethTxManager 负责发送交易到 l1: `zkevm-ethtx-manager/ethtxmanager/ethtxmanager.go`, cdk 使用的 package 见 cdk/go.mod。

当一段时间未打包，提高 gasPrice

## batch sequence 发送交易逻辑
cdk/sequencesender/ethtx.go sendTx方法中会添加交易到 ethtxmanager 中， 等待发送

```go
s.ethTxManager.AddWithGas(ctx, paramTo, big.NewInt(0), paramData, s.cfg.GasOffset, nil, gas)
```

squence sender 创建交易堆栈
```
github.com/0xPolygon/zkevm-ethtx-manager/ethtxmanager.(*Client).add(...)
	/go/pkg/mod/github.com/wangdayong228/zkevm-ethtx-manager@v0.0.0-20250224081914-8dbf45dfd8f8/ethtxmanager/ethtxmanager.go:338 +0x11f8
github.com/0xPolygon/zkevm-ethtx-manager/ethtxmanager.(*Client).AddWithGas(...)
	/go/pkg/mod/github.com/wangdayong228/zkevm-ethtx-manager@v0.0.0-20250224081914-8dbf45dfd8f8/ethtxmanager/ethtxmanager.go:186 +0x65
github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).sendTx(...)
	/go/src/github.com/0xPolygon/cdk/sequencesender/ethtx.go:73 +0x253
github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).tryToSendSequence(0xc00031e848, {0x1df8500, 0x2a87660})
	/go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:375 +0xac5
github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).sequenceSending(0xc00031e848, {0x1df8500, 0x2a87660})
	/go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:243 +0xa5
created by github.com/0xPolygon/cdk/sequencesender.(*SequenceSender).Start in goroutine 13
	/go/src/github.com/0xPolygon/cdk/sequencesender/sequencesender.go:158 +0x295
```

**sequence sender 不再创建交易**

sequence sender 不再创建交易日志

```js
sequencesender/sequencesender.go:187    batch 3954 is not closed yet    {"pid": 9, "version": "v0.5.1", "module": "sequence-sender"}
```

## zkevm_verifiedBatchNumber 卡住问题
当时用
zkevm_l2_agglayer_address 的交易卡住会导致 zkevm_verifiedBatchNumber 卡住。 

**交易卡主具体原因：**
当 aggregator 设置 SettlementBackend 时，会走 agglayer 提交证明到 l1。
此时发送交易的地址为 params.yaml 的 zkevm_l2_agglayer_address

**解决方法**：当前设置 SettlementBackend 为l1, 即直接提交到l1，这种方式会直接使用 ethtxmanager 模块。

aggregator 创建交易堆栈
```
github.com/0xPolygon/zkevm-ethtx-manager/ethtxmanager.(*Client).add(...)
	/go/pkg/mod/github.com/wangdayong228/zkevm-ethtx-manager@v0.0.0-20250224081914-8dbf45dfd8f8/ethtxmanager/ethtxmanager.go:338 +0x11f8
github.com/0xPolygon/zkevm-ethtx-manager/ethtxmanager.(*Client).Add(...)
	/go/pkg/mod/github.com/wangdayong228/zkevm-ethtx-manager@v0.0.0-20250224081914-8dbf45dfd8f8/ethtxmanager/ethtxmanager.go:180 +0x5e
github.com/0xPolygon/cdk/aggregator.(*Aggregator).settleDirect(...)
	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:579 +0x296
github.com/0xPolygon/cdk/aggregator.(*Aggregator).sendFinalProof(0xc000918008)
	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:498 +0x5ef
created by github.com/0xPolygon/cdk/aggregator.(*Aggregator).Start in goroutine 108
	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:353 +0x672
```

**不创建交易问题**

交易卡主问题解决后，发现 aggregator 会在运行一段时间后不再创建交易

相关日志为
```js
[cdk-node-001] 2025-02-25T03:44:50.873Z DEBUG   aggregator/aggregator.go:668    tryBuildFinalProof start        {"pid": 9, "version": "v0.5.1", "module": "aggregator", "prover": "test-prover", "proverId": "cef539df-85cc-4b88-819d-37f821cf7968", "proverAddr": "172.16.0.14:59562"}
[cdk-node-001] 2025-02-25T03:44:50.874Z DEBUG   aggregator/aggregator.go:674    Send final proof time reached   {"pid": 9, "version": "v0.5.1", "module": "aggregator", "prover": "test-prover", "proverId": "cef539df-85cc-4b88-819d-37f821cf7968", "proverAddr": "172.16.0.14:59562"}
[cdk-node-001] 2025-02-25T03:44:50.919Z DEBUG   aggregator/aggregator.go:687    No proof ready to verify        {"pid": 9, "version": "v0.5.1", "module": "aggregator", "prover": "test-prover", "proverId": "cef539df-85cc-4b88-819d-37f821cf7968", "proverAddr": "172.16.0.14:59562"}
[cdk-node-001] 2025-02-25T03:44:50.919Z DEBUG   aggregator/aggregator.go:901    tryAggregateProofs start        {"pid": 9, "version": "v0.5.1", "module": "aggregator", "prover": "test-prover", "proverId": "cef539df-85cc-4b88-819d-37f821cf7968", "proverAddr": "172.16.0.14:59562"}
[cdk-node-001] 2025-02-25T03:44:50.919Z DEBUG   aggregator/aggregator.go:906    Nothing to aggregate    {"pid": 9, "version": "v0.5.1", "module": "aggregator", "prover": "test-prover", "proverId": "cef539df-85cc-4b88-819d-37f821cf7968", "proverAddr": "172.16.0.14:59562"}
[cdk-node-001] 2025-02-25T03:44:50.919Z DEBUG   aggregator/aggregator.go:1274   tryGenerateBatchProof start     {"pid": 9, "version": "v0.5.1", "module": "aggregator", "prover": "test-prover", "proverId": "cef539df-85cc-4b88-819d-37f821cf7968", "proverAddr": "172.16.0.14:59562"}
[cdk-node-001] 2025-02-25T03:44:50.963Z INFO    aggregator/aggregator.go:1115   Sequencing event for batch 2414 has not been synced yet, so it is not possible to verify it yet. Waiting ...    {"pid": 9, "version": "v0.5.1", "module": "aggregator", "prover": "test-prover", "proverId": "cef539df-85cc-4b88-819d-37f821cf7968", "proverAddr": "172.16.0.14:59562"}
[cdk-node-001] 2025-02-25T03:44:50.963Z DEBUG   aggregator/aggregator.go:1279   Nothing to generate proof       {"pid": 9, "version": "v0.5.1", "module": "aggregator", "prover": "test-prover", "proverId": "cef539df-85cc-4b88-819d-37f821cf7968", "proverAddr": "172.16.0.14:59562"}
```

**创建 squence sync 数据的代码为**
```log
github.com/0xPolygonHermez/zkevm-synchronizer-l1/state/storage/sqlstorage.(*SqlStorage).AddSequencedBatches(
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/state/storage/sqlstorage/sequenced_batches.go:26 +0xb6
github.com/0xPolygonHermez/zkevm-synchronizer-l1/state/model.SetStorageHelper[...]()
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/state/model/common.go:25 +0x59
github.com/0xPolygonHermez/zkevm-synchronizer-l1/state/model.(*BatchState).OnSequencedBatchesOnL1(...)
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/state/model/batch_state.go:50 +0x1d8
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer/actions/banana.(*ProcessorL1SequenceBatchesBanana).ProcessSequenceBatches(...)
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/actions/banana/processor_l1_sequence_batches.go:69 +0x4bf
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer/actions/banana.(*ProcessorL1SequenceBatchesBanana).Process()
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/actions/banana/processor_l1_sequence_batches.go:38 +0xd4
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer/actions/processor_manager.(*L1EventProcessors).Process()
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/actions/processor_manager/processor_manager.go:69 +0x1e8
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer/internal.(*BlockRangeProcess).processElement(...)
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/internal/synchronizer_block_range_process.go:145 +0x3c4
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer/internal.(*BlockRangeProcess).processBlock(...)
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/internal/synchronizer_block_range_process.go:122 +0x28c
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer/internal.(*BlockRangeProcess).internalProcessBlockRange(...})
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/internal/synchronizer_block_range_process.go:95 +0x165
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer/internal.(*BlockRangeProcess).ProcessBlockRange()
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/internal/synchronizer_block_range_process.go:52 +0x3c
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer/l1_sync.(*L1SequentialSync).iteration()
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/l1_sync/l1_syncer_sequential.go:229 +0x38d
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer/l1_sync.(*L1SequentialSync).SyncBlocks()
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/l1_sync/l1_syncer_sequential.go:152 +0x411
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer/internal.(*SynchronizerImpl).Sync(0xc000960d20, 0x0)
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/internal/synchronizer_impl.go:259 +0x3b5
github.com/0xPolygonHermez/zkevm-synchronizer-l1/synchronizer.(*SynchronizerAdapter).Sync(0xc00084ce01?, 0x8?)
	/go/pkg/mod/github.com/wangdayong228/zkevm-synchronizer-l1@v0.0.0-20250225110232-f3a9f41115c2/synchronizer/synchronizer_adapter.go:44 +0x1a
github.com/0xPolygon/cdk/aggregator.(*Aggregator).Start.func1()
	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:309 +0x31
created by github.com/0xPolygon/cdk/aggregator.(*Aggregator).Start in goroutine 88
	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:308 +0x125
```

## L1InfoTree mismatch 问题

合约中计算 ExitRoot Leaf 时用到了链上的 ParentHash，而链下计算使用的是rpc 获取的 ParentHash，会导致双方不一致。所以 jsonrpc-proxy 不能使用修正过的 BlockHash。

### misc
**event相关日志**
```md
<!-- 查看是否有同步到 event -->
etherman/etherman.go:616        Events detected: 0      {"pid": 9}
<!-- 同步到的 event 详情 -->
etherman/etherman.go:			Event detected: topic:
```

```log
2025-02-28T00:38:53.502Z        DEBUG   etherman/etherman.go:616        Events detected: 2      {"pid": 9}
2025-02-28T00:38:53.502Z        DEBUG   etherman/etherman.go:618        Event detected: topic:VerifyBatches(uint64,bytes32,address) blockHash:0xe428ae4fefb4ae254aded225cfcd9bc369d9925136b15c5a6b093c94afcc8d17 blockNumber:207677005 txHash: 0x9cfbe65517c6b5a3f911a48b89f7cca86b4a55071bb83f10d5e0ca1fc2f1b8a8  {"pid": 9}
2025-02-28T00:38:53.502Z        DEBUG   etherman/etherman.go:618        Event detected: topic:VerifyBatchesTrustedAggregator(uint32,uint64,bytes32,bytes32,address) blockHash:0xe428ae4fefb4ae254aded225cfcd9bc369d9925136b15c5a6b093c94afcc8d17 blockNumber:207677005 txHash: 0x9cfbe65517c6b5a3f911a48b89f7cca86b4a55071bb83f10d5e0ca1fc2f1b8a8  {"pid": 9}
2025-02-28T00:38:53.502Z        DEBUG   etherman/etherman.go:600        Processing event: topic:0x9c72852172521097ba7e1482e6b44b351323df0155f97f4ea18fcec28e1f5966 (VerifyBatches(uint64,bytes32,address)) blockHash:0xe428ae4fefb4ae254aded225cfcd9bc369d9925136b15c5a6b093c94afcc8d17 blockNumber:%!s(uint64=207677005) txHash: 0x9cfbe65517c6b5a3f911a48b89f7cca86b4a55071bb83f10d5e0ca1fc2f1b8a8       {"pid": 9}
2025-02-28T00:38:53.502Z        DEBUG   etherman/etherman.go:659        VerifyBatches(uint64,bytes32,address) event detected: Ignoring...  (event: {Address:0x11C9719CD193CDA6C4D71268cB25349777BaB810 Topics:[0x9c72852172521097ba7e1482e6b44b351323df0155f97f4ea18fcec28e1f5966 0x0000000000000000000000000000000000000000000000000000000000002990 0x00000000000000000000000065d79da11c273ce868470a4eaf2019ad0daf5da4] Data:[253 37 167 108 129 102 162 163 138 113 184 42 248 90 178 250 228 172 8 107 140 69 40 56 194 143 243 26 31 224 205 12] BlockNumber:207677005 TxHash:0x9cfbe65517c6b5a3f911a48b89f7cca86b4a55071bb83f10d5e0ca1fc2f1b8a8 TxIndex:0 BlockHash:0xe428ae4fefb4ae254aded225cfcd9bc369d9925136b15c5a6b093c94afcc8d17 Index:1 Removed:false})      {"pid": 9}
2025-02-28T00:38:53.502Z        DEBUG   etherman/etherman.go:600        Processing event: topic:0xd1ec3a1216f08b6eff72e169ceb548b782db18a6614852618d86bb19f3f9b0d3 (VerifyBatchesTrustedAggregator(uint32,uint64,bytes32,bytes32,address)) blockHash:0xe428ae4fefb4ae254aded225cfcd9bc369d9925136b15c5a6b093c94afcc8d17 blockNumber:%!s(uint64=207677005) txHash: 0x9cfbe65517c6b5a3f911a48b89f7cca86b4a55071bb83f10d5e0ca1fc2f1b8a8       {"pid": 9}
2025-02-28T00:38:53.503Z        DEBUG   etherman/etherman.go:659        VerifyBatchesTrustedAggregator(uint32,uint64,bytes32,bytes32,address) event detected: Ignoring...  (event: {Address:0x8B60EE2e16E146e36EB4DE9c5ccaC38A0522Cd21 Topics:[0xd1ec3a1216f08b6eff72e169ceb548b782db18a6614852618d86bb19f3f9b0d3 0x0000000000000000000000000000000000000000000000000000000000000001 0x00000000000000000000000065d79da11c273ce868470a4eaf2019ad0daf5da4] Data:[0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 41 144 253 37 167 108 129 102 162 163 138 113 184 42 248 90 178 250 228 172 8 107 140 69 40 56 194 143 243 26 31 224 205 12 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0] BlockNumber:207677005 TxHash:0x9cfbe65517c6b5a3f911a48b89f7cca86b4a55071bb83f10d5e0ca1fc2f1b8a8 TxIndex:0 BlockHash:0xe428ae4fefb4ae254aded225cfcd9bc369d9925136b15c5a6b093c94afcc8d17 Index:2 Removed:false})    {"pid": 9}
```

**合约相关 event**

zkevm-synchronizer-l1/etherman/etherman_signatures.go:39
```go
signatures = []string{
		"SetBatchFee(uint256)",
		"SetTrustedAggregator(address)",
		"SetVerifyBatchTimeTarget(uint64)",
		"SetMultiplierBatchFee(uint16)",
		"SetPendingStateTimeout(uint64)",
		"SetTrustedAggregatorTimeout(uint64)",
		"OverridePendingState(uint32,uint64,bytes32,bytes32,address)",
		"ProveNonDeterministicPendingState(bytes32,bytes32)",
		"ConsolidatePendingState(uint32,uint64,bytes32,bytes32,uint64)",
		"VerifyBatchesTrustedAggregator(uint32,uint64,bytes32,bytes32,address)",
		"VerifyBatches(uint32,uint64,bytes32,bytes32,address)",
		"OnSequenceBatches(uint32,uint64)",
		"UpdateRollup(uint32,uint32,uint64)",
		"AddExistingRollup(uint32,uint64,address,uint64,uint8,uint64)",
		"CreateNewRollup(uint32,uint32,address,uint64,address)",
		"ObsoleteRollupType(uint32)",
		"AddNewRollupType(uint32,address,address,uint64,uint8,bytes32,string)",
		"AcceptAdminRole(address)",
		"TransferAdminRole(address)",
		"SetForceBatchAddress(address)",
		"SetForceBatchTimeout(uint64)",
		"SetTrustedSequencerURL(string)",
		"SetTrustedSequencer(address)",
		"VerifyBatches(uint64,bytes32,address)",
		"SequenceForceBatches(uint64)",
		"ForceBatch(uint64,bytes32,address,bytes)",
		"SequenceBatches(uint64,bytes32)",
		"InitialSequenceBatches(bytes,bytes32,address)",
		"UpdateEtrogSequence(uint64,bytes,bytes32,address)",
		"Initialized(uint64)",
		"RoleAdminChanged(bytes32,bytes32,bytes32)",
		"RoleGranted(bytes32,address,address)",
		"RoleRevoked(bytes32,address,address)",
		"EmergencyStateActivated()",
		"EmergencyStateDeactivated()",
		"UpdateL1InfoTree(bytes32,bytes32)",
		"UpdateGlobalExitRoot(bytes32,bytes32)",
		"VerifyBatchesTrustedAggregator(uint64,bytes32,address)",
		"OwnershipTransferred(address,address)",
		"UpdateZkEVMVersion(uint64,uint64,string)",
		"ConsolidatePendingState(uint64,bytes32,uint64)",
		"OverridePendingState(uint64,bytes32,address)",
		"SequenceBatches(uint64)",
		"Initialized(uint8)",
		"AdminChanged(address,address)",
		"BeaconUpgraded(address)",
		"Upgraded(address)",
		"RollbackBatches(uint64,bytes32)",
		"SetDataAvailabilityProtocol(address)",
		"UpdateL1InfoTreeV2(bytes32,uint32,uint256,uint64)",
		"InitL1InfoRootMap(uint32,bytes32)",
		"RollbackBatches(uint32,uint64,bytes32)",
	}
```




**查找 sequence 状态 代码**

```
zkevm-synchronizer-l1/state/storage/sqlstorage/sequenced_batches.go 
func (p *SqlStorage) GetSequenceByBatchNumber
```
查询 sql 语句为
```
SELECT from_batch_num, to_batch_num, fork_id, timestamp, block_num, l1_info_root, received_at, source 
FROM sequenced_batches 
WHERE  100 >= from_batch_num  AND 100 <= to_batch_num 
ORDER BY from_batch_num DESC LIMIT 1;
```

db文件配置在 /tmp 目录下，*但没有查到该表*
