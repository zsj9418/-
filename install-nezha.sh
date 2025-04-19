#!/bin/bash

# 用途: 一键部署 lsposed/nezha 项目到 Docker
# 依赖: curl, jq, fzf, Docker, Docker Compose, ss (或 net-tools)

# 项目相关常量
REPO="lsposed/nezha"
PROJECT_DIR="/root/nezha"
DATA_DIR="${PROJECT_DIR}/data"
DB_DIR="${PROJECT_DIR}/database"
LOG_DIR="${PROJECT_DIR}/logs"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
DEPENDENCY_CHECK_FILE="${PROJECT_DIR}/.dependency_checked"

# 默认环境变量
DEFAULT_TZ="Asia/Shanghai"
DEFAULT_NODE_ENV="production"
DEFAULT_NEZHA_PORT="8008"
DEFAULT_HOST_PORT="8008"

# 颜色输出函数
print_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
print_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
print_prompt() { echo -e "\033[1;33m[PROMPT]\033[0m $1"; }

# 检查架构
check_architecture() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        arm*) ARCH="arm" ;;
        *) print_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    print_info "检测到架构: $ARCH"
    export HOST_ARCH=$ARCH
}

# 检查和安装依赖
check_dependencies() {
    if [[ -f "$DEPENDENCY_CHECK_FILE" ]]; then
        print_info "依赖已检查，跳过安装"
        return
    fi
    print_info "检查必要依赖..."

    # 安装 jq
    if ! command -v jq &>/dev/null; then
        print_info "未找到 jq，正在安装..."
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            case $ID in
                ubuntu|debian)
                    sudo apt-get update
                    sudo apt-get install -y jq
                    ;;
                centos|rhel)
                    sudo yum install -y jq
                    ;;
                *)
                    print_error "不支持的系统: $ID，无法安装 jq"
                    exit 1
                    ;;
            esac
        else
            print_error "无法识别系统，无法安装 jq"
            exit 1
        fi
    fi

    # 安装 fzf
    if ! command -v fzf &>/dev/null; then
        print_info "未找到 fzf，正在安装..."
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            case $ID in
                ubuntu|debian)
                    sudo apt-get update
                    sudo apt-get install -y fzf
                    ;;
                centos|rhel)
                    sudo yum install -y fzf
                    ;;
                *)
                    print_error "不支持的系统: $ID，无法安装 fzf"
                    exit 1
                    ;;
            esac
        fi
    fi

    # 安装 Docker
    if ! command -v docker &>/dev/null; then
        print_info "未找到 Docker，正在安装..."
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            case $ID in
                ubuntu|debian)
                    sudo apt-get update
                    sudo apt-get install -y docker.io
                    ;;
                centos|rhel)
                    sudo yum install -y docker
                    ;;
                *)
                    print_error "不支持的系统: $ID"
                    exit 1
                    ;;
            esac
        else
            print_error "无法识别系统，无法安装 Docker"
            exit 1
        fi
        sudo systemctl enable docker
        sudo systemctl start docker
    fi

    # 安装 Docker Compose
    if ! command -v docker-compose &>/dev/null; then
        print_info "未找到 Docker Compose，正在安装..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi

    # 安装 ss（或 net-tools）
    if ! command -v ss &>/dev/null; then
        print_info "未找到 ss，正在安装 net-tools..."
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            case $ID in
                ubuntu|debian)
                    sudo apt-get update
                    sudo apt-get install -y net-tools
                    ;;
                centos|rhel)
                    sudo yum install -y net-tools
                    ;;
                *)
                    print_error "不支持的系统: $ID，无法安装 net-tools"
                    exit 1
                    ;;
            esac
        fi
    fi

    # 标记依赖已检查
    mkdir -p "$PROJECT_DIR"
    touch "$DEPENDENCY_CHECK_FILE"
    print_success "依赖检查和安装完成"
}

# 测试网络连接
check_network() {
    print_info "测试对 hub.docker.com 的网络连接..."
    if ! curl -s -I "https://hub.docker.com" >/dev/null; then
        print_error "无法连接到 hub.docker.com，请检查网络或代理设置"
        exit 1
    fi
    print_success "网络连接正常"
}

# 获取最新的 10 个镜像版本
get_image_versions() {
    print_info "正在获取最新的镜像版本..."
    # 尝试主 API
    RESPONSE=$(curl -s -w "%{http_code}" "https://hub.docker.com/v2/repositories/lsposed/nezha/tags?page_size=100" -o /tmp/nezha_tags.json)
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

    # 检查主 API 结果
    if [[ "$HTTP_CODE" -ne 200 ]]; then
        print_info "主 API 失败（HTTP 状态码: $HTTP_CODE），尝试备用 API..."
        RESPONSE=$(curl -s -w "%{http_code}" "https://registry.hub.docker.com/v2/lsposed/nezha/tags/list?page_size=100" -o /tmp/nezha_tags.json)
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    fi

    # 检查最终结果
    if [[ "$HTTP_CODE" -ne 200 ]]; then
        print_error "无法获取镜像版本列表，HTTP 状态码: $HTTP_CODE"
        if [[ "$HTTP_CODE" -eq 429 ]]; then
            print_error "触发了 Docker Hub 速率限制，将使用 latest 版本"
        elif [[ "$HTTP_CODE" -eq 403 ]]; then
            print_error "访问被拒绝，可能需要 Docker Hub 认证，将使用 latest 版本"
        fi
        echo "API 响应内容："
        cat /tmp/nezha_tags.json
        rm -f /tmp/nezha_tags.json
        return 1
    fi

    # 解析标签，排除非稳定版本
    VERSIONS=$(cat /tmp/nezha_tags.json | jq -r '.results[].name // .tags[]' 2>/dev/null | grep -vE 'dev|beta|test' | sort -V -r | head -n 10)
    rm -f /tmp/nezha_tags.json

    if [[ -z "$VERSIONS" ]]; then
        print_error "无法解析镜像版本列表，可能的原因："
        echo "  - 仓库没有可用标签"
        echo "  - API 返回了意外格式"
        return 1
    fi
    print_success "成功获取版本列表"
    return 0
}

# 使用 fzf 让用户选择版本
select_image_version() {
    if get_image_versions; then
        SELECTED_VERSION=$(echo "$VERSIONS" | fzf --prompt="请选择要安装的版本 (默认: latest): " --height=15)
        if [[ -z "$SELECTED_VERSION" ]]; then
            SELECTED_VERSION="latest"
            print_info "未选择版本，默认使用 latest"
        else
            print_info "已选择版本: $SELECTED_VERSION"
        fi
    else
        print_prompt "无法获取版本列表，使用默认版本 latest"
        SELECTED_VERSION="latest"
        print_info "使用版本: $SELECTED_VERSION"
    fi
    # 验证镜像架构
    print_info "验证镜像 ${REPO}:${SELECTED_VERSION} 的架构兼容性..."
    MANIFEST=$(docker manifest inspect "${REPO}:${SELECTED_VERSION}" 2>/dev/null)
    if [[ -n "$MANIFEST" ]]; then
        SUPPORTS_ARCH=$(echo "$MANIFEST" | jq -r ".manifests[] | select(.platform.architecture == \"$HOST_ARCH\")")
        if [[ -z "$SUPPORTS_ARCH" ]]; then
            print_error "镜像 ${REPO}:${SELECTED_VERSION} 不支持 $HOST_ARCH 架构，将使用 latest"
            SELECTED_VERSION="latest"
        fi
    fi
}

# 询问用户环境变量和端口映射
prompt_user_inputs() {
    print_prompt "请输入时区 (默认: $DEFAULT_TZ，留空回车使用默认值): "
    read -r USER_TZ
    TZ=${USER_TZ:-$DEFAULT_TZ}
    print_info "使用时区: $TZ"

    print_prompt "请输入 Node.js 环境 (默认: $DEFAULT_NODE_ENV，留空回车使用默认值): "
    read -r USER_NODE_ENV
    NODE_ENV=${USER_NODE_ENV:-$DEFAULT_NODE_ENV}
    print_info "使用 Node.js 环境: $NODE_ENV"

    print_prompt "请输入主机映射端口 (默认: $DEFAULT_HOST_PORT，留空回车使用默认值): "
    read -r USER_HOST_PORT
    HOST_PORT=${USER_HOST_PORT:-$DEFAULT_HOST_PORT}
    print_info "使用主机端口: $HOST_PORT (容器内端口固定为 $DEFAULT_NEZHA_PORT)"
}

# 生成 docker-compose.yml
generate_compose_file() {
    mkdir -p "$DATA_DIR" "$DB_DIR" "$LOG_DIR"
    chmod -R 777 "$DATA_DIR" "$DB_DIR" "$LOG_DIR"
    cat > "$COMPOSE_FILE" << EOF
services:
  nezha:
    image: ${REPO}:${SELECTED_VERSION}
    container_name: nezha
    ports:
      - "${HOST_PORT}:${DEFAULT_NEZHA_PORT}"
    volumes:
      - ${DATA_DIR}:/dashboard/data
      - ${DB_DIR}:/dashboard/database
      - ${LOG_DIR}:/dashboard/logs
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      - TZ=${TZ}
      - NODE_ENV=${NODE_ENV}
      - NEZHA_PORT=${DEFAULT_NEZHA_PORT}
    user: root
    restart: unless-stopped
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
EOF
    print_success "已生成 docker-compose.yml"
}

# 部署服务
deploy_service() {
    check_architecture
    check_dependencies
    check_network
    select_image_version
    prompt_user_inputs
    # 检查端口占用
    if command -v ss &>/dev/null; then
        if ss -tuln | grep -q ":${HOST_PORT}\b"; then
            print_error "主机端口 ${HOST_PORT} 已被占用，请选择其他端口或释放端口"
            exit 1
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tuln | grep -q ":${HOST_PORT}\b"; then
            print_error "主机端口 ${HOST_PORT} 已被占用，请选择其他端口或释放端口"
            exit 1
        fi
    else
        print_info "未找到 ss 或 netstat，跳过端口占用检查"
    fi
    generate_compose_file
    print_info "正在启动服务..."
    cd "$PROJECT_DIR" || { print_error "无法进入项目目录"; exit 1; }
    docker-compose up -d
    print_success "服务已部署，访问 http://<宿主机IP>:${HOST_PORT}"
    print_info "最终配置："
    echo "  镜像: ${REPO}:${SELECTED_VERSION}"
    echo "  时区: $TZ"
    echo "  Node.js 环境: $NODE_ENV"
    echo "  端口映射: ${HOST_PORT} -> ${DEFAULT_NEZHA_PORT}"
    print_info "服务状态："
    docker-compose ps
    print_info "容器日志（最近 10 行）："
    docker-compose logs --tail=10
    print_info "测试 UI 访问..."
    if curl -s -I "http://localhost:${HOST_PORT}" >/dev/null; then
        print_success "UI 访问测试成功"
    else
        print_error "UI 访问测试失败，请检查日志和网络配置"
    fi
    print_info "请确保防火墙或云服务器安全组已开放 ${HOST_PORT} 端口"
    # 检查防火墙状态
    if command -v ufw &>/dev/null; then
        print_info "检查 UFW 防火墙状态..."
        sudo ufw status
        print_info "若 ${HOST_PORT} 未开放，运行: sudo ufw allow ${HOST_PORT}"
    fi
}

# 查看服务状态
view_service() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        print_error "项目未部署"
        return
    fi
    cd "$PROJECT_DIR" || { print_error "无法进入项目目录"; exit 1; }
    print_info "服务状态:"
    docker-compose ps
    print_info "容器日志 (最近 10 行):"
    docker-compose logs --tail=10
}

# 停止服务
stop_service() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        print_error "项目未部署"
        return
    fi
    cd "$PROJECT_DIR" || { print_error "无法进入项目目录"; exit 1; }
    print_info "正在停止服务..."
    docker-compose down
    print_success "服务已停止"
}

# 清理和卸载
clean_service() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        print_error "项目未部署"
        return
    fi
    print_prompt "警告: 这将删除所有数据和配置，是否继续? (y/N): "
    read -r CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        print_info "操作取消"
        return
    fi
    cd "$PROJECT_DIR" || { print_error "无法进入项目目录"; exit 1; }
    print_info "正在清理和卸载..."
    docker-compose down -v
    rm -rf "$PROJECT_DIR"
    print_success "项目已卸载"
}

# 重新安装依赖
reinstall_dependencies() {
    print_info "正在重新安装依赖..."
    rm -f "$DEPENDENCY_CHECK_FILE"
    check_dependencies
    print_success "依赖重新安装完成"
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "\033[1;36m=== Nezha Dashboard 一键部署脚本 ===\033[0m"
        echo -e "\033[1;35m部署管理\033[0m"
        echo "  1) 安装或更新服务"
        echo "  2) 重新安装依赖"
        echo -e "\033[1;35m服务操作\033[0m"
        echo "  3) 查看服务状态"
        echo "  4) 停止服务"
        echo "  5) 清理和卸载"
        echo -e "\033[1;35m其他\033[0m"
        echo "  6) 退出"
        print_prompt "请输入选项 (1-6): "
        read -r CHOICE
        case $CHOICE in
            1) deploy_service ;;
            2) reinstall_dependencies ;;
            3) view_service ;;
            4) stop_service ;;
            5) clean_service ;;
            6) print_info "退出脚本"; exit 0 ;;
            *) print_error "无效选项，请选择 1-6" ;;
        esac
        print_prompt "按回车键返回菜单..."
        read
    done
}

# 执行主菜单
main_menu
