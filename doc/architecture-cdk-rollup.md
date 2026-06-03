# 当前 CDK-Work 部署 CDK Rollup 架构图（Erigon Sequencer + Mock Prover + L1 直连）

## 架构总览

```mermaid
flowchart TB
    subgraph L1["L1 (外部链: Conflux eSpace)"]
        subgraph L1C["L1 合约"]
            rollupMgr["PolygonRollupManager"]
            rollup["PolygonZkEVM<br/>(Rollup)"]
            ger["PolygonZkEVM<br/>GlobalExitRoot"]
            bridgeL1["PolygonZkEVMBridge<br/>(L1 Bridge)"]
            verifier["Mock Verifier"]
        end
    end

    subgraph L2["CDK L2 (Kurtosis Enclave: cdk-gen)"]
        subgraph Core["核心组件"]
            sequencer["cdk-erigon-sequencer-1<br/>────────────────<br/>交易排序/出块<br/>内部执行交易<br/>内部 txpool<br/>rpc:8123 ws:8133<br/>datastream:6900"]
            rpc["cdk-erigon-rpc-1<br/>────────────────<br/>只读 RPC 节点<br/>提供 witness 数据<br/>rpc:8123 ws:8133"]
            cdknode["cdk-node-1<br/>────────────────<br/>Aggregator(聚合器)<br/>AggSender(序列提交)<br/>aggregator:50081<br/>rpc:5576 rest:5577"]
            prover["zkevm-prover-1<br/>────────────────<br/>executor:50071<br/>hash-db:50061<br/>(aggregatorClient<br/> 连 cdk-node)"]
            poolmgr["zkevm-pool-manager-1<br/>────────────────<br/>交易池管理<br/>http:8545"]
            bridgesvc["zkevm-bridge-service-1<br/>────────────────<br/>跨链桥中继<br/>grpc:9090 rpc:8080"]
        end

        subgraph Infra["基础设施"]
            postgres[("postgres-1<br/>────────────────<br/>共享数据库 :5432<br/>aggregator_db<br/>bridge_db<br/>prover_db<br/>erigon_state")]
            monitor["grafana-1 :3000<br/>prometheus-1 :9090<br/>panoptichain-1 :9090<br/>status-checker-1"]
        end
    end

    %% ===== Sequencer 连接 =====
    sequencer -->|"读 L1 状态<br/>zkevm.l1-rpc-url"| L1C
    sequencer -->|"datastream :6900<br/>实时同步区块/批次"| rpc
    sequencer -->|":5432<br/>erigon_state"| postgres

    %% ===== RPC 节点连接 =====
    rpc -->|":8545<br/>pool-manager-url<br/>转发 eth_sendRawTransaction"| poolmgr
    rpc -->|":5432<br/>读状态"| postgres

    %% ===== Pool Manager =====
    poolmgr -->|"txpool 协调"| sequencer
    poolmgr -->|":5432"| postgres

    %% ===== CDK Node (Aggregator) =====
    cdknode -->|":8123 HTTP<br/>WitnessURL<br/>zkevm_getWitness"| rpc
    cdknode -->|"提交 proof + sequence<br/>SettlementBackend=l1"| L1C
    cdknode -->|":5432<br/>aggregator_db"| postgres

    %% ===== Prover =====
    prover -->|"aggregatorClient gRPC<br/>连接 :50081<br/>(方向: prover → cdk-node)"| cdknode
    prover -->|":5432<br/>prover_db (SMT)"| postgres

    %% ===== Bridge Service =====
    bridgesvc -->|"监听 L1 桥合约事件"| L1C
    bridgesvc -->|":8123 HTTP<br/>监听 L2 桥合约事件"| rpc
    bridgesvc -->|":5432<br/>bridge_db"| postgres

    %% ===== 监控 =====
    monitor -.->|"采集 metrics"| Core
```

## 数据流（交易 → 区块 → 证明 → L1 结算）

```mermaid
sequenceDiagram
    actor User as 用户
    participant RPC as cdk-erigon-rpc-1<br/>(:8123)
    participant Pool as zkevm-pool-manager-1<br/>(:8545)
    participant Seq as cdk-erigon-sequencer-1
    participant Node as cdk-node-1<br/>(Aggregator :50081)
    participant Prover as zkevm-prover-1
    participant L1 as L1 合约

    Note over Seq: erigon_strict_mode=false<br/>内部执行交易<br/>不连外部 executor

    rect rgb(240, 248, 255)
        Note over User,Pool: 阶段1 — 交易提交
        User->>RPC: eth_sendRawTransaction
        RPC->>Pool: 转发交易 (pool-manager-url)
        Pool->>Seq: txpool 协调
    end

    rect rgb(255, 248, 240)
        Note over Seq,RPC: 阶段2 — 出块与同步
        Seq->>Seq: 排序交易 → 内部执行 → 出块 → 封批次
        Seq-->>RPC: datastream :6900 推送新区块/批次
        RPC->>RPC: 存储区块, 对外提供 RPC 查询
    end

    rect rgb(240, 255, 240)
        Note over Prover,Node: 阶段3 — 证明生成
        Prover->>Node: 建立 gRPC 连接 (aggregatorClient → :50081)
        Node->>RPC: zkevm_getWitness(batchNumber)
        RPC-->>Node: witness 数据
        Node->>Prover: BatchProof 请求
        Note over Prover: mock proof<br/>(aggregatorClientMockTimeout=1μs)
        Prover-->>Node: 递归证明
        Node->>Prover: AggregatedProof 请求
        Prover-->>Node: 聚合证明
        Node->>Prover: FinalProof 请求
        Prover-->>Node: 最终证明
    end

    rect rgb(248, 240, 255)
        Note over Node,L1: 阶段4 — L1 结算
        Node->>L1: sequenceBatches()
        Node->>L1: verifyBatches(proof)
        Note over L1: Mock Verifier 验证通过<br/>Trusted → Virtual → Verified
    end
```

## 端口连接矩阵

```mermaid
flowchart LR
    SEQ("cdk-erigon<br/>-sequencer-1")
    RPC2("cdk-erigon<br/>-rpc-1")
    NODE("cdk-node-1")
    PROVER2("zkevm-prover-1")
    BRIDGE("zkevm-bridge<br/>-service-1")

    L1T["L1 RPC<br/>(外部)"]
    PG[("postgres-1<br/>:5432")]
    RPC3("cdk-erigon-rpc-1<br/>:8123")
    NODE2("cdk-node-1<br/>:50081")
    POOL("zkevm-pool<br/>-manager-1 :8545")

    SEQ --"datastream :6900"--> RPC3
    SEQ --"读 L1 状态"--> L1T
    SEQ --"erigon_state"--> PG
    RPC2 --"sendRawTransaction"--> POOL
    RPC2 --"读状态"--> PG
    NODE --"WitnessURL :8123"--> RPC3
    NODE --"提交 proof + sequence"--> L1T
    NODE --"aggregator_db"--> PG
    PROVER2 --"aggregatorClient :50081"--> NODE2
    PROVER2 --"prover_db"--> PG
    BRIDGE --"监听 L1 桥事件"--> L1T
    BRIDGE --"监听 L2 桥事件 :8123"--> RPC3
    BRIDGE --"bridge_db"--> PG
```

## 配置差异（当前 vs 标准 ZK Rollup）

```mermaid
flowchart LR
    subgraph Current["当前配置 (params.template.yml)"]
        C1["deploy_agglayer: false<br/>→ L1 直连结算"]
        C2["deploy_l1: false<br/>→ 使用外部 L1"]
        C3["erigon_strict_mode: false<br/>→ sequencer 不连 executor"]
        C4["zkevm_use_real_verifier: false<br/>→ mock proof"]
        C5["deploy_optimism_rollup: false<br/>→ 不部署 OP Stack"]
    end

    subgraph Standard["标准 ZK Rollup (rollup.yml)"]
        S1["deploy_agglayer: true<br/>→ Agglayer 结算"]
        S2["deploy_l1: true<br/>→ 部署本地 L1"]
        S3["erigon_strict_mode: true<br/>→ sequencer 连 executor"]
        S4["zkevm_use_real_verifier: false<br/>→ mock proof (相同)"]
        S5["deploy_optimism_rollup: true<br/>→ CDK + OP Stack"]
    end

    Current --- Standard
```

## 验证清单

每条连接的配置来源均可追溯：

| # | 连接 | 配置来源 | 文件:行号 |
|---|------|---------|-----------|
| 1 | sequencer → L1 (读状态) | `zkevm.l1-rpc-url` | `cdk-erigon/config.yml:452` |
| 2 | sequencer → rpc (datastream) | `zkevm.data-stream-port` | `cdk-erigon/config.yml:229-233` |
| 3 | sequencer 不连 executor | `zkevm.executor-urls` 在 `{{if .erigon_strict_mode}}` 内 | `cdk-erigon/config.yml:360-367` |
| 4 | rpc → pool-manager (转发tx) | `zkevm.pool-manager-url` 仅非sequencer | `cdk-erigon/config.yml:182-187` |
| 5 | cdk-node → rpc (witness) | `WitnessURL` | `cdk-node-config.toml:33` |
| 6 | cdk-node → L1 (结算) | `SettlementBackend` + `L1URL` | `cdk-node-config.toml:2,59` |
| 7 | cdk-node → L1 直连原因 | `deploy_agglayer=false` → `settlement_backend="l1"` | `cdk_central_environment.star:51-53` |
| 8 | prover → cdk-node (client) | `aggregatorClientHost:Port` | `prover-config.json:151-155` |
| 9 | cdk-node ← prover (server) | `[Aggregator] Port` | `cdk-node-config.toml:55` |
| 10 | prover mock 模式 | `runAggregatorClientMock:true` | `prover-config.json:84` |
| 11 | prover → postgres | `databaseURL` | `prover-config.json:178` |
| 12 | cdk-node → postgres | `[Aggregator.DB]` | `cdk-node-config.toml:60-67` |

---

# zkevm-prover 架构详解

## 概念：Prover 在做什么

zkEVM rollup 的核心安全问题：**L2 交易在链下执行，L1 怎么相信结果是正确的？**

Prover 的工作就是生成一个**零知识证明**，证明「这批 L2 交易按 zkEVM 规则执行后得到的状态根是正确的」。L1 上的 Verifier 合约验证证明，通过才接受。**不需要信任 L2 节点，只信任数学。**

```
L2 交易批次 ——→ zkevm-prover ——→ ZK Proof ——→ L1 Verifier 合约验证
                   ▲
                   │
              cdk-node (aggregator)
              编排者：决定什么时候、为哪个 batch 生成证明
```

## 证明管线：Stark → Circom → Groth16

一次完整的 batch 证明经过**三级流水线**：

```
BatchProof               AggregatedProof           FinalProof
(Stark)                  (Circom 递归)             (Groth16)

witness ──→ Stark ──→ Aggregated ──→ Final ──→ L1 verify
            proof        proof         proof       (链上验)
            ~2MB         ~2MB          ~1KB
```

Stark 证明体积大但生成快，Groth16 证明极小（~1KB，适合上链）但需要超大电路。所以流程是先生成 Stark 证明，再用 Circom 电路递归压缩成聚合证明，最后用 Groth16 生成可在链上验证的最终证明。

## 总览

`zkevm-prover` 是一个 C++ 单二进制项目（产物 `zkProver`），通过 JSON 配置中的 4 个 `run*` 开关控制启动哪些 gRPC 服务。**单 prover 和多 prover 配置完全相同**，区别仅在于 `proverName` 不同，cdk-node 通过 DB 的 `GeneratingSince` 时间戳锁分配任务给空闲 prover。

```
                    ┌──────────────────────────────────┐
                    │        zkProver 进程              │
                    │                                   │
runExecutorServer   │  :50071  cdk-node/erigon 调用，    │
                    │          执行 batch → 生成 Stark    │
                    │          证明                      │
                    │                                   │
runHashDBServer     │  :50061  SMT/Hash 查询服务          │
                    │          (erigon/cdk-node 调用)     │
                    │                                   │
runAggregatorClient │  连接 cdk-node aggregator :50081   │
                    │  接收聚合/最终证明任务               │
                    │  (prover → cdk-node，主动连接)       │
                    │                                   │
runAggregatorServer │  :50081  独立 aggregator 服务        │
                    │  仅开发/测试用，生产默认 false       │
                    └──────────────────────────────────┘
```

**关键设计**：prover 通过 `runAggregatorClient` **主动连接** cdk-node 的 aggregator（而非 cdk-node 连接 prover）。cdk-node 的 aggregator 作为 gRPC server 接受 prover 连接，通过双向流分发证明任务。这是一种**拉取模型**（pull model）。

声明在 `src/config/config.hpp:17-31`，默认值在 `src/config/config.cpp:118-125`：

| 标志 | 代码默认值 | Kurtosis 模板值 | 作用 | 源文件:行号 |
|------|----------|----------------|------|-----------|
| `runExecutorServer` | `true` | `true` | 启动 Executor gRPC **服务端**（被 erigon/cdk-node 调用） | `config.hpp:17`, `config.cpp:118` |
| `runHashDBServer` | `true` | `true` | 启动 HashDB gRPC **服务端**（提供 SMT 状态） | `config.hpp:20`, `config.cpp:121` |
| `runAggregatorClient` | `false` | `{{.zkevm_use_real_prover_client}}` | 启动聚合器 gRPC **客户端**（连接 cdk-node，生成真实证明） | `config.hpp:23`, `config.cpp:124` |
| `runAggregatorClientMock` | `false` | `{{.zkevm_use_mock_prover_client}}` | 启动 mock 聚合器客户端（生成假证明） | `config.hpp:24`, `config.cpp:125` |
| `runAggregatorServer` | `false` | `false` | 启动聚合器 gRPC **服务端**（**仅开发调试用**，生产不用） | `config.hpp:22`, `config.cpp:123` |

> **注意**：代码默认值 `runAggregatorClient=false` 不代表生产配置。Kurtosis 部署时通过模板变量决定用 `runAggregatorClient`（真实 prover）还是 `runAggregatorClientMock`（mock prover）。生产环境必开其一。

## PROVER_CONSTRUCTOR 初始化流程

`Prover` 对象构造时依次加载多项式常量、构建 Merkle Tree，这是启动最耗时的阶段：

```
PROVER_CONSTRUCTOR
│
├─ 1. LOAD_STARK_INFO         加载 starkInfo (元数据/常量配置)
│
├─ 2. Starks::Starks()        加载 zkEVM 多项式常量
│   ├─ LOAD_CONST_POLS          mmap zkevm.const
│   │                           (fork.12: ~58.5GB, mapConstPolsFile=true 时毫秒级)
│   │
│   ├─ CALCULATE_CONST_TREE     构建常量 Merkle Tree
│   │   ├─ EXTEND_CONST_POLS      NTT 多项式扩展 (degree N → NExtended)
│   │   │                         (CPU 密集，fork.12 约 10-15 分钟)
│   │   └─ MERKELIZE_CONST_TREE   Merkle 树构建 (大量 Hash，CPU 密集)
│   │
│   └─ LOAD_CONST_TREE          mmap zkevm.constantsTree (如有预计算文件可跳过上一步)
│
├─ 3. Stark 递归证明器         加载递归证明多项式 (c12a.const, c12b.const...)
│
├─ 4. Final 证明器             加载 Groth16 电路 (bls12381, BN128, zkey + vkey)
│
└─ ✅ PROVER_CONSTRUCTOR 完成 → 启动 gRPC servers
```

用 `mapConstPolsFile=false`（默认）时，`LOAD_CONST_POLS` 会通过 `loadFileParallel()` 8 线程 fread 全量拷贝 ~58.5GB 数据，导致 `PROVER_CONSTRUCTOR` 总计耗时 ~2700s。设为 `true` 后 mmap 虚拟映射只需毫秒级（0.000058s），但 `EXTEND_CONST_POLS` 和 `MERKELIZE_CONST_TREE` 仍然是 CPU 密集型计算（fork.12 约 10-20 分钟）。

## 单 Prover vs 多 Prover

**配置完全相同**。每个 prover 都独立运行 `runExecutorServer` + `runHashDBServer` + `runAggregatorClient`，都连接到同一个 cdk-node aggregator。

```
prover-1 ──AggregatorClient──→ cdk-node:50081 (aggregator)
prover-2 ──AggregatorClient──→ cdk-node:50081
prover-3 ──AggregatorClient──→ cdk-node:50081
```

cdk-node 通过 prover db 中 `GeneratingSince` 时间戳锁分配任务：取最早 `GeneratingSince`（最久空闲）的 prover 干活，prover 进锁时设当前时间戳。这就是 `getAndLockBatchToProve()`（`aggregator.go:1073`）的机制。

`runAggregatorServer` 仅在开发调试时启用，用于在不启动完整 cdk-node 的情况下单独测试 aggregator 服务。生产部署中始终为 `false`。

## Executor（端口 50071）

**gRPC 服务端**，暴露 `ExecutorService`（`src/grpc/proto/executor.proto:9`）：

```protobuf
service ExecutorService {
    rpc ProcessBatch(ProcessBatchRequest) returns (ProcessBatchResponse);
    rpc ProcessBatchV2(ProcessBatchRequestV2) returns (ProcessBatchResponseV2);
    rpc ProcessStatelessBatchV2(ProcessStatelessBatchRequestV2) returns (ProcessBatchResponseV2);
}
```

**作用**：接收一批 L2 交易作为输入，通过 14 个内部状态机（Main SM、Storage SM、Keccak-f SM 等）运行 zkEVM ROM，计算：
- 结果状态根（state root）
- Gas 消耗
- 交易回执
- 执行 trace（多项式承诺）

**执行器不生成任何 ZK 证明**。它是纯计算引擎——EVM 级别的交易执行。证明由 Stark → Circom 流水线在 executor 产出 trace 之后另行生成。

**谁调用它**：cdk-node 的 sequencer 组件，在出块时为每个待处理的交易调用 `ProcessBatch()` 做 gas 估算和状态计算。端口默认 `50071`，配置项 `executorServerPort`（`config.hpp:75`, `config.cpp:184`）。

**HashDB 依赖**：Executor 执行时需要读写 Sparse Merkle Tree 状态。通过 `hashDBURL` 决定访问方式（`config.hpp:85`, `config.cpp:192`，默认 `"local"`）：
- `"local"` → 进程内直接调用 HashDB 类（性能最优）
- `"host:port"` → 通过 gRPC 远程访问（独立部署场景）

## HashDB / StateDB（端口 50061）

**gRPC 服务端**，暴露 `HashDBService`（`src/grpc/proto/hashdb.proto:23`），提供：
- `Set/Get`：读写 SMT 节点（账户状态：余额、nonce、存储槽）
- `SetProgram/GetProgram`：存储/读取合约字节码（以 `hash(bytecode)` 索引）
- `LoadDB`：加载输入数据库（批次开始前）
- `Flush`：刷新脏数据到持久化存储（批次结束后）
- `GetLatestStateRoot`、`StartBlock`、`FinishBlock` 等

**后端存储**由 `databaseURL` 配置决定（`config.hpp:175`, `config.cpp:278`）：
- `"local"` → 内存 SQLite（默认，stateless 模式）
- `"postgresql://..."` → 外部 PostgreSQL（有状态模式）

**配置项**（均在 `src/config/config.hpp` / `config.cpp`）：

| 配置 | 默认值 | 说明 | 源文件:行号 |
|------|-------|------|-----------|
| `dbMTCacheSize` | 8GB | Merkle Tree 节点缓存 | `config.cpp:167` |
| `dbProgramCacheSize` | 1GB | 合约字节码缓存 | `config.cpp:181` |
| `maxHashDBThreads` | 8 | gRPC 线程池上限 | `config.cpp:302` |
| `stateManager` | `true` | 批次间状态合并，避免写入膨胀 | `config.cpp:293` |

## AggregatorClient

**关键设计：这是一个 gRPC 客户端，不是服务端。** 它连接到在 cdk-node 内部运行的 aggregator 服务器（端口 50081）。

通信协议（`src/grpc/proto/aggregator.proto:17`）：

```protobuf
service AggregatorService {
    rpc Channel(stream ProverMessage) returns (stream AggregatorMessage);
}
```

这是一个**双向流（bidirectional stream）**，遵循**拉取模型（pull model）**：
1. AggregatorClient **主动**连接到 `aggregatorClientHost:aggregatorClientPort`
2. cdk-node 的 aggregator 通过这个流发送证明请求
3. prover 算完后通过同一个流回传结果

配置字段（声明 `config.hpp:90-95`，默认值 `config.cpp:195-199`）：

| 配置 | 默认值 | 说明 | 源文件:行号 |
|------|-------|------|-----------|
| `aggregatorClientHost` | `"127.0.0.1"` | cdk-node aggregator 的**单个**主机名 | `config.cpp:196` |
| `aggregatorClientPort` | `50081` | aggregator 端口 | `config.cpp:195` |
| `aggregatorClientMaxStreams` | `0`（无限制） | 并发双向流数 | `config.cpp:199` |
| `aggregatorClientWatchdogTimeout` | 60s | 连接空闲超时 | `config.cpp:198` |

**重要限制**：`aggregatorClientHost` 是单一 `string` 而非数组，一个 prover 进程只能连接**一个** cdk-node aggregator。多链场景下每链需要独立的 prover 进程（每进程一台机器，见下方[多链共享分析](#多链共享分析)）。

## 与外部系统交互——两条独立通道

```
cdk-erigon-sequencer ──gRPC──→ Executor (:50071)
    ProcessBatch() 执行交易、估算 gas、计算状态根
    批次构建阶段，不涉及证明

AggregatorClient (prover) ──gRPC:50081──→ cdk-node aggregator (Go)
    双向流 Channel() 发送证明请求
    cdk-node 的 aggregator 负责：
    1. 监控 L1 上需要证明的批次
    2. 向 prover 请求 GenBatchProof
    3. 聚合多个批次 → GenAggregatedProof
    4. 生成最终 Groth16 证明 → GenFinalProof
    5. 调用 L1 PolygonZkEVM 合约提交证明
```

> 注：erigon 模式下，sequencer 在 `cdk-erigon` 中（非 `cdk-node`）。`cdk-node` 内置 aggregator（通过 `--components=...,aggregator` 启用），是证明流程的**编排器**，prover 是**工作节点**。

## Aggregator 内部流程（Batch → Proof → L1 结算）

cdk-node 的 aggregator 是一个单线程串行循环，通过 gRPC 双向流驱动 prover：

```
cdk-node 启动
  │
  └─ Start() [aggregator.go:299]
       │
       ├─ l1Syncr.Sync(true) [go:301]                  同步 L1 历史数据
       ├─ go l1Syncr.Sync(false) [go:308]              后台持续同步 L1
       ├─ GetLatestVerifiedBatchNum() [go:329]         找到 L1 上最后 verified 的 batch
       └─ go sendFinalProof() [go:353] ──────────────────────────────────────┐
            │                                                                 │
            │  ← 后台 goroutine，阻塞等 finalProof channel                     │
            │                                                                 │
            └─ gRPC Serve() [go:358] → Channel(stream) [go:398]               │
                 │  ← 每个 prover 一个 stream                                  │
                 │                                                             │
                 └── 主循环 (go:398-472, 死循环永不退出) ───────────────┐      │
                      │                                                   │      │
                 ┌────┘                                                   │      │
                 │                                                        │      │
                 ▼                                                        │      │
            ① IsIdle() [go:437]                                           │      │
               │                                                          │      │
               ├─ busy → sleep(RetryTime) [go:468] → 回到 ①              │      │
               │                                                          │      │
               └─ idle ↓                                                  │      │
                                                                           │      │
            ② tryBuildFinalProof(prover, nil) [go:451→676]                 │      │
               │                                                          │      │
               ├─ 没 ready proof → 跳过                                    │      │
               │                                                          │      │
               └─ 有 ready proof ↓                                        │      │
                    │                                                     │      │
                    ├─ canVerifyProof() [go:687→1424]                     │      │
                    │   └─ 时间窗口没到 → 跳过                              │      │
                    │                                                     │      │
                    └─ 时间到了 ↓                                          │      │
                         │                                                │      │
                         ├─ buildFinalProof() [go:739→628]                │      │
                         │    ├─ prover.FinalProof() [go:638]             │      │
                         │    ├─ prover.WaitFinalProof() [go:647]         │      │
                         │    └─ finalProof <- msg [go:756] ─────────────→│      │
                         │                                                │      │
                         └─ resetVerifyProofTime() [go:523→1447]          │      │
                                                                           │      │
            ③ tryAggregateProofs(prover) [go:456→909]                      │      │
               │                                                          │      │
               ├─ 没 2 个待聚合 proof → 跳过                               │      │
               │                                                          │      │
               └─ 有 ↓                                                    │      │
                    │                                                     │      │
                    ├─ prover.AggregatedProof() [go:970]                  │      │
                    └─ prover.WaitRecursiveProof() [go:982]               │      │
                                                                           │      │
            ④ tryGenerateBatchProof(prover) [go:462→1267]                  │      │
               │  ← 仅当 ③ 没干活                                          │      │
               │                                                          │      │
               ├─ 没新 batch 需要验证 → 跳过                               │      │
               │                                                          │      │
               └─ 有新 batch ↓                                            │      │
                    │                                                     │      │
                    ├─ getAndLockBatchToProve() [go:1276→1073]            │      │
                    │  │                                                  │      │
                    │  ├─ GetLatestVerifiedBatchNum() [go:1089]           │      │
                    │  ├─ 递增 batchNum，跳过已有 proof [go:1098-1122]    │      │
                    │  ├─ GetSequenceByBatchNumber() [go:1125]            │      │
                    │  │   └─ 没同步到 → ✋ 卡住                            │      │
                    │  ├─ GetVirtualBatchByBatchNumber() [go:1151]        │      │
                    │  ├─ rpcClient.GetBatch() [go:1162]                  │      │
                    │  └─ CalculateAccInputHash() [go:1204]               │      │
                    │                                                     │      │
                    ├─ getWitness() [go:1287→1371]                        │      │
                    │   └─ rpcClient.GetWitness() 重试循环 [go:1371-1389] │      │
                    ├─ buildInputProver() [go:1309→1453]                  │      │
                    ├─ prover.BatchProof() [go:1319]                      │      │
                    ├─ prover.WaitRecursiveProof() [go:1330]              │      │
                    ├─ performSanityChecks() [go:1340→1393]               │      │
                    │   └─ mismatch → HALTING (goroutine 死循环)           │      │
                    └─ tryBuildFinalProof(prover, proof) [go:1348]        │      │
                         └─ 同上 ②                                         │      │
                                                                           │      │
            ⑤ 有产出 → continue [go:470]（立刻下一轮循环）                  │      │
               没产出 → sleep(RetryTime) [go:468] → 回到 ①                 │      │
                                                                           │      │
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╲╌│
                                                                           │    │
sendFinalProof() ── 后台 goroutine [aggregator.go:481]                      │    │
  │                                                                        │    │
  ├─ <- finalProof channel [go:486]              收到 ②/④ 发来的 msg       │    │
  ├─ startProofVerification() [go:495]             上锁                      │    │
  ├─ rpcClient.GetBatch() [go:498]                 拿 final batch 的实际值   │    │
  │                                                                        │    │
  ├─ switch SettlementBackend [go:511]:                                     │    │
  │    │                                                                   │    │
  │    ├─ L1 (默认):                                                        │    │
  │    │    └─ settleDirect() [go:517→580]                                 │    │
  │    │         ├─ BuildTrustedVerifyBatchesTxData() [go:586]             │    │
  │    │         ├─ ethTxManager.Add() [go:596]                            │    │
  │    │         └─ handleMonitoredTxResult() [go:607→1630]                │    │
  │    │              ├─ success → DeleteGeneratedProofs() [go:1656]       │    │
  │    │              └─ failed  → FATAL (os.Exit) [go:1633]              │    │
  │    │                                                                   │    │
  │    └─ AggLayer:                                                        │    │
  │         └─ settleWithAggLayer() [go:513→528]                           │    │
  │              ├─ sign tx [go:544]                                       │    │
  │              ├─ aggLayerClient.SendTx() [go:554]                       │    │
  │              └─ aggLayerClient.WaitTxToBeMined() [go:569]              │    │
  │                                                                        │    │
  ├─ resetVerifyProofTime() [go:522→1447]                                    │    │
  └─ endProofVerification() [go:523→1440]          → 解锁 → 等下一个 msg    │    │
```

**主循环调用优先级**：FinalProof（已有 proof 直接提交）> AggregatedProof（合并两个 proof）> BatchProof（对新 batch 发起证明）。每轮只执行一项，成功后立即进入下一轮不 sleep。

**日志关键字**（按流程顺序）：

| 阶段 | 日志 |
|------|------|
| 初始化 | `"Last Verified Batch Number:%v"` |
| prover 连接 | `"Establishing stream connection with prover"` |
| prover 空闲检查 | `"Prover is not idle"` |
| 发起 batch proof | `"Sending a batch to the prover..."` |
| batch proof 完成 | `"Batch proof generated"` |
| 发起聚合 | `"Aggregating proofs: %d-%d and %d-%d"` |
| 聚合完成 | `"Aggregated proof generated"` |
| 发起 final proof | `"Final proof ID for batches [%d-%d]: %s"` |
| 构建 final proof 完成 | `"tryBuildFinalProof end"` |
| mock 识别 | `"Recursive proof does not contain state root. Possibly mock prover is in use."` |
| sequence 未同步 | `"Sequencing event for batch %d has not been synced yet..."` |
| virtual 未同步 | `"Virtual batch %d has not been synced yet..."` |
| 提交 L1 | `"Verifying final proof with ethereum smart contract"` |
| HALT | `"HALTING: State root from the proof does not match..."` |
| HALT | `"HALTING: Acc input hash from the proof does not match..."` |

## cdk-node 的 prove 相关日志
```log
[cdk-node-1] 2026-05-20T08:08:48.992Z	DEBUG	aggregator/aggregator.go:685	tryBuildFinalProof start	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:08:48.992Z	DEBUG	aggregator/aggregator.go:691	Send final proof time reached	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:08:48.996Z	INFO	aggregator/aggregator.go:644	Final proof ID for batches [240-241]: 6be8b970-28da-48ba-b4ea-378693e1cd0a	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "recursiveProofId": "6beefb2a-3bea-47a9-ac1b-d2d58f0d6964", "batches": "240-241"}
[cdk-node-1] 2026-05-20T08:08:49.056Z	WARN	aggregator/aggregator.go:662	NewLocalExitRoot and NewStateRoot look like a mock values, using values from executor instead: LER: 000000..000000, SR: b95041..cb75d4	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "recursiveProofId": "6beefb2a-3bea-47a9-ac1b-d2d58f0d6964", "batches": "240-241", "finalProofId": "6be8b970-28da-48ba-b4ea-378693e1cd0a"}
[cdk-node-1] github.com/0xPolygon/cdk/aggregator.(*Aggregator).buildFinalProof
[cdk-node-1] 	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:662
[cdk-node-1] github.com/0xPolygon/cdk/aggregator.(*Aggregator).tryBuildFinalProof
[cdk-node-1] 	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:739
[cdk-node-1] github.com/0xPolygon/cdk/aggregator.(*Aggregator).Channel
[cdk-node-1] 	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:451
[cdk-node-1] github.com/0xPolygon/cdk/aggregator/prover._AggregatorService_Channel_Handler
[cdk-node-1] 	/go/src/github.com/0xPolygon/cdk/aggregator/prover/aggregator_grpc.pb.go:109
[cdk-node-1] 2026-05-20T08:08:49.056Z	DEBUG	aggregator/aggregator.go:759	tryBuildFinalProof end	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "proofId": "6beefb2a-3bea-47a9-ac1b-d2d58f0d6964", "batches": "240-241"}
[cdk-node-1] 2026-05-20T08:08:49.056Z	DEBUG	aggregator/aggregator.go:918	tryAggregateProofs start	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:08:49.056Z	INFO	aggregator/aggregator.go:493	Verifying final proof with ethereum smart contract	{"pid": 9, "version": "e6765ad", "module": "aggregator", "proofId": "6be8b970-28da-48ba-b4ea-378693e1cd0a", "batches": "240-241"}
[cdk-node-1] 2026-05-20T08:08:49.057Z	DEBUG	aggregator/aggregator.go:923	Nothing to aggregate	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:08:49.057Z	DEBUG	aggregator/aggregator.go:1273	tryGenerateBatchProof start	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	common/common.go:92	OldAccInputHash: 0x39623d7c4342c0f3b19f9b220de511cf533c72c1c4954a46638ac24c1b0b1b91	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	common/common.go:93	BatchHashData: bea4a0cd17ead07d3c4e59f8396e120c8bce9e452c14c3eebc340fb32681bf86	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	common/common.go:94	L1InfoRoot: 0xe406a72bf8c00a771648f8ff944fe7f38a966b03444501720847c7f86c1fbfb7	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	common/common.go:95	TimeStampLimit: 1779250392	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	common/common.go:96	Sequencer Address: 0xa609eC0BA1e43cBEA6bf70A2eBEE47E47B50e51f	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	common/common.go:97	Forced BlockHashL1: 0x0000000000000000000000000000000000000000000000000000000000000000	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	common/common.go:98	CalculatedAccInputHash: 0x51d8d1d4ec0a4bdc1517487b52b4e3a66af456f6bc67f6af69b13343b5e63ad8	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	aggregator/aggregator.go:1217	Calculated acc input hash for batch 243: 0x51d8d1d4ec0a4bdc1517487b52b4e3a66af456f6bc67f6af69b13343b5e63ad8	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	aggregator/aggregator.go:1218	OldAccInputHash: 0x39623d7c4342c0f3b19f9b220de511cf533c72c1c4954a46638ac24c1b0b1b91	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	aggregator/aggregator.go:1219	L1InfoRoot: 0xe406a72bf8c00a771648f8ff944fe7f38a966b03444501720847c7f86c1fbfb7	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	aggregator/aggregator.go:1220	TimestampLimit: 1779250392	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	aggregator/aggregator.go:1221	LastCoinbase: 0xa609eC0BA1e43cBEA6bf70A2eBEE47E47B50e51f	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	DEBUG	aggregator/aggregator.go:1222	ForcedBlockHashL1: 0x0000000000000000000000000000000000000000000000000000000000000000	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:08:49.118Z	INFO	aggregator/aggregator.go:1243	All information to generate proof for batch 243 is ready. Witness will be requested.	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:08:49.120Z	INFO	aggregator/aggregator.go:1286	Requesting witness for batch 243	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:10:20.350Z	INFO	aggregator/aggregator.go:390	Last Verified Batch Number:241	{"pid": 9, "version": "e6765ad", "module": "aggregator", "batch": 241}
[cdk-node-1] 2026-05-20T08:13:56.272Z	DEBUG	aggregator/aggregator.go:1661	deleted generated proofs from 240 to 241	{"pid": 9, "monitoredTxId": "0x91633bb9123ab8fe45d6154dbdf5e1e5be779f4c432c3aec0a9ec6a67cda885e"}
[cdk-node-1] 2026-05-20T08:19:40.981Z	DEBUG	aggregator/aggregator.go:1388	Time to get witness for batch 243: 10m51.861708651s	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	INFO	aggregator/aggregator.go:1288	Witness received for batch 243	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	INFO	aggregator/aggregator.go:1308	Sending zki + batch to the prover, batchNumber [243]	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "batch": 243}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	l1infotree/tree.go:35	Initial count: 0	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	l1infotree/tree.go:36	Initial root: 0x27ae5ba08d7291c96c8cbddcc148bf48a6d68c7974b94356f53754ef6171d757	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	aggregator/aggregator.go:1586	Witness length: 1379845	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	aggregator/aggregator.go:1587	BatchL2Data length: 46293	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	aggregator/aggregator.go:1588	OldAccInputHash: 0x39623d7c4342c0f3b19f9b220de511cf533c72c1c4954a46638ac24c1b0b1b91	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	aggregator/aggregator.go:1589	L1InfoRoot: 0xe406a72bf8c00a771648f8ff944fe7f38a966b03444501720847c7f86c1fbfb7	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	aggregator/aggregator.go:1590	TimestampLimit: 1779250392	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	aggregator/aggregator.go:1591	SequencerAddr: 0xa609eC0BA1e43cBEA6bf70A2eBEE47E47B50e51f	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	aggregator/aggregator.go:1592	AggregatorAddr: 0x0506Ed1657f8F19BcCE016b44116619C576B1192	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	aggregator/aggregator.go:1593	L1InfoTreeData: map[]	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	DEBUG	aggregator/aggregator.go:1594	ForcedBlockhashL1: 0x0000000000000000000000000000000000000000000000000000000000000000	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:40.982Z	INFO	aggregator/aggregator.go:1316	Sending a batch to the prover. OldAccInputHash [0x39623d7c4342c0f3b19f9b220de511cf533c72c1c4954a46638ac24c1b0b1b91], L1InfoRoot [0xe406a72bf8c00a771648f8ff944fe7f38a966b03444501720847c7f86c1fbfb7]	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "batch": 243}
[cdk-node-1] 2026-05-20T08:19:40.998Z	INFO	aggregator/aggregator.go:1337	Batch proof generated	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "batch": 243, "proofId": "dea54c79-3158-4d8c-8b40-9edaa2323bfd"}
[cdk-node-1] 2026-05-20T08:19:40.998Z	INFO	aggregator/aggregator.go:1405	State root sanity check for batch 243 passed	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "batch": 243, "proofId": "dea54c79-3158-4d8c-8b40-9edaa2323bfd"}
[cdk-node-1] 2026-05-20T08:19:40.998Z	INFO	aggregator/aggregator.go:1418	Acc input hash sanity check for batch 243 passed	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "batch": 243, "proofId": "dea54c79-3158-4d8c-8b40-9edaa2323bfd"}
[cdk-node-1] 2026-05-20T08:19:40.998Z	DEBUG	aggregator/aggregator.go:685	tryBuildFinalProof start	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:40.998Z	DEBUG	aggregator/aggregator.go:691	Send final proof time reached	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.003Z	DEBUG	aggregator/aggregator.go:785	Proof batch number 243 is not the following to last verfied batch number 241	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.004Z	DEBUG	aggregator/aggregator.go:1305	tryGenerateBatchProof end	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "batch": 243, "proofId": "dea54c79-3158-4d8c-8b40-9edaa2323bfd"}
[cdk-node-1] 2026-05-20T08:19:41.006Z	DEBUG	aggregator/aggregator.go:685	tryBuildFinalProof start	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.006Z	DEBUG	aggregator/aggregator.go:691	Send final proof time reached	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.012Z	DEBUG	aggregator/aggregator.go:704	No proof ready to verify	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.012Z	DEBUG	aggregator/aggregator.go:918	tryAggregateProofs start	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.013Z	INFO	aggregator/aggregator.go:945	Aggregating proofs: 242-242 and 243-243	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.013Z	INFO	aggregator/aggregator.go:979	Proof ID for aggregated proof: b3d49530-a177-407f-b8d0-e0a1cf9807ce	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "batches": "242-243"}
[cdk-node-1] 2026-05-20T08:19:41.014Z	INFO	aggregator/aggregator.go:989	Aggregated proof generated	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "batches": "242-243", "proofId": "b3d49530-a177-407f-b8d0-e0a1cf9807ce"}
[cdk-node-1] 2026-05-20T08:19:41.015Z	DEBUG	aggregator/aggregator.go:685	tryBuildFinalProof start	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.015Z	DEBUG	aggregator/aggregator.go:691	Send final proof time reached	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.018Z	INFO	aggregator/aggregator.go:644	Final proof ID for batches [242-243]: 786052d8-f6cb-4341-8182-e371d43a5af3	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "recursiveProofId": "b3d49530-a177-407f-b8d0-e0a1cf9807ce", "batches": "242-243"}
[cdk-node-1] 2026-05-20T08:19:41.070Z	WARN	aggregator/aggregator.go:662	NewLocalExitRoot and NewStateRoot look like a mock values, using values from executor instead: LER: 000000..000000, SR: 288ec8..6bf4c7	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "recursiveProofId": "b3d49530-a177-407f-b8d0-e0a1cf9807ce", "batches": "242-243", "finalProofId": "786052d8-f6cb-4341-8182-e371d43a5af3"}
[cdk-node-1] github.com/0xPolygon/cdk/aggregator.(*Aggregator).buildFinalProof
[cdk-node-1] 	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:662
[cdk-node-1] github.com/0xPolygon/cdk/aggregator.(*Aggregator).tryBuildFinalProof
[cdk-node-1] 	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:739
[cdk-node-1] github.com/0xPolygon/cdk/aggregator.(*Aggregator).tryAggregateProofs
[cdk-node-1] 	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:1041
[cdk-node-1] github.com/0xPolygon/cdk/aggregator.(*Aggregator).Channel
[cdk-node-1] 	/go/src/github.com/0xPolygon/cdk/aggregator/aggregator.go:456
[cdk-node-1] github.com/0xPolygon/cdk/aggregator/prover._AggregatorService_Channel_Handler
[cdk-node-1] 	/go/src/github.com/0xPolygon/cdk/aggregator/prover/aggregator_grpc.pb.go:109
[cdk-node-1] 2026-05-20T08:19:41.070Z	DEBUG	aggregator/aggregator.go:759	tryBuildFinalProof end	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "proofId": "b3d49530-a177-407f-b8d0-e0a1cf9807ce", "batches": "242-243"}
[cdk-node-1] 2026-05-20T08:19:41.070Z	DEBUG	aggregator/aggregator.go:942	tryAggregateProofs end	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750", "batches": "242-243", "proofId": "b3d49530-a177-407f-b8d0-e0a1cf9807ce"}
[cdk-node-1] 2026-05-20T08:19:41.070Z	INFO	aggregator/aggregator.go:493	Verifying final proof with ethereum smart contract	{"pid": 9, "version": "e6765ad", "module": "aggregator", "proofId": "786052d8-f6cb-4341-8182-e371d43a5af3", "batches": "242-243"}
[cdk-node-1] 2026-05-20T08:19:41.071Z	DEBUG	aggregator/aggregator.go:685	tryBuildFinalProof start	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.071Z	DEBUG	aggregator/aggregator.go:688	Time to verify proof not reached or proof verification in progress	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.071Z	DEBUG	aggregator/aggregator.go:918	tryAggregateProofs start	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.071Z	DEBUG	aggregator/aggregator.go:923	Nothing to aggregate	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.071Z	DEBUG	aggregator/aggregator.go:1273	tryGenerateBatchProof start	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	common/common.go:92	OldAccInputHash: 0x51d8d1d4ec0a4bdc1517487b52b4e3a66af456f6bc67f6af69b13343b5e63ad8	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	common/common.go:93	BatchHashData: 5a8ccb576c360817f0be16216c1f53c8b12ab80ccce29eb40540e1c75d327d1f	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	common/common.go:94	L1InfoRoot: 0xe406a72bf8c00a771648f8ff944fe7f38a966b03444501720847c7f86c1fbfb7	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	common/common.go:95	TimeStampLimit: 1779250409	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	common/common.go:96	Sequencer Address: 0xa609eC0BA1e43cBEA6bf70A2eBEE47E47B50e51f	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	common/common.go:97	Forced BlockHashL1: 0x0000000000000000000000000000000000000000000000000000000000000000	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	common/common.go:98	CalculatedAccInputHash: 0x62d8e1541cc3d5b0ebf95fcbb6eff86b08466950de17fc68ef41e530451eeca3	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	aggregator/aggregator.go:1217	Calculated acc input hash for batch 244: 0x62d8e1541cc3d5b0ebf95fcbb6eff86b08466950de17fc68ef41e530451eeca3	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	aggregator/aggregator.go:1218	OldAccInputHash: 0x51d8d1d4ec0a4bdc1517487b52b4e3a66af456f6bc67f6af69b13343b5e63ad8	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	aggregator/aggregator.go:1219	L1InfoRoot: 0xe406a72bf8c00a771648f8ff944fe7f38a966b03444501720847c7f86c1fbfb7	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	aggregator/aggregator.go:1220	TimestampLimit: 1779250409	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	aggregator/aggregator.go:1221	LastCoinbase: 0xa609eC0BA1e43cBEA6bf70A2eBEE47E47B50e51f	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.145Z	DEBUG	aggregator/aggregator.go:1222	ForcedBlockHashL1: 0x0000000000000000000000000000000000000000000000000000000000000000	{"pid": 9, "version": "e6765ad", "module": "aggregator"}
[cdk-node-1] 2026-05-20T08:19:41.146Z	INFO	aggregator/aggregator.go:1243	All information to generate proof for batch 244 is ready. Witness will be requested.	{"pid": 9, "version": "e6765ad", "module": "aggregator", "prover": "test-prover", "proverId": "84ebe404-4a65-4155-83e7-3e1d607ed1ec", "proverAddr": "172.16.0.16:59750"}
```

## 证明流水线（Stark → Circom → Groth16）

executor 产出执行 trace 后，证明生成走以下流水线：

```
执行 trace → Stark 证明 → StarkC12a → Recursive1 (batch proof)
                                       → Recursive2 (aggregated proof)
                                       → RecursiveF + Groth16 (final proof)
```

**Executor + HashDB = 执行系统**（做 EVM 计算），**Stark/Circom = 证明系统**（做数学证明）。两者在代码层面独立，executor 的输出是 Stark 的输入。

## 当前部署中的服务划分

以当前 `erigon_strict_mode: false` 为例：

| Kurtosis 服务 | 跑的组件 | 关键配置 | 配置文件 |
|-------------|---------|---------|---------|
| `zkevm-prover-001` | Executor + HashDB **+** AggregatorClientMock | `runExecutorServer: true`, `runHashDBServer: true`, `runAggregatorClientMock: true` | `prover-config.json` |
| `cdk-node-001` | 内置 Aggregator（服务端）+ SequenceSender | `--components=sequence-sender,aggregator` | `cdk-node-config.toml` |
| `cdk-erigon-sequencer-001` | Sequencer（内部执行交易，**不调外部 executor**） | `zkevm.executor-strict: false` | `cdk-erigon/config.yml` |

当 `erigon_strict_mode: true` 时，还会额外部署 `zkevm-stateless-executor-001`（见下方"Stateless Executor 部署条件"）。

## Stateless Executor 部署条件

`zkevm-stateless-executor` 只在 `erigon_strict_mode: true` 时部署（`kurtosis-cdk/cdk_erigon.star:6-27`）：

```python
if args["erigon_strict_mode"]:
    stateless_configs["stateless_executor"] = True
    ...
    zkevm_prover_package.start_stateless_executor(...)
```

服务名格式：`"zkevm-" + type + args["deployment_suffix"]`（`lib/zkevm_prover.star:37`），type 为 `"stateless-executor"` 时得到 `zkevm-stateless-executor-001`。

sequencer 配置侧（`cdk-erigon/config.yml:360-367`）：

```yaml
zkevm.executor-strict: {{.erigon_strict_mode}}
{{if .erigon_strict_mode}}
zkevm.executor-urls: zkevm-stateless-executor{{.deployment_suffix}}:{{.zkevm_executor_port}}
{{end}}
```

| `erigon_strict_mode` | 独立 Stateless Executor | Executor 位置 | Sequencer 行为 |
|---------------------|------------------------|--------------|--------------|
| `false`（当前） | ❌ 不部署 | `zkevm-prover-001` 进程内（idle） | 内部执行交易 |
| `true` | ✅ 部署 | 独立 `zkevm-stateless-executor-001` | 调用外部 executor 验证 |

## 硬件要求

### CPU

| 要求 | 级别 | 证据 | 文件:行号 |
|------|------|------|-----------|
| AVX2 | **必须** | `CXXFLAGS := ... -mavx2` 写死在编译选项 | `zkevm-prover/Makefile:31` |
| AVX512F | 推荐 | 编译时通过 `/proc/cpuinfo` 自动检测 AVX-512 | `zkevm-prover/Makefile:52-61` |
| 不需 GPU | — | Docker 镜像用 CPU 构建产物 `zkProver`，非 `zkProverGpu` | `zkevm-prover/Dockerfile:21` |

启动时打印当前模式（`src/main.cpp:337-342`）：

```cpp
#ifdef __AVX512__
    zklog.info("Vectorization based on AVX512");
#else
    zklog.info("Vectorization based on AVX2");
#endif
```

版本号也区分（`src/config/version.hpp:6-9`）：带 AVX512 编译时后缀 `v8.0.0-RC16.avx512`。

支持 AVX2 的 CPU：Intel Haswell (2013+) / AMD Excavator (2015+) — 几乎所有服务器都满足。
支持 AVX512F 的 CPU：Intel Skylake-X (2017+) / AMD Zen 4 (2022+)，证明生成速度大幅提升。

### 内存

| 组件 | 估计用量 | 能否跨进程共享 | 源文件:行号 |
|------|---------|-------------|-----------|
| 常量多项式（mmap 文件） | ~200-300GB（解压后 ~115GB 磁盘） | ✅ OS `mmap` `MAP_PRIVATE` 共享物理页 | `utils.cpp:382` |
| DB MT Cache (`dbMTCacheSize`) | 默认 8GB/进程 | ❌ | `config.cpp:167` |
| DB Program Cache (`dbProgramCacheSize`) | 默认 1GB/进程 | ❌ | `config.cpp:181` |
| Stark 证明工作区 | 数百GB | ❌ | — |
| **总计**（单进程） | **512-700GB** | |

**多进程共享**：常量多项式在磁盘上约 115GB（`tools/download_archive.sh` 下载），通过 `mmap` 映射到虚拟内存后约 200-300GB，多个进程 mmap 同一个只读文件时操作系统共享同一份物理内存页。因此多进程总内存 ≈ 共享常量 + N × 每进程工作区。

### 核心数

无硬性最低要求。证明计算通过 OpenMP（`-fopenmp`）并行化，默认使用所有可用核心（`omp_get_num_procs()`）。实际瓶颈是内存，32-64 核服务器足够。

## 多链共享分析

| 组件 | 端口 | 能否跨链共享 | 原因 |
|------|------|------------|------|
| Executor (stateless) | 50071 | 技术上可以，但不推荐 | 无状态且链无关，但 sequencer 频繁低延迟调用，多链共享会竞争 `maxExecutorThreads`；每链独立部署更可靠 |
| HashDB | 50061 | ❌ | 存储链特定的 Sparse Merkle Tree 状态 |
| AggregatorClient | 50081（连出） | ❌ | 单一 `aggregatorClientHost` 字段，一个进程只能连一个 cdk-node aggregator；aggregator 绑定特定的 L1 `PolygonZkEVM` 合约 |

**实际多链方案**：
- Executor 每链独立部署（轻量，无需大内存，sequencer 频繁低延迟调用不应跨链竞争）
- AggregatorClient 每链独立：每个链起一个 prover 进程，各连各的 cdk-node aggregator
- 每个 prover 进程需 512-700GB+ RAM，**每链需一台独立 prover 机器**

---

# 方案一：Prover 独立部署，启用真实 ZK 证明

## 架构变化

启用真实 prover 后，zkevm-prover 从 Kurtosis enclave 内移到独立的高内存机器上：

```mermaid
flowchart TB
    subgraph L1["L1 (外部链)"]
        L1C["L1 合约<br/>(Real Verifier 替换 Mock Verifier)"]
    end

    subgraph Kurtosis["Kurtosis Enclave (cdk-gen)"]
        SEQ["cdk-erigon-sequencer-1"]
        RPC["cdk-erigon-rpc-1"]
        NODE["cdk-node-1<br/>Aggregator :50081"]
        POOL["zkevm-pool-manager-1"]
        BRIDGE["zkevm-bridge-service-1"]
        PG[("postgres-1 :5432")]
    end

    subgraph ExtProver["独立高内存机器 (700GB+ RAM)"]
        PROVER["zkevm-prover<br/>────────────────<br/>executor :50071 (仅 strict_mode)<br/>hash-db :50061<br/>aggregatorClient → cdk-node"]
        PROVER_DB[("prover_db<br/>PostgreSQL")]
    end

    SEQ -->|"datastream :6900"| RPC
    SEQ -->|"读 L1 状态"| L1C
    RPC -->|"sendRawTransaction :8545"| POOL
    POOL -->|"txpool 协调"| SEQ
    NODE -->|"WitnessURL :8123"| RPC
    NODE -->|"提交 proof + sequence"| L1C
    BRIDGE -->|"监听 L1 桥事件"| L1C
    BRIDGE -->|"监听 L2 桥事件"| RPC

    PROVER -->|"aggregatorClient gRPC<br/>→ NODE_HOST:32785"| NODE
    PROVER -->|":5432"| PROVER_DB
    SEQ -->|"executor-urls :50071<br/>(仅 strict_mode=true)"| PROVER

    SEQ -->|":5432"| PG
    RPC -->|":5432"| PG
    NODE -->|":5432"| PG
    POOL -->|":5432"| PG
    BRIDGE -->|":5432"| PG
```

**关键变化：**

| 变化点 | Mock 模式 | Real Prover 模式 |
|--------|----------|-----------------|
| zkevm-prover 位置 | Kurtosis 内 `zkevm-prover-1` | 独立机器，不在 Kurtosis 内 |
| prover 启动方式 | Kurtosis 自动启动 | 手动 docker run / systemd |
| `runAggregatorClientMock` | `true` | `false` |
| `runAggregatorClient` | `false` | `true` |
| L1 Verifier 合约 | Mock Verifier | Real Verifier |
| 证明时间 | 1μs (mock) | 数分钟 (真实) |
| 硬件需求 | 普通 | CPU: AVX2 (必须) / AVX512 (推荐)<br/>内存: 512-700GB+ RAM<br/>**不需 GPU** |
| 证明流水线 | AggregatorClientMock → 假证明 | AggregatorClient → Executor →<br/>Stark → Circom → Groth16 |

## 实施步骤

### 步骤 1：修改部署参数

**文件**: `cdk-work/scripts/params.template.yml`

```yaml
args:
  zkevm_use_real_verifier: true    # 新增：启用真实验证器
  erigon_strict_mode: true         # 可选：让 sequencer 等待 executor 外部验证
  # ... 其余保持不变
```

**代码证据** — `zkevm_use_real_verifier` 的两处关键作用：

| 作用 | 文件:行号 | 代码 |
|------|-----------|------|
| 跳过 Kurtosis 内 prover 启动 | `kurtosis-cdk/cdk_central_environment.star:30-37` | `if (not args["zkevm_use_real_verifier"] ...): start_prover(...)` |
| 默认值定义 | `kurtosis-cdk/input_parser.star:316` | `"zkevm_use_real_verifier": False` |
| 注释说明需要大量内存 | `kurtosis-cdk/input_parser.star:313-316` | `# By default a mock verifier is deployed. Change to true to deploy a real verifier which will require a real prover. Note: This will require a lot of memory to run!` |

**`erigon_strict_mode` 的作用**（可选开启）：

| 作用 | 文件:行号 | 代码 |
|------|-----------|------|
| 控制 executor-urls 是否渲染 | `kurtosis-cdk/templates/cdk-erigon/config.yml:360-367` | `zkevm.executor-strict: {{.erigon_strict_mode}}` + `{{if .erigon_strict_mode}}zkevm.executor-urls: ...{{end}}` |
| 默认值定义 | `kurtosis-cdk/input_parser.star:321` | `"erigon_strict_mode": True` |
| 注释说明 | `kurtosis-cdk/input_parser.star:319-321` | `# This flag will enable a stateless executor to verify the execution of the batches.` |

### 步骤 2：确认 Kurtosis 部署跳过 Prover

设置 `zkevm_use_real_verifier: true` 后，`cdk_central_environment.star:30-37` 的条件判断 `not args["zkevm_use_real_verifier"]` 为 `false`，整个 `start_prover(...)` 块被跳过。

部署后的 Kurtosis 服务列表将**不再包含** `zkevm-prover-1`：

```
# 预期服务列表（与当前对比）
当前:  zkevm-prover-1  executor:50071, hash-db:50061   ← 会被移除
       cdk-node-1       aggregator:50081                ← 保留，等待外部 prover 连接
       其余服务不变
```

### 步骤 3：创建 Prover 配置文件 (`config.json`)

你要创建一个 JSON 配置文件，prover 启动时通过 `-c <path>` 加载（默认查找 `config/config.json`）。

**参考模板**（带完整注释的每一个字段）：
- `kurtosis-cdk/templates/trusted-node/prover-config.json`
- `cdk/test/config/test.prover.config.json`（真实模式示例）

下面是一个**可直接使用的最小真实 prover 配置**，`< >` 标注的 3 个值需要你根据实际环境填入：

```json
{
    "runExecutorServer": true,             // 保留：sequencer 调 executor 需要（开启 strict_mode 时）
    "runHashDBServer": true,               // 保留：提供 SMT 状态访问
    "runAggregatorClient": true,           // ★ 启动真实证明生成
    "runAggregatorClientMock": false,      // ★ 关闭假证明

    "aggregatorClientHost": "<CDK_NODE_IP_OR_HOSTNAME>",  // ★ 填 cdk-node 所在主机 IP
    "aggregatorClientPort": <CDK_NODE_AGGREGATOR_PORT>,   // ★ 填 cdk-node 的 aggregator 对外端口（如 32785）

    "proverName": "real-prover",           // 自定义名称，cdk-node 日志中可见

    "databaseURL": "local",                // 先用 "local" 验证连通性；生产改为 PostgreSQL 连接串
    "dbMTCacheSize": 8192,                 // 8GB
    "dbProgramCacheSize": 1024,            // 1GB

    "maxExecutorThreads": 20,
    "maxHashDBThreads": 8,

    "hashDBServerPort": 50061,
    "executorServerPort": 50071,

    "executeInParallel": true,
    "useMainExecGenerated": true,
    "stateManager": true
}
```

**字段说明**（按你关心的顺序）：

| 字段 | 你要填什么 | 默认值 | 源码出处 |
|------|----------|-------|---------|
| `aggregatorClientHost` | ★ cdk-node 所在主机的 IP 或 Docker 容器名 | `"127.0.0.1"` | `config.cpp:196` |
| `aggregatorClientPort` | ★ cdk-node aggregator 的对外端口（非容器内 50081，是主机映射端口） | `50081` | `config.cpp:195` |
| `databaseURL` | `"local"` = 内存 SQLite（无需外部 DB）；生产填 PostgreSQL 连接串 | `"local"` | `config.cpp:278` |
| `runAggregatorClient` | `true` 启用真实证明生成 | `false` | `config.cpp:124` |
| `runAggregatorClientMock` | `false` 关闭假证明 | `false` | `config.cpp:125` |
| `proverName` | 任意字符串，用于在 cdk-node 日志中识别此 prover | `"UNSPECIFIED"` | `config.cpp:305` |
| `runExecutorServer` | `true`（sequencer 调 executor 需要） | `true` | `config.cpp:118` |
| `runHashDBServer` | `true`（提供 HashDB gRPC 服务） | `true` | `config.cpp:121` |
| `maxExecutorThreads` | gRPC executor 线程池，可按 CPU 核数调整 | `20` | `config.cpp:299` |
| `maxHashDBThreads` | gRPC HashDB 线程池 | `8` | `config.cpp:302` |
| `dbMTCacheSize` | Merkle Tree 缓存 (MB) | `8192` | `config.cpp:167` |
| `dbProgramCacheSize` | 合约字节码缓存 (MB) | `1024` | `config.cpp:181` |
| `stateManager` | 批次间状态合并 | `true` | `config.cpp:293` |
| `executeInParallel` | 并行执行辅助状态机 | `true` | `config.cpp:153` |

> **提醒**：prover 连接 cdk-node 的方向是 **prover → cdk-node**（`AggregatorClient` 是客户端），因此 `aggregatorClientHost/Port` 要填 cdk-node 的网络地址，不是 prover 自己的地址。

### 步骤 4：准备 Prover 数据库

两种方式任选其一：

**方式 A — 复用 Kurtosis 的 prover_db（推荐）**

Kurtosis 部署时 postgres 容器内已自动创建 `prover_db`（含 `state.nodes`、`state.program` 表），外部 prover 直接连该实例即可。通过 `kurtosis port print cdk-gen postgres-1 postgres` 获取映射端口，数据库连接串格式：

```
postgresql://prover_user:<password>@<kurtosis-host>:<mapped-port>/prover_db
```

> 密码为 `databases.star` 中 `PROVER_DB` 定义的 `password` 字段值。 当前值为 “redacted”

**方式 B — 自建 PostgreSQL**

在 prover 机器上自建数据库，执行初始化脚本 `kurtosis-cdk/templates/databases/prover-db-init.sql`：

```bash
createdb prover_db
psql -d prover_db -f prover-db-init.sql
```

### 步骤 5：下载多项式常量文件

真实证明需要多项式常量文件（115GB），详见 [方案二 — 步骤 C](#步骤-c下载多项式常量文件)。


### 步骤 6：启动外部 Prover

**前置条件**：硬件要求见上方 [硬件要求](#硬件要求) 章节（AVX2 必须、AVX512 推荐、512-700GB RAM、不需 GPU）。

**Docker 启动**：

```bash
docker run -d \
  --name zkevm-prover \
  -v /path/to/real-prover-config.json:/usr/src/app/config.json \
  -v /data/prover-polynomials/v8.0.0-rc.9-fork.12/config:/usr/src/app/config \
  hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12 \
  zkProver -c /usr/src/app/config.json
```

> `-v` 第二个挂载的容器内路径 `/usr/src/app/config` 必须与配置中 `configPath` 一致（默认 `"config"`），zkProver 二进制的工作目录为 `/usr/src/app`。

**镜像版本来源**：

| 来源 | 镜像 | 文件:行号 |
|------|------|-----------|
| 当前部署 | `hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12` | `cdk-work/scripts/params.template.yml:22` |
| kurtosis-cdk 默认 | `hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12` | `kurtosis-cdk/input_parser.star:72` |
| CDK versions.json | `hermeznetwork/zkevm-prover:v8.0.0-RC14-fork.12` | `cdk/crates/cdk/versions.json:13` |

**Kurtosis 内启动逻辑参考** — `kurtosis-cdk/lib/zkevm_prover.star:38-52`：

```python
# 所有模式使用同一镜像，通过 config 区分 prover/executor/stateless-executor
image=args["zkevm_prover_image"],
cmd=['/usr/local/bin/zkProver -c /etc/zkevm/{type}-config.json']
```

### 步骤 7：配置网络连通性

这是方案一最关键的步骤。Prover 需要访问 cdk-node 的 aggregator 端口。

**问题**：Kurtosis 内服务使用 Docker 内部 DNS（如 `cdk-node-1`），外部机器无法直接解析。

**当前端口映射**（来自你的实际部署）：

```
cdk-node-1: aggregator: 50081/tcp -> grpc://127.0.0.1:32785
```

**方案 A — 同一 Docker 网络**（推荐，最简单）：

将 prover 容器挂载到 Kurtosis enclave 的 Docker 网络，可直接使用内部 DNS：

```bash
# 1. 查找 Kurtosis 创建的 Docker 网络
docker network ls | grep kurtosis

# 2. 启动 prover 时指定该网络
docker run -d \
  --network $(docker network ls -q -f name=kt-) \
  --name zkevm-prover \
  -v /path/to/real-prover-config.json:/usr/src/app/config.json \
  hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12 \
  zkProver -c /usr/src/app/config.json
```

此时 `aggregatorClientHost` 可以直接使用 `"cdk-node-1"`，端口使用容器内端口 `50081`。

**方案 B — 主机端口映射**：

如果 prover 在另一台机器上，需要确保 cdk-node 的 aggregator 端口对外可达：

1. 确认 Kurtosis 动态端口映射到 `0.0.0.0` 而非 `127.0.0.1`
2. 在 prover 配置中使用主机 IP + 映射端口
3. 配置防火墙放行

**方案 C — SSH 隧道**：

在 prover 机器上建立到 cdk-node 的 SSH 隧道：

```bash
ssh -L 50081:localhost:32785 user@cdk-node-host -N
```

然后 prover 配置中 `aggregatorClientHost: "127.0.0.1"`, `aggregatorClientPort: 50081`。

### 步骤 8：处理 erigon_strict_mode（可选）

如果同时开启了 `erigon_strict_mode: true`，sequencer 需要在出块前等待 executor 的外部验证。详解见上方 [Stateless Executor 部署条件](#stateless-executor-部署条件)。

如果外部 prover 不在同一 Docker 网络（方案 A），需要修改 fork 的模板让 executor 地址可配置（模板写死了 `zkevm-stateless-executor-1:50071`），或者采用方案 A 让 Docker DNS 解析生效。

### 步骤 9：部署并验证

```bash
# 1. 重新部署 CDK（prover 不再在 Kurtosis 内启动）
bash cdk_pipe.sh

# 2. 确认 cdk-node 的 aggregator 端口映射
kurtosis port print cdk-gen cdk-node-1 aggregator

# 3. 启动外部 prover
docker run -d --name zkevm-prover ... 

# 4. 检查 prover 日志，确认连接 aggregator 成功
docker logs -f zkevm-prover
# 预期日志: "Connected to aggregator" / "Waiting for proof requests"

# 5. 检查 cdk-node 日志，确认收到 prover 连接
kurtosis service logs cdk-gen cdk-node-1
# 预期: aggregator_current_connected_provers 指标 > 0

# 6. 观察 proof 生成
cast rpc --rpc-url $L2_RPC zkevm_verifiedBatchNumber
# 应该随时间增长（不再卡住）
```

## 步骤汇总与代码证据索引

| 步骤 | 操作 | 关键文件 | 关键配置/行号 |
|------|------|---------|-------------|
| 1 | 修改部署参数 | `params.template.yml` | 新增 `zkevm_use_real_verifier: true` |
| 1 | 参数默认值 | `input_parser.star` | 316 |
| 1 | 参数注释（需要大量内存） | `input_parser.star` | 313-316 |
| 2 | prover 跳过启动的条件 | `cdk_central_environment.star` | 30-37 |
| 3 | prover 配置模板（带注释） | `prover-config.json` | 全文 |
| 3 | 真实模式示例 | `cdk/test/config/test.prover.config.json` | 全文 |
| 3 | ★ `aggregatorClientHost` | `config.cpp:196` | 填 cdk-node 主机 IP |
| 3 | ★ `aggregatorClientPort` | `config.cpp:195` | 填 cdk-node aggregator 对外端口 |
| 3 | `runAggregatorClient` | `config.cpp:124` | → `true` |
| 3 | `runAggregatorClientMock` | `config.cpp:125` | → `false` |
| 3 | `databaseURL` | `config.cpp:278` | 先用 `"local"`，生产改 PostgreSQL |
| 4 | prover DB：推荐复用 Kurtosis 的 prover_db，备选自建 | `templates/databases/prover-db-init.sql` | 全文 |
| 5 | 下载多项式常量文件（115GB） | GCS `zkevm/zkproverc/` | `download_archive.sh:8` |
| 6 | Docker 启动命令参考 | `test/docker-compose.yml` | 20-28 |
| 6 | prover 镜像版本 | `params.template.yml` / `input_parser.star` | 22 / 72 |
| 6 | Kurtosis 启动逻辑 | `lib/zkevm_prover.star` | 38-52 |
| 7 | 网络连通（当前映射示例） | 实际 enclave inspect 输出 | — |
| 8 | strict_mode executor-urls 条件 | `templates/cdk-erigon/config.yml` | 360-367 |
| 8 | strict_mode 默认值 | `input_parser.star` | 319-321 |
| 9 | aggregator 端口 | `cdk-node-config.toml` | 55 |
| 9 | aggregator DB 配置 | `cdk-node-config.toml` | 60-67 |
| 9 | WitnessURL 配置 | `cdk-node-config.toml` | 33 |

---

# 方案二：Prover 留在 Kurtosis 内，启用真实 ZK 证明

方案一需要独立机器部署 prover，方案二则是 **不拆分 prover，让它继续在 Kurtosis enclave 内运行，但把证明从 mock 切换为真实**。

## 与方案一的本质区别

| | 方案一（独立部署） | 方案二（Kurtosis 内） |
|---|---|---|
| prover 位置 | 独立大内存机器 | 与 sequencer/node 同机（Kurtosis 容器内或手动 docker run） |
| 主机要求 | prover 机器单独满足即可；Kurtosis 主机不变 | **整台 Kurtosis 主机必须满足**（Docker 容器共享宿主内核内存） |
| 网络复杂度 | 需配置 cdk-node aggregator 端口对外暴露 | prover 用 Docker DNS 直连 `cdk-node-1:50081`，零配置 |
| Kurtosis 修改 | 无需改模板 | 方式一（推荐）不需要；方式二/三需要修改模板 |
| 多项式文件 | 手动下载后通过 `-v` 直接挂载 | 方式一（推荐）同样用 `-v` 挂载；方式二构建镜像；方式三 artifact（详见步骤 C-D） |
| 隔离性 | prover 资源独立，不影响其他服务 | prover 和其他服务争抢同一主机资源 |

## 为什么需要 700GB —— 与方案无关，是真实 prover 自身的需求

**无论方案一还是方案二，真实 prover 自身都需要 512-700GB+ RAM**。方案二不同的只是：prover 跑在 Kurtosis 主机上，因此这台主机必须满足这个内存要求。

**事实依据**：

| 来源 | 原文 | 文件:行号 |
|------|------|-----------|
| prover 配置文档 | `runAggregatorClient` 标注 "requires 512GB of RAM" | `zkevm-prover/src/config/README.md:19` |
| kurtosis-cdk 模板注释 | "Running this service most likely requires 700GB+ of physical memory" | `kurtosis-cdk/templates/trusted-node/prover-config.json:69-70` |

> 512GB 与 700GB 两个数字来自不同出处，512GB 是 prover 项目配置文档中 `runAggregatorClient` 的标注，700GB 是 kurtosis-cdk 模板的经验值注释。实际需求取决于批次大小和并发度，建议预留 700GB+。

**内存消耗在哪里**：

| 消耗来源 | 规模 | 能否 OS 级跨进程共享 |
|---------|------|-------------------|
| 常量多项式文件（证明密钥、验证密钥、STARK 参数） | 压缩包 75GB → 解压 115GB → mmap 后虚拟内存 ~200-300GB | ✅ 只读 mmap，OS 共享物理页 |
| Merkle Tree 缓存 (`dbMTCacheSize`) | 默认 8GB | ❌ 每进程独立 |
| 合约字节码缓存 (`dbProgramCacheSize`) | 默认 1GB | ❌ 每进程独立 |
| Stark 证明工作区（多项式提交、FFT 中间结果） | 数百GB | ❌ 临时计算空间 |

**关键**：尽管常量多项式文件可通过 OS mmap 跨进程共享物理页（这是技术事实），但每进程的工作内存仍需 300-400GB，因此实际部署中**一个 prover 进程 ≈ 一台 700GB 机器**。如需多链，每链一台 prover 机器。

## 为什么 kurtosis-cdk 不直接支持

`cdk_central_environment.star:30-37` 只有两个路径：

```python
if (not args["zkevm_use_real_verifier"] ...):
    zkevm_prover_package.start_prover(...)   # prover 启动，但是 mock 模式
# else: 根本不启动 prover（给方案一留空间）
```

模板 `prover-config.json` 里的模式是写死的（见第 72、84 行）：
- `runAggregatorClient: false` — 不生成真实证明
- `runAggregatorClientMock: true` — 生成假证明（当 `stateless_executor` 为 false 时）

**没有模板变量控制"用真实证明还是 mock"**。要实现方案二，必须修改模板或部署后覆盖配置。

**模板未处理多项式文件注入**。即便开启了 `runAggregatorClient: true`，标准 prover 镜像不含多项式文件（115GB），真实证明无法运行。还需额外解决文件注入问题（详见下方步骤 C-D）。

## 实施步骤

### 步骤 A：改 Kurtosis fork 的 prover 模板

在你 fork 的 `Pana/kurtosis-cdk` 中，修改 `templates/trusted-node/prover-config.json`：

将第 72 行和第 84 行的逻辑改为可配置：

```
# 原逻辑（写死 mock）：
"runAggregatorClient": false,          # 第 72 行
"runAggregatorClientMock": true,       # 第 84 行（非 stateless 时）

# 改为模板变量控制：
"runAggregatorClient": {{.zkevm_use_real_prover_client}},     # 由 args 控制
"runAggregatorClientMock": {{.zkevm_use_mock_prover_client}},  # 与上面互斥
```

在 `input_parser.star` 中添加默认值：

```python
"zkevm_use_real_prover_client": False,   # 默认 mock
"zkevm_use_mock_prover_client": True,
```

在你的 `params.template.yml` 中覆盖：

```yaml
args:
  zkevm_use_real_prover_client: true
  zkevm_use_mock_prover_client: false
```

### 步骤 B：部署在 700GB+ RAM 的主机上

Kurtosis 主机需要满足 prover 的硬件要求（见 [硬件要求](#硬件要求)），其他服务如 cdk-erigon、cdk-node 等额外需要少量资源。

### 步骤 C：下载多项式常量文件

**无论方案一还是方案二，真实证明都需要多项式常量文件。** 这是 Stark → Circom → Groth16 证明流水线的运行时输入，与 mock 模式无关。

文件来源与规模：

| 项目 | 数值 |
|------|------|
| 压缩包大小 | ~75 GB (`.tgz`) |
| 解压后大小 | ~115 GB |
| 下载地址 | `https://storage.googleapis.com/zkevm/zkproverc/v8.0.0-rc.9-fork.12.tgz` |

解压后的目录结构（与 `configPath` = `"config"` 拼合后的默认路径）：

```
config/
├── zkevm/
│   ├── zkevm.const          # 常量多项式（mmap 后 ~200-300GB 虚拟内存）
│   ├── zkevm.consttree       # 常量树（当前 LOAD_CONST_FILES=false，运行时计算）
│   ├── zkevm.starkinfo.json  # STARK 结构描述
│   ├── zkevm.verifier.dat    # 验证器参数
│   ├── zkevm.verkey.json     # 验证密钥
│   └── zkevm.chelpers.bin    # C 辅助函数
├── c12a/                     # StarkC12a 阶段（同上结构）
│   ├── c12a.const
│   └── ...
├── recursive1/               # Recursive1 阶段
├── recursive2/               # Recursive2 阶段
├── recursivef/               # RecursiveF 阶段
├── final/                    # Groth16 最终证明
│   ├── final.fflonk.verkey.json
│   └── final.fflonk.zkey
└── scripts/                  # ROM/脚本文件（镜像自带，会被覆盖）
    ├── keccak_script.json
    └── storage_sm_rom.json
```

**下载命令**（在 Kurtosis 主机上执行）：

```bash
# 参考 zkevm-prover/tools/download_archive.sh（config.cpp:225-266 定义默认路径）
mkdir -p /data/prover-polynomials && cd /data/prover-polynomials
wget -c https://storage.googleapis.com/zkevm/zkproverc/v8.0.0-rc.9-fork.12.tgz
tar -xzvf v8.0.0-rc.9-fork.12.tgz
# 解压后得到 v8.0.0-rc.9-fork.12/config/ 目录，含全部多项式文件

# 验证关键文件存在
ls v8.0.0-rc.9-fork.12/config/zkevm/zkevm.const
ls v8.0.0-rc.9-fork.12/config/c12a/c12a.const
ls v8.0.0-rc.9-fork.12/config/recursivef/recursivef.const
ls v8.0.0-rc.9-fork.12/config/final/final.fflonk.zkey
```

> **版本对应关系**：`download_archive.sh:8` 中 `ARCHIVE_NAME="v8.0.0-rc.9-fork.12"`。当前使用的 prover 镜像是 `v8.0.0-RC16-fork.12`（`params.template.yml:22`），多项式存档与 prover 二进制的大版本（fork.12）匹配即可。如果未来升级 prover 镜像版本，需同步确认多项式存档版本。

### 步骤 D：将多项式文件注入 Prover 容器（方案二核心难点）

标准 prover Docker 镜像（`hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12`）**不包含**多项式文件。证据：

- `Dockerfile:24` 确实 `COPY ./config ./config`，但 CI 构建时不会提前运行 `download_archive.sh`（115GB 产物无法推送到 Docker Hub）
- kurtosis-cdk 的 prover 配置模板（`templates/trusted-node/prover-config.json`）中没有显式设置 `zkevmConstPols` 等路径字段，全部依赖 C++ 默认值 `configPath + "/zkevm/zkevm.const"`（`config.cpp:219,225`）
- **Kurtosis `ServiceConfig` 不支持 Docker `-v`/`--volume` 绑定挂载**。官方 API 仅有 `files` 字段（artifact 打包上传），没有 `volumes`、`volume_mounts` 或 `bind_mounts` 字段

以下是四种注入方式的分析。

#### 方式一：跳过 Kurtosis Prover，手动 docker run -v 挂载（推荐）

**原理**：不在 Kurtosis 内启动 prover，而是手动 `docker run`，通过 `-v` 绑定挂载宿主机多项式目录，并将容器接入 Kurtosis 的 Docker 网络，从而享受 Docker DNS 直连 `cdk-node-1:50081`。

```
                          Kurtosis Enclave (Docker Network: kt-xxx)
  ┌──────────────────────────────────────────────────────────────┐
  │  sequencer │ rpc │ cdk-node :50081 │ pool-mgr │ bridge       │
  │                        ▲                                     │
  │                        │ Docker DNS: cdk-node-1:50081        │
  │                        │                                     │
  │  ┌─────────────────────┼───────────────────────────────┐     │
  │  │ zkevm-prover ───────┘                               │     │
  │  │ (手动 docker run --network kt-xxx)                   │     │
  │  │ -v /data/prover-polynomials/.../config:/usr/src/app/config │
  │  └─────────────────────────────────────────────────────┘     │
  └──────────────────────────────────────────────────────────────┘
```

**步骤**：

**D1. 参数配置** — 在 `params.template.yml` 中设置，确保 Kurtosis 跳过 prover 启动：

```yaml
args:
  # zkevm_use_real_verifier: true → L1 使用 Real Verifier
  # zkevm_use_real_prover_client: false → 不在 Kurtosis 内启动 prover
  zkevm_use_real_verifier: true
  zkevm_use_real_prover_client: false
  zkevm_use_mock_prover_client: false
```

条件逻辑（`cdk_central_environment.star:30-37`）：
```
(not true or false) → (false or false) → false → 跳过 start_prover()
```

prover 不在 Kurtosis 内启动，也就不需要修改 kurtosis-cdk 的 prover 配置模板 — **步骤 A 可跳过**。

**D2. 部署 CDK（不含 prover）并获取 Docker 网络名**：

```bash
# 部署 CDK
bash cdk_pipe.sh

# 查找 Kurtosis 创建的 Docker 网络（格式 kt-<enclave-name>）
docker network ls | grep kt-
# 输出示例: 1a2b3c4d5e6f   kt-cdk-gen   bridge   local
export KURTOSIS_NETWORK=$(docker network ls -q -f name=kt-)
echo $KURTOSIS_NETWORK
```

**D3. 创建 Prover 配置文件**（参考方案一步骤 3 的模板）：

```bash
cat > /data/prover-polynomials/prover-config.json << 'PROVERCFG'
{
    "runExecutorServer": true,
    "runHashDBServer": true,
    "runAggregatorClient": true,
    "runAggregatorClientMock": false,

    "aggregatorClientHost": "cdk-node-1",
    "aggregatorClientPort": 50081,

    "configPath": "/usr/src/app/config",

    "databaseURL": "local",
    "dbMTCacheSize": 8192,
    "dbProgramCacheSize": 1024,

    "maxExecutorThreads": 20,
    "maxHashDBThreads": 8,

    "hashDBServerPort": 50061,
    "executorServerPort": 50071,

    "executeInParallel": true,
    "useMainExecGenerated": true,
    "stateManager": true,

    "mapConstPolsFile": true
}
PROVERCFG
```

> **关键**：`aggregatorClientHost: "cdk-node-1"` 使用 Docker 内部 DNS（同一网络内自动解析）。`mapConstPolsFile: true` 启用 mmap 减少内存复制开销。

**D4. 启动 Prover 容器**：

```bash
docker run -d \
  --name zkevm-prover \
  --network $KURTOSIS_NETWORK \
  -v /data/prover-polynomials/v8.0.0-rc.9-fork.12/config:/usr/src/app/config \
  -v /data/prover-polynomials/prover-config.json:/usr/src/app/config.json \
  hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12 \
  zkProver -c /usr/src/app/config.json
```

| 优点 | 缺点 |
|------|------|
| 宿主机文件直接挂载，零拷贝开销 | prover 不纳入 Kurtosis 生命周期管理 |
| 不需要构建 115GB 镜像 | prover 启停需手动操作 |
| 不需要修改 kurtosis-cdk 代码（步骤 A 可跳过） | 需要额外获取 Kurtosis Docker 网络名 |
| 多项式文件更新只需替换宿主机目录 | — |
| Docker DNS 直连 `cdk-node-1:50081`，零网络配置 | — |

#### 方式二：构建包含多项式文件的自定义 Docker 镜像

**原理**：基于标准 prover 镜像，将多项式文件 COPY 进去，构建一个"完整版"镜像。Kurtosis 仍管理 prover，但镜像含全部文件。

```dockerfile
# Dockerfile.prover-full
FROM hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12

# 将步骤 C 下载的多项式文件覆盖进镜像的 config/ 目录
COPY ./v8.0.0-rc.9-fork.12/config /usr/src/app/config
```

```bash
# 构建（在 /data/prover-polynomials 目录下）
docker build -f Dockerfile.prover-full \
  -t my-registry/zkevm-prover:v8.0.0-RC16-fork.12-full .

# 推送到私有 registry（可选，单机部署可跳过）
docker push my-registry/zkevm-prover:v8.0.0-RC16-fork.12-full
```

然后修改 `params.template.yml` 引用新镜像：

```yaml
args:
  zkevm_prover_image: "my-registry/zkevm-prover:v8.0.0-RC16-fork.12-full"
```

**需要先完成步骤 A**（修改 prover 配置模板，开启 `runAggregatorClient: true`）。

| 优点 | 缺点 |
|------|------|
| Kurtosis 统一管理 prover 生命周期 | 镜像 ~115GB，构建耗时（tar 解压 + COPY 约 10-20 分钟） |
| 每次重建 enclave 无需重新上传文件 | `docker push/pull` 极其缓慢（仅单机部署可忽略） |
| 与标准镜像使用方式完全一致 | 镜像版本升级需重新构建 |

#### 方式三：通过 Kurtosis `plan.upload_files` 挂载

**原理**：在 Kurtosis Starlark 中调用 `plan.upload_files()` 上传多项式目录作为 artifact，再通过 `ServiceConfig.files` 挂载到容器。

需要修改两处 kurtosis-cdk 代码：

**修改 1** — `lib/zkevm_prover.star`：`_start_service()` 增加 `polynomial_artifact` 参数：

```python
def _start_service(plan, type, args, config_artifact, polynomial_artifact, start_port_name):
    # ... 省略 cpu_arch 检测等 ...
    files = {
        "/etc/zkevm": config_artifact,
    }
    if polynomial_artifact:
        files["/usr/src/app/config"] = polynomial_artifact

    return plan.add_service(
        name="zkevm-" + type + args["deployment_suffix"],
        config=ServiceConfig(
            image=args["zkevm_prover_image"],
            ports=ports,
            public_ports=public_ports,
            files=files,
            # ... 省略 entrypoint/cmd ...
        ),
    )
```

同步修改 `start_prover()`、`start_executor()`、`start_stateless_executor()` 三个公开函数的签名。

**修改 2** — `cdk_central_environment.star`：在调用 `start_prover()` 前上传多项式文件：

```python
polynomial_artifact = None
if args["zkevm_use_real_prover_client"]:
    polynomial_artifact = plan.upload_files(
        src=args["zkevm_prover_polynomial_path"],
        name="prover-polynomials",
    )

zkevm_prover_package.start_prover(
    plan, args, prover_config_artifact, polynomial_artifact, "zkevm_prover_start_port"
)
```

在 `input_parser.star` 中添加：

```python
"zkevm_prover_polynomial_path": "/data/prover-polynomials/v8.0.0-rc.9-fork.12/config",
```

**需要先完成步骤 A**。

| 优点 | 缺点 |
|------|------|
| 镜像保持标准大小 | 每次重建 enclave 需重新打包/传输 115GB（同一主机约 10-30 分钟） |
| 多项式文件可独立更新，无需重建镜像 | 需修改 3 个 Starlark 文件的函数签名 |
| 不依赖 Docker registry | `plan.upload_files` 对超大目录的支持未充分验证 |

#### 方式四：修改 entrypoint，容器启动时下载

**原理**：在 `zkevm_prover.star` 的 `cmd` 中前置 wget 下载逻辑。

```python
cmd=[
    'apt update && apt install -y wget && '
    'wget -c https://storage.googleapis.com/zkevm/zkproverc/v8.0.0-rc.9-fork.12.tgz -P /tmp/ && '
    'tar -xzf /tmp/v8.0.0-rc.9-fork.12.tgz -C /tmp/ && '
    'rm -rf /usr/src/app/config && '
    'mv /tmp/v8.0.0-rc.9-fork.12/config /usr/src/app/config && '
    '/usr/local/bin/zkProver -c /etc/zkevm/{0}-config.json'.format(type),
],
```

| 优点 | 缺点 |
|------|------|
| 零 kurtosis-cdk 结构改动 | 每次容器重启下载 75GB（约 10-60 分钟，取决于 GCS 带宽） |
| 实现最简单 | 容器启动时间从秒级变为小时级 |
| 不占额外磁盘空间（仅容器内） | 网络中断导致启动失败，无断点续传保障 |

#### 推荐

| 场景 | 推荐方式 |
|------|---------|
| 单机部署，想用 Docker -v 直接挂载 | **方式一**（零拷贝，不改 kurtosis-cdk，跳过步骤 A） |
| 需要 Kurtosis 管理 prover 生命周期 | **方式二**（构建含多项式镜像） |
| 频繁重建 enclave 的实验环境 | **方式三**（避免反复构建 115GB 镜像） |
| 快速验证、网络条件好 | 方式四（改动最小，但启动极慢） |

以下步骤 E 基于**方式一**编写（最简实施路径：不改 kurtosis-cdk，宿主机目录直接挂载）。

### 步骤 E：部署并验证

```bash
# 1. 确认 params.template.yml 中的参数
grep -E 'zkevm_use_real_verifier|zkevm_use_real_prover_client' cdk-work/scripts/params.template.yml

# 2. 部署 CDK（Kurtosis 跳过 prover 启动）
bash cdk_pipe.sh

# 3. 确认 prover 不在 Kurtosis 服务列表中
kurtosis enclave inspect cdk-gen | grep -c zkevm-prover
# 预期输出: 0

# 4. 启动外部 prover 容器（加入 Kurtosis Docker 网络）
export KURTOSIS_NETWORK=$(docker network ls -q -f name=kt-)
docker run -d \
  --name zkevm-prover \
  --network $KURTOSIS_NETWORK \
  -v /data/prover-polynomials/v8.0.0-rc.9-fork.12/config:/usr/src/app/config \
  -v /data/prover-polynomials/prover-config.json:/usr/src/app/config.json \
  hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12 \
  zkProver -c /usr/src/app/config.json

# 5. 检查 prover 日志，确认连接 aggregator 成功
docker logs -f zkevm-prover
# 预期日志含: "Vectorization based on AVX2" 或 "AVX512"
# 不应出现: "zkevm.const file not found" 之类错误

# 6. 检查 cdk-node 日志，确认收到 prover 连接
kurtosis service logs cdk-gen cdk-node-1 | grep -i "prover"

# 7. 观察 verified batch 增长（真实证明需要数分钟，非瞬时）
cast rpc --rpc-url $L2_RPC zkevm_verifiedBatchNumber
```

## 方案二的优势与局限

**优势**：
- 网络配置极简：prover 和 cdk-node 在同一 Docker 网络，直接用 `cdk-node-1:50081`
- 不引入外部依赖，整体在一个主机上
- 方式一（推荐）**不需要修改 kurtosis-cdk 代码**，直接用 `docker run -v` + Kurtosis Docker 网络
- 方式二保留 Kurtosis 统一管理 prover 生命周期

**局限**：
- 主机必须同时满足 prover (700GB+) 和其他所有服务的内存需求
- prover 资源消耗可能影响 sequencer 出块延迟
- 方式二/三**必须 fork 并修改 kurtosis-cdk 模板**（方式一可跳过步骤 A）
- **必须额外处理多项式文件注入**（115GB）——标准镜像不含此文件（方式一用 `-v` 挂载最简）
- 扩容受限：多链场景下每链都需要一台 700GB+ 主机

## 选择建议

| 场景 | 推荐方案 |
|------|---------|
| 单链测试/验证真实性 | 方案二方式一（最简：不改 kurtosis-cdk，docker run -v 挂载） |
| 单链长期运行 | 方案二方式一（Docker DNS 直连，宿主机文件挂载，零拷贝） |
| 生产环境单链 | 方案一（独立部署，资源隔离最彻底） |
| 多链生产 | 方案一（每链一台独立 prover 机器，每链一个独立 AggregatorClient 进程） |
| 需要 Kurtosis 管理 prover | 方案二方式二（构建含多项式镜像） |
| 不想改 kurtosis-cdk 代码 | 方案二方式一 或 方案一（两者均不需要改模板） |


# 简要综合实施步骤

  1. 同一台机器运行 cdk+prover： 配置 `zkevm_use_real_verifier: false` 后部署， 即完成 Kurtosis 启动 mock prover + L1 Mock Verifier
  2. 将 mock prover 拆到独立机器： `docker stop zkevm-prover-1`（Kurtosis 内的 prover 容器），独立启动 mock prover，接上面的 cdk-node, 至此 “独立 mock prover + kurtosis cdk” 完成
  3. 开始验证 “独立 real prover + kurtosis cdk”，修改 cdk 配置 `zkevm_use_real_verifier: false` 后部署 kurtosis-cdk
  4. 独立启动 real prover，接上面 cdk-node，验证通过则完成

## mock zkevm-prover 配置
```sh
docker run -d \
  --name mock-prover-config-for-real-cdk.json \
  -v ~/tmp/mock-prover-config.json:/usr/src/app/config.json \
  hermeznetwork/zkevm-prover:v8.0.0-RC9-fork.12 \
  zkProver -c /usr/src/app/config.json
```

```json
{
     "runExecutorServer": true,
     "runHashDBServer": true,
     "runAggregatorClient": false,
     "runAggregatorClientMock": true,
     "aggregatorClientMockTimeout": 1,

     "aggregatorClientHost": "cdk-node-1",
     "aggregatorClientPort": 50081,

     "proverName": "test-prover",

     "executorServerPort": 50071,
     "hashDBServerPort": 50061,
     "hashDBURL": "local",
     "databaseURL": "postgresql://prover_user:redacted@postgres-1:5432/prover_db",

     "keccakScriptFile": "config/scripts/keccak_script.json",
     "storageRomFile": "config/scripts/storage_sm_rom.json",

     "dbMTCacheSize": 1024,
     "dbProgramCacheSize": 1024,
     "dbMultiWrite": true,
     "dbNumberOfPoolConnections": 30,
     "dbGetTree": true,

     "maxExecutorThreads": 20,
     "maxHashDBThreads": 8,

     "executeInParallel": true,
     "useMainExecGenerated": true,
     "stateManager": true,
     "cleanerPollingPeriod": 600,
     "requestsPersistence": 3600,

     "saveOutputToFile": true,
     "saveProofToFile": true,
     "outputPath": "output"
}
```

## real prover 配置

```sh
docker run -d \
  --name real-prover \
  -v /home/ubuntu/tmp/real-prover-config.json:/usr/src/app/config.json \
  -v /home/ubuntu/workspace/v8.0.0-rc.9-fork.12/config:/usr/src/app/config \
  hermeznetwork/zkevm-prover:v8.0.0-RC9-fork.12 \
  zkProver -c /usr/src/app/config.json
```

```json
{
     "runExecutorServer": true,
     "runHashDBServer": true,
     "runAggregatorClient": true,
     "runAggregatorClientMock": false,

     "aggregatorClientHost": "172.31.28.198",
     "aggregatorClientPort": 32784,

     "proverName": "real-prover-rc9-fork12",

     "executorServerPort": 50071,
     "hashDBServerPort": 50061,
     "hashDBURL": "local",
     "databaseURL": "postgresql://prover_user:redacted@172.31.28.198:32771/prover_db",

     "keccakScriptFile": "config/scripts/keccak_script.json",
     "storageRomFile": "config/scripts/storage_sm_rom.json",

     "dbMTCacheSize": 1024,
     "dbProgramCacheSize": 1024,
     "dbMultiWrite": true,
     "dbNumberOfPoolConnections": 30,
     "dbGetTree": true,

     "executeInParallel": true,
     "useMainExecGenerated": true,
     "stateManager": true,
     "cleanerPollingPeriod": 600,
     "requestsPersistence": 3600,

     "saveOutputToFile": true,
     "saveProofToFile": true,
     "outputPath": "output",
     "configPath": "/usr/src/app/config",

     "mapConstPolsFile": true,
     "mapConstantsTreeFile": true,
     "maxExecutorThreads": 4,    
     "maxProverThreads": 1
}
```

### 各配置项说明

**运行模式（核心）**

| 字段 | 值 | 说明 |
|------|---|------|
| `runExecutorServer` | `true` | 启动 Executor gRPC 服务端（端口 50071），被 sequencer 调用执行交易 |
| `runHashDBServer` | `true` | 启动 HashDB gRPC 服务端（端口 50061），提供 Sparse Merkle Tree 状态读写 |
| `runAggregatorClient` | `false` | 不启动真实证明客户端。改为 `true` 后连接 cdk-node aggregator 生成真实 ZK 证明，需 512GB+ RAM |
| `runAggregatorClientMock` | `true` | 启动 mock 证明客户端，生成假证明（瞬时返回），用于测试全链路连通性 |
| `aggregatorClientMockTimeout` | `1` | mock 证明返回延迟（微秒），`1` = 几乎瞬时。模拟真实延迟可设为 `180000000`（3分钟） |

**网络连接**

| 字段 | 值 | 说明 |
|------|---|------|
| `aggregatorClientHost` | `"cdk-node-1"` | cdk-node aggregator 的主机名。同一 Docker 网络内用服务名；外部部署改为宿主机 IP |
| `aggregatorClientPort` | `50081` | cdk-node aggregator 端口。同一 Docker 网络用容器内端口；外部部署改为映射端口（如 `32783`） |

**数据库**

| 字段 | 值 | 说明 |
|------|---|------|
| `databaseURL` | `"postgresql://...@postgres-1:5432/prover_db"` | SMT 状态持久化。`"local"` = 进程内 SQLite（不需外部 DB）；同一 Docker 网络用服务名；外部部署改为宿主机 IP:映射端口 |
| `dbMTCacheSize` | `1024` | Merkle Tree 节点缓存（MB）。默认 8192（8GB），mock 模式可降至 1024 |
| `dbProgramCacheSize` | `1024` | 合约字节码缓存（MB）。默认 1024（1GB） |
| `dbMultiWrite` | `true` | 批量写入数据库，减少 DB 往返 |
| `dbNumberOfPoolConnections` | `30` | 数据库连接池大小 |
| `dbGetTree` | `true` | 使用 PostgreSQL PL-SQL `GetTree` 函数获取 SMT 路径 |

**端口与服务**

| 字段 | 值 | 说明 |
|------|---|------|
| `executorServerPort` | `50071` | Executor gRPC 服务监听端口 |
| `hashDBServerPort` | `50061` | HashDB gRPC 服务监听端口 |
| `hashDBURL` | `"local"` | Executor 访问 HashDB 的方式。`"local"` = 进程内直连（性能最优）；设为 `"host:port"` 则走 gRPC 远程访问 |

**脚本文件（ROM）**

| 字段 | 值 | 说明 |
|------|---|------|
| `keccakScriptFile` | `"config/scripts/keccak_script.json"` | Keccak-f 状态机 ROM 脚本 |
| `storageRomFile` | `"config/scripts/storage_sm_rom.json"` | Storage 状态机 ROM 脚本 |

> 镜像自带，路径由 `configPath`（默认 `"config"`）前缀拼合。

**线程池**

| 字段 | 值 | 说明 |
|------|---|------|
| `maxExecutorThreads` | `20` | Executor gRPC 服务最大线程数 |
| `maxHashDBThreads` | `8` | HashDB gRPC 服务最大线程数 |

**性能与状态管理**

| 字段 | 值 | 说明 |
|------|---|------|
| `executeInParallel` | `true` | 并行执行辅助状态机（Keccak、SHA256 等），提升吞吐 |
| `useMainExecGenerated` | `true` | 使用编译期生成的 Main SM 代码，比解释执行快 |
| `stateManager` | `true` | 批次间状态合并，避免重复写 DB 导致膨胀 |

**清理**

| 字段 | 值 | 说明 |
|------|---|------|
| `cleanerPollingPeriod` | `600` | 已完成批次清理检查间隔（秒） |
| `requestsPersistence` | `3600` | 已完成批次保留时间（秒），超时后清理 |

**调试输出**

| 字段 | 值 | 说明 |
|------|---|------|
| `saveOutputToFile` | `true` | 保存执行结果到文件 |
| `saveProofToFile` | `true` | 保存生成的证明到文件 |
| `outputPath` | `"output"` | 输出文件目录 |
| `proverName` | `"test-prover"` | prover 标识名，出现在 cdk-node 日志和 metrics 中 |

### mock → real 变动清单

| 字段 | mock | real |
|------|------|------|
| `runAggregatorClient` | `false` | `true` |
| `runAggregatorClientMock` | `true` | `false` |
| `aggregatorClientMockTimeout` | `1` | 删除此行 |
| `databaseURL` | 视部署方式 | 外部部署时改 IP:映射端口 |
| `aggregatorClientHost` | `"cdk-node-1"` | 外部部署时改宿主机 IP |