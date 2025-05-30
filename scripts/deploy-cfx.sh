pm2 start 0
kurtosis enclave rm -f cdk-cfx
sh ./update-salt.sh
kurtosis run --enclave cdk-cfx --args-file ./params-cfx.yml ../kurtosis-cdk 2>&1 > ./logs/deploy-cfx.log

echo "Remenber send eth to 0x8943545177806ED17B9F23F0a21ee5948eCaa776 on zkc_l2_rpc"
# 给一直发交易的地址转账
# cast send --legacy --rpc-url $zkc_l2_rpc --private-key $zkc_l2_pk --value 1000ether 0x8943545177806ED17B9F23F0a21ee5948eCaa776