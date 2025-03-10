#!/bin/bash
set -euo pipefail

# 配置常量
docker_name="nexterm"
docker_img="germannewsmaker/nexterm:latest"
default_port=6989
CONFIG_DIR="/home/docker/nexterm"
LOG_FILE="/var/log/nexterm-deploy.log"

# 初始化日志路径
setup_logging() {
    local log_dir=$(dirname "$LOG_FILE")
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir"
    fi
    if [[ ! -w "$log_dir" ]]; then
        echo -e "\033[31m日志目录 $log_dir 无写权限，请检查权限设置。\033[0m"
        exit 1
    fi
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

# 输入验证
confirm_operation() {
    local prompt=$1
    local max_attempts=3
    for ((i=1; i<=max_attempts; i++)); do
        read -rp "${prompt} (y/n) " answer
        case "$answer" in
            [yY]|yes|YES) return 0 ;;
            [nN]|no|NO) return 1 ;;
            *) red "无效输入，请重试 ($i/$max_attempts)";;
        esac
    done
    red "超过最大尝试次数，操作中止"
    exit 1
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
        x86_64 | amd64)
            PLATFORM="linux/amd64"
            ;;
        armv7l | armhf)
            PLATFORM="linux/arm/v7"
            ;;
        aarch64 | arm64)
            PLATFORM="linux/arm64"
            ;;
        *)
            red "当前设备架构 ($ARCH) 未被支持，请确认镜像是否兼容。"
            exit 1
            ;;
    esac

    green "检测到系统：$SYSTEM，架构：$ARCH，适配平台：$PLATFORM"
}

# 依赖安装
install_dependencies() {
    yellow "开始安装系统依赖..."
    if ! command -v docker &>/dev/null; then
        case $SYSTEM in
            debian)
                sudo $PACKAGE_MANAGER update && sudo $PACKAGE_MANAGER install -y docker.io curl jq bash-completion || {
                    red "依赖安装失败，请检查网络连接或权限。"; exit 1; }
                ;;
            centos)
                sudo $PACKAGE_MANAGER install -y docker-ce docker-ce-cli containerd.io bash-completion jq || {
                    red "依赖安装失败，请检查网络连接或权限。"; exit 1; }
                ;;
        esac
        sudo systemctl enable --now docker
        green "Docker 安装完成。"
    else
        green "Docker 已安装，跳过依赖安装。"
    fi
}

# 检查用户权限
check_user_permission() {
    if ! groups | grep -q docker; then
        yellow "当前用户不在 docker 组中，正在尝试添加..."
        sudo usermod -aG docker $USER
        red "已将用户添加到 docker 组，请重新登录后运行脚本，或者使用 'sudo' 运行脚本。"
        exit 1
    fi
}

# 检测端口是否可用
validate_port() {
    while true; do
        read -p "请输入希望使用的端口（默认 $default_port）：" user_port
        user_port=${user_port:-$default_port}
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

# 清理旧版本
clean_legacy() {
    if docker inspect $docker_name &>/dev/null; then
        yellow "发现已存在容器"
        confirm_operation "是否卸载当前版本？" && {
            docker stop $docker_name || true
            docker rm $docker_name || true
            docker rmi $docker_img || true
            rm -rf $CONFIG_DIR
            green "旧版本已清理"
        }
    fi
}

# 镜像拉取
pull_image() {
    yellow "尝试拉取镜像..."
    if docker pull $docker_img; then
        green "镜像拉取成功"
    else
        red "镜像拉取失败，请检查网络连接或镜像地址。"
        exit 1
    fi
}

# 容器启动
start_container() {
    yellow "启动容器..."
    docker_run="docker run -d \
        --name $docker_name \
        --network host \
        -v $CONFIG_DIR:/app/data \
        --restart unless-stopped \
        $docker_img"
    eval $docker_run || {
        red "容器启动失败"; exit 1; }
}

# 部署验证
verify_deployment() {
    local public_ip=$(curl -s --max-time 3 ifconfig.me || hostname -I | awk '{print $1}')
    if docker ps | grep -q $docker_name; then
        green "部署成功！访问地址：http://${public_ip}:${PORT}"
        echo "数据目录：$CONFIG_DIR"
        echo "使用以下命令检查容器日志：docker logs $docker_name"
    else
        red "容器运行异常，请检查日志：docker logs $docker_name"
        exit 1
    fi
}

# 主流程
main() {
    setup_logging
    confirm_operation "是否执行 Nexterm 部署？" || exit
    detect_system_and_architecture
    check_user_permission
    install_dependencies
    validate_port
    clean_legacy
    pull_image
    start_container
    verify_deployment
}

main
