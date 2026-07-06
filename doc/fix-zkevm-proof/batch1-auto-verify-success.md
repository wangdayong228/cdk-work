# batch 1 从手动 cast 到自动验证成功的复盘

## 背景

此前 L1 合约在验证 batch 1 的 proof 时一直抛出 `InvalidProof()` (`0x09bde339`)。
当时为了确认 proof 本身没问题，我们用 `cast` 手动把 aggregator 生成的 proof 直接发到 L1 合约，结果交易成功、`lastVerifiedBatch` 更新为 1。
但目标是让**自动部署脚本运行结束后，aggregator 就能自动完成这一步**，不需要手动干预。

## 1. 之前手动发交易的回顾

手动发交易时的做法（详细命令见 [doc-report/manual-batch1-verify-and-keystore-mismatch.md](file:///home/ubuntu/workspace/ydyl-deployment-suite/doc-report/manual-batch1-verify-and-keystore-mismatch.md)）：

1. 从 aggregator 日志里拿到 calldata。
2. 用 agglayer 的私钥构造并签名 raw transaction：
   - `to`: RollupManager 合约
   - `data`: `trustedVerifyBatchesToConsensus(...)` 的编码
   - `from`: agglayer 地址（`0xDE5F...d8673`）
3. 用 `cast publish --raw` 把交易发到 L1 RPC。

之所以必须手动，是因为当时 aggregator 用来签名的 keystore 不是 agglayer keystore，导致：
- `SenderProofToL1Addr` 配置的是 agglayer 地址；
- 但实际签名用的是另一个地址；
- L1 合约只把 `TRUSTED_AGGREGATOR_ROLE` 授给了 agglayer 地址；
- 所以 aggregator 自动发交易时被合约拒绝，出现 `InvalidProof()` 的间接表现（inputSnark 里的 `msg.sender` 不对）。

当时实际执行的命令大致如下（从 aggregator 日志拿到 calldata 后，用 agglayer 私钥签名并发布）：

```bash
PK_AGG=0x74262e55fe39342452c2326cbbed451e0c82111253e75ae7b955a9126f6be35f
TARGET=0xDF9b97b40b90B7fdd2a2EDC5dd7ec7b107C763F5        # 旧 RollupManager
DATA=0x1489ed10...                                        # aggregator 生成的 calldata
NONCE=$(cast nonce $(cast wallet address --private-key $PK_AGG) --rpc-url $RPC)

raw=$(cast mktx $TARGET $DATA \
  --private-key $PK_AGG \
  --rpc-url $RPC \
  --nonce $NONCE \
  --gas-limit 10000000 \
  --legacy)

cast publish $raw --rpc-url $RPC
```

交易成功返回 `status: 0x1`，`lastVerifiedBatch` 更新为 1。

手动发交易绕过了这个签名问题，证明 proof 本身是正确的。

## 2. 这次让 batch 1 自动成功的关键改动

为了让自动部署完成后 batch 1 直接被 aggregator 验证通过，做了两类修改：

### 2.1 kurtosis-cdk 配置：让 aggregator 用 agglayer keystore 签名

- 在 [kurtosis-cdk/cdk_central_environment.star](file:///home/ubuntu/workspace/ydyl-deployment-suite/kurtosis-cdk/cdk_central_environment.star) 里把 `agglayer.keystore` 作为 artifact 返回。
- 在 [kurtosis-cdk/lib/cdk_node.star](file:///home/ubuntu/workspace/ydyl-deployment-suite/kurtosis-cdk/lib/cdk_node.star) 里把 `agglayer` artifact 挂到 cdk-node 容器的 `/etc/cdk/`。
- 在 [kurtosis-cdk/templates/trusted-node/cdk-node-config.toml](file:///home/ubuntu/workspace/ydyl-deployment-suite/kurtosis-cdk/templates/trusted-node/cdk-node-config.toml) 里设置：
  - `AggregatorPrivateKeyPath = "/etc/cdk/agglayer.keystore"`
  - `SenderProofToL1Addr = agglayer 地址`

这样 aggregator 提交 L1 验证交易时，签名地址与 L1 合约授权的地址一致。

### 2.2 cdk_pipe.sh：自动构建包含 aggregator 修复的 cdk-node 镜像

之前 `cdk_pipe.sh` 没有自动构建 cdk-node 镜像的逻辑，部署时用的是旧的 `davidyoung2025/cdk:local` 镜像，里面没有 aggregator 的最新修复。

在 [cdk_pipe.sh](file:///home/ubuntu/workspace/ydyl-deployment-suite/cdk_pipe.sh) 中新增了 `ensure_cdk_node_image()`：

- 当 cdk 子模块有未提交修改、或镜像不存在、或源码提交时间晚于镜像创建时间时，自动 `make build-docker` 并 `docker tag cdk davidyoung2025/cdk:local`。
- 同时保留并清理了 `ensure_cdk_erigon_image()`，避免 cdk-erigon 镜像也落后。

这样每次运行 `./cdk_pipe.sh` 都会把本地 aggregator 的修复打进镜像。

## 3. 验证证据

本次自动部署完成后：

- RollupManager: `0x4D6FD98a43f841cC1d7C36A7702209866132337A`
- L1 VerifyBatches 事件出现在 block `7064391`
- 交易哈希：`0x92e9d362e3e821d79d4ed26d0c8aa69aca0df0ad6be35de1082fc0735044cf03`
- 交易发送方：`0xDE5F8eDBdABc5Ad61Cf7De0c10E1a37BEC5d8673`
- 交易状态：`status = 1`（成功）
- `lastVerifiedBatch = 1`
- cdk-node 配置中的 `SenderProofToL1Addr = 0xDE5F8eDBdABc5Ad61Cf7De0c10E1a37BEC5d8673`，与交易发送方一致

cdk-node 日志中的 VerifyBatches 事件片段：

```
VerifyBatches event ... NumBatch: 1, StateRoot: 0x938004036428a4a65d9b62e2f2adf0dcd1e8121fca0781ff20095e2c1f99034b,
ExitRoot: 0x0000..., Aggregator: 0xDE5F8eDBdABc5Ad61Cf7De0c10E1a37BEC5d8673
```

这说明 batch 1 确实是由 aggregator 自动提交并被 L1 合约接受的，没有再出现 `InvalidProof()`。

## 4. batch 2 / batch 3 的连续自动验证

在 batch 1 自动成功后，重新部署并观察 batch 2/3：

- RollupManager: `0x800F5648420d96c412F909Ed7A395B54Cef6FB7B`
- 重新部署后约 6 分钟，`getLastVerifiedBatch(1)` 从 `0` 变为 `1`（batch 1 自动成功）
- 再过约 8 分钟，`getLastVerifiedBatch(1)` 从 `1` 变为 `3`（batch 2 + batch 3 自动成功）

`cdk-node` 日志片段：

```
Batch proof generated ... batch: 1, proofId: "d92d037c-..."
L1 accInputHash is zero for batch 2 (not the final batch of its sequence), using locally computed value: 0xb33592dc...
Sending a batch to the prover. ... batch: 2
Batch proof generated ... batch: 2, proofId: "1473d8c2-..."
Recursive proof 2-2 not eligible to be verified: not containing complete sequences
Sending a batch to the prover. ... batch: 3
Batch proof generated ... batch: 3, proofId: "08e320dd-..."
```

L1 合约最终 `lastVerifiedBatch = 3`，说明 batch 2 和 batch 3 也被自动验证通过。

### 4.1 让 batch 2/3 能连续验证的额外修复

连续验证失败的根本原因是：L1 合约的 `sequencedBatches` 只保存每个 sequence 最后一个 batch 的 `accInputHash`，中间 batch 返回 `0x0`。原版 aggregator 从 L1 读取 `accInputHash` 后，对中间 batch 会拿到零值并跳过本地计算，导致下一 batch 找不到上一 batch 的 `accInputHash`。

在 [cdk/aggregator/aggregator.go](file:///home/ubuntu/workspace/ydyl-deployment-suite/cdk/aggregator/aggregator.go) 中加入回退逻辑：

- 先从 L1 读 `accInputHash`；
- 如果返回零值，说明当前 batch 不是所在 sequence 的最后一个 batch，用 `cdkcommon.CalculateAccInputHash(...)` 本地计算；
- 把结果写进内存 `accInputHash` 缓存，保证下一 batch 的 `oldAccInputHash` 链不中断。

关键日志即上面的 `L1 accInputHash is zero for batch 2 ... using locally computed value`。

### 4.2 重新部署后避免重复构建 cdk-erigon 镜像

`cdk_pipe.sh` 里的 `ensure_cdk_erigon_image()` / `ensure_cdk_node_image()` 之前只要本地有未提交修改就会强制重新构建。由于 `cdk-erigon` 本地经常带有未提交的实验性改动，每次重新部署都重新构建它非常慢。

调整判断顺序后：只要本地 Docker 镜像的创建时间不早于源码最新提交时间，即使存在未提交改动也不再重新构建；只有当镜像确实比源码旧时才会构建。

这样在本次重新部署时，`cdk-erigon` 镜像没有重复构建，只重新构建了 `cdk-node` 镜像，显著加快了迭代。

## 5. 持续产生 L2 交易的脚本

为了让 sequencer 持续关闭 batch、驱动更多 proof，新增了脚本：

[cdk-work/scripts/send-l2-txs.sh](file:///home/ubuntu/workspace/ydyl-deployment-suite/cdk-work/scripts/send-l2-txs.sh)

基本用法：

```bash
cd /home/ubuntu/workspace/ydyl-deployment-suite
./cdk-work/scripts/send-l2-txs.sh
```

脚本会：

- 从 `output/cdk_pipe.state` 读取 `L2_RPC_URL` 和 `L2_PRIVATE_KEY`；
- 默认每 30 秒向 `0xdead` 发送 `1 wei`；
- 可通过环境变量调整：

```bash
INTERVAL=10 AMOUNT=0.001ether COUNT=100 ./cdk-work/scripts/send-l2-txs.sh
```

当前部署中 sequencer 已经关闭到 batch 46（这些 batch 来自之前的 L2 交易和部署步骤），即使不额外发交易，prover 也会自动继续验证。若希望更快产生新 batch，可以运行该脚本。

## 6. 结论

- batch 1 自动验证成功：核心原因是 aggregator 使用 agglayer keystore 签名，且 `cdk_pipe.sh` 自动把修复构建进镜像；
- batch 2 / batch 3 也连续自动验证成功：核心原因是对 L1 只保存 sequence 末尾 `accInputHash` 的特性做了本地回退计算；
- 新增 `send-l2-txs.sh` 用于在需要时持续制造 L2 交易；
- 自动部署脚本现在可以在无人工干预的情况下，使 zkEVM L2 正常工作。
