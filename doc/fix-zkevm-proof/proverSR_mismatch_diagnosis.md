# zkevm-prover proverSR 不匹配 rpcSR 诊断报告

**日期**: 2026-06-15  
**状态**: 诊断进行中，已定位根因，待实施修复  
**涉及组件**: CDK Aggregator, zkevm-prover, cdk-erigon Sequencer  
**外部 Prover**: `47.85.169.235` (容器名: `real-prover-rc16-fork12`, fork ID: 12)

---

## 一、问题概述

### 核心问题
Prover 生成的证明中的 `proverSR`（State Root）与 L2 链（cdk-erigon RPC）返回的 `rpcSR` 不匹配，导致 L1 合约验证失败（`InvalidProof: 0x09bde339`）。

### 当前状态
- **proverSR**（固定）: `0x4085dad91ac6fc0d589d7118a9c1183c319b533ec33069379133a039e9d69f23`
- **rpcSR**（L2 链）: `0xc24c756faaf1a59f7a84dddc261dbd0dd07b79c7a4d3c8141e96ebc1a25d2b99`
- **proverLER / rpcLER**: 均为 `0x000...000`（匹配）
- **批次**: batch 1（genesis batch，包含初始部署交易）
- **proverSR 确定性**: 每次完全一致（证明生成过程是确定性的）

### 错误表现
- Aggregator 尝试使用 batch 1 的证明进行 settlement
- L1 合约 `verifyBatchesTrustedAggregator` 返回 `InvalidProof (0x09bde339)`
- 循环重试，无进展
- Batches 2-3 的聚合证明持续返回 `COMPLETED_ERROR`

---

## 二、关键发现与线索

### 线索 1: CDK Docker 使用旧版代码（缺少 mismatch 中止逻辑）

**证据**:
```
配置位置: /etc/cdk/cdk-node-config.toml
注释明确说明: "Disable state root sanity check for genesis batch compatibility
              (SMT root in erigon differs from the state root in block header)"
```

**分析**:
- 运行中的 Docker 镜像 (`davidyoung2025/cdk:local`, 构建于 2026-06-12 06:46)
- 日志中**没有** "aborting settlement" 日志
- 当前源码中 `compareFinalProofRootsWithRPC` 函数（提交 `30bf0f9`, 2026-06-04）会检测不匹配并中止 settlement
- **结论**: Docker 镜像使用旧版 `aggregator.go`，`sendFinalProof` 函数中**没有**调用 `compareFinalProofRootsWithRPC`，直接用 `rpcSR` 构建 settlement tx
- **后果**: Settlement 使用 `rpcSR` 但 proof 是用 `proverSR` 生成的，L1 合约拒绝

### 线索 2: Witness SMT root 与 block header state root 不一致（核心根因）

**证据**:
- 配置注释明确指出: "SMT root in erigon differs from the state root in block header"
- `BatchProofSanityCheckEnabled = false`（专门为了绕过此问题而禁用）

**数据流分析**:
```
1. Aggregator 从 sequencer 获取 batch 1 的 witness（类型: "trimmed"）
2. Prover 收到 stateless input → witness2db() 解析 witness
3. witness2db() 从 witness header 中提取 oldStateRoot
   - 位置: zkevm-prover/src/prover/witness.cpp:535-546
   - fea2scalar(fr, stateRoot, hash) → hash 来自 calculateWitnessHash()
   - 这是 witness 中 SMT 的根节点 hash
4. Prover executor 从 oldStateRoot + db（witness 中的状态条目）开始执行
5. Executor 计算 newStateRoot → 进入 publics[19..26] → 生成证明
6. Aggregator 对比:
   - proverSR（来自证明的 publics）: 0x4085dad9...
   - rpcSR（来自 L2 链 batch 1 的 block header）: 0xc24c756f...
   - 不匹配！
```

**根因推断**:
- cdk-erigon 生成 witness 时，SMT（Sparse Merkle Trie）的根节点 hash **不等于** batch 1 结束后的实际 state root
- 可能原因：
  - Genesis state 的 SMT 结构与 erigon 的 state trie 结构有差异
  - Witness 生成过程中 unwind 逻辑（`UnwindForWitness`）改变了状态
  - Trimmed witness 只包含交易中访问的状态，缺少关键条目
- **结果**: Prover 从一个错误的 oldStateRoot 开始执行，计算出不同的 newStateRoot

### 线索 3: 使用 trimmed witness（非 full witness）

**证据**:
```
日志: "Requesting witness for batch X of type trimmed"
配置: UseFullWitness = false（未设置，使用默认值）
```

**影响**:
- Trimmed witness 只包含 ephemerally executed block 中访问的状态条目
- 如果 ephemerally execution 与 prover 执行有差异，witness 可能缺少关键状态
- **但**: 由于 proverSR 每次完全一致，问题可能不在 trimmed vs full，而是 oldStateRoot 本身就错了

### 线索 4: Fork ID 一致（已排除）

- Sequencer: forkid 12
- Prover: fork.12
- ✅ Fork ID 不匹配已排除

### 线索 5: Batch 1 是 genesis batch

- Batch 1 是链上的第一个批次，包含初始合约部署
- 从 genesis state 开始执行
- Genesis state 的 SMT root 可能与 cdk-erigon 的 state root 计算方式不同

### 线索 6: 无法 SSH 到远程 prover

- 提供的 PEM 文件路径 `/Users/xinghao/Desktop/polygon-suite/dayong-op-stack.pem` 是用户本地 Mac 路径
- 本机没有此文件
- `~/.ssh/id_rsa` 也被拒绝（Permission denied）
- **影响**: 无法检查 prover 侧日志（包括 oldStateRoot、newStateRoot、pols.SR[lastN] 的详细值）

---

## 三、问题分层

### 问题 A: Settlement 使用错误的 state root（Docker 版本问题）
- **描述**: 运行中的 CDK Docker 不包含 `compareFinalProofRootsWithRPC` 中止逻辑
- **后果**: 即使 proverSR ≠ rpcSR，settlement 仍会发送（使用 rpcSR），导致 L1 合约拒绝
- **解决**: 重建 CDK Docker 镜像以包含最新代码

### 问题 B: Prover 计算的 newStateRoot 与 L2 链不匹配（核心问题）
- **描述**: Prover 从 witness 提取的 oldStateRoot 不正确，导致 newStateRoot 计算错误
- **根因**: cdk-erigon witness 生成中的 SMT root 与 block header state root 不一致
- **解决**: 需要调查 witness 生成逻辑，可能需要：
  - 切换到 full witness
  - 修复 cdk-erigon 的 witness SMT root 提取
  - 或者让 settlement 使用 proverSR 而非 rpcSR（但这需要确认证明确实正确）

---

## 四、完整数据流追踪

### Batch Proof 生成流程
```
CDK Aggregator
  │
  ├─ getWitness(batchNum, UseFullWitness=false)
  │   └─ cdk-erigon sequencer: zkevm_getBatchWitness → generateWitness()
  │       ├─ ExecuteBlockEphemerallyZk()  → 跟踪状态读取
  │       ├─ BuildWitnessFromTrieDbState() → 生成 trimmed witness
  │       └─ witness header 包含 SMT root（= oldStateRoot）
  │
  └─ gRPC: GenStatelessBatchProof(prover)
      └─ zkevm-prover
          ├─ witness2db(witness, db, programs, oldStateRoot)
          │   └─ 从 witness header 提取 oldStateRoot
          │
          ├─ executor.executeBatch(oldStateRoot, db, batchL2Data)
          │   └─ 执行交易，计算 newStateRoot
          │
          ├─ publics[0..18]  = oldStateRoot, oldAccInputHash, oldBatchNum...
          ├─ publics[19..26] = newStateRoot（来自 cmPols.Main.SR[lastN]）
          └─ batch_proof.json（包含 publics）
```

### Aggregated / Final Proof 流程
```
genAggregatedProof(batch_proof1, batch_proof2)
  ├─ 验证: batch1.newStateRoot == batch2.oldStateRoot
  └─ joinzkin(): newStateRoot 来自 zkin2

genFinalProof(aggregated_proof)
  ├─ 从 recursive proof JSON 的 publics[19..26] 提取 newStateRoot
  ├─ fea2scalar → pProverRequest->input.publicInputsExtended.newStateRoot
  ├─ BUG FIX: pProverRequest->proof.publicInputsExtended = pProverRequest->input.publicInputsExtended
  └─ finalProof.Public.NewStateRoot → gRPC 返回给 aggregator
```

### Aggregator Settlement 流程
```
sendFinalProof()
  ├─ compareFinalProofRootsWithRPC(finalProof, rpcBatch)
  │   ├─ proverSR = hashFromProverPublicInput(finalProof.Public.NewStateRoot)
  │   ├─ rpcSR = rpcBatch.StateRoot()
  │   └─ 如果 proverSR != rpcSR → 返回 error（中止 settlement）
  │
  └─ [旧版代码] 直接构建 inputs.NewStateRoot = rpcBatch.StateRoot().Bytes()
      └─ settleDirect() → L1 verifyBatchesTrustedAggregator
          └─ 合约拒绝: proof 的 newStateRoot ≠ tx 中的 newStateRoot
```

---

## 五、待办事项（To-Do）

### 紧急修复（恢复 settlement）

- [ ] **Task 1**: 重建 CDK Docker 镜像
  - **目的**: 包含最新的 `aggregator_roots.go`（在 proverSR≠rpcSR 时中止 settlement）
  - **步骤**:
    1. 确认本地 cdk 代码是最新的（包含提交 `30bf0f9`）
    2. 执行 `docker build -t davidyoung2025/cdk:local .`（在 cdk/ 目录下）
    3. 重启 cdk-node 容器
  - **预期**: 新的 Docker 会在 roots 不匹配时中止 settlement，避免发送无效证明

### 核心诊断（解决 proverSR 不匹配）

- [ ] **Task 2**: 检查 witness oldStateRoot 与 L2 链 genesis state root
  - **目的**: 确认 oldStateRoot 是否错误
  - **需要 SSH 到远程 prover** 检查日志或保存的文件：
    - `batch_proof.input.json` 中的 `publicInputsExtended.publicInputs.oldStateRoot`
    - Prover 日志: `oldStateRoot=... newStateRoot=... pols.SR[lastN]=...`
  - **对比**: 使用 `eth_getStorageRoot` 或类似 RPC 查询 batch 0 的 state root

- [ ] **Task 3**: 尝试切换到 full witness
  - **目的**: 排除 trimmed witness 缺少状态条目的问题
  - **步骤**:
    1. 修改 `/etc/cdk/cdk-node-config.toml`: `UseFullWitness = true`
    2. 重启 cdk-node
    3. 清除已有证明（让 aggregator 重新生成 batch 1 proof）
    4. 观察新的 proverSR 是否匹配 rpcSR
  - **风险**: Full witness 更大，证明生成时间更长

- [ ] **Task 4**: 调查 cdk-erigon witness 生成逻辑
  - **目的**: 找出 SMT root 与 block header state root 不一致的根因
  - **关键函数**:
    - `cdk-erigon/zk/witness/witness.go:generateWitness()`
    - `cdk-erigon/zk/witness/witness_utils.go:BuildWitnessFromTrieDbState()`
    - `cdk-erigon/smtv2/` 中的 SMT witness 构建
  - **需要检查**:
    - `UnwindForWitness` 对状态的影响
    - Genesis state 的 SMT 初始化逻辑
    - Witness header 中的 root hash 从何而来

### 长期优化

- [ ] **Task 5**: 启用 BatchProofSanityCheck（在修复根因后）
  - **当前**: `BatchProofSanityCheckEnabled = false`
  - **目标**: 修复 witness SMT root 问题后，启用 sanity check

- [ ] **Task 6**: 解决 batches 2-3 聚合证明 COMPLETED_ERROR
  - **当前状态**: 聚合证明持续失败
  - **可能原因**: 与 batch 1 的问题相关（batch 1 的 newStateRoot 错误导致后续聚合失败）

---

## 六、关键代码位置

### CDK Aggregator
- 根比较: `cdk/aggregator/aggregator_roots.go:compareFinalProofRootsWithRPC()` (lines 19-57)
- Settlement 流程: `cdk/aggregator/aggregator.go:sendFinalProof()` (lines 481-539)
- Witness 获取: `cdk/aggregator/aggregator.go:getWitness()` (lines 1384-1403)
- Stateless input: `cdk/aggregator/aggregator.go:getAggregatorInputProver()` (lines 1573-1588)

### zkevm-prover
- witness2db: `zkevm-prover/src/prover/witness.cpp:507-555`
- Batch proof: `zkevm-prover/src/prover/prover.cpp:genBatchProof()` (lines 440-740)
- Final proof: `zkevm-prover/src/prover/prover.cpp:genFinalProof()` (lines 917-1120)
- Stateless proof: `zkevm-prover/src/service/aggregator/aggregator_client.cpp:GenStatelessBatchProof()`

### cdk-erigon
- Witness 生成: `cdk-erigon/zk/witness/witness.go:generateWitness()` (lines 161-285)
- Witness 构建: `cdk-erigon/zk/witness/witness_utils.go:BuildWitnessFromTrieDbState()` (lines 122-174)
- RPC API: `cdk-erigon/turbo/jsonrpc/zkevm_api.go:GetBatchWitness()`

---

## 七、相关配置

### 当前配置（cdk-node-config.toml）
```toml
[Aggregator]
    Port = "50081"
    RetryTime = "30s"
    VerifyProofInterval = "10s"
    GasOffset = 150000
    SettlementBackend = "l1"
    BatchProofSanityCheckEnabled = false  # ← 禁用 sanity check
    # UseFullWitness 未设置 → 默认 false（trimmed witness）
    RPCURL = "http://cdk-erigon-sequencer-1:8123"
    WitnessURL = "http://cdk-erigon-sequencer-1:8123"
```

### Docker 信息
- CDK 镜像: `davidyoung2025/cdk:local`（构建于 2026-06-12 06:46）
- CDK 容器: `cdk-node-1--9397cb0db13e44bda60a238450f16edf`
- Prover 容器: `real-prover-rc16-fork12`（IP: 47.85.169.235）

---

## 八、下一步行动建议

### 立即可做（无需 SSH）
1. **重建 CDK Docker** → 阻止无效 settlement 发送
2. **切换到 full witness** → 测试是否能解决 newStateRoot 不匹配
3. **查看 L2 链的 genesis state root** → 使用 RPC 查询 batch 0 的 state root

### 需要 SSH（如果可能）
1. 检查 prover 日志中的 `oldStateRoot` 和 `newStateRoot`
2. 检查 prover 保存的 `batch_proof.input.json` 和 `batch_proof.output.json`
3. 对比 witness 中的 oldStateRoot 与 L2 链的 genesis state root

### 备选方案
- 如果 full witness 也无法解决，可能需要修改 settlement 逻辑使用 `proverSR` 而非 `rpcSR`
- 但这需要先确认证明的正确性（通过独立验证或通过 L1 合约的 proof 验证）

---

**报告生成时间**: 2026-06-15  
**诊断人员**: AI Assistant  
**状态**: 持续更新中
