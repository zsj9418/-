#!/bin/bash

# 设置默认 TERM 环境变量以增强终端兼容性
if [ -z "$TERM" ] || [ "$TERM" = "dumb" ]; then
    export TERM="xterm"
fi

# 检查是否具有 sudo 权限
check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo "此脚本需要 root 权限运行，请以 root 用户运行或使用 'sudo' 执行。"
        exit 1
    fi
}

# 检测系统包管理工具
detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
    else
        echo "无法检测到支持的包管理工具 (apt-get/yum/dnf/pacman/zypper)，请手动安装必要的依赖后重试。"
        exit 1
    fi
}

# 检测并安装依赖，只执行一次
install_dependencies() {
    echo "正在检测并安装缺失的依赖..."
    local DEPS=("curl" "gnupg" "lsb-release" "ca-certificates" "software-properties-common" "wget" "jq")
    for DEP in "${DEPS[@]}"; do
        if ! command -v "$DEP" >/dev/null 2>&1; then
            echo "安装依赖：$DEP"
            case $PKG_MANAGER in
                apt-get)
                    sudo apt-get update
                    sudo apt-get install -y "$DEP"
                    ;;
                yum)
                    sudo yum install -y "$DEP"
                    ;;
                dnf)
                    sudo dnf install -y "$DEP"
                    ;;
                pacman)
                    sudo pacman -Sy --noconfirm "$DEP"
                    ;;
                zypper)
                    sudo zypper install -y "$DEP"
                    ;;
            esac
        else
            echo "$DEP 已安装，跳过..."
        fi
    done
}

# 检测系统架构
get_architecture() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="x86_64" ;;
        aarch64) ARCH="aarch64" ;;
        armv7l) ARCH="armv7" ;;
        *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac
    echo "$ARCH"
}

# 检测系统版本
get_os_version() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
    else
        echo "无法检测系统版本"
        exit 1
    fi
    echo "$OS_NAME $OS_VERSION"
}

# 检测是否安装 Docker
check_docker_installed() {
    if command -v docker >/dev/null 2>&1; then
        echo "Docker 已安装，版本信息如下："
        docker --version
        return 0
    else
        echo "Docker 未安装。"
        return 1
    fi
}

# 检测是否安装 Docker Compose
check_docker_compose_installed() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "Docker Compose 已安装，版本信息如下："
        docker-compose --version
        return 0
    else
        echo "Docker Compose 未安装。"
        return 1
    fi
}

# 获取可用 Docker 版本
fetch_docker_versions() {
    local ARCH=$(get_architecture)
    local URL="https://download.docker.com/linux/static/stable/$ARCH/"
    echo "正在获取可用的 Docker 版本列表..."
    VERSIONS=$(curl -s "$URL" | grep -oP 'docker-\K[0-9]+\.[0-9]+\.[0-9]+' | sort -rV | uniq)
    if [ -z "$VERSIONS" ]; then
        echo "无法获取版本列表，请检查网络连接、代理设置或 DNS 配置。"
        exit 1
    fi
    echo "$VERSIONS"
}

# 选择 Docker 版本（使用 select 实现上下键选择）
select_docker_version() {
    local VERSIONS=($(fetch_docker_versions))
    if [ ${#VERSIONS[@]} -eq 0 ]; then
        echo "未找到可用 Docker 版本，退出。"
        exit 1
    fi

    echo "请使用上下键选择 Docker 版本（回车确认，留空选择最新版本）："
    PS3="请输入数字选择版本（默认最新版本）： "
    select VERSION in "${VERSIONS[@]}" "默认最新版本"; do
        if [ "$VERSION" = "默认最新版本" ] || [ -z "$REPLY" ]; then
            echo ""
            break
        elif [ -n "$VERSION" ]; then
            echo "$VERSION"
            break
        else
            echo "无效选择，请重新选择。"
        fi
    done
}

# 安装 Docker
install_docker() {
    if check_docker_installed; then
        read -p "Docker 已安装，是否重新安装？(y/n): " REINSTALL
        if [[ "$REINSTALL" != "y" ]]; then
            echo "跳过 Docker 安装。"
            return
        fi
    fi

    local ARCH=$(get_architecture)
    local VERSION=$(select_docker_version)

    # 定义临时文件夹
    TEMP_DIR="/tmp/docker_install"
    mkdir -p "$TEMP_DIR"

    if [ -z "$VERSION" ]; then
        echo "未选择版本，安装最新版本的 Docker..."
        DOCKER_URL="https://download.docker.com/linux/static/stable/$ARCH/docker.tgz"
    else
        echo "您选择安装的 Docker 版本为：$VERSION"
        DOCKER_URL="https://download.docker.com/linux/static/stable/$ARCH/docker-$VERSION.tgz"
    fi

    echo "正在下载 Docker 二进制包：$DOCKER_URL"
    wget -O "$TEMP_DIR/docker.tgz" "$DOCKER_URL" || {
        echo "下载失败，请检查网络连接、代理设置、DNS 配置或 Docker 版本号是否正确。"
        rm -rf "$TEMP_DIR"
        exit 1
    }

    echo "正在解压 Docker 包到临时文件夹..."
    tar -zxf "$TEMP_DIR/docker.tgz" -C "$TEMP_DIR"
    sudo mv "$TEMP_DIR/docker/"* /usr/bin/

    # 清理临时文件夹
    echo "清理临时文件..."
    rm -rf "$TEMP_DIR"

    echo "Docker 安装完成，请重新登录以应用用户组更改或运行 'sudo systemctl start docker' 启动服务。"
}

# 安装 Docker Compose
install_docker_compose() {
    if check_docker_compose_installed; then
        read -p "Docker Compose 已安装，是否重新安装？(y/n): " REINSTALL
        if [[ "$REINSTALL" != "y" ]]; then
            echo "跳过 Docker Compose 安装。"
            return
        fi
    fi

    echo "正在安装 Docker Compose..."
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name) || {
        echo "获取 Docker Compose 最新版本失败，请检查网络连接、代理设置或 GitHub API 是否可达。"
        exit 1
    }
    sudo curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || {
        echo "下载 Docker Compose 失败，请检查网络连接、代理设置或 GitHub 是否可达。"
        exit 1
    }
    sudo chmod +x /usr/local/bin/docker-compose
    echo "Docker Compose 安装完成。"
}

# 卸载 Docker
uninstall_docker() {
    echo "正在卸载 Docker..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    sudo rm -rf /var/lib/docker
    sudo rm -rf /etc/docker
    sudo rm -rf /usr/bin/docker*
    echo "Docker 残留文件已清理。"
}

# 卸载 Docker Compose
uninstall_docker_compose() {
    echo "正在卸载 Docker Compose..."
    sudo rm -rf /usr/local/bin/docker-compose
    sudo rm -rf ~/.docker/compose
    echo "Docker Compose 残留文件已清理。"
}

# 生成 daemon.json 配置文件
generate_daemon_config() {
    echo "正在生成 Docker daemon.json 配置文件..."

    DEFAULT_DATA_ROOT="/opt/docker"
    read -p "请输入 Docker data-root 路径 (留空默认: ${DEFAULT_DATA_ROOT}): " DATA_ROOT_INPUT
    DATA_ROOT="${DATA_ROOT_INPUT:-${DEFAULT_DATA_ROOT}}"

    DAEMON_CONFIG=$(cat <<EOF
{
  "iptables": true,
  "ip6tables": true,
  "registry-mirrors": [
    "https://registry.cn-chengdu.aliyuncs.com",
    "https://mirror.ccs.tencentyun.com",
    "https://docker.mirrors.huaweicloud.com",
    "https://hub-mirror.c.163.com"
  ],
  "data-root": "${DATA_ROOT}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "5m",
    "max-file": "3"
  }
}
EOF
)

    echo "daemon.json 文件内容如下："
    echo "$DAEMON_CONFIG"

    sudo mkdir -p /etc/docker
    echo "$DAEMON_CONFIG" | sudo tee /etc/docker/daemon.json > /dev/null

    if [ $? -eq 0 ]; then
        echo "/etc/docker/daemon.json 文件生成成功。"
        echo "正在重启 Docker 服务以应用配置..."
        sudo systemctl restart docker || {
            echo "Docker 服务重启失败，请确保 Docker 已正确安装并运行，或手动重启：sudo systemctl restart docker"
        }
        if [ $? -eq 0 ]; then
            echo "Docker 服务重启成功，新配置已加载。"
        fi
    else
        echo "/etc/docker/daemon.json 文件生成失败，请检查权限或重试。"
    fi
}

# 主脚本入口
main() {
    check_sudo
    detect_package_manager
    install_dependencies

    echo "欢迎使用 Docker 和 Docker Compose 一键安装脚本"
    echo "检测系统信息..."
    ARCH=$(get_architecture)
    OS=$(get_os_version)
    echo "系统架构: $ARCH"
    echo "系统版本: $OS"

    while true; do
        echo "请选择要执行的操作："
        echo "1. 安装 Docker"
        echo "2. 安装 Docker Compose"
        echo "3. 安装 Docker 和 Docker Compose"
        echo "4. 卸载 Docker"
        echo "5. 卸载 Docker Compose"
        echo "6. 卸载 Docker 和 Docker Compose"
        echo "7. 查询 Docker 和 Docker Compose 的安装状态"
        echo "8. 生成 daemon.json 配置文件"
        echo "9. 退出脚本"
        read -p "请输入数字 (1/2/3/4/5/6/7/8/9): " CHOICE

        case $CHOICE in
            1)
                install_docker
                ;;
            2)
                install_docker_compose
                ;;
            3)
                install_docker
                install_docker_compose
                ;;
            4)
                uninstall_docker
                ;;
            5)
                uninstall_docker_compose
                ;;
            6)
                uninstall_docker
                uninstall_docker_compose
                ;;
            7)
                check_docker_installed
                check_docker_compose_installed
                ;;
            8)
                generate_daemon_config
                ;;
            9)
                echo "退出脚本。"
                exit 0
                ;;
            *)
                echo "无效的选择，请重新输入。"
                ;;
        esac
    done
}

main
