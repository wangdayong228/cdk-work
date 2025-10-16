# 已改为配置文件中配置
# sed -i 's/"salt": "0x.*",/"salt": "0x'$(xxd -p < /dev/random  | tr -d "\n" | head -c 64)'",/' ../../kurtosis-cdk/templates/contract-deploy/deploy_parameters.json