#!/bin/bash
set -euo pipefail

# 配置常量
docker_name="nexterm"
docker_img="germannewsmaker/nexterm:latest"
default_port=6989
internal_port=6989  # 容器内部服务端口
CONFIG_DIR="/home/docker/nexterm"
LOG_FILE="/var/log/nexterm-deploy.log"
LOG_MAX_SIZE=1048576  # 1M

# 初始化日志路径
setup_logging() {
    local log_dir=$(dirname "$LOG_FILE")
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir"
    [[ ! -w "$log_dir" ]] && { echo -e "\033[31m日志目录 $log_dir 无写权限，请检查权限设置。\033[0m"; exit 1; }

    # 如果日志文件超过 1MB，则清空
    [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]] && > "$LOG_FILE"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# 信号捕获
cleanup() {
    echo "捕获中断信号，执行清理..."
    docker stop $docker_name || true
    exit 1
}
trap cleanup SIGINT SIGTERM

# 带颜色输出
red() { echo -e "\033[31m$@\033[0m"; }
green() { echo -e "\033[32m$@\033[0m"; }
yellow() { echo -e "\033[33m$@\033[0m"; }

# 封装用户输入询问
prompt_user_input() {
    local prompt=$1
    local default_value=$2
    local input
    read -p "$prompt（默认值：$default_value）：" input
    echo "${input:-$default_value}"
}

# 封装确认操作
confirm_operation() {
    local prompt=$1
    while true; do
        read -rp "${prompt} (y/n): " answer
        case "$answer" in
            [yY]|yes|YES) return 0 ;;
            [nN]|no|NO) return 1 ;;
            *) red "无效输入，请输入 y 或 n。" ;;
        esac
    done
}

# 系统和架构检测
detect_system_and_architecture() {
    if grep -qiE "ubuntu|debian" /etc/os-release; then
        SYSTEM="debian"
        PACKAGE_MANAGER="apt"
    elif grep -qi "centos" /etc/os-release; then
        SYSTEM="centos"
        PACKAGE_MANAGER="yum"
    else
        red "不支持的系统类型，请手动安装依赖环境。"
        exit 1
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64 | amd64) PLATFORM="linux/amd64" ;;
        armv7l | armhf) PLATFORM="linux/arm/v7" ;;
        aarch64 | arm64) PLATFORM="linux/arm64" ;;
        *) red "当前设备架构 ($ARCH) 未被支持，请确认镜像是否兼容。"; exit 1 ;;
    esac

    green "检测到系统：$SYSTEM，架构：$ARCH，适配平台：$PLATFORM"
}

# 检测端口是否可用
validate_port() {
    while true; do
        user_port=$(prompt_user_input "请输入希望使用的端口" "$default_port")
        if [[ "$user_port" =~ ^[0-9]+$ && "$user_port" -ge 1 && "$user_port" -le 65535 ]]; then
            if lsof -i:$user_port &>/dev/null; then
                red "端口 $user_port 已被占用，请选择其他端口。"
            else
                export PORT=$user_port
                green "端口 $PORT 可用。"
                break
            fi
        else
            red "输入无效，端口号必须是 1-65535 范围内的数字。"
        fi
    done
}

# 提供网络模式选择并提示
choose_network_mode() {
    echo -e "\n请选择网络模式："
    echo "1. bridge（推荐，适合大多数场景）"
    echo "2. host（直接使用主机网络，可能与其他服务冲突）"
    while true; do
        read -p "请输入选项（1 或 2）：" choice
        case $choice in
            1) NETWORK_MODE="bridge"; green "选择的网络模式：bridge"; break ;;
            2) NETWORK_MODE="host"; green "选择的网络模式：host"; break ;;
            *) red "无效选项，请重新输入。" ;;
        esac
    done
}

# 清理旧版本
clean_legacy() {
    if docker inspect $docker_name &>/dev/null; then
        yellow "发现已存在容器 $docker_name"
        confirm_operation "是否卸载当前版本？" && {
            docker stop $docker_name || true
            docker rm $docker_name || true
            green "容器已删除。"

            if docker images | grep -q $docker_img; then
                docker rmi $docker_img || true
                green "镜像已删除。"
            fi

            if [[ -d "$CONFIG_DIR" ]]; then
                confirm_operation "是否删除持久化数据目录 $CONFIG_DIR？" && {
                    rm -rf "$CONFIG_DIR"
                    green "持久化数据目录已删除。"
                } || {
                    yellow "持久化数据目录保留，方便下次部署加载。"
                }
            fi

            docker network prune -f || true
            docker volume prune -f || true
            green "无用的网络和卷已清理。"
        }
    else
        yellow "未发现需要清理的容器。"
    fi
}

# 镜像拉取
pull_image() {
    yellow "尝试拉取镜像..."
    if docker pull $docker_img; then
        green "镜像拉取成功。"
    else
        red "镜像拉取失败，请检查网络连接或镜像地址。"
        exit 1
    fi
}

# 容器启动
start_container() {
    yellow "启动容器..."
    if [[ "$NETWORK_MODE" == "host" ]]; then
        docker_run="docker run -d \
            --name $docker_name \
            --network host \
            -v $CONFIG_DIR:/app/data \
            --restart unless-stopped \
            $docker_img"
    else
        docker_run="docker run -d \
            --name $docker_name \
            --network bridge \
            -v $CONFIG_DIR:/app/data \
            -p $PORT:$internal_port \
            --restart unless-stopped \
            $docker_img"
    fi

    eval $docker_run || { red "容器启动失败，请检查日志。"; exit 1; }
}

# 部署验证
verify_deployment() {
    local public_ip=$(curl -s --max-time 3 ifconfig.me || hostname -I | awk '{print $1}')
    if docker ps | grep -q $docker_name; then
        green "部署成功！访问地址：http://${public_ip}:${PORT}"
        echo "数据目录：$CONFIG_DIR"
        echo "使用以下命令检查容器日志：docker logs $docker_name"
        echo "使用以下命令停止容器：docker stop $docker_name"
    else
        red "容器运行异常，请检查日志：docker logs $docker_name"
        exit 1
    fi
}

# 菜单功能
menu() {
    echo -e "\n请选择操作："
    echo "1. 部署 Nexterm"
    echo "2. 卸载清理 Nexterm"
    echo "3. 退出脚本"
    read -p "请输入选项（1-3）：" choice
    case $choice in
        1)
            validate_port
            choose_network_mode
            clean_legacy
            pull_image
            start_container
            verify_deployment
            ;;
        2) clean_legacy ;;
        3) green "退出脚本。"; exit 0 ;;
        *) red "无效选项，请重新选择。" ;;
    esac
}

# 主流程
main() {
    setup_logging
    detect_system_and_architecture
    while true; do
        menu
    done
}

main
