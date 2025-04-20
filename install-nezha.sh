#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 默认参数
IMAGE_NAME="nap0o/nezha"
DEFAULT_TAG="latest"
DEFAULT_WEB_PORT="80"
DEFAULT_AGENT_PORT="5555"
DEFAULT_DATA_DIR="/nezha/data"
DEFAULT_TIMEZONE="Asia/Shanghai"
CONTAINER_NAME="nezha"
MAX_LOG_SIZE="1m"
RETRY_COUNT=3
DEPENDENCY_CHECK_FILE="/tmp/nezha_dependency_check"

# 检查是否以root权限运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请以root权限运行此脚本（使用 sudo）${NC}"
        exit 1
    fi
}

# 检测系统类型
detect_os() {
    if [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        PKG_MANAGER="apt-get"
    elif [ -f /etc/redhat-release ]; then
        OS_TYPE="redhat"
        PKG_MANAGER="yum"
    elif [ "$(uname -s)" == "Darwin" ]; then
        OS_TYPE="macos"
        PKG_MANAGER="brew"
    else
        echo -e "${RED}不支持的操作系统${NC}"
        exit 1
    fi
    echo -e "${GREEN}检测到操作系统: $OS_TYPE${NC}"
}

# 检测设备架构
detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) ARCH_NAME="amd64";;
        armv7l|armhf) ARCH_NAME="armhf";;
        aarch64|arm64) ARCH_NAME="arm64";;
        *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1;;
    esac
    echo -e "${GREEN}检测到设备架构: $ARCH_NAME${NC}"
}

# 检查并安装依赖
check_dependencies() {
    if [ -f "$DEPENDENCY_CHECK_FILE" ]; then
        echo -e "${GREEN}依赖已检查过，跳过重复检测${NC}"
        return 0
    fi

    echo -e "${BLUE}检查依赖...${NC}"
    local deps_installed=0

    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Docker 未安装，正在安装...${NC}"
        case $OS_TYPE in
            debian)
                $PKG_MANAGER update && $PKG_MANAGER install -y docker.io
                systemctl start docker
                systemctl enable docker
                ;;
            redhat)
                $PKG_MANAGER install -y docker
                systemctl start docker
                systemctl enable docker
                ;;
            macos)
                if ! command -v brew &> /dev/null; then
                    echo -e "${YELLOW}Homebrew 未安装，正在安装...${NC}"
                    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                fi
                brew install docker
                ;;
        esac
        deps_installed=1
    fi

    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}curl 未安装，正在安装...${NC}"
        case $OS_TYPE in
            debian) $PKG_MANAGER install -y curl;;
            redhat) $PKG_MANAGER install -y curl;;
            macos) brew install curl;;
        esac
        deps_installed=1
    fi

    if ! command -v ss &> /dev/null; then
        echo -e "${YELLOW}ss 未安装，正在安装...${NC}"
        case $OS_TYPE in
            debian) $PKG_MANAGER install -y iproute2;;
            redhat) $PKG_MANAGER install -y iproute;;
            macos) echo -e "${YELLOW}macOS 不支持 ss，使用 netstat 替代${NC}";;
        esac
        deps_installed=1
    fi

    if [ $deps_installed -eq 0 ]; then
        echo -e "${GREEN}所有依赖已满足${NC}"
    fi
    touch "$DEPENDENCY_CHECK_FILE"
}

# 获取可用镜像版本
get_available_tags() {
    echo -e "${BLUE}正在从 Docker Hub 获取可用版本...${NC}"
    TAGS=$(curl -s "https://hub.docker.com/v2/repositories/nap0o/nezha/tags?page_size=100" | \
           grep -o '"name":"[^"]*"' | sed 's/"name":"\(.*\)"/\1/' | grep -v "latest" | sort -r)
    TAGS="latest $TAGS"
    if [ -z "$TAGS" ]; then
        echo -e "${RED}无法获取版本列表，使用默认版本 $DEFAULT_TAG${NC}"
        SELECTED_TAG="$DEFAULT_TAG"
    else
        echo -e "${BLUE}可用版本如下:${NC}"
        i=1
        for tag in $TAGS; do
            echo "$i) $tag"
            ((i++))
        done
        read -p "请选择版本号（直接回车使用默认值 $DEFAULT_TAG）: " TAG_CHOICE
        if [ -z "$TAG_CHOICE" ]; then
            SELECTED_TAG="$DEFAULT_TAG"
        else
            SELECTED_TAG=$(echo "$TAGS" | sed -n "${TAG_CHOICE}p")
            if [ -z "$SELECTED_TAG" ]; then
                echo -e "${YELLOW}无效选择，使用默认版本 $DEFAULT_TAG${NC}"
                SELECTED_TAG="$DEFAULT_TAG"
            fi
        fi
    fi
    echo -e "${GREEN}已选择版本: $SELECTED_TAG${NC}"
    IMAGE_NAME="$IMAGE_NAME:$SELECTED_TAG"
}

# 检查并设置数据目录
setup_data_dir() {
    echo -e "${BLUE}设置数据目录...${NC}"
    read -p "请输入数据目录路径（直接回车使用默认值 $DEFAULT_DATA_DIR）: " DATA_DIR
    DATA_DIR=${DATA_DIR:-$DEFAULT_DATA_DIR}
    mkdir -p "$DATA_DIR"
    chown -R 1000:1000 "$DATA_DIR" # 哪吒探针默认使用 UID/GID 1000
    echo -e "${GREEN}数据目录设置为: $DATA_DIR${NC}"
}

# 获取用户输入
get_user_input() {
    read -p "请输入 Web 端口（直接回车使用默认值 $DEFAULT_WEB_PORT）: " WEB_PORT
    WEB_PORT=${WEB_PORT:-$DEFAULT_WEB_PORT}
    read -p "请输入 Agent 端口（直接回车使用默认值 $DEFAULT_AGENT_PORT）: " AGENT_PORT
    AGENT_PORT=${AGENT_PORT:-$DEFAULT_AGENT_PORT}
    read -p "请输入时区（直接回车使用默认值 $DEFAULT_TIMEZONE）: " TIMEZONE
    TIMEZONE=${TIMEZONE:-$DEFAULT_TIMEZONE}
}

# 动态检测端口
check_port() {
    local port=$1
    local port_name=$2
    if [ "$OS_TYPE" == "macos" ]; then
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
    echo $port
}

# 选择网络模式
select_network_mode() {
    echo -e "${BLUE}请选择网络模式:${NC}"
    echo "1) bridge (默认)"
    echo "2) host"
    echo "3) macvlan"
    read -p "请输入选项 (1-3，直接回车使用默认值 1): " NETWORK_CHOICE
    case $NETWORK_CHOICE in
        2) NETWORK_MODE="--network host";;
        3) NETWORK_MODE="--network macvlan";;
        *) NETWORK_MODE="--network bridge";;
    esac
    echo -e "${GREEN}网络模式: $NETWORK_MODE${NC}"
}

# 拉取镜像并重试
pull_image() {
    echo -e "${BLUE}正在拉取镜像 $IMAGE_NAME...${NC}"
    for ((i=1; i<=RETRY_COUNT; i++)); do
        if docker pull "$IMAGE_NAME"; then
            echo -e "${GREEN}镜像拉取成功${NC}"
            return 0
        fi
        echo -e "${YELLOW}第 $i 次拉取失败，重试中...${NC}"
        sleep 2
    done
    echo -e "${RED}镜像拉取失败，请检查网络或镜像名称${NC}"
    exit 1
}

# 启动容器
start_container() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${YELLOW}检测到同名容器 $CONTAINER_NAME 已存在${NC}"
        read -p "是否删除并重新创建？(y/n): " REMOVE
        if [ "$REMOVE" == "y" ]; then
            docker rm -f "$CONTAINER_NAME"
        else
            echo -e "${RED}请手动删除容器或更改容器名称${NC}"
            exit 1
        fi
    fi

    docker run -d \
        --name "$CONTAINER_NAME" \
        $NETWORK_MODE \
        -v "$DATA_DIR:/dashboard/data" \
        -v /etc/timezone:/etc/timezone:ro \
        -v /etc/localtime:/etc/localtime:ro \
        -p "$WEB_PORT:18080" \
        -p "$AGENT_PORT:5555" \
        -e NEZHA_PORT="$WEB_PORT" \
        -e TZ="$TIMEZONE" \
        --restart unless-stopped \
        --log-opt max-size="$MAX_LOG_SIZE" \
        "$IMAGE_NAME"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}容器 $CONTAINER_NAME 启动成功！${NC}"
        echo -e "Web 访问地址: http://localhost:$WEB_PORT"
        echo -e "Agent 端口: $AGENT_PORT"
        echo -e "数据目录: $DATA_DIR"
        echo -e "时区: $TIMEZONE"
    else
        echo -e "${RED}容器启动失败，请检查配置${NC}"
        exit 1
    fi
}

# 查看容器状态
view_containers() {
    echo -e "${BLUE}当前所有容器状态:${NC}"
    docker ps -a
}

# 强化卸载功能
uninstall() {
    echo -e "${YELLOW}正在卸载 $CONTAINER_NAME...${NC}"

    # 停止并删除容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${BLUE}检测到容器 $CONTAINER_NAME${NC}"
        docker rm -f "$CONTAINER_NAME" 2>/dev/null
        echo -e "${GREEN}容器 $CONTAINER_NAME 已删除${NC}"
    else
        echo -e "${YELLOW}未找到容器 $CONTAINER_NAME，跳过删除${NC}"
    fi

    # 删除镜像
    if docker images -q "$IMAGE_NAME" | grep -q .; then
        read -p "是否删除镜像 $IMAGE_NAME？(y/n): " DELETE_IMAGE
        if [ "$DELETE_IMAGE" == "y" ]; then
            docker rmi "$IMAGE_NAME" 2>/dev/null
            echo -e "${GREEN}镜像 $IMAGE_NAME 已删除${NC}"
        else
            echo -e "${YELLOW}保留镜像 $IMAGE_NAME${NC}"
        fi
    else
        echo -e "${YELLOW}未找到镜像 $IMAGE_NAME，跳过删除${NC}"
    fi

    # 删除数据目录
    if [ -d "$DATA_DIR" ]; then
        read -p "是否删除数据目录 $DATA_DIR？(y/n): " DELETE_DATA
        if [ "$DELETE_DATA" == "y" ]; then
            rm -rf "$DATA_DIR"
            echo -e "${GREEN}数据目录 $DATA_DIR 已删除${NC}"
        else
            echo -e "${YELLOW}保留数据目录 $DATA_DIR${NC}"
        fi
    else
        echo -e "${YELLOW}未找到数据目录 $DATA_DIR，跳过删除${NC}"
    fi

    # 清理无用 Docker 资源
    read -p "是否清理无用的 Docker 网络和卷？(y/n): " CLEAN_DOCKER
    if [ "$CLEAN_DOCKER" == "y" ]; then
        docker network prune -f 2>/dev/null
        docker volume prune -f 2>/dev/null
        echo -e "${GREEN}无用的 Docker 网络和卷已清理${NC}"
    else
        echo -e "${YELLOW}跳过清理 Docker 网络和卷${NC}"
    fi

    # 删除依赖检查标记文件
    if [ -f "$DEPENDENCY_CHECK_FILE" ]; then
        rm -f "$DEPENDENCY_CHECK_FILE"
        echo -e "${GREEN}依赖检查标记文件已删除${NC}"
    fi

    echo -e "${GREEN}卸载完成${NC}"
}

# 主菜单
main_menu() {
    detect_os
    detect_arch
    while true; do
        echo -e "${BLUE}=== 哪吒探针部署脚本 ===${NC}"
        echo "1) 安装并启动哪吒探针"
        echo "2) 查看容器状态"
        echo "3) 卸载哪吒探针"
        echo "4) 退出"
        read -p "请选择操作 (1-4): " CHOICE
        case $CHOICE in
            1)
                check_root
                check_dependencies
                get_available_tags
                get_user_input
                setup_data_dir
                WEB_PORT=$(check_port "$WEB_PORT" "Web")
                AGENT_PORT=$(check_port "$AGENT_PORT" "Agent")
                select_network_mode
                pull_image
                start_container
                ;;
            2)
                view_containers
                ;;
            3)
                uninstall
                ;;
            4)
                echo -e "${GREEN}退出脚本${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重试${NC}"
                ;;
        esac
    done
}

# 执行主菜单
main_menu
