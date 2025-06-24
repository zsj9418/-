#!/bin/bash

# 全局颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ====================================================================
# V0 版本 - Argo Nezha 部署逻辑 (来自第一个脚本)
# ====================================================================

# V0 - Argo Nezha 相关变量
V0_IMAGE="fscarmen/argo-nezha:latest"
V0_CONTAINER_NAME="argo-nezha"
V0_CONFIG_FILE="./argo_nezha_env.conf"

# V0 - 读取环境变量
function v0_read_env() {
    if [ -f "$V0_CONFIG_FILE" ]; then
        source "$V0_CONFIG_FILE"
    fi
}

# V0 - 保存环境变量
function v0_save_env() {
    cat <<EOF >"$V0_CONFIG_FILE"
GH_USER="$GH_USER"
GH_CLIENTID="$GH_CLIENTID"
GH_CLIENTSECRET="$GH_CLIENTSECRET"
GH_BACKUP_USER="$GH_BACKUP_USER"
GH_REPO="$GH_REPO"
GH_EMAIL="$GH_EMAIL"
GH_PAT="$GH_PAT"
REVERSE_PROXY_MODE="$REVERSE_PROXY_MODE"
ARGO_AUTH="$ARGO_AUTH"
ARGO_DOMAIN="$ARGO_DOMAIN"
NO_AUTO_RENEW="$NO_AUTO_RENEW"
DASHBOARD_VERSION="$DASHBOARD_VERSION"
EOF
    echo -e "${GREEN}配置已保存到 $V0_CONFIG_FILE${NC}"
}

# V0 - 输入环境变量
function v0_input_env() {
    echo -e "${YELLOW}以下变量为必填项，空缺将阻止安装：${NC}"
    read -rp "GH_USER (github 用户名): " GH_USER
    while [[ -z "$GH_USER" ]]; do
        read -rp "GH_USER 不能为空，请重新输入: " GH_USER
    done

    read -rp "GH_CLIENTID (GitHub Client ID): " GH_CLIENTID
    while [[ -z "$GH_CLIENTID" ]]; do
        read -rp "GH_CLIENTID 不能为空，请重新输入: " GH_CLIENTID
    done

    read -rp "GH_CLIENTSECRET (GitHub Client Secret): " GH_CLIENTSECRET
    while [[ -z "$GH_CLIENTSECRET" ]]; do
        read -rp "GH_CLIENTSECRET 不能为空，请重新输入: " GH_CLIENTSECRET
    done

    read -rp "GH_BACKUP_USER (可选): " GH_BACKUP_USER
    read -rp "GH_REPO (可选): " GH_REPO
    read -rp "GH_EMAIL (可选): " GH_EMAIL
    read -rp "GH_PAT (可选): " GH_PAT
    read -rp "REVERSE_PROXY_MODE [caddy/nginx/grpcwebproxy] (默认caddy): " REVERSE_PROXY_MODE
    REVERSE_PROXY_MODE=${REVERSE_PROXY_MODE:-caddy}

    read -rp "ARGO_AUTH (Argo隧道Json/Token): " ARGO_AUTH
    while [[ -z "$ARGO_AUTH" ]]; do
        read -rp "ARGO_AUTH 不能为空，请重新输入: " ARGO_AUTH
    done

    read -rp "ARGO_DOMAIN (Argo 域名): " ARGO_DOMAIN
    while [[ -z "$ARGO_DOMAIN" ]]; do
        read -rp "ARGO_DOMAIN 不能为空，请重新输入: " ARGO_DOMAIN
    done

    read -rp "NO_AUTO_RENEW (如不使用脚本同步功能填1，默认留空): " NO_AUTO_RENEW
    read -rp "DASHBOARD_VERSION(填0.17.9): " DASHBOARD_VERSION
    
}

# V0 - 部署 Argo Nezha
function v0_deploy() {
    echo -e "${BLUE}开始部署 Argo Nezha (V0 版本)...${NC}"
    echo "读取现有配置环境..."
    v0_read_env
    echo -e "${BLUE}>>> 当前配置如下：${NC}"
    env | grep -E "GH_|ARGO_|REVERSE_PROXY_MODE|NO_AUTO_RENEW" | sed 's/^/\t/' # 缩进显示

    echo -e "\n是否重新输入环境变量？[y/N]"
    read -r CHOICE
    if [[ "$CHOICE" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        v0_input_env
        v0_save_env
    fi

    # 检查docker
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}Docker 未安装，自动安装 Docker...${NC}"
        curl -fsSL get.docker.com | bash || { echo -e "${RED}Docker 安装失败！${NC}"; exit 1; }
        systemctl start docker &>/dev/null
        systemctl enable docker &>/dev/null
    fi

    # =========================
    # 端口与网络模式交互
    # =========================
    NET_MODE=""
    PORT_MAPPING=""
    echo
    echo -e "${BLUE}请选择网络模式:${NC}"
    echo "1) bridge (Docker 默认, 推荐)"
    echo "2) host (容器与主机共用网络)"
    read -rp "请输入数字 [1/2] 回车默认 bridge: " NET_CHOICE

    if [[ "$NET_CHOICE" == "2" || "$NET_CHOICE" =~ ^[hH][oO][sS][tT]$ ]]; then
        NET_MODE="--network host"
        PORT_MAPPING=""
        echo -e "${GREEN}已选择 host 模式，使用主机网络，不做端口单独映射。${NC}"
    else
        NET_MODE=""
        echo -e "${GREEN}已选择 bridge 模式。${NC}"
        read -rp "输入宿主机端口用于映射容器8008端口 (如8008，留空则不做端口映射): " HOST_PORT
        if [[ -n "$HOST_PORT" ]]; then
            if [[ ! "$HOST_PORT" =~ ^[0-9]{2,5}$ ]]; then
                echo -e "${YELLOW}端口号 '$HOST_PORT' 无效，将跳过端口映射。${NC}"
                PORT_MAPPING=""
            else
                PORT_MAPPING="-p ${HOST_PORT}:8008"
                echo -e "${GREEN}端口映射: 设备端口 ${HOST_PORT} => 容器8008${NC}"
            fi
        else
            PORT_MAPPING=""
            echo -e "${YELLOW}未设置端口映射。${NC}"
        fi
    fi
    # =========================

    if docker ps -a --format '{{.Names}}' | grep -q "^$V0_CONTAINER_NAME$"; then
        echo -e "${YELLOW}已有同名容器 ($V0_CONTAINER_NAME)，停止并删除中...${NC}"
        docker stop "$V0_CONTAINER_NAME" && docker rm "$V0_CONTAINER_NAME" || { echo -e "${RED}停止/删除旧容器失败！${NC}"; exit 1; }
    fi

    echo -e "${BLUE}开始拉取镜像 $V0_IMAGE...${NC}"
    docker pull "$V0_IMAGE" || { echo -e "${RED}镜像拉取失败！${NC}"; exit 1; }

    echo -e "${BLUE}启动容器 $V0_CONTAINER_NAME...${NC}"
    docker run -d --name "$V0_CONTAINER_NAME" \
        $NET_MODE $PORT_MAPPING \
        -e GH_USER="$GH_USER" \
        -e GH_CLIENTID="$GH_CLIENTID" \
        -e GH_CLIENTSECRET="$GH_CLIENTSECRET" \
        -e GH_BACKUP_USER="$GH_BACKUP_USER" \
        -e GH_REPO="$GH_REPO" \
        -e GH_EMAIL="$GH_EMAIL" \
        -e GH_PAT="$GH_PAT" \
        -e REVERSE_PROXY_MODE="$REVERSE_PROXY_MODE" \
        -e ARGO_AUTH="$ARGO_AUTH" \
        -e ARGO_DOMAIN="$ARGO_DOMAIN" \
        -e NO_AUTO_RENEW="$NO_AUTO_RENEW" \
        -e DASHBOARD_VERSION="$DASHBOARD_VERSION" \
        --restart always \
        "$V0_IMAGE"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}部署完成！容器 $V0_CONTAINER_NAME 已启动。${NC}"
        echo -e "${YELLOW}如需再次修改变量，可 rerun 本脚本选择 'V0 版本' 并重新填写。${NC}"
    else
        echo -e "${RED}容器启动失败，请检查 Docker 日志：${NC}"
        docker logs "$V0_CONTAINER_NAME"
        exit 1
    fi
}

# V0 - 卸载 Argo Nezha
function v0_uninstall() {
    echo -e "${YELLOW}停止并删除 argo-nezha 容器...${NC}"
    docker stop "$V0_CONTAINER_NAME" 2>/dev/null && docker rm "$V0_CONTAINER_NAME" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}容器 $V0_CONTAINER_NAME 已卸载。${NC}"
    else
        echo -e "${YELLOW}未找到容器 $V0_CONTAINER_NAME，跳过删除。${NC}"
    fi

    if docker images -q "$V0_IMAGE" &>/dev/null; then
        echo -e "${YELLOW}删除镜像 $V0_IMAGE...${NC}"
        docker rmi "$V0_IMAGE" 2>/dev/null
        echo -e "${GREEN}镜像 $V0_IMAGE 已删除。${NC}"
    else
        echo -e "${YELLOW}未找到镜像 $V0_IMAGE，跳过删除。${NC}"
    fi
    echo -e "${GREEN}V0 版本卸载完成。${NC}"
}

# V0 - 显示 Argo Nezha 状态
function v0_show_status() {
    echo -e "${BLUE}Argo Nezha ($V0_CONTAINER_NAME) 容器状态：${NC}"
    docker ps -a --filter "name=$V0_CONTAINER_NAME"
    echo -e "${BLUE}最新日志 (20 行)：${NC}"
    docker logs --tail 20 "$V0_CONTAINER_NAME" 2>/dev/null
}

# ====================================================================
# V1 版本 - Nezha Dashboard 部署逻辑 (来自第二个脚本)
# ====================================================================

# V1 - Nezha Dashboard 相关变量 (保持与原脚本一致)
V1_IMAGE_NAME="ghcr.io/nezhahq/nezha"
V1_DEFAULT_TAG="latest"
V1_DEFAULT_WEB_PORT="8008"
V1_DEFAULT_AGENT_PORT="5555"
V1_DEFAULT_DATA_DIR="/opt/nezha/dashboard"
V1_DEFAULT_TIMEZONE="Asia/Shanghai"
V1_CONTAINER_NAME="nezha-dashboard"
V1_MAX_LOG_SIZE="1m"
V1_RETRY_COUNT=3
V1_DEPENDENCY_CHECK_FILE="/tmp/nezha_dependency_check_v1" # 区分 V0 和 V1 的依赖文件
V1_MIN_DISK_SPACE=1 # 最小磁盘空间（GB）
V1_MIN_MEMORY=150 # 最小内存（MB）

# V1 - 检查是否以root权限运行
function v1_check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请以root权限运行此脚本（使用 sudo）${NC}"
        exit 1
    fi
}

# V1 - 检测系统类型
function v1_detect_os() {
    if [ -f /etc/debian_version ]; then
        V1_OS_TYPE="debian"
        V1_PKG_MANAGER="apt-get"
    elif [ -f /etc/redhat-release ]; then
        V1_OS_TYPE="redhat"
        V1_PKG_MANAGER="yum"
    elif [ "$(uname -s)" == "Darwin" ]; then
        V1_OS_TYPE="macos"
        V1_PKG_MANAGER="brew"
    else
        echo -e "${RED}不支持的操作系统${NC}"
        exit 1
    fi
    echo -e "${GREEN}检测到操作系统: $V1_OS_TYPE${NC}"
}

# V1 - 检测设备架构
function v1_detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) V1_ARCH_NAME="amd64";;
        armv7l|armhf) V1_ARCH_NAME="armhf";;
        aarch64|arm64) V1_ARCH_NAME="arm64";;
        *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1;;
    esac
    echo -e "${GREEN}检测到设备架构: $V1_ARCH_NAME${NC}"
}

# V1 - 检查磁盘空间
function v1_check_disk_space() {
    local required_space=$1
    local available_space=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ -z "$available_space" ] || [ "$available_space" -lt "$required_space" ]; then
        echo -e "${RED}错误：可用磁盘空间 (${available_space:-0} GB) 小于要求 ($required_space GB)${NC}"
        exit 1
    fi
    echo -e "${GREEN}磁盘空间检查通过：可用 $available_space GB${NC}"
}

# V1 - 检查内存
function v1_check_memory() {
    local available_memory=$(free -m | grep -i mem | awk '{print $7}')
    if [ -z "$available_memory" ]; then
        available_memory=$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')
    fi
    if [ -z "$available_memory" ] || [ "$available_memory" -lt "$V1_MIN_MEMORY" ]; then
        echo -e "${RED}错误：可用内存 (${available_memory:-0} MB) 小于要求 ($V1_MIN_MEMORY MB)${NC}"
        exit 1
    fi
    echo -e "${GREEN}内存检查通过：可用 $available_memory MB${NC}"
}

# V1 - 检查并安装依赖
function v1_check_dependencies() {
    if [ -f "$V1_DEPENDENCY_CHECK_FILE" ]; then
        echo -e "${GREEN}V1 版本依赖已检查过，跳过重复检测${NC}"
        return 0
    fi

    echo -e "${BLUE}检查 V1 版本依赖...${NC}"
    local deps_installed=0

    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Docker 未安装，正在安装...${NC}"
        case $V1_OS_TYPE in
            debian)
                $V1_PKG_MANAGER update && $V1_PKG_MANAGER install -y docker.io
                systemctl start docker
                systemctl enable docker
                ;;
            redhat)
                $V1_PKG_MANAGER install -y docker
                systemctl start docker
                systemctl enable docker
                ;;
            macos)
                if ! command -v brew &> /dev/null; then
                    echo -e "${YELLOW}Homebrew 未安装，请手动安装${NC}"
                    exit 1
                fi
                brew install docker
                ;;
        esac
        deps_installed=1
    fi

    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}curl 未安装，正在安装...${NC}"
        case $V1_OS_TYPE in
            debian) $V1_PKG_MANAGER install -y curl;;
            redhat) $V1_PKG_MANAGER install -y curl;;
            macos) brew install curl;;
        esac
        deps_installed=1
    fi

    if [ $deps_installed -eq 0 ]; then
        echo -e "${GREEN}所有依赖已满足${NC}"
    fi
    touch "$V1_DEPENDENCY_CHECK_FILE"
}

# V1 - 获取可用镜像版本（直接使用默认版本）
function v1_get_available_tags() {
    echo -e "${BLUE}使用 GitHub Container Registry 镜像: ${V1_IMAGE_NAME}:${V1_DEFAULT_TAG}${NC}"
    V1_FULL_IMAGE_NAME="${V1_IMAGE_NAME}:${V1_DEFAULT_TAG}" # 确保包含标签
}

# V1 - 检查并设置数据目录
function v1_setup_data_dir() {
    echo -e "${BLUE}设置数据目录...${NC}"
    read -p "请输入数据目录路径（直接回车使用默认值 $V1_DEFAULT_DATA_DIR）: " V1_DATA_DIR_INPUT
    V1_DATA_DIR=${V1_DATA_DIR_INPUT:-$V1_DEFAULT_DATA_DIR}
    mkdir -p "$V1_DATA_DIR"
    # Note: Nezha Dashboard Docker image typically runs as UID/GID 1000.
    chown -R 1000:1000 "$V1_DATA_DIR" &>/dev/null # 忽略 chown 错误，如果 1000 用户不存在
    chmod -R 755 "$V1_DATA_DIR"
    echo -e "${GREEN}数据目录设置为: $V1_DATA_DIR${NC}"
}

# V1 - 获取用户输入
function v1_get_user_input() {
    read -p "请输入 Web 端口（直接回车使用默认值 $V1_DEFAULT_WEB_PORT）: " V1_WEB_PORT_INPUT
    V1_WEB_PORT=${V1_WEB_PORT_INPUT:-$V1_DEFAULT_WEB_PORT}
    read -p "请输入 Agent 端口（直接回车使用默认值 $V1_DEFAULT_AGENT_PORT）: " V1_AGENT_PORT_INPUT
    V1_AGENT_PORT=${V1_AGENT_PORT_INPUT:-$V1_DEFAULT_AGENT_PORT}
    read -p "请输入时区（直接回车使用默认值 $V1_DEFAULT_TIMEZONE）: " V1_TIMEZONE_INPUT
    V1_TIMEZONE=${V1_TIMEZONE_INPUT:-$V1_DEFAULT_TIMEZONE}
}

# V1 - 动态检测端口
function v1_check_port() {
    local port=$1
    local port_name=$2
    local current_os_type=$V1_OS_TYPE # 使用 V1 的 OS 类型

    if [ "$current_os_type" == "macos" ]; then
        while netstat -an | grep -q ":$port "; do
            echo -e "${YELLOW}端口 $port ($port_name) 已被占用${NC}"
            read -p "请输入新的 $port_name 端口: " port
        done
    else
        while ss -tuln | grep -q ":$port "; do
            echo -e "${YELLOW}端口 $port ($port_name) 已被占用${NC}"
            read -p "请输入新的 $port_name 端口: " port
        done
    fi
    echo $port # 返回确认后的端口
}

# V1 - 选择网络模式
function v1_select_network_mode() {
    echo -e "${BLUE}请选择网络模式:${NC}"
    echo "1) bridge (默认)"
    echo "2) host"
    echo "3) macvlan (高级用户)"
    read -p "请输入选项 (1-3，直接回车使用默认值 1): " V1_NETWORK_CHOICE
    case $V1_NETWORK_CHOICE in
        2) V1_NETWORK_MODE="--network host";;
        3) V1_NETWORK_MODE="--network macvlan";;
        *) V1_NETWORK_MODE="--network bridge";;
    esac
    echo -e "${GREEN}网络模式: $V1_NETWORK_MODE${NC}"
}

# V1 - 拉取镜像并重试（完全指向 GHCR）
function v1_pull_image() {
    echo -e "${BLUE}正在从 GitHub Container Registry 拉取镜像 ${V1_FULL_IMAGE_NAME}...${NC}"

    for ((i=1; i<=V1_RETRY_COUNT; i++)); do
        if docker pull "${V1_FULL_IMAGE_NAME}"; then
            echo -e "${GREEN}镜像拉取成功${NC}"
            return 0
        fi

        echo -e "${YELLOW}第 $i 次拉取失败，重试中...（等待 2 秒）${NC}"
        sleep 2

        if [ $i -eq $V1_RETRY_COUNT ]; then
            echo -e "${YELLOW}正在验证镜像是否存在...${NC}"
            if ! curl -sI "https://ghcr.io/v2/nezhahq/nezha/manifests/${V1_DEFAULT_TAG}" | grep -q "200 OK"; then
                echo -e "${RED}致命错误：镜像 ${V1_FULL_IMAGE_NAME} 在仓库中不存在${NC}"
                echo -e "请检查以下信息："
                echo -e "1. 项目仓库: https://github.com/nezhahq/nezha/pkgs/container/nezha"
                echo -e "2. 可用标签: latest 或具体版本号（如 v0.15.0）"
                exit 1
            fi
        fi
    done

    echo -e "${RED}镜像拉取失败，请检查以下问题：${NC}"
    echo -e "1. 网络连接：运行 'ping ghcr.io' 和 'curl -I https://ghcr.io'"
    echo -e "2. Docker 配置：检查 /etc/docker/daemon.json 是否包含镜像加速配置"
    echo -e "3. 权限问题：尝试 'docker login ghcr.io'（如需认证）"
    echo -e "4. 手动拉取测试：执行 'docker pull ${V1_FULL_IMAGE_NAME}'"
    exit 1
}

# V1 - 启动容器（确保使用正确的镜像名称）
function v1_start_container() {
    # 停止并删除可能存在的旧容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${V1_CONTAINER_NAME}$"; then
        echo -e "${YELLOW}检测到同名容器 $V1_CONTAINER_NAME，正在停止并删除...${NC}"
        docker stop "$V1_CONTAINER_NAME" &>/dev/null
        docker rm "$V1_CONTAINER_NAME" &>/dev/null
    fi

    echo -e "${BLUE}启动容器 $V1_CONTAINER_NAME...${NC}"
    docker run -d \
        --name "$V1_CONTAINER_NAME" \
        $V1_NETWORK_MODE \
        -v "$V1_DATA_DIR:/dashboard/data" \
        -v /etc/localtime:/etc/localtime:ro \
        -p "$V1_WEB_PORT:8008" \
        -p "$V1_AGENT_PORT:5555" \
        -e PORT="$V1_WEB_PORT" \
        -e TZ="$V1_TIMEZONE" \
        --restart unless-stopped \
        --log-opt max-size="$V1_MAX_LOG_SIZE" \
        "${V1_FULL_IMAGE_NAME}"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}容器 $V1_CONTAINER_NAME 启动成功！${NC}"
        echo -e "Web 访问地址: http://localhost:$V1_WEB_PORT"
        echo -e "Agent 端口: $V1_AGENT_PORT"
        echo -e "数据目录: $V1_DATA_DIR"
        echo -e "时区: $V1_TIMEZONE"
        echo -e "${YELLOW}请在浏览器中访问 http://localhost:$V1_WEB_PORT 进行初始配置（设置管理员账户等）${NC}"
    else
        echo -e "${RED}容器启动失败，请检查以下错误信息：${NC}"
        docker logs "$V1_CONTAINER_NAME"
        exit 1
    fi
}

# V1 - 卸载功能
function v1_uninstall() {
    echo -e "${YELLOW}正在卸载 $V1_CONTAINER_NAME...${NC}"

    if docker ps -a --format '{{.Names}}' | grep -q "^${V1_CONTAINER_NAME}$"; then
        docker rm -f "$V1_CONTAINER_NAME" &>/dev/null
        echo -e "${GREEN}容器 $V1_CONTAINER_NAME 已删除${NC}"
    else
        echo -e "${YELLOW}未找到容器 $V1_CONTAINER_NAME，跳过删除${NC}"
    fi

    if docker images -q "${V1_IMAGE_NAME}" | grep -q .; then
        docker rmi -f "${V1_IMAGE_NAME}" &>/dev/null
        echo -e "${GREEN}镜像 ${V1_IMAGE_NAME} 已删除${NC}"
    else
        echo -e "${YELLOW}未找到镜像 ${V1_IMAGE_NAME}，跳过删除${NC}"
    fi

    # 尝试删除上次使用的数据目录，如果存在的话
    local last_data_dir=$(grep '^V1_DATA_DIR_INPUT=' "$V1_CONFIG_FILE" 2>/dev/null | cut -d= -f2)
    if [ -z "$last_data_dir" ]; then
        last_data_dir="$V1_DEFAULT_DATA_DIR" # 如果配置文件中没有，就用默认值
    fi

    if [ -d "$last_data_dir" ]; then
        read -rp "$(echo -e "${YELLOW}是否删除数据目录 $last_data_dir？(此操作不可逆，建议备份) [y/N]: ${NC}")" confirm_delete_data
        if [[ "$confirm_delete_data" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            rm -rf "$last_data_dir"
            echo -e "${GREEN}数据目录 $last_data_dir 已删除${NC}"
        else
            echo -e "${YELLOW}跳过数据目录删除。${NC}"
        fi
    else
        echo -e "${YELLOW}未找到数据目录 $last_data_dir，跳过删除${NC}"
    fi

    # 删除 V1 配置文件
    if [ -f "$V1_CONFIG_FILE" ]; then
        rm "$V1_CONFIG_FILE"
        echo -e "${GREEN}V1 版本配置文件 $V1_CONFIG_FILE 已删除${NC}"
    fi

    echo -e "${GREEN}V1 版本卸载完成${NC}"
}

# V1 - 查看容器状态
function v1_show_status() {
    echo -e "${BLUE}Nezha Dashboard ($V1_CONTAINER_NAME) 容器状态：${NC}"
    docker ps -a --filter "name=$V1_CONTAINER_NAME"
    echo -e "${BLUE}最新日志 (20 行)：${NC}"
    docker logs --tail 20 "$V1_CONTAINER_NAME" 2>/dev/null
}

# V1 - 保存 V1 配置到文件
function v1_save_env() {
    cat <<EOF >"$V1_CONFIG_FILE"
V1_WEB_PORT_INPUT="$V1_WEB_PORT_INPUT"
V1_AGENT_PORT_INPUT="$V1_AGENT_PORT_INPUT"
V1_TIMEZONE_INPUT="$V1_TIMEZONE_INPUT"
V1_DATA_DIR_INPUT="$V1_DATA_DIR_INPUT"
V1_NETWORK_CHOICE="$V1_NETWORK_CHOICE"
EOF
    echo -e "${GREEN}V1 配置已保存到 $V1_CONFIG_FILE${NC}"
}

# V1 - 读取 V1 配置从文件
function v1_read_env() {
    if [ -f "$V1_CONFIG_FILE" ]; then
        source "$V1_CONFIG_FILE"
        # 重新应用读取到的值，如果它们是空的，则应用默认值
        V1_WEB_PORT=${V1_WEB_PORT_INPUT:-$V1_DEFAULT_WEB_PORT}
        V1_AGENT_PORT=${V1_AGENT_PORT_INPUT:-$V1_DEFAULT_AGENT_PORT}
        V1_TIMEZONE=${V1_TIMEZONE_INPUT:-$V1_DEFAULT_TIMEZONE}
        V1_DATA_DIR=${V1_DATA_DIR_INPUT:-$V1_DEFAULT_DATA_DIR}
        V1_NETWORK_CHOICE_TEMP=${V1_NETWORK_CHOICE:-1} # 用于重新设置网络模式
        case $V1_NETWORK_CHOICE_TEMP in
            2) V1_NETWORK_MODE="--network host";;
            3) V1_NETWORK_MODE="--network macvlan";;
            *) V1_NETWORK_MODE="--network bridge";;
        esac
        echo -e "${GREEN}已加载 V1 版本配置。${NC}"
    else
        echo -e "${YELLOW}未找到 V1 版本配置，将使用默认值或提示输入。${NC}"
        # 如果配置文件不存在，确保变量被设置为空，以便 input 函数可以正常工作
        V1_WEB_PORT_INPUT=""
        V1_AGENT_PORT_INPUT=""
        V1_TIMEZONE_INPUT=""
        V1_DATA_DIR_INPUT=""
        V1_NETWORK_CHOICE=""
        V1_WEB_PORT=$V1_DEFAULT_WEB_PORT
        V1_AGENT_PORT=$V1_DEFAULT_AGENT_PORT
        V1_TIMEZONE=$V1_DEFAULT_TIMEZONE
        V1_DATA_DIR=$V1_DEFAULT_DATA_DIR
        V1_NETWORK_MODE="--network bridge" # 默认值
    fi
}

# V1 - 部署 Nezha Dashboard
function v1_deploy() {
    echo -e "${BLUE}开始部署 Nezha Dashboard (V1 版本)...${NC}"
    v1_read_env # 读取现有配置

    echo -e "${BLUE}>>> 当前 V1 配置预览：${NC}"
    echo -e "\tWeb 端口: ${V1_WEB_PORT}"
    echo -e "\tAgent 端口: ${V1_AGENT_PORT}"
    echo -e "\t数据目录: ${V1_DATA_DIR}"
    echo -e "\t时区: ${V1_TIMEZONE}"
    echo -e "\t网络模式: ${V1_NETWORK_MODE}"

    echo -e "\n是否重新输入环境变量？[y/N]"
    read -r CHOICE
    if [[ "$CHOICE" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        v1_get_user_input
        v1_setup_data_dir
        V1_WEB_PORT=$(v1_check_port "$V1_WEB_PORT" "Web")
        V1_AGENT_PORT=$(v1_check_port "$V1_AGENT_PORT" "Agent")
        v1_select_network_mode
        v1_save_env # 保存新输入或确认的配置
    fi

    v1_check_root
    v1_detect_os
    v1_detect_arch
    v1_check_disk_space $V1_MIN_DISK_SPACE
    v1_check_memory
    v1_check_dependencies
    v1_get_available_tags # 设置 V1_FULL_IMAGE_NAME
    v1_pull_image
    v1_start_container
}

# ====================================================================
# 主菜单逻辑
# ====================================================================

function main_menu() {
    while true; do
        echo -e "\n${BLUE}=== 哪吒探针多版本部署脚本 ===${NC}"
        echo -e "${GREEN}1) 安装/管理 Argo Nezha (V0 版本 - Cloudflare Tunnel 集成)${NC}"
        echo -e "${GREEN}2) 安装/管理 Nezha Dashboard (V1 版本 - 独立面板)${NC}"
        echo -e "${RED}3) 退出${NC}"
        read -rp "请选择一个操作 (1-3): " main_sel

        case "$main_sel" in
            1)
                echo -e "\n${BLUE}--- Argo Nezha (V0) 管理 ---${NC}"
                echo "1) 部署/重新部署 Argo Nezha"
                echo "2) 卸载 Argo Nezha"
                echo "3) 查看 Argo Nezha 运行状态"
                echo "4) 返回主菜单"
                read -rp "请选择 V0 版本操作: " v0_sel
                case "$v0_sel" in
                    1) v0_deploy ;;
                    2) v0_uninstall ;;
                    3) v0_show_status ;;
                    4) continue ;; # 返回主菜单
                    *) echo -e "${RED}无效选项，请重试。${NC}" ;;
                esac
                ;;
            2)
                echo -e "\n${BLUE}--- Nezha Dashboard (V1) 管理 ---${NC}"
                echo "1) 安装/重新安装 Nezha Dashboard"
                echo "2) 卸载 Nezha Dashboard"
                echo "3) 查看 Nezha Dashboard 运行状态"
                echo "4) 返回主菜单"
                read -rp "请选择 V1 版本操作: " v1_sel
                case "$v1_sel" in
                    1) v1_deploy ;;
                    2) v1_uninstall ;;
                    3) v1_show_status ;;
                    4) continue ;; # 返回主菜单
                    *) echo -e "${RED}无效选项，请重试。${NC}" ;;
                esac
                ;;
            3)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择。${NC}"
                ;;
        esac
        echo -e "\n-----------------------------"
    done
}

# 脚本启动
main_menu
