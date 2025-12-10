#!/bin/bash
set -xEueo pipefail
trap 'echo "🔴 update_nginx_ports.sh 执行失败: 行 $LINENO, 错误信息: $BASH_COMMAND"; exit 1' ERR

# 处理命令行参数 - 只接受一个参数作为 ENCLAVE_NAME
if [ $# -eq 1 ]; then
  ENCLAVE_NAME="$1"
else
  echo "错误：必须指定 ENCLAVE_NAME！"
  exit 1
fi

echo "使用 Enclave: $ENCLAVE_NAME"

if [ -z "$L1_RPC_URL" ]; then
  echo "错误：请设置 L1_RPC_URL 环境变量！"
  exit 1
fi

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 从模板文件读取内容
TEMPLATE_FILE="${SCRIPT_DIR}/${ENCLAVE_NAME}-upstreams.tmpl.conf"
INGRESS_FILE="${SCRIPT_DIR}/${ENCLAVE_NAME}-ingress.conf"
if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "错误：模板文件 $TEMPLATE_FILE 不存在！"
  exit 1
fi

# 确保 ingress 源文件存在
if [ ! -f "$INGRESS_FILE" ]; then
  echo "错误：$INGRESS_FILE 不存在"
  exit 1
fi

# 复制时显式目标文件名，并使用 sudo；按需选择 -f(覆盖) 或 -n(不覆盖)
sudo cp -f "$INGRESS_FILE" "/etc/nginx/sites-available/${ENCLAVE_NAME}-ingress.conf"
# 创建/更新符号链接：-s(软链) -f(覆盖已存在) -n(不跟随目录) -v(可选：打印)
sudo ln -sfn "/etc/nginx/sites-available/${ENCLAVE_NAME}-ingress.conf" "/etc/nginx/sites-enabled/${ENCLAVE_NAME}-ingress.conf"

# 读取模板文件内容
template=$(cat "$TEMPLATE_FILE")
echo "已加载模板文件: $TEMPLATE_FILE"

# 获取 kurtosis 中服务的 HTTP 端口

# 获取 kurtosis 中服务的 HTTP 端口
# L1_RPC_PORT=$zkc_l1_rpc||"http://127.0.0.1:3030"

# if [ "$ENCLAVE_NAME" == "cdk-eth" ]; then
#     # L1_RPC_PORT="http://"$(kurtosis port print ${ENCLAVE_NAME} el-1-geth-lighthouse rpc)
#     L1_RPC_PORT="https://eth.yidaiyilu0.site/rpc"
# fi


# if [ "$ENCLAVE_NAME" != "cdk-cfx" ]; then
#     L1_RPC_PORT=$(kurtosis port print ${ENCLAVE_NAME} cdk-erigon-rpc-1 rpc)
# fi

L2_RPC_PORT=$(kurtosis port print ${ENCLAVE_NAME} cdk-erigon-rpc-1 rpc)
# TODO: kurtosis 当前没有启动 bridge-ui 服务，启动后更新
BRIDGE_UI_PORT=http://127.0.0.1:9999 #$(kurtosis port print ${ENCLAVE_NAME} zkevm-bridge-ui-1 web-ui)
BRIDGE_SERVICE_RPC_PORT=$(kurtosis port print ${ENCLAVE_NAME} zkevm-bridge-service-1 rpc)
PROMETHEUS_PORT=$(kurtosis port print ${ENCLAVE_NAME} prometheus-1 http)
GRAFANA_PORT=$(kurtosis port print ${ENCLAVE_NAME} grafana-1 dashboards)


# 替换模板中的变量
output=$(echo "$template" | sed "s|{{cdk_l1_rpc}}|$L1_RPC_URL|g" \
                          | sed "s|{{cdk_l2_rpc}}|$L2_RPC_PORT|g" \
                          | sed "s|{{cdk_bridge_ui}}|$BRIDGE_UI_PORT|g" \
                          | sed "s|{{cdk_bridge_service_rpc}}|$BRIDGE_SERVICE_RPC_PORT|g" \
                          | sed "s|{{cdk_grafana}}|$GRAFANA_PORT|g" \
                          | sed "s|{{cdk_prometheus}}|$PROMETHEUS_PORT|g")

# 输出替换后的结果
echo "生成的Nginx配置如下:"
echo "----------------------------------------"
echo "$output"
echo "----------------------------------------"

# 交互式询问是否接受
# read -p "是否接受此配置并写入到/etc/nginx/sites-available/${ENCLAVE_NAME}-upstream.conf? (y/n): " answer

# # 转换为小写以便于处理
# answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')

answer="y"

if [[ "$answer" == "y" || "$answer" == "yes" ]]; then
    # 写入文件
    CONFIG_FILE="/etc/nginx/sites-available/${ENCLAVE_NAME}-ports"
    echo "$output" | sudo tee "$CONFIG_FILE" > /dev/null
    if [ $? -eq 0 ]; then
        echo "配置已成功写入到 $CONFIG_FILE"
        
        # 创建符号链接到 sites-enabled 目录
        LINK_FILE="/etc/nginx/sites-enabled/${ENCLAVE_NAME}-ports"
        if [ -L "$LINK_FILE" ]; then
            sudo rm -f "$LINK_FILE"
        fi

        echo "创建符号链接到 sites-enabled 目录..."
        sudo ln -s "$CONFIG_FILE" "$LINK_FILE" || echo "创建符号链接失败，请手动执行: sudo ln -s $CONFIG_FILE $LINK_FILE"
        
        echo "提示：正在测试和重新加载Nginx配置..."
        sudo nginx -t  # 测试配置
        sudo nginx -s reload  # 重新加载Nginx
        echo "Nginx配置重启完成！"
    else
        echo "写入配置文件失败，请检查权限"
        exit 1
    fi
else
    echo "操作已取消，未写入配置文件"
fi