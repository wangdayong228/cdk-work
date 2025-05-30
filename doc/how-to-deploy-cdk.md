# 如何适用 cdk 部署一条 espace l2
1. 如果 cdk docker image 没有编译过或代码有修改，先编译 cdk docker： `cd cdk && make build-docker`
2. l1 发送 1000 eth 到地址 `0x577C45D5Df835cc97e7c4BFDaDf3320611B115De`，该地址为配置的 l1_preallocated_mnemonic
3. 使用 `cd cdk-work && ./deploy-cfx.sh` 脚本部署一个新的 cdk l2, 它里面本质做了如下操作:
    a. 清除了之前部署的 enclave
    b. 运行 update-salt.sh 更新 cdk 合约部署时用到的 盐
    c. 运行 kurtosis run 命令 来部署相关服务
4. 运行 `cd cdk-work/update-nginx && ./update_nginx_ports.sh YOUR_ENCLAVE_NAME` 生成 nginx 配置，**该配置会修改cdk-xxx-ports中的端口映射**并自动 reload nginx。对应关系见[cdk 端口映射关系](#cdk-端口映射关系)
5. 如果conflux作为l1, 则修改 `jsonrpc-proxy` service 用到的 l2 rpc 端口号 (同上修改 cdk-ports 即可), 并重启服务 `pm2 restart 0`
6. 给账号 `0x8943545177806ED17B9F23F0a21ee5948eCaa776` 在 l2 上转移一笔资金, 该账号会不停发送交易, 具体转账命令参看 readme.md 中的说明(设置 rpc, 设置私钥, 发送交易) 
    - `cast send --legacy --rpc-url $zk_l2_rpc --private-key $zk_l2_pk --value 1000ether 0x8943545177806ED17B9F23F0a21ee5948eCaa776`

## cdk 端口映射关系

1. l2 的 rpc 服务使用 cdk-erigon-rpc-001 的  rpc 端口
2. grafana 使用 grafana-001 的 dashboards 端口
3. bridge 的 UI 使用 zkevm-bridge-ui-001 的 web-ui 端口
4. bridge 的 service 使用 zkevm-bridge-service-001 的 rpc 端口

## 配置相关
1. 设置绑定静态宿主机端口： `args.use_dynamic_ports: false` （可能会因为端口冲突之类的部署失败）

## MISC

子涵在进行 l2 的跨链测试, cdk 重新部署后, 需要给它的测试账号转一笔钱 `0x180F2613c52c903A0d79B8025D8B14e461b22eF1`

并且发送新的 合约地址