#!/bin/bash

# 依赖列表 (gnupg 和 lsb-release 根据常见系统情况添加)
DEPS=("curl" "wget" "jq" "fzf")
DOCKER_VERSIONS_URL="https://download.docker.com/linux/static/stable/"

# 全局变量
INSTALL_STATUS=$(mktemp)  # 记录依赖安装状态
DOCKER_URL=""
DOCKER_INSTALL_DIR="/tmp/docker_install"
ARCH=""
OS=""
PKG_MANAGER=""

# 函数: 检查是否具有 sudo 权限
check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo "此脚本需要 root 权限运行，请以 root 用户运行或使用 'sudo' 执行。"
        exit 1
    fi
}

# 函数: 检测系统包管理工具
detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    else
        echo "无法检测到支持的包管理工具 (apt-get/yum/dnf)，请手动安装必要的依赖后重试。"
        exit 1
    fi
}

# 函数: 安装依赖
install_dependencies() {
    echo "正在检测并安装缺失的依赖..."

    # 检查是否已经安装过
    local installed_deps=($(cat "$INSTALL_STATUS" 2>/dev/null)) # 读取安装状态,忽略报错
    local needs_install=()

    # 先尝试安装基础依赖,不管安装情况
    case "$PKG_MANAGER" in
        apt-get)
            sudo apt-get update -y >/dev/null 2>&1
            sudo apt-get install -y --no-install-recommends ca-certificates gnupg lsb-release software-properties-common >/dev/null 2>&1
            ;;
        yum)
            sudo yum install -y ca-certificates gnupg lsb-release software-properties-common >/dev/null 2>&1
            ;;
        dnf)
            sudo dnf install -y ca-certificates gnupg lsb-release software-properties-common >/dev/null 2>&1
            ;;
    esac

    # 检测真正需要安装的
    for DEP in "${DEPS[@]}"; do
        is_installed=false
        for INSTALLED in "${installed_deps[@]}"; do
            if [[ "$DEP" == "$INSTALLED" ]]; then
                is_installed=true
                break
            fi
        done

        if ! $is_installed; then
            if ! command -v "$DEP" >/dev/null 2>&1; then
                needs_install+=("$DEP")  # 加入待安装列表
            fi
        fi
    done

    # 开始安装
    if [[ ${#needs_install[@]} -gt 0 ]]; then
        echo "需要安装以下依赖: ${needs_install[*]}"
        for DEP in "${needs_install[@]}"; do
            echo "安装依赖：$DEP"
            case "$PKG_MANAGER" in
                apt-get)
                    sudo apt-get install -y --no-install-recommends "$DEP" || { echo "安装 $DEP 失败"; exit 1; }
                    ;;
                yum)
                    sudo yum install -y "$DEP" || { echo "安装 $DEP 失败"; exit 1; }
                    ;;
                dnf)
                    sudo dnf install -y "$DEP" || { echo "安装 $DEP 失败"; exit 1; }
                    ;;
            esac
            echo "$DEP" >> "$INSTALL_STATUS" # 添加到安装状态
        done
    else
        echo "所有依赖已安装，跳过..."
    fi
}

# 函数: 获取系统架构
get_architecture() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="x86_64" ;;
        aarch64) ARCH="aarch64" ;;
        armv7l) ARCH="armv7l" ;;
        *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac
    echo "$ARCH"
}

# 函数: 获取系统版本
get_os_version() {
    if [ -f /etc/os-release ]; then
        OS_NAME=$(grep ^ID= /etc/os-release | awk -F= '{print $2}' | tr -d '"')
        OS_VERSION=$(grep ^VERSION_ID= /etc/os-release | awk -F= '{print $2}' | tr -d '"')
    else
        echo "无法检测系统版本。请确保 /etc/os-release 文件存在并且格式正确。"
        exit 1
    fi
    echo "$OS_NAME $OS_VERSION"
}

# 函数: 检测是否安装 Docker
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

# 函数: 检测是否安装 Docker Compose
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

# 函数: 获取 Docker 版本列表并进行过滤(去除重复版本)
fetch_docker_versions() {
    ARCH=$(get_architecture)
    local URL="$DOCKER_VERSIONS_URL$ARCH/"
    local VERSIONS
    VERSIONS=$(curl -s "$URL" | grep -oP 'docker-\K[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | uniq)
    if [ -z "$VERSIONS" ]; then
        echo "无法获取版本列表，请检查网络连接或该架构是否支持。"
        exit 1
    fi
    # 去掉多余的提示词，只返回版本
    echo "$VERSIONS"
}

# 函数: 选择 Docker 版本
select_docker_version() {
    local VERSIONS=($(fetch_docker_versions))

    if command -v fzf >/dev/null 2>&1; then
        # 使用 fzf 工具
        local SELECTED_VERSION=$(printf "%s\n" "${VERSIONS[@]}" | fzf --prompt="选择 Docker 版本 > " --height 20 --reverse)
        # 清理版本号中的多余字符（如换行符和空格）
        SELECTED_VERSION=$(echo "$SELECTED_VERSION" | tr -d '[:space:]')
        if [ -n "$SELECTED_VERSION" ]; then
            echo "$SELECTED_VERSION"
            return
        else
            echo "未选择版本，跳过..."
            return
        fi
    fi

    echo ""  # 如果没有任何工具可用或用户退出，返回空字符串
}

# 函数: 安装 Docker
install_docker() {
    if check_docker_installed; then
        read -r -p "Docker 已安装，是否重新安装？(y/n): " REINSTALL
        if [[ "$REINSTALL" != "y" ]]; then
            echo "跳过 Docker 安装。"
            return
        fi
    fi

    ARCH=$(get_architecture)
    echo "正在获取可用的 Docker 版本列表..." # 放在选择版本之前提示
    local VERSION=$(select_docker_version)
    DOCKER_INSTALL_DIR="/tmp/docker_install"
    mkdir -p "$DOCKER_INSTALL_DIR"

    if [ -z "$VERSION" ]; then
        echo "未选择版本，安装最新版本的 Docker..."
        DOCKER_URL="$DOCKER_VERSIONS_URL$ARCH/docker.tgz"
    else
        echo "您选择安装的 Docker 版本为：$VERSION"
        # 确保 VERSION 是干净的，没有多余字符
        VERSION=$(echo "$VERSION" | tr -d '[:space:]')
        DOCKER_URL="$DOCKER_VERSIONS_URL$ARCH/docker-$VERSION.tgz"
    fi

    echo "正在下载 Docker 二进制包：$DOCKER_URL"
    curl -fSL --retry 3 "$DOCKER_URL" -o "$DOCKER_INSTALL_DIR/docker.tgz" || { echo "下载失败，请检查版本号或网络状态。"; rm -rf "$DOCKER_INSTALL_DIR"; exit 1; }

    echo "正在解压 Docker 包到临时文件夹..."
    tar -zxf "$DOCKER_INSTALL_DIR/docker.tgz" -C "$DOCKER_INSTALL_DIR" || { echo "解压失败。"; rm -rf "$DOCKER_INSTALL_DIR"; exit 1; }

    # 安装 Docker 二进制文件
    sudo chown root:root "$DOCKER_INSTALL_DIR/docker/"*
    sudo mv "$DOCKER_INSTALL_DIR/docker/"* /usr/local/bin/

    # 创建 Docker 用户组
    sudo groupadd -f docker

    # 将当前用户添加到 Docker 用户组
    if ! sudo gpasswd -a "$USER" docker; then
        echo "无法将当前用户添加到 'docker' 用户组，请手动添加。"
    fi
    newgrp docker

    # 创建 Docker 服务文件
    cat <<EOF | sudo tee /etc/systemd/system/docker.service
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP \$MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable docker
    sudo systemctl start docker

    # 验证安装
    if command -v docker >/dev/null 2>&1; then
        docker version >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "Docker 安装成功，请重新登录以应用用户组更改。"
        else
            echo "Docker 安装后，版本验证失败，请检查安装。"
        fi
    else
        echo "Docker 安装失败。"
    fi

    # 清理临时文件夹
    echo "清理临时文件..."
    rm -rf "$DOCKER_INSTALL_DIR"
}

# 函数: 安装 Docker Compose
install_docker_compose() {
    if check_docker_compose_installed; then
        read -r -p "Docker Compose 已安装，是否重新安装？(y/n): " REINSTALL
        if [[ "$REINSTALL" != "y" ]]; then
            echo "跳过 Docker Compose 安装。"
            return
        fi
    fi

    echo "正在安装 Docker Compose..."
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    sudo curl -fsSL "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || { echo "下载 Docker Compose 失败"; exit 1; }
    sudo chmod +x /usr/local/bin/docker-compose
    echo "Docker Compose 安装完成。"
}

# 函数: 卸载 Docker
uninstall_docker() {
    echo "正在卸载 Docker..."

    # 停止并禁用 Docker 服务
    sudo systemctl stop docker
    sudo systemctl disable docker

    # 删除软件包
    case "$PKG_MANAGER" in
        apt-get)
            sudo apt-get remove -y --purge docker docker-engine docker.io containerd runc
            ;;
        yum|dnf)
            sudo yum remove -y docker docker-engine docker.io containerd runc
            ;;
    esac

    # 清理文件和目录
    sudo rm -rf /var/lib/docker
    sudo rm -rf /etc/docker
    sudo rm -rf /usr/local/bin/docker*
    sudo rm -f /etc/systemd/system/docker.service

    # 清理用户组
    sudo groupdel docker
    echo "Docker 残留文件已清理。"

    # 清理镜像、容器和网络
    docker system prune -a -f
}

# 函数: 卸载 Docker Compose
uninstall_docker_compose() {
    echo "正在卸载 Docker Compose..."
    sudo rm -rf /usr/local/bin/docker-compose
    sudo rm -rf ~/.docker/compose
    echo "Docker Compose 残留文件已清理。"
}

# 函数: 生成 daemon.json 配置文件
generate_daemon_config() {
    echo "正在生成 Docker daemon.json 配置文件..."

    local DEFAULT_DATA_ROOT="/opt/docker"
    local DEFAULT_REGISTRY_MIRRORS=(
        "https://registry.cn-chengdu.aliyuncs.com"
        "https://mirror.ccs.tencentyun.com"
        "https://docker.mirrors.huaweicloud.com"
        "https://hub-mirror.c.163.com"
    )
    local DEFAULT_LOG_MAX_SIZE="5m"
    local DEFAULT_LOG_MAX_FILE="3"

    read -r -p "请输入 Docker data-root 路径 (留空默认: ${DEFAULT_DATA_ROOT}): " DATA_ROOT_INPUT
    DATA_ROOT="${DATA_ROOT_INPUT:-${DEFAULT_DATA_ROOT}}"

    local REGISTRY_MIRRORS_JSON=$(echo "${DEFAULT_REGISTRY_MIRRORS[@]}" | jq -c -s .)

    DAEMON_CONFIG=$(cat <<EOF
{
  "iptables": true,
  "ip6tables": true,
  "registry-mirrors": $REGISTRY_MIRRORS_JSON,
  "data-root": "${DATA_ROOT}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DEFAULT_LOG_MAX_SIZE}",
    "max-file": "${DEFAULT_LOG_MAX_FILE}"
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
        sudo systemctl restart docker
        if [ $? -eq 0 ]; then
            echo "Docker 服务重启成功，新配置已加载。"
        else
            echo "Docker 服务重启失败，请手动重启 Docker 服务: sudo systemctl restart docker"
        fi
    else
        echo "/etc/docker/daemon.json 文件生成失败，请检查权限或重试。"
    fi
}

# 主函数: 脚本入口
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
        read -r -p "请输入数字 (1/2/3/4/5/6/7/8/9): " CHOICE

        case "$CHOICE" in
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

# 删除安装状态文件,保证只安装一次依赖
rm -f "$INSTALL_STATUS"
