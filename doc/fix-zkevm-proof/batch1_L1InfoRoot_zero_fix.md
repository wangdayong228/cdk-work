# Batch 1 InvalidProof 修复：L1InfoRoot 零值问题

## 问题现象

应用上一次修复（删除 `buildInputProver` 中 batch 1 的 `forcedBlockhashL1` 和 `l1InfoRoot` 覆盖）并重新部署后，aggregator 提交 proof 到 L1 时仍然收到 `InvalidProof (0x09bde339)` 错误：

```
ERROR aggregator/aggregator.go:632 Error Adding TX to ethTxManager: failed to estimate gas: execution reverted: revert:  (0x09bde339)
```

日志显示发送给 prover 的参数中 `L1InfoRoot` 仍然为全零：

```
DEBUG aggregator/aggregator.go:1592 L1InfoRoot: 0x0000000000000000000000000000000000000000000000000000000000000000
INFO  aggregator/aggregator.go:1333 Sending a batch to the prover. OldAccInputHash [0x00...00], L1InfoRoot [0x00...00]
```

## 根因分析

### L1InfoRoot 的来源

Aggregator 的 `tryGetBatchToVerify` 函数从 L1 同步数据库中获取 batch 信息：

1. **virtual_batch 表** — 由 L1 syncer 同步，包含 `l1_info_root` 字段（允许 NULL）
2. **sequenced_batches 表** — 包含 SequenceBatches 事件的完整数据，包括 `l1_info_root`

### 问题代码

`cdk/aggregator/aggregator.go` 第 1209-1214 行：

```go
l1InfoRoot := common.Hash{}

if virtualBatch.L1InfoRoot == nil {
    log.Debugf("L1InfoRoot is nil for batch %d", batchNumberToVerify)
    virtualBatch.L1InfoRoot = &l1InfoRoot  // 设为零值！
}
```

当 `virtual_batch.l1_info_root` 为 NULL 时，代码将 `L1InfoRoot` 设为零值 `0x0000...0000`。

### 为什么 virtual_batch.l1_info_root 为 NULL

L1 syncer 在同步 SequenceBatches 事件并存储到 `virtual_batch` 表时，未能正确提取和存储 `l1_info_root` 字段。这导致 batch 1 的 `l1_info_root` 为 NULL。

验证方法：

```bash
docker exec cdk-node-1 sqlite3 /tmp/aggregator_sync_db.sqlite \
  "SELECT batch_num, l1_info_root FROM virtual_batch WHERE batch_num = 1;"
# 输出: 1| (NULL)

docker exec cdk-node-1 sqlite3 /tmp/aggregator_sync_db.sqlite \
  "SELECT from_batch_num, to_batch_num, l1_info_root FROM sequenced_batches WHERE from_batch_num <= 1;"
# 输出: 1|1|0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5
```

`sequenced_batches` 表有正确的 `l1_info_root` 值：`0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5`

### 为什么导致 InvalidProof

L1 上的 FFLONK verifier 验证 proof 时，会验证 `newAccInputHash`。而 `accInputHash` 的计算依赖于 `L1InfoRoot`：

```
accInputHash = keccak256(oldAccInputHash || batchL2Data || l1InfoRoot || timestamp || coinbase || forcedBlockhashL1)
```

Prover 使用 `L1InfoRoot = 0x00...00` 计算出的 `accInputHash` 与 L1 上使用正确 `L1InfoRoot` 计算的 `accInputHash` 不匹配，导致验证失败。

## 修复方案

### 代码修复

修改 `cdk/aggregator/aggregator.go`，当 `virtualBatch.L1InfoRoot` 为 nil 时，从 `sequence.L1InfoRoot`（`sequenced_batches` 表）回退读取：

```go
// 修改前
l1InfoRoot := common.Hash{}

if virtualBatch.L1InfoRoot == nil {
    log.Debugf("L1InfoRoot is nil for batch %d", batchNumberToVerify)
    virtualBatch.L1InfoRoot = &l1InfoRoot
}

// 修改后
if virtualBatch.L1InfoRoot == nil {
    log.Warnf("L1InfoRoot is nil for batch %d, falling back to sequence L1InfoRoot", batchNumberToVerify)
    seqL1InfoRoot := sequence.L1InfoRoot
    virtualBatch.L1InfoRoot = &seqL1InfoRoot
}
```

### 修改的文件

- `cdk/aggregator/aggregator.go` — `tryGetBatchToVerify` 函数

### 编译和部署

```bash
source /home/ubuntu/.ydyl-env
cd cdk
go build -o /tmp/cdk-node ./cmd/

# 复制到容器
docker cp /tmp/cdk-node <container>:/usr/local/bin/cdk-node

# 清理旧 proof
docker exec <container> sqlite3 /tmp/aggregator_db.sqlite "DELETE FROM proof WHERE batch_num = 1;"

# 重启
docker restart <container>
```

## 修复验证

修复后日志显示正确的 L1InfoRoot：

```
DEBUG aggregator/aggregator.go:1235 L1InfoRoot: 0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5
INFO  aggregator/aggregator.go:1332 Sending a batch to the prover. OldAccInputHash [0x00...00], L1InfoRoot [0xad3228b6...]
DEBUG aggregator/aggregator.go:1591 L1InfoRoot: 0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5
```

## 待解决问题

1. **Syncer bug**：为什么 `zkevm-synchronizer-l1` 在同步 SequenceBatches 事件时没有将 `l1_info_root` 存储到 `virtual_batch` 表？这需要排查 syncer 中 Banana fork 的 `sequence_batches_decode` 逻辑。

2. **长期修复**：修复 syncer 的数据同步逻辑，确保 `l1_info_root` 被正确存储到 `virtual_batch` 表，而不是依赖 aggregator 的回退逻辑。
