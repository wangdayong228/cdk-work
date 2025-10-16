# Trusted Batch 和 Virtual Batch Number 的关系和区别

## 概述

在 zkEVM 系统中，批次处理是一个多阶段的过程，涉及到不同类型的批次状态。本文档详细解释了 Trusted Batch 和 Virtual Batch Number 之间的关系和区别。

## 1. Virtual Batch（虚拟批次）

### 定义和特征

- **Virtual Batch** 是从 L1 上的 sequenced batch（已排序批次）中获取的批次
- 它们是已经在 L1 上被排序但还未被验证的批次
- Virtual Batch 包含实际的 L2 交易数据

### 代码结构

```go
type VirtualBatch struct {
    BatchNumber             uint64        // 批次号
    ForkID                  uint64        // 分叉ID
    BatchL2Data             []byte        // L2交易数据
    VlogTxHash              common.Hash   // L1交易哈希
    Coinbase                common.Address // 矿工地址
    SequencerAddr           common.Address // 排序器地址
    SequenceFromBatchNumber uint64        // 关联的sequenced batch号
    BlockNumber             uint64        // L1区块号
    L1InfoRoot              *common.Hash  // L1信息根
    ReceivedAt              time.Time     // 接收时间
    BatchTimestamp          *time.Time    // 批次时间戳
}
```

### Virtual Batch Number 的含义

- `zkevm_virtualBatchNumber` 返回最新的虚拟批次号
- 它表示下一个需要被零知识证明验证的批次
- 这个数字代表已经被排序但还未被验证的最新批次

## 2. Trusted Batch（可信批次）

### 定义和特征

- **Trusted Batch** 是通过 Trusted Aggregator（可信聚合器）验证的批次
- 它们是已经通过零知识证明验证并在 L1 上确认的批次
- Trusted Batch 代表网络的最终确认状态

### 验证流程

```solidity
function verifyBatchesTrustedAggregator(
    uint64 pendingStateNum,
    uint64 initNumBatch,
    uint64 finalNewBatch,
    bytes32 newLocalExitRoot,
    bytes32 newStateRoot,
    bytes32[24] calldata proof
) external onlyTrustedAggregator
```

### 关键组件

- **Trusted Aggregator**: 具有特殊权限的验证者角色
- **Zero-Knowledge Proof**: 用于验证批次正确性的密码学证明
- **State Root**: 批次执行后的状态根哈希
- **Exit Root**: 用于跨链操作的退出根

## 3. 三种批次状态的关系

在 zkEVM 系统中，批次有三种主要状态：

### 1. Trusted Batch（可信批次） - `zkevm_batchNumber`
- 已经被排序器处理的批次
- 包含实际的交易数据
- 但还未提交到 L1

### 2. Virtual Batch（虚拟批次） - `zkevm_virtualBatchNumber`
- 已经在 L1 上被排序的批次
- 等待零知识证明验证
- 数据已经在 L1 上可用

### 3. Verified Batch（已验证批次） - `zkevm_verifiedBatchNumber`
- 已经通过零知识证明验证的批次
- 在 L1 上最终确认
- 代表网络的最终状态

## 4. 数据流向

```
L2 交易 → Trusted Batch → Virtual Batch → Verified Batch
         (排序器处理)   (L1排序)     (ZK证明验证)
```

### 详细流程说明

1. **交易收集阶段**: L2 交易被排序器收集和处理
2. **批次创建阶段**: 排序器将交易打包成 Trusted Batch
3. **L1 提交阶段**: 批次数据被提交到 L1，成为 Virtual Batch
4. **证明生成阶段**: 为 Virtual Batch 生成零知识证明
5. **最终验证阶段**: 通过 Trusted Aggregator 验证并确认为 Verified Batch

## 5. 关键区别总结

| 特征 | Trusted Batch | Virtual Batch |
|------|---------------|---------------|
| **位置** | L2 排序器 | L1 合约 |
| **状态** | 已处理，未提交 | 已排序，未验证 |
| **数据可用性** | 仅在 L2 | 在 L1 上可用 |
| **验证状态** | 未验证 | 等待 ZK 证明 |
| **最终性** | 临时的 | 接近最终 |
| **回滚风险** | 较高 | 较低 |
| **查询方式** | `zkevm_batchNumber` | `zkevm_virtualBatchNumber` |

## 6. Virtual Batch Number 不增长的问题诊断

### 可能原因

如果 `zkevm_virtualBatchNumber` 不再增长，可能的原因包括：

#### 1. L1 排序过程停止
- 批次没有被提交到 L1
- 排序器服务异常
- L1 网络连接问题

#### 2. DataStream 服务器问题
- 无法获取最新的排序批次
- DataStream 服务器宕机或超时
- 缓存数据过期

#### 3. 同步问题
- L1 同步器无法正常工作
- 区块同步延迟
- 网络分区或连接中断

#### 4. 资源不足
- 系统资源不足导致处理停止
- 内存或存储空间不足
- CPU 资源耗尽

#### 5. 批次关闭逻辑问题
- 批次未正确关闭
- 批次关闭条件未满足
- 批次状态检查逻辑错误

### 诊断步骤

1. **检查 DataStream 服务器状态**
   ```bash
   # 检查 DataStream 服务器连接
   curl -X POST -H "Content-Type: application/json" --data '{"method":"zkevm_virtualBatchNumber","params":[],"id":1,"jsonrpc":"2.0"}' http://sequencer:8545
   ```

2. **检查批次处理日志**
   ```bash
   # 查看排序器日志
   kurtosis service logs cdk-cfx cdk-node-001 --follow=false | grep -i batch
   ```

3. **检查 L1 同步状态**
   ```bash
   # 检查 L1 同步器状态
   kurtosis service logs cdk-cfx zkevm-synchronizer-l1-001 --follow=false | tail -50
   ```

4. **检查资源使用情况**
   ```bash
   # 检查系统资源
   kurtosis enclave inspect cdk-cfx
   ```

## 7. 相关代码位置

### Virtual Batch 相关代码
- `zkevm-synchronizer-l1/state/entities/virtual_batch.go` - Virtual Batch 结构定义
- `cdk-erigon/turbo/jsonrpc/zkevm_api.go` - API 接口实现
- `zkevm-synchronizer-l1/state/storage/*/virtual_batch.go` - 存储层实现

### Trusted Batch 相关代码
- `cdk/etherman/aggregator.go` - Trusted Aggregator 实现
- `agglayer-contracts/contracts/PolygonZkEVM.sol` - 智能合约实现
- `cdk/aggregator/aggregator.go` - 聚合器逻辑

### 批次处理相关代码
- `cdk/sequencesender/sequencesender.go` - 批次发送逻辑
- `cdk-erigon/zk/datastream/server/data_stream_server.go` - DataStream 服务器
- `zkevm-synchronizer-l1/synchronizer/synchronizer.go` - 同步器实现

## 8. 监控和告警建议

### 关键指标监控
1. **批次号差异监控**
   - `trusted_batch_number - virtual_batch_number` 的差值
   - 差值过大时触发告警

2. **批次处理速度监控**
   - 每分钟处理的批次数量
   - 处理速度异常时告警

3. **DataStream 服务健康检查**
   - 定期检查 DataStream 服务可用性
   - 响应时间监控

4. **资源使用率监控**
   - CPU、内存、存储使用率
   - 资源不足时提前告警

### 告警规则示例
```yaml
# Prometheus 告警规则示例
groups:
  - name: zkevm_batch_monitoring
    rules:
      - alert: VirtualBatchNumberNotIncreasing
        expr: increase(zkevm_virtual_batch_number[5m]) == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Virtual batch number has not increased for 5 minutes"
          
      - alert: BatchNumberGapTooLarge
        expr: zkevm_batch_number - zkevm_virtual_batch_number > 100
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Gap between trusted and virtual batch numbers is too large"
```

## 总结

理解 Trusted Batch 和 Virtual Batch Number 的区别对于诊断 zkEVM 网络问题至关重要。Virtual Batch Number 不增长通常表明批次从 L2 到 L1 的提交过程出现了问题，需要从多个角度进行排查和修复。通过适当的监控和告警机制，可以及时发现并解决此类问题，确保网络的正常运行。 