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
