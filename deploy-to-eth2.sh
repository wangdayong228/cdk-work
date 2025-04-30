# pm2 start 0
kurtosis enclave rm -f cdk-eth2
sh ./update-salt.sh
kurtosis run --enclave cdk-eth2 --args-file ./params-eth2.yml ../kurtosis-cdk 2>&1 > deploy-to-eth2.log

echo "Remenber send eth to 0x8943545177806ED17B9F23F0a21ee5948eCaa776 and 0x180F2613c52c903A0d79B8025D8B14e461b22eF1 on zk2_l2_rpc"
# 给一直发交易的地址转账
# cast send --legacy --rpc-url $zk2_l2_rpc --private-key $zk2_l2_pk --value 1000ether 0x8943545177806ED17B9F23F0a21ee5948eCaa776

# 部署完并配置完 nginx 的 cdk2-ports 后执行
# cast send --legacy --rpc-url $zk2_l2_rpc --private-key $zk2_l2_pk --value 1000ether 0x180F2613c52c903A0d79B8025D8B14e461b22eF1

