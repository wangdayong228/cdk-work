# errors

## contract-deploy error ✅

[2025-01-21 03:22:38] Setting the data availability protocol 
Error: server returned an error response: error code -32602: Specified block header does not exist
[2025-01-21 03:22:38] Deploying deterministic deployment proxy
Error: server returned an error response: error code -32602: Specified block header does not exist
Error: server returned an error response: error code -32003: nonce too low

Specified block header does not exist: 是由于  eth_feeHistory 方法不稳定(偶尔返回错误)导致的, 服务会自动重试

nonce too low 是因为 deterministic deployment proxy 在 espace 已完成部署, 可直接跳过

## the following required arguments were not provided ✅

error: the following required arguments were not provided:
  <WHO>

Usage: cast code --rpc-url <URL> <WHO>

For more information, try '--help'.

这是一个 cast 错误
在注释代码时多注释了两行, 导致 cast code 的参数获取不到

## zkevm-bridge-ui-001 部署失败 ✅

在进行默认 local 部署时 `kurtosis run --enclave cdk github.com/0xPolygon/kurtosis-cdk`

Adding service with name 'zkevm-bridge-ui-001' and image 'leovct/zkevm-bridge-ui:multi-network'

https://github.com/0xPolygon/kurtosis-cdk/issues/447

核心原因: 机器内存不足

## 开启 deploy_l2_contracts 后  ✅

```sh
Deploying contracts on L2
There was an error executing Starlark code
An error occurred executing instruction (number 78) at github.com/0xPolygon/kurtosis-cdk/deploy_l2_contracts.star[13:14]:
  exec(service_name="contracts-001", recipe=ExecRecipe(command=["/bin/sh", "-c", "export l2_rpc_url=http://{{kurtosis:477c4ab869b24e6c9501b1a9e77520da:ip_address.runtime_value}}:8123 && chmod +x /opt/contract-deploy/run-l2-contract-setup.sh && /opt/contract-deploy/run-l2-contract-setup.sh"]), description="Deploying contracts on L2")
  Caused by: Exec returned exit code '1' that is not part of the acceptable status codes '[0]', with output:
    "\x1b[32m[2025-01-21 10:18:11]\x1b[0m Waiting for the L2 RPC to be available\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m L2 RPC is now available\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding bridge autoclaimer account on l2\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0xD80f26DfB98d77F8a3E7D7f8d61F6E727905e7F6\n0xdd241893cbb5b7afc8a8cd42ad12cfa25bf47c5bf058daace4b139369fb818d7\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding accounts on l2\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0x577C45D5Df835cc97e7c4BFDaDf3320611B115De\n0x5221fa299d97d08478e6c19e955815d304e4c46518c68b7283ca0445f0ad125e\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0x65d79Da11c273CE868470a4eAf2019AD0DAF5da4\n0xc413b0dcdedc99a4af88a698f609418032239f3401908432d0a9f1ce2effde3f\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0xD80f26DfB98d77F8a3E7D7f8d61F6E727905e7F6\n0x3401fad5f1e40a97002aa5a82c312c1ec28862043bcc51a9290fbe4ea351b1d9\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0x4c17a8D5bedc03848E09CA5F2d1AAF600721f6B9\n0xbd138692579bd3b72283da3a3f4628aec4f5e6a66e750c40bf0eb02ce67818d8\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0x68302C26bfd18A2d7F043Dd17CdF9342CB52158F\n0x8a5519440cb6c1becfd48d7592710056f26188400fe6f720390181886990766a\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0x0CF46Ac969a8F10e6c52ef1805F123538ff97E0f\n0xd6eef6bc777910048bf1828c159b6f447a01dbe217fc645e49684b93e74915a8\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0xcCc3750C59814A572a9C4714567CfcabaE9614B7\n0x5acb02adf95384d91884610b087129c2c8104398c0a76a7740682e1e7b0e7c6f\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0x1a31cC5D7B440a08668a95a052bC0Cfc3eE9729c\n0xb54e9e1acc0283ca6c3652b3ae89a5c0d2a9f0408910117ea2594bd066bc105f\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0x7F5ce0D687ea7ee25b7Eab803F1ee1Dd32EC224F\n0xc9014f4254f04bfb9a692a1a24c9974c490e1b7fed823acb16741fef765f6dc8\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Funding 0x580D941F1a7177F7C79E417FcAf91bC3C0480797\n0x3d43ccbdda0a1b8f1299bb36537302094067572f59139f5a3c12354c9b1df7c3\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Deploying deterministic deployment proxy on l2\nError: server returned an error response: error code -32000: RPC error response: INTERNAL_ERROR: could not replace existing tx\n\x1b[32m[2025-01-21 10:18:17]\x1b[0m Sleeping 10 seconds\nError: server returned an error response: error code -32000: RPC error response: INTERNAL_ERROR: insufficient funds\n\x1b[32m[2025-01-21 10:18:27]\x1b[0m No code at expected l2 address: 0x4e59b44847b379578588920ca78fbf26c0b4956c\n"

Error encountered running Starlark code.
```

发送脚本有问题, 在本地进行了修改

## "Deploying lxly bridge and call on l1" failed

最后两步操作的交易失败了(Unkown contract error)

```sh
[2025-01-21 10:39:48] Deploying lxly bridge and call on l1
Compiling 55 files with Solc 0.8.20
installing solc version "0.8.20"
Successfully installed solc 0.8.20
Solc 0.8.20 finished in 2.80s
Compiler run successful with warnings:
Warning (9302): Return value of low-level calls not used.
   --> lib/zkevm-contracts/contracts/v2/PolygonZkEVMBridgeV2.sol:957:13:
    |
957 |             address(token).call(
    |             ^ (Relevant source part starts here and spans across multiple lines).

Warning (9302): Return value of low-level calls not used.
    --> lib/zkevm-contracts/contracts/v2/PolygonZkEVMBridgeV2.sol:1009:13:
     |
1009 |             address(token).call(
     |             ^ (Relevant source part starts here and spans across multiple lines).

Warning (9302): Return value of low-level calls not used.
  --> src/JumpPoint.sol:63:27:
   |
63 |             if (!success) fallbackAddress.call{value: balance}("");
   |                           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Script ran successfully.

== Logs ==
  Deployed BridgeExtension Implementation to:  0x7bAbf98Cb7cbD2C85F13813409f495B9cF0Dd7D0
  Deployed BridgeExtensionProxy to:  0x64B20Eb25AEd030FD510EF93B9135278B152f6a6

## Setting up 1 EVM.

==========================

Chain 71

Estimated gas price: 20 gwei

Estimated total gas used for script: 3700485

Estimated amount required: 0.0740097 ETH

==========================

Transactions saved to: /opt/lxly-bridge-and-call/broadcast/DeployInitBridgeAndCall.s.sol/71/run-latest.json

Sensitive values saved to: /opt/lxly-bridge-and-call/cache/DeployInitBridgeAndCall.s.sol/71/run-latest.json

Error: Transaction Failure: 0x119aa2ad680c1d2dfe2acb2cdc35fc8e11de7c9deec87d774bd6bb9212e4625e
Transaction Failure: 0x50ef9079f8b6064a7cad53b8f47d88adca0403d366353c6025d55ba2d3220e40
```

失败的交易接受地址(to): https://evmtestnet.confluxscan.io/address/0x4e59b44847b379578588920ca78fbf26c0b4956c

这个是因为打开了 `deploy_l2_contracts` 配置, 它会运行 `templates/contract-deploy/run-l2-contract-setup.sh` 里面
会 clone https://github.com/AggLayer/lxly-bridge-and-call 并使用 forge script 运行 DeployInitBridgeAndCall.s.sol 脚本.

该脚本中使用了固定的 salt=1 来调用 create2 部署合约, 因为其中的合约在 espace 测试网已经运行过, 第二次运行会失败.

所以需要每次部署前, 修改该 salt 值, 然后再部署.

另外 lxly-bridge-and-call 是 agglayer 的一个组件, 应该不影响 cdk 本身的运行.

## 运行一段时间后 agglayer 服务会停掉 ✅

内存不足

## kurtosis log 数据量很大 ✅

因为 cdk-node-001 服务有大量的 log, 是因为 rpc 不兼容导致的不断重试并大量打印重复日志

## l1 rpc 错误

```sh
2025-01-24T07:33:05.248Z error: Req-77 Error: {"method":"zkevm_batchNumber","error":{"code":-32601,"message":"the method zkevm_batchNumber does not exist/is not available"}}
2025-01-24T07:33:05.315Z error: Req-78 Error: {"method":"zkevm_virtualBatchNumber","error":{"code":-32601,"message":"the method zkevm_virtualBatchNumber does not exist/is not available"}}
2025-01-24T07:33:05.383Z error: Req-79 Error: {"method":"zkevm_verifiedBatchNumber","error":{"code":-32601,"message":"the method zkevm_verifiedBatchNumber does not exist/is not available"}}
2025-01-24T07:33:32.901Z error: Req-43 Error: {"method":"bor_getSnapshotProposerSequence","params":["0xc1d1deb"],"error":{"code":-32601,"message":"the method bor_getSnapshotProposerSequence does not exist/is not available"}}
2025-01-24T07:33:32.966Z error: Req-44 Error: {"method":"txpool_status","error":{"code":-32601,"message":"the method txpool_status does not exist/is not available"}}
2025-01-24T07:33:33.234Z error: Req-48 Error: {"method":"eth_sendRawTransaction","params":["0xf86d820944850df84758008252089485da99c8a7c2c95964c8efd687e95e632fc533d68609184e72a0008081b1a0513d472f5c8790dc84fde0f800e54d0fe5faaa896571d8d4317607d03459bca1a0654cccb82f75899cf2cdf4986f20443d3824438b3db0f6def3995f40c1bfb4af"],"error":{"code":-32003,"message":"nonce too high"}}
```

## Setting up 1 EVM.  ✅  RPC 不稳定导致
Error: Could not instantiate forked environment with provider 172.23.41.25

Context:
- Error #0: Failed to get latest block number
- Error #1: server returned an error response: error code -32001: , data: "upstrem status: 400"


## L2 Sender balance not enough: 0x8943545177806ED17B9F23F0a21ee5948eCaa776 ✅

## kurtosis service logs cdk cdk-node-001 没有反应

因为日志太多, 导致响应很慢

如何清理日志: kurtosis? docker? 或者服务自动清理?

## 卡在 Validating plan and preparing container images - execution will begin shortly
原因未知，删掉 enclave 重试就可以过去

## 