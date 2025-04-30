# cdk

## 目标

在 Conflux eSpace 部署一个 Polygon zkEVM L2

部署方式:

1. kurtosis-cdk: `cd kurtosis-cdk && ./deploy-to-espace.sh`
2. 自己手动部署: 需要了解各个模块的作用, 以及如何启动(编译,配置等), 总体而言比较复杂

暂时选择第一种方式

## [kurtosis](https://docs.kurtosis.com/) 常见操作

kurtosis clean --all

kurtosis enclave inspect cdk

kurtosis service shell cdk contracts-001

kurtosis service logs cdk cdk-node-001

## kurtosis-cdk 

在一个已有 L1 上部署 CDK 参考文档: https://github.com/0xPolygon/kurtosis-cdk/blob/main/docs/deploy-using-sepolia.org

主要注意事项:

1. 部署合约时 hardcode 了一些 gasLimit, 需要进行 double
2. 需要一个没有 rate limit 的 L1 RPC 服务 
3. cdk 在有修改后，需要 build docker，`cd cdk && make build-docker`

## cdk 可配置的模块

1. SCALING SOLUTION: Rollup/Validium
2. Sequencer: centralised/decentralised
3. Data availability: local/l1/3rd party
4. prover: type1/type2
5. agglayer: enable/disable

the Polygon CDK stack has 3 main configurations (with options to customize further): 

1. zk rollup config
2. validium config
3. Agglayer native config.

## params.yml 配置

params.yml 用于覆盖[默认配置](https://teams.microsoft.com/l/message/19:eefe6ee693434fe5bf6d255232b7c3d6@thread.v2/1744009724103?context=%7B%22contextType%22%3A%22chat%22%7D)

启动时指定配置文件 `kurtosis run --enclave cdk --args-file ./params.yml .`

## trusted/virtual/verified batch 的含义

[cdk-erigon-sequencer-001](https://docs.polygon.technology/cdk/getting-started/cdk-erigon/#trusted-state)

## cdk 各个模块的作用

https://docs.polygon.technology/cdk/getting-started/cdk-erigon/#polygon-zkevm-components

zkevm-stateless-executor 和 zkevm-prover 的区别? 他们共用一个 image (zkevm-prover); zkevm-prover 主要用来生成交易执行的 zkproof

cdk-erigon 中有一个配置 zkevm.executor-urls 是指向 zkevm-stateless-executor 的.

在 cdk 中 sequencer 负责执行交易和创建 block, batch.

难道 sequencer 又调用了 zkevm-stateless-executor 来执行交易?

官方回复: zkevm-stateless-executor 主要用于生成交易执行的 trace: The executor is responsible for generating a correct execution trace from a given set of inputs.

## zkevm 各个合约的作用和关系

https://docs.polygon.technology/zkEVM/architecture/high-level/smart-contracts/

## 如何查看状态?

```sh
# 设置 rpc
rpc_url=$(kurtosis port print cdk cdk-erigon-rpc-001 rpc)
export ETH_RPC_URL="$(kurtosis port print cdk cdk-erigon-rpc-001 rpc)"

# You might have to change this value!
# 设置 private key 环境变量用于发送交易
zkevm_l2_admin_private_key="$(yq '.args.zkevm_l2_admin_private_key' .github/tests/external-l1/deploy-cdk-to-sepolia.yml)" 
zkevm_l2_admin_private_key="0x9b82a200f0918eb9aa0de19fe0da05dc77bb065dd912a0d7e1f3e2c7de6b122c"

# 查看 batch number
cast rpc --rpc-url $rpc_url zkevm_batchNumber
cast rpc --rpc-url $rpc_url zkevm_virtualBatchNumber
cast rpc --rpc-url $rpc_url zkevm_verifiedBatchNumber

# 转账
cast send --legacy --rpc-url $rpc_url --private-key $zkevm_l2_admin_private_key --value 1 0x0000000000000000000000000000000000000000
cast send --legacy --rpc-url $rpc_url --private-key $zkevm_l2_admin_private_key --value 100000000000000000000 0x8943545177806ED17B9F23F0a21ee5948eCaa776
```


## Issues

1. zkevm_virtualBatchNumber & zkevm_verifiedBatchNumber 返回值一直是 0x1: 具体原因及修复方式参看 batch-sequence-issue.md

### Next step

1. 是否需要 enable 真实的 prover, 需要 GPU?
2. 跨链操作, 准备一批有余额的账户用于测试  ✅
3. 配置 bridge-ui 可访问  ✅ 基本 ready, 但是需要配置 bridge-service url, 目前看需要配置一个 grpc-gateway
4. 配置 oberervility ✅

## 有错误日志的 service 

1. zkevm-stateless-executor-001
2. zkevm-bridge-service-001
3. cdk-node-001

## MISC

1. grafana: https://cdkgrafana.conflux123.xyz/
2. bridge service 中 net_id=0 表示l1, net_id=1表示l2。 

## FAQs

1. Full Execution Proofs (FEP) 和 Pessimistic Proofs (PP) 区别? 前者是指所有的状态转换都有 proof 生成; 后者是指 agglayer 跨链服务的相关证明; 两者不是一个维度的东西



curl --location 'http://127.0.0.1:13030' \
--header 'Content-Type: application/json' \
--data '{
	"jsonrpc":"2.0",
	"method":"eth_gasPrice",
	"params":[],
	"id":73
}'