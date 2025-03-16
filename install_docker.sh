#!/bin/bash

# 依赖列表 (gnupg 和 lsb-release 根据常见系统情况添加)
DEPS=("curl" "wget" "jq" "fzf")
DOCKER_VERSIONS_URL="https://download.docker.com/linux/static/stable/"
COMPOSE_RELEASES_URL="https://api.github.com/repos/docker/compose/releases"

# 全局变量
INSTALL_STATUS=$(mktemp)  # 记录依赖安装状态
DOCKER_URL=""
DOCKER_INSTALL_DIR=""
ARCH=""
OS=""
PKG_MANAGER=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 函数: 检查是否具有 sudo 权限
check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}此脚本需要 root 权限运行，请以 root 用户运行或使用 'sudo' 执行。${NC}"
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
        echo -e "${RED}无法检测到支持的包管理工具 (apt-get/yum/dnf)，请手动安装必要的依赖后重试。${NC}"
        exit 1
    fi
}

# 函数: 安装依赖
install_dependencies() {
    echo "正在检测并安装缺失的依赖..."
    local installed_deps=($(dpkg-query -f '${binary:Package}\n' -W | grep -Fxf <(printf "%s\n" "${DEPS[@]}") 2>/dev/null))
    local needs_install=()

    for DEP in "${DEPS[@]}"; do
        if [[ ! " ${installed_deps[@]} " =~ " ${DEP} " ]]; then
            needs_install+=("$DEP")
        fi
    done

    if [[ ${#needs_install[@]} -gt 0 ]]; then
        echo "需要安装以下依赖: ${needs_install[*]}"
        for DEP in "${needs_install[@]}"; do
            echo "安装依赖：$DEP"
            case "$PKG_MANAGER" in
                apt-get) sudo apt-get install -y --no-install-recommends "$DEP" || { echo -e "${RED}安装 $DEP 失败${NC}"; exit 1; } ;;
                yum) sudo yum install -y "$DEP" || { echo -e "${RED}安装 $DEP 失败${NC}"; exit 1; } ;;
                dnf) sudo dnf install -y "$DEP" || { echo -e "${RED}安装 $DEP 失败${NC}"; exit 1; } ;;
            esac
            echo "$DEP" >> "$INSTALL_STATUS"
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
        armv6l) ARCH="armv6l" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac
    echo "$ARCH"
}

# 函数: 获取系统版本
get_os_version() {
    if [ -f /etc/os-release ]; then
        OS_NAME=$(grep ^ID= /etc/os-release | awk -F= '{print $2}' | tr -d '"')
        OS_VERSION=$(grep ^VERSION_ID= /etc/os-release | awk -F= '{print $2}' | tr -d '"')
    else
        echo -e "${RED}无法检测系统版本。请确保 /etc/os-release 文件存在并且格式正确。${NC}"
        exit 1
    fi
    echo "$OS_NAME $OS_VERSION"
}

# 函数: 检查磁盘空间并选择安装目录
check_and_set_install_dir() {
    local REQUIRED_SPACE=500  # 需要至少 500MB 空间

    # 获取脚本的存放目录
    local DIR=$(dirname "$(realpath "$0")")
    local DEFAULT_DIR="${DIR}/docker_install"

    # 确保默认目录存在
    mkdir -p "$DEFAULT_DIR" 2>/dev/null || {
        echo -e "${RED}无法创建默认目录 $DEFAULT_DIR，请检查权限。${NC}"
        exit 1
    }

    # 检查默认目录的可用空间
    local AVAILABLE_SPACE=$(df -m "$DEFAULT_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -z "$AVAILABLE_SPACE" ]]; then
        echo -e "${RED}无法检测目录 $DEFAULT_DIR 的磁盘空间，请检查系统状态。${NC}"
        exit 1
    fi

    echo -e "${YELLOW}默认目录: $DEFAULT_DIR (可用空间: ${AVAILABLE_SPACE}MB, 需要空间: ${REQUIRED_SPACE}MB)${NC}"
    read -r -p "是否需要指定自定义安装目录？(直接回车使用默认目录): " CUSTOM_DIR

    if [[ -n "$CUSTOM_DIR" ]]; then
        # 确保自定义目录存在
        mkdir -p "$CUSTOM_DIR" 2>/dev/null || {
            echo -e "${RED}无法创建自定义目录 $CUSTOM_DIR，请检查权限。${NC}"
            exit 1
        }
        AVAILABLE_SPACE=$(df -m "$CUSTOM_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
        if [[ -z "$AVAILABLE_SPACE" ]]; then
            echo -e "${RED}无法检测目录 $CUSTOM_DIR 的磁盘空间，请检查系统状态。${NC}"
            exit 1
        fi
        if [[ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]]; then
            echo -e "${RED}自定义目录 $CUSTOM_DIR 空间不足 (可用: ${AVAILABLE_SPACE}MB, 需要: ${REQUIRED_SPACE}MB)，退出脚本。${NC}"
            exit 1
        fi
        DOCKER_INSTALL_DIR="$CUSTOM_DIR/docker_install"
        echo -e "${GREEN}使用自定义目录: $DOCKER_INSTALL_DIR (可用空间: ${AVAILABLE_SPACE}MB)${NC}"
    else
        if [[ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]]; then
            echo -e "${RED}默认目录 $DEFAULT_DIR 空间不足 (可用: ${AVAILABLE_SPACE}MB, 需要: ${REQUIRED_SPACE}MB)，退出脚本。${NC}"
            exit 1
        fi
        DOCKER_INSTALL_DIR="$DEFAULT_DIR"
        echo -e "${GREEN}使用默认目录: $DOCKER_INSTALL_DIR (可用空间: ${AVAILABLE_SPACE}MB)${NC}"
    fi

    mkdir -p "$DOCKER_INSTALL_DIR" || {
        echo -e "${RED}创建目录 $DOCKER_INSTALL_DIR 失败，请检查权限或磁盘空间。${NC}"
        exit 1
    }
}

# 函数: 检测是否安装 Docker
check_docker_installed() {
    if command -v docker >/dev/null 2>&1; then
        echo -e "${GREEN}Docker 已安装，版本信息如下：${NC}"
        docker --version
        return 0
    else
        echo -e "${YELLOW}Docker 未安装。${NC}"
        return 1
    fi
}

# 函数: 检测是否安装 Docker Compose
check_docker_compose_installed() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo -e "${GREEN}Docker Compose 已安装，版本信息如下：${NC}"
        docker-compose --version
        return 0
    else
        echo -e "${YELLOW}Docker Compose 未安装。${NC}"
        return 1
    fi
}

# 函数: 获取 Docker 版本列表并进行过滤
fetch_docker_versions() {
    local CACHE_FILE="$DOCKER_INSTALL_DIR/docker_versions_cache"
    if [[ -f "$CACHE_FILE" && $(stat -c %Y "$CACHE_FILE") -gt $(($(date +%s) - 3600)) ]]; then
        cat "$CACHE_FILE"
        return
    fi

    ARCH=$(get_architecture)
    local URL="$DOCKER_VERSIONS_URL$ARCH/"
    local VERSIONS
    VERSIONS=$(curl -s "$URL" | grep -oP 'docker-\K[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | uniq)
    if [ -z "$VERSIONS" ]; then
        echo -e "${RED}无法获取版本列表，请检查网络连接或该架构是否支持。${NC}"
        exit 1
    fi
    echo "$VERSIONS" > "$CACHE_FILE"
    echo "$VERSIONS"
}

# 函数: 选择 Docker 版本（美化 fzf 界面）
select_docker_version() {
    local VERSIONS=($(fetch_docker_versions))

    if command -v fzf >/dev/null 2>&1; then
        local HEADER="选择 Docker 版本 (架构: $ARCH)"
        local INFO="使用 ↑↓ 导航，Enter 确认，Ctrl+C 取消"
        local SELECTED_VERSION=$(printf "%s\n" "${VERSIONS[@]}" | fzf \
            --prompt="请选择版本 > " \
            --header="$HEADER" \
            --header-lines=1 \
            --info=inline:"$INFO" \
            --height=20 \
            --reverse \
            --border \
            --color="header:blue,bg+:black,pointer:green" \
            --preview="echo '预览: Docker v{}'")
        SELECTED_VERSION=$(echo "$SELECTED_VERSION" | tr -d '[:space:]')
        if [ -n "$SELECTED_VERSION" ]; then
            echo "$SELECTED_VERSION"
            return
        else
            echo -e "${YELLOW}未选择版本，跳过...${NC}"
            return
        fi
    fi

    echo ""
}

# 函数: 获取 Docker Compose 版本列表
fetch_docker_compose_versions() {
    local VERSIONS
    VERSIONS=$(curl -s "$COMPOSE_RELEASES_URL" | jq -r '.[].tag_name' | sort -Vr | uniq)
    if [ -z "$VERSIONS" ]; then
        echo -e "${RED}无法获取 Docker Compose 版本列表，请检查网络连接。${NC}"
        exit 1
    fi
    echo "$VERSIONS"
}

# 函数: 选择 Docker Compose 版本 (美化 fzf 界面)
select_docker_compose_version() {
    local VERSIONS=($(fetch_docker_compose_versions))

    if command -v fzf >/dev/null 2>&1; then
        local HEADER="选择 Docker Compose 版本"
        local INFO="使用 ↑↓ 导航，Enter 确认，Ctrl+C 取消"
        local SELECTED_VERSION=$(printf "%s\n" "${VERSIONS[@]}" | fzf \
            --prompt="请选择版本 > " \
            --header="$HEADER" \
            --header-lines=1 \
            --info=inline:"$INFO" \
            --height=20 \
            --reverse \
            --border \
            --color="header:blue,bg+:black,pointer:green" \
            --preview="echo '预览: Docker Compose v{}'")
        SELECTED_VERSION=$(echo "$SELECTED_VERSION" | tr -d '[:space:]')
        if [ -n "$SELECTED_VERSION" ]; then
            echo "$SELECTED_VERSION"
            return
        else
            echo -e "${YELLOW}未选择版本，跳过...${NC}"
            return
        fi
    fi
    echo ""
}

# 函数: 安装 Docker
install_docker() {
    if check_docker_installed; then
        read -r -p "Docker 已安装，是否重新安装？(y/n): " REINSTALL
        if [[ "$REINSTALL" != "y" ]]; then
            echo -e "${YELLOW}跳过 Docker 安装。${NC}"
            return
        fi
    fi

    ARCH=$(get_architecture)
    echo "正在获取可用的 Docker 版本列表..."
    local VERSION=$(select_docker_version)
    check_and_set_install_dir

    if [ -z "$VERSION" ]; then
        echo -e "${YELLOW}未选择版本，安装最新版本的 Docker...${NC}"
        DOCKER_URL="$DOCKER_VERSIONS_URL$ARCH/docker.tgz"
    else
        echo -e "${GREEN}您选择安装的 Docker 版本为：$VERSION${NC}"
        VERSION=$(echo "$VERSION" | tr -d '[:space:]')
        DOCKER_URL="$DOCKER_VERSIONS_URL$ARCH/docker-$VERSION.tgz"
    fi

    echo "正在下载 Docker 二进制包：$DOCKER_URL"
    curl -fSL --retry 3 "$DOCKER_URL" -o "$DOCKER_INSTALL_DIR/docker.tgz" || { echo -e "${RED}下载失败，请检查版本号或网络状态。${NC}"; rm -rf "$DOCKER_INSTALL_DIR"; exit 1; }

    echo "正在解压 Docker 包到临时文件夹..."
    tar -zxf "$DOCKER_INSTALL_DIR/docker.tgz" -C "$DOCKER_INSTALL_DIR" || { echo -e "${RED}解压失败，可能是空间不足或权限问题。${NC}"; rm -rf "$DOCKER_INSTALL_DIR"; exit 1; }

    echo "正在安装 Docker 二进制文件..."
    sudo chown root:root "$DOCKER_INSTALL_DIR/docker/"*
    sudo mv "$DOCKER_INSTALL_DIR/docker/"* /usr/local/bin/ || { echo -e "${RED}移动 Docker 文件失败，请检查权限或磁盘空间。${NC}"; exit 1; }

    echo "创建 Docker 用户组..."
    sudo groupadd -f docker

    echo "将当前用户添加到 Docker 用户组..."
    if ! sudo gpasswd -a "$USER" docker >/dev/null 2>&1; then
        echo -e "${YELLOW}警告：无法将用户 '$USER' 添加到 'docker' 组，请手动执行 'sudo gpasswd -a $USER docker'。${NC}"
    else
        echo -e "${GREEN}用户 '$USER' 已成功添加到 'docker' 组。${NC}"
    fi

    echo "配置 Docker 服务..."
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

    echo "启动 Docker 服务..."
    sudo systemctl daemon-reload
    sudo systemctl enable docker >/dev/null 2>&1
    sudo systemctl start docker >/dev/null 2>&1

    if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
        echo -e "${GREEN}Docker 安装成功！版本信息：${NC}"
        docker --version
        echo -e "${YELLOW}请重新登录或重启 shell 以应用 'docker' 组更改。${NC}"
    else
        echo -e "${RED}Docker 安装失败或服务启动失败，请检查日志：sudo journalctl -u docker${NC}"
        exit 1
    fi

    echo "清理临时文件..."
    rm -rf "$DOCKER_INSTALL_DIR"
}

# 函数: 安装 Docker Compose
install_docker_compose() {
    if check_docker_compose_installed; then
        read -r -p "Docker Compose 已安装，是否重新安装？(y/n): " REINSTALL
        if [[ "$REINSTALL" != "y" ]]; then
            echo -e "${YELLOW}跳过 Docker Compose 安装。${NC}"
            return
        fi
    fi

    echo "正在获取可用的 Docker Compose 版本列表..."
    local COMPOSE_VERSION=$(select_docker_compose_version)

    if [ -z "$COMPOSE_VERSION" ]; then
        echo -e "${YELLOW}未选择版本，安装最新版本的 Docker Compose...${NC}"
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    else
        echo -e "${GREEN}您选择安装的 Docker Compose 版本为：$COMPOSE_VERSION${NC}"
        COMPOSE_VERSION=$(echo "$COMPOSE_VERSION" | tr -d '[:space:]')
    fi

    ARCH=$(get_architecture)
    os_name=$(uname -s)
    arch_name=$(uname -m)

    case "$os_name" in
        Linux)
            case "$arch_name" in
                x86_64) compose_file="docker-compose-Linux-x86_64" ;;
                aarch64) compose_file="docker-compose-Linux-aarch64" ;;
                armv7l) compose_file="docker-compose-Linux-armv7l" ;; # 适用于32位ARM
                armv6l) compose_file="docker-compose-Linux-armv6l" ;; # 早期树莓派
                *)
                    echo -e "${RED}不支持的 Linux 架构: $arch_name${NC}"
                    exit 1
                    ;;
            esac
            ;;
        Darwin) # macOS
            case "$arch_name" in
                x86_64) compose_file="docker-compose-Darwin-x86_64" ;;
                arm64) compose_file="docker-compose-Darwin-arm64" ;; # Apple Silicon
                *)
                    echo -e "${RED}不支持的 macOS 架构: $arch_name${NC}"
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo -e "${RED}不支持的操作系统: $os_name${NC}"
            exit 1
            ;;
    esac

    echo "正在安装 Docker Compose 版本：$COMPOSE_VERSION"
    sudo curl -fsSL "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/$compose_file" -o /usr/local/bin/docker-compose || { echo -e "${RED}下载 Docker Compose 失败${NC}"; exit 1; }
    sudo chmod +x /usr/local/bin/docker-compose
    echo -e "${GREEN}Docker Compose 安装完成。${NC}"
}

# 函数: 卸载 Docker
uninstall_docker() {
    echo "正在卸载 Docker..."

    # 1. 停止 Docker 服务
    sudo systemctl stop docker.service 2>/dev/null || true # 忽略停止失败

    # 2. 禁用 Docker 服务
    sudo systemctl disable docker.service 2>/dev/null || true # 忽略禁用失败

    # 3. 移除 Docker 包 (根据包管理器)
    case "$PKG_MANAGER" in
        apt-get) sudo apt-get remove -y --purge docker docker-engine docker.io containerd runc docker-ce docker-ce-cli 2>/dev/null || true ;; # 忽略移除失败，包含 docker-ce
        yum|dnf) sudo yum remove -y docker docker-engine docker.io containerd runc docker-ce docker-ce-cli 2>/dev/null || true ;; # 忽略移除失败，包含 docker-ce
    esac

    # 4. 移除相关文件和目录
    sudo rm -rf /var/lib/docker /etc/docker /usr/local/bin/docker* /usr/bin/docker* /usr/sbin/docker* /opt/docker  # 删除 /opt/docker
    sudo rm -f /etc/systemd/system/docker.service
    sudo rm -f /etc/systemd/system/docker.socket
    sudo rm -rf /var/run/docker
    sudo rm -rf /var/log/docker*

    # 5. 移除 Docker 用户组
    sudo groupdel docker 2>/dev/null || true # 忽略用户组删除失败

    # 6. 清理镜像、容器、网络和卷
    echo "清理 Docker 镜像，容器，网络和卷..."
    docker system prune -a -f 2>/dev/null || true  # 忽略清理失败

    # 7. 尝试清理 containerd 和 runc 的残留
    echo "尝试清理 containerd 和 runc 的残留..."
    sudo rm -rf /var/lib/containerd 2>/dev/null || true
    sudo rm -rf /run/containerd 2>/dev/null || true
    sudo rm -rf /usr/local/bin/containerd 2>/dev/null || true
    sudo rm -rf /usr/local/bin/runc 2>/dev/null || true

    # 8. 清理日志 (可选)
    echo "尝试清理 Docker 日志..."
    sudo find /var/log -name "docker*" -delete 2>/dev/null || true

    # 9. 更新 systemd
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo systemctl reset-failed 2>/dev/null || true

    echo -e "${GREEN}Docker 已卸载，残留文件已清理。${NC}"
}


# 函数: 卸载 Docker Compose
uninstall_docker_compose() {
    echo "正在卸载 Docker Compose..."
    sudo rm -rf /usr/local/bin/docker-compose ~/.docker/compose
    sudo rm -rf /opt/docker-compose # 删除可能的compose安装目录
    echo -e "${GREEN}Docker Compose 残留文件已清理。${NC}"
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

    # 使用 jq 确保 registry-mirrors 正确生成 JSON 数组
    local REGISTRY_MIRRORS_JSON=$(printf '%s\n' "${DEFAULT_REGISTRY_MIRRORS[@]}" | jq -R . | jq -s .)

    # 使用 heredoc 和变量替换生成完整的 JSON 配置
    DAEMON_CONFIG=$(cat <<EOF
{
  "iptables": true,
  "ip6tables": true,
  "registry-mirrors": ${REGISTRY_MIRRORS_JSON},
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

    # 验证 JSON 格式是否正确
    if ! echo "$DAEMON_CONFIG" | jq . >/dev/null 2>&1; then
        echo -e "${RED}错误：生成的 daemon.json 格式不正确，请检查脚本依赖（如 jq）。${NC}"
        exit 1
    fi

    sudo mkdir -p /etc/docker
    echo "$DAEMON_CONFIG" | sudo tee /etc/docker/daemon.json > /dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}/etc/docker/daemon.json 文件生成成功。${NC}"
        echo "正在重启 Docker 服务以应用配置..."
        sudo systemctl restart docker
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Docker 服务重启成功，新配置已加载。${NC}"
        else
            echo -e "${YELLOW}Docker 服务重启失败，请手动重启: sudo systemctl restart docker${NC}"
        fi
    else
        echo -e "${RED}/etc/docker/daemon.json 文件生成失败，请检查权限或重试。${NC}"
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
        echo -e "${YELLOW}请选择要执行的操作：${NC}"
        echo -e "${GREEN}1. 安装 Docker${NC}"
        echo -e "${GREEN}2. 安装 Docker Compose${NC}"
        echo -e "${GREEN}3. 安装 Docker 和 Docker Compose${NC}"
        echo -e "${RED}4. 卸载 Docker${NC}"
        echo -e "${RED}5. 卸载 Docker Compose${NC}"
        echo -e "${RED}6. 卸载 Docker 和 Docker Compose${NC}"
        echo -e "${YELLOW}7. 查询 Docker 和 Docker Compose 的安装状态${NC}"
        echo -e "${YELLOW}8. 生成 daemon.json 配置文件${NC}"
        echo -e "${RED}9. 退出脚本${NC}"
        read -r -p "请输入数字 (1/2/3/4/5/6/7/8/9): " CHOICE

        case "$CHOICE" in
            1) install_docker ;;
            2) install_docker_compose ;;
            3) install_docker; install_docker_compose ;;
            4) uninstall_docker ;;
            5) uninstall_docker_compose ;;
            6) uninstall_docker; uninstall_docker_compose ;;
            7) check_docker_installed; check_docker_compose_installed ;;
            8) generate_daemon_config ;;
            9) echo -e "${GREEN}退出脚本。${NC}"; exit 0 ;;
            *) echo -e "${RED}无效的选择，请重新输入。${NC}" ;;
        esac
    done
}

main

rm -f "$INSTALL_STATUS"
