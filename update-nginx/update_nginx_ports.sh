#!/bin/bash

# 设置错误时退出
set -e
set -x

# 处理命令行参数 - 只接受一个参数作为 ENCLAVE_NAME
if [ $# -eq 1 ]; then
  ENCLAVE_NAME="$1"
else
  ENCLAVE_NAME="cdk-cfx"  # 默认值
fi

echo "使用 Enclave: $ENCLAVE_NAME"

# 从模板文件读取内容
TEMPLATE_FILE="${ENCLAVE_NAME}.template"
if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "错误：模板文件 $TEMPLATE_FILE 不存在！"
  exit 1
fi

# 读取模板文件内容
template=$(cat "$TEMPLATE_FILE")
echo "已加载模板文件: $TEMPLATE_FILE"

# 获取 kurtosis 中服务的 HTTP 端口
L1_RPC_PORT="http://127.0.0.1:3031"

if [ "$ENCLAVE_NAME" != "cdk-cfx" ]; then
    L1_RPC_PORT=$(kurtosis port print ${ENCLAVE_NAME} cdk-erigon-rpc-001 rpc)
fi

L2_RPC_PORT=$(kurtosis port print ${ENCLAVE_NAME} cdk-erigon-rpc-001 rpc)
BRIDGE_UI_PORT=$(kurtosis port print ${ENCLAVE_NAME} zkevm-bridge-ui-001 web-ui)
BRIDGE_SERVICE_RPC_PORT=$(kurtosis port print ${ENCLAVE_NAME} zkevm-bridge-service-001 rpc)
PROMETHEUS_PORT=$(kurtosis port print ${ENCLAVE_NAME} prometheus-001 http)
GRAFANA_PORT=$(kurtosis port print ${ENCLAVE_NAME} grafana-001 dashboards)


# 替换模板中的变量
output=$(echo "$template" | sed "s|{{cdk_l1_rpc}}|$L1_RPC_PORT|g" \
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
read -p "是否接受此配置并写入到/etc/nginx/sites-available/${ENCLAVE_NAME}-ports? (y/n): " answer

# 转换为小写以便于处理
answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')

if [[ "$answer" == "y" || "$answer" == "yes" ]]; then
    # 写入文件
    CONFIG_FILE="/etc/nginx/sites-available/${ENCLAVE_NAME}-ports"
    echo "$output" | sudo tee "$CONFIG_FILE" > /dev/null
    if [ $? -eq 0 ]; then
        echo "配置已成功写入到 $CONFIG_FILE"
        
        # 创建符号链接到 sites-enabled 目录
        LINK_FILE="/etc/nginx/sites-enabled/${ENCLAVE_NAME}-ports"
        if [ ! -L "$LINK_FILE" ]; then
            echo "创建符号链接到 sites-enabled 目录..."
            sudo ln -s "$CONFIG_FILE" "$LINK_FILE" || echo "创建符号链接失败，请手动执行: sudo ln -s $CONFIG_FILE $LINK_FILE"
        fi
        
        echo "提示：正在测试和重新加载Nginx配置..."
        nginx -t  # 测试配置
        nginx -s reload  # 重新加载Nginx
        echo "Nginx配置重启完成！"
    else
        echo "写入配置文件失败，请检查权限"
        exit 1
    fi
else
    echo "操作已取消，未写入配置文件"
fi