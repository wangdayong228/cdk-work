# real-proof 上链失败备忘

cdk-node原始日志：[real-proof-tx-fail.log](./real-proof-tx-fail.log)
zkevm-prover日志：[zkevm-prover-ok.log](./zkevm-prover-ok.log)

## 问题

real-prover 已为 batch **11** 生成 batch proof（链下 state root / acc input hash sanity check 通过），并组装 **batch 1–1** 的 final proof。`cdk-node` aggregator 在 `settleDirect` 向 L1 提交验证交易时，于 `eth_estimateGas` 阶段 revert，未真正发链。

- 日志关键字：`Verifying final proof with ethereum smart contract` → `Error Adding TX to ethTxManager` → `execution reverted: InvalidProof()`（`0x09bde339`）
- 拟验证区间：上一已验证 batch **0** → 本笔 **1**（`initNumBatch=0`, `finalNewBatch=1`）
- 同期链上 `Last Verified Batch Number: 0`；日志另有 batch 11 与 verified 0 不连续的 debug，属并行证明队列，与本次 estimate 失败交易（1–1）并存

详见 [real-proof-tx-fail.log](./real-proof-tx-fail.log) 约 L40–L50。

## 合约与方法

- 合约：`PolygonRollupManager` `0x3A4ae1ba5155e049F2aD330a224F4DC78ed1326d`
- 方法：`verifyBatchesTrustedAggregator`（selector `0x1489ed10`）
- 发送方：`0xfb6a4D81c92e5AD6511d153d61CA3a94Cb31099a`

## calldata 解码（estimate 失败交易）

| 参数 | 值 |
|------|-----|
| rollupID | 1 |
| pendingStateNum | 0 |
| initNumBatch | 0 |
| finalNewBatch | 1 |
| newLocalExitRoot | `0x0` |
| newStateRoot | `0xd3b7248f48f6cf645ab4b990cd7d8932ca2d1c3b68317211b7daed0762c2680a` |
| beneficiary | `0xfb6a4D81c92e5AD6511d153d61CA3a94Cb31099a` |
| proof | `bytes32[24]` |

## 可能原因

L1 验证器认为 Groth16 证明无效：calldata 中 `newStateRoot` / `newLocalExitRoot` 与 proof 内 public input 不一致，或 verifier / fork 与 real-prover 不匹配。

## 疑点

`zkevm_getBatchByNumber(1)` 的 `localExitRoot`、`mainnetExitRoot`、`rollupExitRoot` 均为 0，但 batch 有交易且 `stateRoot` 非零；aggregator 上链 LER 来自该 RPC，需与 prover final proof 对照。

## 排查步骤
这是一个典型的**多层依赖、难以定位根因**的调试问题。我帮你建立一个系统性的拆解框架。

### 核心思路：构建"验证链"，从最末端向上逐层排查

```
cdk-erigon 产出数据
       ↓
   Prover 消费数据 → 生成 Proof
       ↓
   合约验证 Proof
```

任何一层出问题都会导致最终验证失败，但**错误只在最末端可见**。所以要反向拆解。

---

### 第一步：先隔离"版本匹配"问题（最快排除）

这是成本最低的检查，先做完再说别的。

| 检查项 | 方法 |
|---|---|
| Prover 版本 vs 合约版本 | 找 PolygonRollupManager 部署时绑定的 verifier 合约地址，对应哪个 proof system 版本 |
| Prover 版本 vs cdk-erigon 版本 | 查官方的 compatibility matrix，两者是否在同一个 release 组合里 |
| vk（verification key）是否一致 | 合约里存的 vk hash，和你 prover 用的 vk，是否完全一致 |

**最小验证方式**：拿一个官方已知可以验证通过的 proof（e2e 测试 fixture），直接扔进合约调用，看能不能过。能过 → 合约和 vk 没问题，问题在你生成的 proof。

---

### 第二步：隔离 Proof 本身的有效性

**不依赖你的链上数据**，先验证 prover 本身工作正常。

```
用 prover 的 test mode / mock input 生成一个 proof
→ 本地用 snarkjs 或 prover 自带 verify 工具验证
→ 再调合约验证
```

- 如果本地 verify 过、合约也过 → prover 没问题，问题在**输入数据**
- 如果本地 verify 过、合约不过 → **public inputs 的编码/格式**有问题
- 如果本地 verify 都不过 → prover 版本或 vk 有问题

---

### 第三步：隔离 Public Inputs 的正确性

这是最容易出问题、也最难定位的地方。zkEVM proof 的 public inputs 通常包含：

```
oldStateRoot / newStateRoot
oldAccInputHash / newAccInputHash
oldNumBatch / finalNewBatch
chainID / forkID
```

**关键：合约验证时自己会重新计算 inputHash，和你提交的对比**

所以你需要：

```
1. 把合约里 _computeInputSnark 或类似函数的逻辑抠出来
2. 用你的数据在链下重新算一遍 inputHash
3. 和 prover 实际用的 inputHash 比对
```

如果两者不一致，再进一步看是哪个字段错了。

---

### 第四步：隔离 cdk-erigon 数据的正确性

cdk-erigon 提供给 prover 的关键数据：

- `batchL2Data`（交易数据）
- `witness` / `executor` 的执行 trace
- state roots

**最小化测试方法**：

```
取一个极简 batch（比如只有 1 笔转账或甚至空 batch）
→ 手动构造或从 erigon 拿到这个 batch 的完整输入
→ 单独跑 prover executor 阶段（不跑完整 prove）
→ 验证 executor 输出的 newStateRoot 和链上一致
```

把 batch 做到最小，任何数据异常都会变得明显。

---

### 给你一个排查优先级

```
① vk / 版本匹配          ← 10分钟能确认，先排掉
② 用已知fixture验合约     ← 确认合约本身没问题
③ prover 自验 proof       ← 确认 prover 工作正常
④ public inputs 重算比对  ← 最可能的根因
⑤ erigon 数据逐字段比对   ← 如果④发现不一致再往上追
```

---

### 一个实用建议

把每一层的**输入/输出固定下来存成文件**，每次复现问题时用同一份数据。这样你改了任何一层，都能精确知道是哪一层的变化导致了结果变化。相当于给每层建一个"快照测试"。
