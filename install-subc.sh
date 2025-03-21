#!/bin/bash
set -euo pipefail

# 配置常量
SUB_WEB_IMAGE="careywong/subweb:latest"
SUB_WEB_NAME="SubWeb"
SUB_WEB_PORT_DEFAULT=25501
SUB_WEB_CONTAINER_PORT=80  # 容器内部服务监听端口

SUB_CONVERTER_IMAGE="ghcr.io/metacubex/subconverter:latest"
SUB_CONVERTER_NAME="SubConverter"
SUB_CONVERTER_PORT_DEFAULT=25500
SUB_CONVERTER_CONTAINER_PORT=25500  # 容器内部服务监听端口

SING_BOX_IMAGE="jwy8645/sing-box-subscribe:latest"
SING_BOX_NAME="sing-box-subscribe"
SING_BOX_PORT_DEFAULT=5000
SING_BOX_CONTAINER_PORT=5000  # 容器内部服务监听端口

LOG_FILE="/var/log/deploy-tools.log"

# 初始化日志
init_log() {
    if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
        LOG_FILE="/tmp/deploy-tools.log"
    fi
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo -e "\033[33m日志文件: $LOG_FILE\033[0m"
}

# 带颜色输出
red() { echo -e "\033[31m$@\033[0m"; }
green() { echo -e "\033[32m$@\033[0m"; }
yellow() { echo -e "\033[33m$@\033[0m"; }

# 清理旧容器
clean_legacy() {
    local container_name=$1
    if docker ps -a --format '{{.Names}}' | grep -q "^$container_name$"; then
        yellow "发现已存在容器 $container_name"
        read -p "是否卸载当前版本？(y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            docker stop "$container_name" || true
            docker rm "$container_name" || true
            green "旧版本已清理"
        fi
    fi
}

# 验证端口是否可用
check_port() {
    local port=$1
    if lsof -i:"$port" &>/dev/null; then
        red "端口 $port 已被占用"
        exit 1
    fi
}

# 部署容器的通用函数
deploy_container() {
    local name=$1
    local host_port=$2
    local container_port=$3
    local image=$4
    local network_mode=$5

    clean_legacy "$name"
    check_port "$host_port"

    yellow "正在部署 $name 容器..."
    docker pull "$image" || {
        red "拉取镜像失败，请检查网络连接或镜像地址。"
        exit 1
    }

    if [[ "$network_mode" == "host" ]]; then
        docker run -d --name "$name" --restart always --net host "$image" || {
            red "容器启动失败，请检查日志：docker logs $name"
            exit 1
        }
    else
        docker run -d --name "$name" --restart always --net bridge -p "$host_port:$container_port" "$image" || {
            red "容器启动失败，请检查日志：docker logs $name"
            exit 1
        }
    fi

    green "$name 部署成功！访问地址：http://<你的服务器IP>:${host_port}"
}

# 部署 SubWeb
deploy_sub_web() {
    read -p "请输入 SubWeb 监听端口（默认 $SUB_WEB_PORT_DEFAULT，直接回车使用默认）：" port
    port=${port:-$SUB_WEB_PORT_DEFAULT}

    echo -e "\n请选择网络模式："
    select network_mode in "bridge" "host"; do
        case $network_mode in
            bridge|host) break ;;
            *) red "无效选项，请重新选择。" ;;
        esac
    done

    deploy_container "$SUB_WEB_NAME" "$port" "$SUB_WEB_CONTAINER_PORT" "$SUB_WEB_IMAGE" "$network_mode"
}

# 部署 SubConverter
deploy_sub_converter() {
    read -p "请输入 SubConverter 监听端口（默认 $SUB_CONVERTER_PORT_DEFAULT，直接回车使用默认）：" port
    port=${port:-$SUB_CONVERTER_PORT_DEFAULT}

    echo -e "\n请选择网络模式："
    select network_mode in "bridge" "host"; do
        case $network_mode in
            bridge|host) break ;;
            *) red "无效选项，请重新选择。" ;;
        esac
    done

    deploy_container "$SUB_CONVERTER_NAME" "$port" "$SUB_CONVERTER_CONTAINER_PORT" "$SUB_CONVERTER_IMAGE" "$network_mode"
}

# 部署 SingBoxSubscribe
deploy_sing_box() {
    read -p "请输入 SingBoxSubscribe 监听端口（默认 $SING_BOX_PORT_DEFAULT，直接回车使用默认）：" port
    port=${port:-$SING_BOX_PORT_DEFAULT}

    echo -e "\n请选择网络模式："
    select network_mode in "bridge" "host"; do
        case $network_mode in
            bridge|host) break ;;
            *) red "无效选项，请重新选择。" ;;
        esac
    done

    deploy_container "$SING_BOX_NAME" "$port" "$SING_BOX_CONTAINER_PORT" "$SING_BOX_IMAGE" "$network_mode"
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n\033[32m请选择要执行的操作：\033[0m"
        echo "1. 部署 SubWeb"
        echo "2. 部署 SubConverter"
        echo "3. 部署 SingBoxSubscribe"
        echo "4. 退出"
        read -p "请输入选项（1/2/3/4）：" choice

        case $choice in
            1) deploy_sub_web ;;
            2) deploy_sub_converter ;;
            3) deploy_sing_box ;;
            4) green "退出脚本"; exit 0 ;;
            *) red "无效选项，请重试。" ;;
        esac
    done
}

# 主函数
main() {
    init_log

    if ! command -v docker &>/dev/null; then
        install_dependencies
    fi

    main_menu
}

main
