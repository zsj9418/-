#!/bin/bash

# 函数：判断系统架构
get_architecture() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="x86_64" ;;
        aarch64) ARCH="aarch64" ;;
        armv7l) ARCH="armv7" ;;
        *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac
    echo $ARCH
}

# 函数：判断系统版本
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

# 函数：检测是否安装 Docker
check_docker_installed() {
    if command -v docker >/dev/null 2>&1; then
        echo "Docker 已安装，版本信息如下："
        docker --version
    else
        echo "Docker 未安装。"
    fi
}

# 函数：检测是否安装 Docker Compose
check_docker_compose_installed() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "Docker Compose 已安装，版本信息如下："
        docker-compose --version
    else
        echo "Docker Compose 未安装。"
    fi
}

# 函数：安装依赖
install_dependencies() {
    echo "正在检测并安装缺失的依赖..."
    local DEPS=("curl" "gnupg" "lsb-release" "ca-certificates" "software-properties-common" "wget" "jq" "dialog")
    for DEP in "${DEPS[@]}"; do
        if ! dpkg -l | grep -q "^ii  $DEP "; then
            sudo apt-get install -y $DEP
        else
            echo "$DEP 已安装，跳过..."
        fi
    done
}

# 函数：爬取 Docker 官方页面获取版本信息
fetch_docker_versions() {
    local ARCH=$(get_architecture)
    local URL="https://download.docker.com/linux/static/stable/$ARCH/"
    echo "正在获取可用的 Docker 版本列表..."
    VERSIONS=$(curl -s $URL | grep -oP 'docker-\K[0-9]+\.[0-9]+\.[0-9]+' | sort -rV | uniq)
    if [ -z "$VERSIONS" ]; then
        echo "无法获取版本列表，请检查网络连接。"
        exit 1
    fi
    echo "$VERSIONS"
}

# 函数：让用户选择 Docker 版本
select_docker_version() {
    local VERSIONS=($(fetch_docker_versions))
    local MENU_ITEMS=()
    for VERSION in "${VERSIONS[@]}"; do
        MENU_ITEMS+=("$VERSION" "$VERSION")
    done

    # 使用 dialog 显示版本选择菜单
    SELECTED_VERSION=$(dialog --clear --title "Docker 版本选择" --menu "使用上下键选择版本，回车确定：" 15 50 10 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)

    if [ $? -eq 0 ]; then
        echo "$SELECTED_VERSION"
    else
        echo ""
    fi
}

# 函数：安装 Docker
install_docker() {
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
    wget -O "$TEMP_DIR/docker.tgz" "$DOCKER_URL"
    if [ $? -ne 0 ]; then
        echo "下载失败，请检查版本号或网络状态。"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    echo "正在解压 Docker 包到临时文件夹..."
    tar -zxf "$TEMP_DIR/docker.tgz" -C "$TEMP_DIR"
    sudo mv "$TEMP_DIR/docker/"* /usr/bin/

    # 清理临时文件夹
    echo "清理临时文件..."
    rm -rf "$TEMP_DIR"

    echo "Docker 安装完成，请重新登录以应用用户组更改。"
}

# 函数：安装 Docker Compose
install_docker_compose() {
    echo "正在安装 Docker Compose..."
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    sudo curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    echo "Docker Compose 安装完成。"
}

# 函数：卸载 Docker
uninstall_docker() {
    echo "正在卸载 Docker..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc
    sudo rm -rf /var/lib/docker
    sudo rm -rf /etc/docker
    sudo rm -rf /usr/bin/docker*
    echo "Docker 残留文件已清理。"
}

# 函数：卸载 Docker Compose
uninstall_docker_compose() {
    echo "正在卸载 Docker Compose..."
    sudo rm -rf /usr/local/bin/docker-compose
    sudo rm -rf ~/.docker/compose
    echo "Docker Compose 残留文件已清理。"
}

# 主脚本
echo "欢迎使用 Docker 和 Docker Compose 一键安装脚本"
echo "检测系统信息..."
ARCH=$(get_architecture)
OS=$(get_os_version)
echo "系统架构: $ARCH"
echo "系统版本: $OS"

# 检测是否已安装 Docker 和 Docker Compose
echo "检测设备是否已安装 Docker 和 Docker Compose..."
check_docker_installed
check_docker_compose_installed

# 用户选择
echo "请选择要执行的操作："
echo "1. 安装 Docker"
echo "2. 安装 Docker Compose"
echo "3. 安装 Docker 和 Docker Compose"
echo "4. 卸载 Docker"
echo "5. 卸载 Docker Compose"
echo "6. 卸载 Docker 和 Docker Compose"
echo "7. 查询 Docker 和 Docker Compose 的安装状态"
read -p "请输入数字 (1/2/3/4/5/6/7): " CHOICE

case $CHOICE in
    1)
        install_dependencies
        install_docker
        ;;
    2)
        install_dependencies
        install_docker_compose
        ;;
    3)
        install_dependencies
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
    *)
        echo "无效的选择，退出脚本。"
        exit 1
        ;;
esac

echo "脚本执行完成！"
