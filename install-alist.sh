#!/bin/bash
set -euo pipefail

# 配置常量
DOCKER_IMAGE="xhofe/alist:latest"
DOCKER_NAME="alist"
CONFIG_DIR="/home/docker/alist/conf"
DEFAULT_PORT=5244
LOG_FILE="/var/log/alist-deploy.log"

# 初始化日志
init_log() {
    if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
        LOG_FILE="/tmp/alist-deploy.log"
    fi
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo -e "\033[33m日志文件: $LOG_FILE\033[0m"
}

# 带颜色输出
red() { echo -e "\033[31m$@\033[0m"; }
green() { echo -e "\033[32m$@\033[0m"; }
yellow() { echo -e "\033[33m$@\033[0m"; }

# 系统和架构检测
detect_system_and_architecture() {
    local os=""
    local arch=""
    if grep -qiE "ubuntu|debian" /etc/os-release; then
        os="debian"
    elif grep -qi "centos" /etc/os-release; then
        os="centos"
    else
        red "不支持的操作系统类型"
        exit 1
    fi

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l|armhf) arch="armv7" ;;
        *) red "不支持的架构: $(uname -m)"; exit 1 ;;
    esac

    echo "$os $arch"
}

# 安装依赖
install_dependencies() {
    yellow "开始安装系统依赖..."
    local system_info
    system_info=$(detect_system_and_architecture)
    local os_type=$(echo "$system_info" | awk '{print $1}')

    case "$os_type" in
        debian)
            sudo apt update && sudo apt install -y docker.io curl jq
            ;;
        centos)
            sudo yum install -y yum-utils device-mapper-persistent-data lvm2
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io jq
            ;;
    esac

    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER" || true
    green "依赖安装完成！"
}

# 清理旧版本
clean_legacy() {
    if docker ps -a --format '{{.Names}}' | grep -q "^$DOCKER_NAME$"; then
        yellow "发现已存在容器 $DOCKER_NAME"
        confirm_operation "是否卸载当前版本？" && {
            docker stop "$DOCKER_NAME" || true
            docker rm "$DOCKER_NAME" || true
            docker rmi "$DOCKER_IMAGE" || true
            rm -rf "$CONFIG_DIR"
            green "旧版本已清理"
        }
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

# 拉取镜像
pull_image() {
    yellow "拉取镜像..."
    docker pull "$DOCKER_IMAGE" || {
        red "镜像拉取失败，请检查网络连接或镜像地址。"
        exit 1
    }
}

# 询问挂载目录
ask_mount_directories() {
    local mount_dirs=()
    while true; do
        read -rp "请输入需要挂载的目录（留空结束）: " dir
        if [[ -z "$dir" ]]; then
            break
        fi
        if [[ ! -d "$dir" ]]; then
            red "目录不存在，请重新输入"
            continue
        fi
        mount_dirs+=("-v $dir:$dir")
    done
    echo "${mount_dirs[@]}"
}

# 启动容器
start_container() {
    local port=$1
    local mount_dirs=$2
    local mount_opts=""
    if [[ -n "$mount_dirs" ]]; then
        mount_opts="$mount_dirs"
    fi

    yellow "启动容器..."
    docker run -d \
        --name "$DOCKER_NAME" \
        --network host \
        -v "$CONFIG_DIR:/opt/alist/data" \
        $mount_opts \
        --restart unless-stopped \
        -p "$port:$port" \
        "$DOCKER_IMAGE" || {
            red "容器启动失败，请检查日志：docker logs $DOCKER_NAME"
            exit 1
        }

    green "容器启动成功！访问地址：http://<你的服务器IP>:$port"
}

# 部署验证
verify_deployment() {
    local public_ip=$(curl -s --max-time 3 ifconfig.me || hostname -I | awk '{print $1}')
    if docker ps | grep -q "$DOCKER_NAME"; then
        green "部署成功！访问地址："
        echo -e "http://${public_ip}:5244"
        echo -e "默认账号：admin"
        echo -e "默认密码：通过以下命令获取："
        echo -e "docker exec -it $DOCKER_NAME ./alist admin random"
        echo -e "手动设置一个密码,`NEW_PASSWORD`是指你需要设置的密码"
        echo -e "docker exec -it $DOCKER_NAME ./alist admin set NEW_PASSWORD"
    else
        red "容器运行异常，查看日志：docker logs $DOCKER_NAME"
        exit 1
    fi
}

# 主流程
main() {
    init_log
    confirm_operation "是否执行 Alist 部署？" || exit

    # 检查 Docker 是否安装
    if ! command -v docker &>/dev/null; then
        install_dependencies
    fi

    clean_legacy
    pull_image

    # 自定义端口
    read -p "请输入 Alist 服务监听端口（默认 $DEFAULT_PORT，直接回车使用默认）：" port
    port=${port:-$DEFAULT_PORT}
    check_port "$port"

    # 询问挂载目录
    yellow "请添加需要挂载到容器的目录（宿主机路径:容器路径）"
    mount_dirs=$(ask_mount_directories)

    start_container "$port" "$mount_dirs"
    verify_deployment
}

main
