#!/bin/bash
set -euo pipefail

# 配置常量
SUB_CONVERTER_IMAGE="asdlokj1qpi23/subconverter:latest"
SUB_CONVERTER_NAME="SubConverter"
SUB_CONVERTER_PORT_DEFAULT=25500

SING_BOX_IMAGE="jwy8645/sing-box-subscribe:latest"
SING_BOX_NAME="sing-box-subscribe"
SING_BOX_PORT_DEFAULT=5000

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

# 清理旧容器
clean_legacy() {
    local container_name=$1
    if docker ps -a --format '{{.Names}}' | grep -q "^$container_name$"; then
        yellow "发现已存在容器 $container_name"
        confirm_operation "是否卸载当前版本？" && {
            docker stop "$container_name" || true
            docker rm "$container_name" || true
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

# 部署容器的通用函数
deploy_container() {
    local name=$1
    local port=$2
    local image=$3

    clean_legacy "$name"
    check_port "$port"

    yellow "正在部署 $name 容器..."
    docker pull "$image" || {
        red "拉取镜像失败，请检查网络连接或镜像地址。"
        exit 1
    }

    docker run -d --name "$name" --restart always --net host -p "$port:$port" "$image" || {
        red "容器启动失败，请检查日志：docker logs $name"
        exit 1
    }

    green "$name 部署成功！访问地址：http://<你的服务器IP>:$port"
}

# 部署 SubConverter
deploy_sub_converter() {
    read -p "请输入 SubConverter 监听端口（默认 $SUB_CONVERTER_PORT_DEFAULT，直接回车使用默认）：" port
    port=${port:-$SUB_CONVERTER_PORT_DEFAULT}
    deploy_container "$SUB_CONVERTER_NAME" "$port" "$SUB_CONVERTER_IMAGE"
}

# 部署 SingBoxSubscribe
deploy_sing_box() {
    read -p "请输入 SingBoxSubscribe 监听端口（默认 $SING_BOX_PORT_DEFAULT，直接回车使用默认）：" port
    port=${port:-$SING_BOX_PORT_DEFAULT}
    deploy_container "$SING_BOX_NAME" "$port" "$SING_BOX_IMAGE"
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n\033[32m请选择要执行的操作：\033[0m"
        echo "1. 部署 SubConverter"
        echo "2. 部署 SingBoxSubscribe"
        echo "3. 退出"
        read -p "请输入选项（1/2/3）：" choice

        case $choice in
            1) deploy_sub_converter ;;
            2) deploy_sing_box ;;
            3) green "退出脚本"; exit 0 ;;
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
