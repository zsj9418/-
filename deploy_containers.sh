#!/bin/bash
set -euo pipefail

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 初始化日志
init_log() {
    LOG_FILE="/var/log/$(basename "$0").log"
    if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
        LOG_FILE="/tmp/$(basename "$0").log"
    fi
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo -e "${YELLOW}日志文件: $LOG_FILE${NC}"
}

# 检查依赖
check_deps() {
    local deps=("docker" "lsof")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo -e "${RED}错误: 未安装 $dep${NC}"
            exit 1
        fi
    done
}

# 自动识别系统和架构
detect_system_and_architecture() {
    OS=$(uname -s)
    ARCH=$(uname -m)

    case "$OS" in
        Linux) OS_TYPE="linux" ;;
        Darwin) OS_TYPE="macos" ;;
        *) echo -e "${RED}错误: 不支持的操作系统: $OS${NC}"; exit 1 ;;
    esac

    case "$ARCH" in
        x86_64|amd64) ARCH_TYPE="amd64" ;;
        aarch64) ARCH_TYPE="arm64" ;;
        armv7l|armhf) ARCH_TYPE="armv7" ;;
        armv6l) ARCH_TYPE="armv6" ;;
        *) echo -e "${RED}错误: 不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac

    echo -e "${GREEN}检测到系统: $OS_TYPE, 架构: $ARCH_TYPE${NC}"
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if lsof -i:"$port" &>/dev/null; then
        echo -e "${RED}错误: 端口 $port 已被占用${NC}"
        exit 1
    fi
}

# 部署容器的通用函数
deploy_container() {
    local name=$1
    local port=$2
    local image=$3
    local internal_port=$4

    if docker ps -a --format '{{.Names}}' | grep -q "^$name$"; then
        echo -e "${RED}错误: 容器 $name 已存在，请先停止或删除。${NC}"
        exit 1
    fi

    check_port "$port"

    echo -e "${YELLOW}正在部署 $name 容器...${NC}"
    docker run -d --name "$name" -p "$port:$internal_port" "$image"

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}$name 容器已成功部署！${NC}"
        echo -e "${YELLOW}访问地址：http://<你的服务器IP>:$port${NC}"
    else
        echo -e "${RED}错误: $name 容器部署失败${NC}"
        exit 1
    fi
}

# 部署 Lobe Chat
deploy_lobe_chat() {
    read -p "请输入 Lobe Chat 监听端口（默认 3210，直接回车使用默认）：" LOBE_PORT
    LOBE_PORT=${LOBE_PORT:-3210}
    deploy_container "lobe-chat" "$LOBE_PORT" "lobehub/lobe-chat:latest" "3210"
}

# 部署 WebSSH
deploy_webssh() {
    read -p "请输入 WebSSH 监听端口（默认 2222，直接回车使用默认）：" WEBSSH_PORT
    WEBSSH_PORT=${WEBSSH_PORT:-2222}
    deploy_container "webssh" "$WEBSSH_PORT" "jrohy/webssh" "5032"
}

# 部署 Looking Glass Server
deploy_looking_glass() {
    read -p "请输入 Looking Glass Server 外部访问端口（默认 80，直接回车使用默认）：" HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-80}
    
    # 保持内部服务监听端口为 80
    echo -e "${YELLOW}正在部署 Looking Glass Server 容器...${NC}"
    docker run -d --name "looking-glass" \
        -p "$HTTP_PORT:80" \
        "wikihostinc/looking-glass-server"

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Looking Glass Server 容器已成功部署！${NC}"
        echo -e "${YELLOW}访问地址：http://<你的服务器IP>:$HTTP_PORT${NC}"
    else
        echo -e "${RED}错误: Looking Glass Server 容器部署失败${NC}"
        exit 1
    fi
}

# 卸载容器
uninstall_container() {
    local container_name=$1
    echo -e "${YELLOW}正在卸载 $container_name...${NC}"

    # 停止并删除容器
    docker stop "$container_name" &>/dev/null || true
    docker rm "$container_name" &>/dev/null || true

    echo -e "${GREEN}$container_name 已成功卸载！${NC}"
}

# 查看容器状态
check_container_status() {
    local container_name=$1
    if docker ps -a --format '{{.Names}}' | grep -q "^$container_name$"; then
        echo -e "${GREEN}$container_name 正在运行。${NC}"
    else
        echo -e "${RED}$container_name 未运行。${NC}"
    fi
}

# 主菜单
main_menu() {
    echo -e "${GREEN}请选择操作：${NC}"
    echo "1. 部署 Lobe Chat"
    echo "2. 部署 WebSSH"
    echo "3. 部署 Looking Glass Server"
    echo "4. 同时部署所有容器"
    echo "5. 卸载 Lobe Chat"
    echo "6. 卸载 WebSSH"
    echo "7. 卸载 Looking Glass Server"
    echo "8. 查看所有容器状态"
    echo "9. 退出"
    read -p "请输入选项（1-9）: " choice

    case $choice in
        1) deploy_lobe_chat ;;
        2) deploy_webssh ;;
        3) deploy_looking_glass ;;
        4) deploy_lobe_chat; deploy_webssh; deploy_looking_glass ;;
        5) uninstall_container "lobe-chat" ;;
        6) uninstall_container "webssh" ;;
        7) uninstall_container "looking-glass" ;;
        8) check_container_status "lobe-chat"; check_container_status "webssh"; check_container_status "looking-glass" ;;
        9) echo -e "${GREEN}退出脚本${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; main_menu ;;
    esac
}

# 主函数
main() {
    init_log
    check_deps
    detect_system_and_architecture
    main_menu
}

# 执行主函数
main
