# zkEVM 问题调试启动指南

## 连服务器

```sh
ssh -o StrictHostKeyChecking=no -i /Users/dayong/.ssh/dayong-op-stack.pem ubuntu@44.247.2.2
```

## 部署 kurtosis-cdk enclave 及周边服务
```sh
# rm -f /home/ubuntu/workspace/ydyl-deployment-suite/output/cdk_pipe.state; rm -f /home/ubuntu/workspace/ydyl-deployment-suite/cdk-work/output/*; rm -rf /home/ubuntu/workspace/ydyl-deployment-suite/zk-claim-service/.env;
kurtosis enclave rm cdk-gen -f 2>&1 | tail -2 && rm -f /home/ubuntu/workspace/ydyl-deployment-suite/output/cdk_pipe.state && pm2 delete jsonrpc-proxy-cdk 2>/dev/null; echo "清理完成"
```
```sh
rm workspace/ydyl-deployment-suite/output/cdk_pipe.state
cd workspace/ydyl-deployment-suite
L2_CHAIN_ID=10000 L1_CHAIN_ID=7655 L1_RPC_URL=http://184.32.182.132/espace L1_VAULT_PRIVATE_KEY=0xde5a8e8b373a70b6b475cb441ba61d8626fd6d3db81726aadc610867503d5778 L1_BRIDGE_HUB_CONTRACT=0x7aC81f608D15819148317EeAD3169734664205Bb L1_REGISTER_BRIDGE_PRIVATE_KEY=0xa3d9e98f0ba98960bf3755b7519d18b2250b0b8be5e38d5483dcfa3875df2d6f DRYRUN=false FORCE_DEPLOY_CDK=true ENABLE_GEN_ACC=false ./cdk_pipe.sh
```

部署完后会有一套 kurtosis cdk enclave 和 jsonrpc-proxy；jsonrpc-proxy-cdk 是一个代理，用于 conflux rpc 适配，使用 pm2 管理；（pm2其它服务用不到)

```
➜  pm2 ls
┌────┬────────────────────────────────────────┬─────────────┬─────────┬─────────┬──────────┬────────┬──────┬───────────┬──────────┬──────────┬──────────┬──────────┐
│ id │ name                                   │ namespace   │ version │ mode    │ pid      │ uptime │ ↺    │ status    │ cpu      │ mem      │ user     │ watching │
├────┼────────────────────────────────────────┼─────────────┼─────────┼─────────┼──────────┼────────┼──────┼───────────┼──────────┼──────────┼──────────┼──────────┤
│ 0  │ jsonrpc-proxy-cdk                      │ default     │ N/A     │ fork    │ 3819     │ 51m    │ 0    │ online    │ 0%       │ 115.7mb  │ ubuntu   │ disabled │
│ 5  │ l1-l2-eventListener                    │ default     │ 1.0.0   │ cluster │ 42429    │ 31m    │ 0    │ online    │ 0%       │ 70.1mb   │ ubuntu   │ disabled │
│ 6  │ l1-l2-proofFetcher                     │ default     │ 1.0.0   │ cluster │ 42430    │ 31m    │ 0    │ online    │ 0%       │ 70.4mb   │ ubuntu   │ disabled │
│ 7  │ l1-l2-transactionSender                │ default     │ 1.0.0   │ cluster │ 42443    │ 31m    │ 0    │ online    │ 0%       │ 71.4mb   │ ubuntu   │ disabled │
│ 8  │ l1-l2-transactionSenderBalanceCheck    │ default     │ 1.0.0   │ cluster │ 42444    │ 31m    │ 0    │ online    │ 0%       │ 72.4mb   │ ubuntu   │ disabled │
│ 1  │ l2-l1-eventListener                    │ default     │ 1.0.0   │ cluster │ 42401    │ 31m    │ 0    │ online    │ 0%       │ 71.6mb   │ ubuntu   │ disabled │
│ 2  │ l2-l1-proofFetcher                     │ default     │ 1.0.0   │ cluster │ 42402    │ 31m    │ 0    │ online    │ 0%       │ 70.2mb   │ ubuntu   │ disabled │
│ 3  │ l2-l1-transactionSender                │ default     │ 1.0.0   │ cluster │ 42415    │ 31m    │ 0    │ online    │ 0%       │ 71.3mb   │ ubuntu   │ disabled │
│ 4  │ l2-l1-transactionSenderBalanceCheck    │ default     │ 1.0.0   │ cluster │ 42416    │ 31m    │ 0    │ online    │ 0%       │ 73.9mb   │ ubuntu   │ disabled │
│ 9  │ ydyl-console-service                   │ default     │ N/A     │ fork    │ 50413    │ 30m    │ 0    │ online    │ 0%       │ 39.4mb   │ ubuntu   │ disabled │
└────┴────────────────────────────────────────┴─────────────┴─────────┴─────────┴──────────┴────────┴──────┴───────────┴──────────┴──────────┴──────────┴──────────┘
```

## 看 kurtosis enclave 各容器情况

```sh
kurtosis enclave inspect cdk-gen
```

```
========================================== User Services ==========================================
UUID           Name                     Ports                                                     Status
db8dde8d44b5   cdk-erigon-rpc-1         pprof: 6060/tcp -> http://127.0.0.1:32777                 RUNNING
                                        prometheus: 9091/tcp -> http://127.0.0.1:32780
                                        rpc: 8123/tcp -> http://127.0.0.1:32778
                                        ws-rpc: 8133/tcp -> ws://127.0.0.1:32779
bbe0fd12ac25   cdk-erigon-sequencer-1   data-streamer: 6900/tcp -> datastream://127.0.0.1:32772   RUNNING
                                        pprof: 6060/tcp -> http://127.0.0.1:32771
                                        prometheus: 9091/tcp -> http://127.0.0.1:32775
                                        rpc: 8123/tcp -> http://127.0.0.1:32773
                                        ws-rpc: 8133/tcp -> ws://127.0.0.1:32774
e7f1f4893f4a   cdk-node-1               aggregator: 50081/tcp -> grpc://127.0.0.1:32783           RUNNING
                                        rest: 5577/tcp -> http://127.0.0.1:32782
                                        rpc: 5576/tcp -> http://127.0.0.1:32781
b01247b94c9f   contracts-1              http: 8080/tcp -> http://127.0.0.1:32769                  RUNNING
881e97583ca2   grafana-1                dashboards: 3000/tcp -> http://127.0.0.1:32789            RUNNING
51b50890726e   panoptichain-1           prometheus: 9090/tcp -> http://127.0.0.1:32787            RUNNING
9a1f8780624d   postgres-1               postgres: 5432/tcp -> postgresql://127.0.0.1:32770        RUNNING
c0cc30439eb0   prometheus-1             http: 9090/tcp -> http://127.0.0.1:32788                  RUNNING
b47845a91589   status-checker-1         prometheus: 9090/tcp -> http://127.0.0.1:32790            RUNNING
3f7cd17108d6   zkevm-bridge-service-1   grpc: 9090/tcp -> grpc://127.0.0.1:32786                  RUNNING
                                        prometheus: 8090/tcp -> http://127.0.0.1:32785
                                        rpc: 8080/tcp -> http://127.0.0.1:32784
1491b0db4b8e   zkevm-pool-manager-1     http: 8545/tcp -> http://127.0.0.1:32776                  RUNNING
```

## 看某个服务的 docker 容器

```sh
docker ps | grep <Name>
```

```
➜  ~ docker ps | grep cdk-node-1
c7a9909cc831   davidyoung2025/cdk:local                                                                                  "sh -c 'sleep 20 && …"   18 minutes ago   Up 18 minutes   0.0.0.0:32781->5576/tcp, [::]:32781->5576/tcp, 0.0.0.0:32782->5577/tcp, [::]:32782->5577/tcp, 0.0.0.0:32783->50081/tcp, [::]:32783->50081/tcp                                                                                                                                                                                        cdk-node-1--e7f1f4893f4a40119e1f9323dcca1bb0
```

## 当修改某个 repo 后需要 build docker

比如 cdk-node 在修改后需要 `make build-docker`；然后修改 tag 到当前容器使用的 tag；当前 cdk 是 `davidyoung2025/cdk:local`。cdk-erigon 是 `hermeznetwork/cdk-erigon:v2.61.24`。

## 部署 zkevm-prover

### 设置 config 文件

其中：

- `aggregatorClientHost` 改为上方 kurtosis cdk IP，也就是 `44.247.2.2`
- `aggregatorClientPort` 改为上方 kurtosis enclave `cdk-node-1` aggregator 端口，也就是 `32783`
- `databaseURL` 中的 IP 改为 kurtosis cdk IP，也就是 `44.247.2.2`；端口改为 `postgres-1` 的端口，也就是 `32770`

```json
{
     "runExecutorServer": true,
     "runHashDBServer": true,
     "runAggregatorClient": true,
     "runAggregatorClientMock": false,

     "aggregatorClientHost": "44.247.2.2",
     "aggregatorClientPort": 32783,

     "proverName": "real-prover-rc16-fork12",

     "executorServerPort": 50071,
     "hashDBServerPort": 50061,
     "hashDBURL": "local",
     "databaseURL": "postgresql://prover_user:redacted@44.247.2.2:32770/prover_db",

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

     "saveRequestToFile": true,
     "saveResponseToFile": true,
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

### 启动容器

```sh
docker rm real-prover 2>/dev/null; docker run -d \
  --name real-prover \
  -v /root/polygon-suite/zkevm-prover/config.json:/usr/src/app/config.json \
  -v /root/polygon-suite/zkevm-prover/v8.0.0-rc.9-fork.12/config:/usr/src/app/config \
  hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12 \
  zkProver -c /usr/src/app/config.json
```

启动到生成证明大约 1～3 小时，在 `outputPath` 下可以看到 grpc 的通信数据。


启动到生成证明大约 1～3 小时，在 `outputPath` 下可以看到 grpc 的通信数据。

---

## 自动对比 InvalidProof (0x09bde339) 两边数据

当 aggregator 提交 batch proof 到 L1 失败并返回 `execution reverted: InvalidProof()` 时，需要对比 **prover 电路 public inputs** 与 **L1 合约期望的 inputSnark 字段**，定位具体哪个字段不匹配。

### 工具位置

`cdk-work/scripts/compare-invalidproof.py`

### 依赖

- Python 3
- `cast` (foundry) — 用于查询 L1 链上数据
- `docker` — 用于从 aggregator 容器提取 proof

### 用法 1：自动从 aggregator 容器提取并对比（推荐）

```sh
cd /home/ubuntu/workspace/ydyl-deployment-suite/cdk-work/scripts
python3 compare-invalidproof.py --batch 1
```

参数说明：
- `--batch 1`：要对比的 batch 编号（默认 1）
- `--aggregator-container cdk-node-1--...`：aggregator 容器名（默认当前 enclave 的 cdk-node-1）
- `--l1-rpc http://184.32.182.132/espace`：L1 RPC URL
- `--rollup-manager 0x9dfC9f5864F1d1a7dB83EC2e81F876BFD68dF1EE`：RollupManager 合约地址

### 用法 2：离线模式（手动提供 publics）

如果你已经从其他地方拿到了 prover 的 publics 数组（44 个 Goldilocks field elements），可以离线对比：

```sh
python3 compare-invalidproof.py --offline \
  --publics '2420688097,2333259367,2981116379,1944022402,1542236844,4111906473,3224877213,4286371784,0,0,0,0,0,0,0,0,0,10000,12,2420688097,2333259367,2981116379,1944022402,1542236844,4111906473,3224877213,4286371784,878221566,4158253300,1449558182,1396388316,308403776,3351930181,2850044872,3172363002,0,0,0,0,0,0,0,0,1' \
  --l1-rpc http://184.32.182.132/espace
```

### 输出示例

```
======================================================================
Batch 1 InvalidProof 对比结果
======================================================================

Field                Prover (circuit)                                                     L1 (contract)                                                        Status
-------------------- -------------------------------------------------------------------- -------------------------------------------------------------------- ----------
oldStateRoot         0xff7cd7c8c037b89df516b6a95becaaac73df6d82b1b039db8b12b6679048c4e1   0xd96db188d8a5a3193c085e10488be6624182c23955a5927e0cf3ae941f10d1ea   MISMATCH
oldAccInputHash      0x0000000000000000000000000000000000000000000000000000000000000000   0x0000000000000000000000000000000000000000000000000000000000000000   OK
initNumBatch         0                                                                    0                                                                    OK
chainID              10000                                                                10000                                                                OK
forkID               12                                                                   12                                                                   OK
newStateRoot         0xff7cd7c8c037b89df516b6a95becaaac73df6d82b1b039db8b12b6679048c4e1   0x0000000000000000000000000000000000000000000000000000000000000000   MISMATCH
newAccInputHash      0xbd166afaa9e03bc8c7ca65451261de40533b31dc566680a6f7d9e8f4345898fe   0x3b488027196ccf45ee5a2897daf281536fd8aa37535b76c47de4b46125d88644   MISMATCH
newLocalExitRoot     0x0000000000000000000000000000000000000000000000000000000000000000   0x0000000000000000000000000000000000000000000000000000000000000000   OK
finalNewBatch        1                                                                    1                                                                    OK

======================================================================
发现 4 个不匹配字段: oldStateRoot, newStateRoot, newAccInputHash
这些字段的差异会导致 inputSnark 的 sha256 结果不同，从而触发 InvalidProof (0x09bde339)。
======================================================================
```

### 字段说明

| 字段 | L1 来源 | Prover 来源 |
|------|---------|-------------|
| oldStateRoot | `batchNumToStateRoot[initNumBatch]` | witness2db 从 witness 重算的 OLD smt 根 |
| oldAccInputHash | `sequencedBatches[initNumBatch].accInputHash` | publics[8..15] |
| newStateRoot | aggregator 传入 (= proverSR) | publics[19..26] |
| newAccInputHash | `sequencedBatches[finalNewBatch].accInputHash` | publics[27..34] |
| newLocalExitRoot | aggregator 传入 (= proverLER) | publics[35..42] |

### fea2scalar 解码算法

prover 的 publics 是 Goldilocks field elements (uint64)。`compare-invalidproof.py` 使用与 zkevm-prover 相同的 `fea2scalar` 算法解码为 bytes32：

- 每 2 个 publics 元素组成一个 64 位值：高 32 位来自奇数索引元素，低 32 位来自偶数索引元素
- 4 对元素组成 256 位 = 32 字节
- 整体大端排列（第 7/6 对在最前面）

例如 publics[19..26] 解码为 newStateRoot：
```python
pairs = [
    (publics[26] << 32) + publics[25],  # fe7 + fe6
    (publics[24] << 32) + publics[23],  # fe5 + fe4
    (publics[22] << 32) + publics[21],  # fe3 + fe2
    (publics[20] << 32) + publics[19],  # fe1 + fe0
]
scalar = (pairs[0] << 192) | (pairs[1] << 128) | (pairs[2] << 64) | pairs[3]
```
