#!/bin/bash
set -euo pipefail

# 配置常量
SUB_WEB_IMAGE="careywong/subweb:latest"
SUB_WEB_NAME="SubWeb"
SUB_WEB_PORT_DEFAULT=25501
SUB_WEB_CONTAINER_PORT=80

SUB_CONVERTER_IMAGE="ghcr.io/metacubex/subconverter:latest"
SUB_CONVERTER_NAME="SubConverter"
SUB_CONVERTER_PORT_DEFAULT=25500
SUB_CONVERTER_CONTAINER_PORT=25500

SING_BOX_IMAGE="jwy8645/sing-box-subscribe:latest" # 默认值，arm64
SING_BOX_NAME="sing-box-subscribe"
SING_BOX_PORT_DEFAULT=5000
SING_BOX_CONTAINER_PORT=5000

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

# 查看容器状态
check_container() {
    local container_name=$1
    if docker ps -a --format '{{.Names}}' | grep -q "^$container_name$"; then
        echo "容器 $container_name 状态："
        docker ps -a --filter "name=^/$container_name$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    else
        echo "容器 $container_name 不存在。"
    fi
}

# 卸载容器（加入是否卸载镜像）
remove_container() {
    local container_name=$1
    # 根据容器名字获取镜像名
    local image_name
    image_name=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "")
    if docker ps -a --format '{{.Names}}' | grep -q "^$container_name$"; then
        read -p "确认要卸载容器 $container_name 吗？(y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            # 卸载容器
            docker stop "$container_name" || true
            docker rm "$container_name" || true
            green "容器 $container_name 已卸载。"
            # 提示用户是否要删除镜像
            if [[ -n "$image_name" ]]; then
                read -p "要删除镜像 $image_name 吗？(y/n): " del_img
                if [[ "$del_img" =~ ^[Yy]$ ]]; then
                    docker rmi "$image_name" || red "删除镜像失败或者镜像不存在。"
                fi
            fi
        fi
    else
        echo "容器 $container_name 不存在，无需卸载。"
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

# 子菜单：管理容器（查看/卸载）
manage_container() {
    local container_name=$1
    while true; do
        echo -e "\n请选择操作："
        echo "1. 查看容器状态"
        echo "2. 卸载容器"
        echo "3. 返回上级菜单"
        read -p "输入选项（1/2/3）:" opt
        case "$opt" in
            1) check_container "$container_name" ;;
            2) remove_container "$container_name" ;;
            3) break ;;
            *) red "无效选择，请重新输入。" ;;
        esac
    done
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
    manage_container "$SUB_WEB_NAME"
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
    manage_container "$SUB_CONVERTER_NAME"
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

    architecture=$(uname -m)
    case "$architecture" in
        x86_64* | amd64*)
            SING_BOX_IMAGE="jwy8645/sing-box-subscribe:amd64"
            ;;
        aarch64* | arm64*)
            SING_BOX_IMAGE="jwy8645/sing-box-subscribe:latest"
            ;;
        *)
            red "不支持的架构: $architecture，将尝试拉取默认 arm64 镜像。"
            ;;
    esac
    deploy_container "$SING_BOX_NAME" "$port" "$SING_BOX_CONTAINER_PORT" "$SING_BOX_IMAGE" "$network_mode"
    manage_container "$SING_BOX_NAME"
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n\033[32m请选择要执行的操作：\033[0m"
        echo "1. 部署 SubWeb"
        echo "2. 管理 SubWeb (查看/卸载)"
        echo "3. 部署 SubConverter"
        echo "4. 管理 SubConverter"
        echo "5. 部署 SingBoxSubscribe"
        echo "6. 管理 SingBoxSubscribe"
        echo "7. 退出"
        read -p "请输入选项（1/2/3/4/5/6/7）：" choice

        case $choice in
            1) deploy_sub_web ;;
            2) manage_container "$SUB_WEB_NAME" ;;
            3) deploy_sub_converter ;;
            4) manage_container "$SUB_CONVERTER_NAME" ;;
            5) deploy_sing_box ;;
            6) manage_container "$SING_BOX_NAME" ;;
            7) green "退出脚本"; exit 0 ;;
            *) red "无效选项，请重试。" ;;
        esac
    done
}

# 主程序
main() {
    init_log

    if ! command -v docker &>/dev/null; then
        # 这里可以调用安装依赖的函数
        red "请先安装 Docker！"
        exit 1
    fi

    main_menu
}

main
