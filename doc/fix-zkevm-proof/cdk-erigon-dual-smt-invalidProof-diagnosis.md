# 诊断报告：cdk-erigon 双 SMT 架构与 oldStateRoot 不匹配导致 InvalidProof

## 问题描述

L1 FFLONK verifier 合约持续验证失败（`InvalidProof`，事件 `0x09bde339`）。通过诊断脚本 `compare-invalidproof.py` 确认：

| 数据项 | L1 合约值 | Prover proof 值 | 状态 |
|--------|-----------|-----------------|------|
| oldStateRoot | `0x8b4b0276...` | `0x76ed8327...` | **不匹配** |
| newStateRoot | `0x0000...`（待验证） | `0x7306...` | L1 尚未验证 |
| newAccInputHash | `0x3365f587...` | `0x3365f587...` | 已匹配 |

**核心问题**：Prover 计算的 oldStateRoot 与 L1 合约 batchNumToStateRoot[1] 中存储的值不一致，导致 212 字节 inputSnark 取模后的结果不匹配验证器预期值。

---

## 根因分析：cdk-erigon 双 SMT 架构

### 双轨设计

cdk-erigon 同时维护两套 SMT（Sparse Merkle Tree）：

| 特性 | OLD SMT | smtv2 |
|------|---------|-------|
| 代码路径 | `smt/pkg/smt/` | `smtv2/` |
| 数据库表 | `HermezSmt`, `HermezSmtStats`, `HermezSmtHashKey`, `HermezSmtAccountValues`, `HermezSmtMetadata` | `HermezSmtIntermediateHashes` |
| 读写接口 | `EriDb`（通过 `NewSMT(eridb, false)`） | 独立的 smtv2 实现 |
| 被谁使用 | **zkevm-prover 的 witness 构建器** | Sequencer block header stateRoot |
| `OnlySmtV2` 影响 | 默认 `true` 时 InterHashes Stage 跳过维护 | 始终维护 |

### 缺陷：Sequencer 只维护 smtv2，不维护 OLD SMT

**问题代码位置**：`zk/stages/stage_sequence_execute_blocks.go:finaliseBlock()`

```go
// 原代码（只维护 smtv2）
} else {
    newRoot, err = zkIncrementIntermediateHashes_v2_Forwards(...)
    // ← 没有调用 zkIncrementIntermediateHashes 来维护 OLD SMT
}
```

**连锁反应**：

1. **Sequencer** 出块时，`finaliseBlock()` 只调用 `zkIncrementIntermediateHashes_v2_Forwards` 计算 smtv2 root（写入 `HermezSmtIntermediateHashes` 表）。
2. **InterHashes Stage** 在 sequencer 模式下是 no-op（`stage_sequencer_interhashes.go:20`："This stages does NOTHING while going forward, because its done during execution"）。
3. **OLD SMT 表**（`HermezSmt` 等）在整个 sequencer 生命周期中**从未被写入**。
4. **zkevm-prover** 连接 sequencer/RPC，构建 witness 时始终读取 OLD SMT：
   ```go
   // zk/witness/witness_utils.go:166-169
   eridb := db2.NewRoEriDb(tx)
   smtTrie := smt.NewRoSMT(eridb)   // ← 始终使用 OLD SMT
   witness, err = smtTrie.BuildWitness(rl, ctx)
   ```
5. Prover 从空的或过时的 OLD SMT 表计算 oldStateRoot → **与 sequencer 的 smtv2 root 不一致** → inputSnark 哈希错误 → L1 验证失败。

### Genesis SMT 不持久化

**问题代码位置**：`core/genesis_write.go:619-620`

```go
sparseDb := eridb.NewMemDb()   // ← 内存数据库
sparseTree := smt.NewSMT(sparseDb, false)
```

Genesis 的 SMT 构建在 `MemDb`（内存）中，`GenesisToBlock()` 的 goroutine 结束后 MemDb 被销毁，**从未持久化到 HermezSmt 表**。新的 enclave 部署后 OLD SMT 表为空，直到 sequencer 开始出块——而出块也不维护 OLD SMT。

### RPC/sync 节点：`OnlySmtV2` 默认值为 true

**问题代码位置**：`cmd/utils/flags.go:989-993`

```go
OnlySmtV2 = cli.BoolFlag{
    Name:  "zkevm.only-smt-v2",
    Usage: "Only use SMT v2 for state changes",
    Value: true,    // ← 默认 true
}
```

`OnlySmtV2=true` 时，InterHashes Stage（RPC/sync 节点使用）跳过 OLD SMT 维护：
```go
// stage_interhashes.go:163
if cfg.zk.OnlySmtV2 {
    // 只运行 smtv2
    if root, err = zkIncrementIntermediateHashes_v2_Forwards(...); err != nil {
        return trie.EmptyRoot, err
    }
} else {
    // 同时运行 OLD SMT 和 smtv2
    if root, err = zkIncrementIntermediateHashes(...); err != nil {
        return trie.EmptyRoot, err
    }
    root2, err := zkIncrementIntermediateHashes_v2_Forwards(...)
}
```

RPC/sync 节点也不维护 OLD SMT，如果 prover 连接 RPC 而非 sequencer，同样会得到错误的 witness。

### 关键代码路径汇总

| 组件 | 入口 | 是否维护 smtv2 | 是否维护 OLD SMT |
|------|------|:-:|:-:|
| Sequencer finaliseBlock | `stage_sequence_execute_blocks.go:215` | ✅ | ❌（修复前） |
| Sequencer InterHashes Stage | `stage_sequencer_interhashes.go:20` | no-op | no-op |
| RPC/sync InterHashes Stage | `stage_interhashes.go:163-180` | ✅ | ❌（`OnlySmtV2=true`） |
| Genesis 初始化 | `genesis_write.go:619-620` | MemDb（不持久化） | MemDb（不持久化） |
| Witness 构建 | `witness_utils.go:166-169` | 不读 | 始终读 OLD SMT |
| Prover | 使用 witness | — | 从 OLD SMT 计算 stateRoot |

---

## 修复方案

### 修复 1：Sequencer finaliseBlock 同时维护 OLD SMT

**文件**：`cdk-erigon/zk/stages/stage_sequence_execute_blocks.go`（约 L212-228）

**改动**：在 smtv2 计算之后，增加 OLD SMT 的增量维护调用。

```go
} else {
    log.Info(fmt.Sprintf("[%s] [SR-DEBUG] IncrementIntermediateHashes for the SMT", batchContext.s.LogPrefix()), "startingBlock", newHeader.Number.Uint64()-1, "endingBlock", newHeader.Number.Uint64())
    commitmentToLog = "smt"
    newRoot, err = zkIncrementIntermediateHashes_v2_Forwards(batchContext.ctx, batchContext.cfg.dirs.Tmp, batchContext.s.LogPrefix(), batchContext.s, batchContext.sdb.tx, newHeader.Number.Uint64()-1, newHeader.Number.Uint64())

    // Also maintain the OLD SMT (HermezSmt tables) so that witness generation
    // produces correct oldStateRoot values. The prover's witness builder reads
    // from OLD SMT tables (HermezSmt/HermezSmtStats), and without this the
    // prover computes wrong state roots causing InvalidProof on L1.
    oldFrom := newHeader.Number.Uint64() - 1
    oldTo := newHeader.Number.Uint64()
    oldRoot, oldErr := zkIncrementIntermediateHashes(batchContext.ctx, batchContext.s.LogPrefix(), batchContext.s, batchContext.sdb.tx, batchContext.sdb.eridb, batchContext.sdb.smt, oldFrom, oldTo)
    if oldErr != nil {
        log.Warn(fmt.Sprintf("[%s] OLD SMT increment failed (non-fatal, continuing with smtv2 root)", batchContext.s.LogPrefix()), "err", oldErr)
    } else if oldRoot != newRoot {
        log.Warn(fmt.Sprintf("[%s] OLD SMT root differs from smtv2 root", batchContext.s.LogPrefix()), "oldSmt", oldRoot, "smtv2", newRoot, "block", oldTo)
    }
}
```

**原理**：`zkIncrementIntermediateHashes` 从 AccountChangeSet 读取状态变更，通过 `batchContext.sdb.eridb` 和 `batchContext.sdb.smt` 写入 OLD SMT 表（`HermezSmt` 等）。`stageDb` 结构在 `SetTx()` 中已初始化好 `eridb` 和 `smt` 实例（`stage_sequence_execute_utils_db.go:38-44`），可直接使用。

**容错设计**：
- OLD SMT 写入失败为 non-fatal（只打 Warn 日志），不影响 sequencer 出块（smtv2 root 是权威值）。
- 如果 OLD SMT root 与 smtv2 root 不一致，打印 Warn 日志便于诊断。

### 修复 2：`OnlySmtV2` 默认值改为 false

**文件**：`cdk-erigon/cmd/utils/flags.go`（L989-993）

**改动**：`Value: true` → `Value: false`

```go
OnlySmtV2 = cli.BoolFlag{
    Name:  "zkevm.only-smt-v2",
    Usage: "Only use SMT v2 for state changes",
    Value: false,   // ← 改为 false
}
```

**原理**：
- Sequencer 不受此标志影响（InterHashes Stage 在 sequencer 模式下是 no-op）。
- RPC/sync 节点使用标准的 InterHashes Stage，`OnlySmtV2=false` 时会同时维护 OLD SMT 和 smtv2（`stage_interhashes.go:163-180` 的 else 分支）。
- 如果 prover 连接 RPC 节点，RPC 的 OLD SMT 表也是正确的。

### 关于 Genesis SMT 持久化

**未做显式修改**。原因分析：

1. `zkIncrementIntermediateHashes` 从 AccountChangeSet 读取 block 0（genesis）的状态变更。
2. Genesis 写入时 `WriteGenesisState()` 通过 `CommitBlock()` + `WriteChangeSets()` 将所有 genesis allocs 写入 AccountChangeSet 表。
3. Sequencer 处理 block 1 时，`finaliseBlock` 调用 `zkIncrementIntermediateHashes(from=0, to=1)`，会从 genesis changeset 读取所有 allocs 并写入 OLD SMT。
4. `ProcessAccount`（genesis 用）和 `SetStorage`（increment 用）使用相同的 SMT 底层操作，对同一组账户产生相同的 root。

因此 OLD SMT 会在 sequencer 出第一个 block 时自动从 genesis changeset 重建，无需额外持久化步骤。

---

## 修复效果预期

修复部署后，`compare-invalidproof.py` 应显示：

| 数据项 | 预期 |
|--------|------|
| oldStateRoot | Prover == L1 合约 ✅ |
| newAccInputHash | Prover == L1 合约 ✅（已修复） |
| newStateRoot | 随 L1 验证更新 |

---

## 涉及文件

| 文件 | 修改类型 |
|------|---------|
| `cdk-erigon/zk/stages/stage_sequence_execute_blocks.go` | 新增代码（finaliseBlock 维护 OLD SMT） |
| `cdk-erigon/cmd/utils/flags.go` | 修改默认值（OnlySmtV2: true → false） |
| `cdk-work/scripts/check-proof-status.py` | 重写（自动发现容器和合约参数） |
| `cdk-work/scripts/compare-invalidproof.py` | 增强（自动发现容器和合约参数） |

## 相关模块

| 模块 | 路径 | 作用 |
|------|------|------|
| OLD SMT | `cdk-erigon/smt/pkg/smt/` | Witness 构建读取的 SMT 实现 |
| smtv2 | `cdk-erigon/smtv2/` | Sequencer 用于 block header stateRoot |
| EriDb | `cdk-erigon/smt/pkg/db/mdbx.go` | OLD SMT 的数据库接口，读写 HermezSmt 表 |
| MemDb | `cdk-erigon/smt/pkg/db/mem-db.go` | 内存 SMT 数据库，genesis 用 |
| InterHashes Stage | `cdk-erigon/zk/stages/stage_interhashes.go` | 标准 InterHashes 阶段 |
| Sequencer InterHashes | `cdk-erigon/zk/stages/stage_sequencer_interhashes.go` | Sequencer 专用（forward 是 no-op） |
| Witness 构建 | `cdk-erigon/zk/witness/witness_utils.go` | 始终使用 OLD SMT |
