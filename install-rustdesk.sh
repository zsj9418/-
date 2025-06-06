#!/bin/bash

# 容器名称
CONTAINER_NAME_HBBS="rustdesk_hbbs"
CONTAINER_NAME_HBBR="rustdesk_hbbr"
IMAGE_NAME="rustdesk/rustdesk-server:latest"
DATA_DIR="./rustdesk_data"

# 确保数据目录存在
mkdir -p "$DATA_DIR"

# 获取服务器IP
get_server_ip() {
    hostname -I | awk '{print $1}'
}

# 提取最新Key（容器日志中的Key行）
extract_key() {
    local container_name=$1
    for i in {1..30}; do
        KEY_LINE=$(docker logs "$container_name" --tail 50 2>/dev/null | grep "Key:" | tail -1)
        if [ -n "$KEY_LINE" ]; then
            echo "$KEY_LINE" | sed -n 's/.*Key: \([^ ]*\).*/\1/p'
            return
        fi
        sleep 1
    done
    echo "未检测到Key信息"
}

# 获取服务器ID（通过日志提取）
get_server_id() {
    local container_name=$1
    id=$(docker logs "$container_name" 2>/dev/null | grep "Generated new keypair for id:" | tail -1 | sed 's/.*for id: *//')
    if [ -z "$id" ]; then
        id="未检测到ID或容器未启动"
    fi
    echo "$id"
}

# 获取中继服务器地址（动态，基于服务器IP）
get_relay_address() {
    SERVER_IP=$(get_server_ip)
    echo "${SERVER_IP}:21117"
}

# 主菜单
function main_menu() {
    clear
    echo "================ RustDesk 自部署脚本 ================"
    echo "请选择操作："
    echo "1) 部署服务器"
    echo "2) 查看容器状态"
    echo "3) 启动容器"
    echo "4) 停止容器"
    echo "5) 卸载清理"
    echo "6) 查看最新生成的Key"
    echo "7) 查看服务器ID、地址和中继地址"
    echo "8) 退出"
    echo "====================================================="
    read -p "请输入选择（1-8）: " choice
    case "$choice" in
        1) deploy_server ;;
        2) check_status ;;
        3) start_containers ;;
        4) stop_containers ;;
        5) cleanup ;;
        6) view_latest_key ;;
        7) view_server_info ;;
        8) exit 0 ;;
        *) echo "无效选择！" ; sleep 2 ; main_menu ;;
    esac
}

# 部署函数
function deploy_server() {
    docker rm -f "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" >/dev/null 2>&1
    echo "请选择网络模式："
    echo "1) host模式"
    echo "2) 桥接（端口映射）模式"
    read -p "输入（1或2）: " net_mode

    if [ "$net_mode" == "1" ]; then
        echo "你选择了host模式，端口由宿主机管理。"
        port_args="--net=host"
        port_config="Host模式"
    elif [ "$net_mode" == "2" ]; then
        echo "请输入端口映射（格式：主机端口:容器端口），多个用空格隔开，例如："
        echo "21114:21114 21115:21115 21116:21116"
        read -p "端口映射: " port_mappings
        port_args=""
        for mapping in $port_mappings; do
            port_args="$port_args -p ${mapping//:/ }"
        done
        port_config="端口映射：$port_mappings"
    else
        echo "无效选择，返回菜单。"
        sleep 2
        main_menu
    fi

    echo "开始部署..."
    if [ "$net_mode" == "1" ]; then
        docker run -d --name "$CONTAINER_NAME_HBBS" --restart=unless-stopped $port_args -v "$DATA_DIR":/root "$IMAGE_NAME" hbbs
        docker run -d --name "$CONTAINER_NAME_HBBR" --restart=unless-stopped $port_args -v "$DATA_DIR":/root "$IMAGE_NAME" hbbr
    else
        docker run -d --name "$CONTAINER_NAME_HBBS" --restart=unless-stopped $port_args -v "$DATA_DIR":/root "$IMAGE_NAME" hbbs
        docker run -d --name "$CONTAINER_NAME_HBBR" --restart=unless-stopped $port_args -v "$DATA_DIR":/root "$IMAGE_NAME" hbbr
    fi

    echo "容器已启动，等待密钥生成..."
    sleep 5

    # 提取Key
    KEY=$(extract_key "$CONTAINER_NAME_HBBS")
    SERVER_IP=$(get_server_ip)
    SERVER_PORT=21117

    echo ""
    echo "== 服务器密钥信息 =="
    echo "IP: $SERVER_IP"
    echo "端口: $SERVER_PORT"
    echo "Key: $KEY"
    echo "请将公钥内容复制到客户端配置中："
    echo "（可用命令：docker logs $CONTAINER_NAME_HBBS --tail 50 | grep 'Key:'）"
    echo ""
    read -p "按回车返回主菜单..." temp
    main_menu
}

# 查看容器状态
function check_status() {
    docker ps -a | grep -E "$CONTAINER_NAME_HBBS|$CONTAINER_NAME_HBBR"
    read -p "按回车返回主菜单..." temp
    main_menu
}

# 启动容器
function start_containers() {
    docker start "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR"
    echo "容器已启动。"
    sleep 2
    main_menu
}

# 停止容器
function stop_containers() {
    docker stop "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR"
    echo "容器已停止。"
    sleep 2
    main_menu
}

# 卸载清理
function cleanup() {
    echo "停止并删除容器..."
    docker rm -f "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" >/dev/null 2>&1
    echo "删除数据目录..."
    rm -rf "$DATA_DIR"
    echo "完成卸载清理。"
    sleep 2
    main_menu
}

# 查看最新生成的Key
function view_latest_key() {
    echo "正在提取最新Key..."
    KEY=$(extract_key "$CONTAINER_NAME_HBBS")
    if [ "$KEY" == "未检测到Key信息" ]; then
        echo "未检测到Key信息，请确保容器已启动并生成密钥。"
    else
        echo "最新生成的Key："
        echo "$KEY"
    fi
    read -p "按回车返回主菜单..." temp
    main_menu
}

# 查看服务器ID、地址和中继地址
function view_server_info() {
    SERVER_ID=$(get_server_id "$CONTAINER_NAME_HBBS")
    SERVER_IP=$(get_server_ip)
    RELAY_ADDR=$(get_relay_address)

    echo "服务器ID：$SERVER_ID"
    echo "服务器地址：$SERVER_IP"
    echo "中继服务器地址：$RELAY_ADDR"
    echo ""
    read -p "按回车返回主菜单..." temp
}


# 脚本入口
while true; do
    main_menu
done
