#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 默认参数
BASE_IMAGE_NAME="b3log/siyuan"
IMAGE_NAME="b3log/siyuan:latest"
DEFAULT_TAG="latest"
DEFAULT_PORT="6806"
DEFAULT_WORKSPACE="/siyuan/workspace"
DEFAULT_AUTH_CODE="12345678"
CONTAINER_NAME="siyuan"
MAX_LOG_SIZE="1m"
RETRY_COUNT=3
DEPENDENCY_CHECK_FILE="/tmp/siyuan_dependency_check"

# 检查是否以root权限运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请以root权限运行此脚本（使用 sudo）${NC}"
        exit 1
    fi
}

# OpenWrt 系统检测
detect_openwrt() {
    if [ -f /etc/openwrt_release ]; then
        OS_TYPE="openwrt"
        PKG_MANAGER="opkg"
        return 0
    else
        return 1
    fi
}

# 常规系统检测
detect_os() {
    if detect_openwrt; then
        return
    elif [ -f /etc/debian_version ]; then
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
}

# 修复 OpenWrt 防火墙规则
fix_openwrt_firewall() {
    if [ "$OS_TYPE" != "openwrt" ]; then
        return
    fi

    echo -e "${BLUE}正在修复 OpenWrt 防火墙配置...${NC}"
    
    local forward_status=$(uci -q get firewall.@defaults[0].forward)
    if [[ "$forward_status" != "ACCEPT" ]]; then
        uci set firewall.@defaults[0].forward='ACCEPT'
        uci commit firewall
    fi

    if ! uci -q get network.docker0 >/dev/null; then
        uci set network.docker0=interface
        uci set network.docker0.type='bridge'
        uci set network.docker0.proto='none'
        uci set network.docker0.firewall_zone='lan'
        uci commit network
    fi

    if ! iptables -t nat -C POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
    fi

    /etc/init.d/firewall restart 2>/dev/null || fw3 reload
    /etc/init.d/network reload
    echo -e "${GREEN}OpenWrt 网络配置已优化${NC}"
}

# 检查并安装依赖
check_dependencies() {
    if [ -f "$DEPENDENCY_CHECK_FILE" ]; then
        return 0
    fi

    echo -e "${BLUE}检查必要依赖...${NC}"
    local deps_installed=0

    if [ "$OS_TYPE" == "openwrt" ]; then
        opkg update >/dev/null 2>&1
        if ! command -v docker &> /dev/null; then
            echo -e "${YELLOW}安装 Docker for OpenWrt...${NC}"
            opkg install dockerd docker luci-app-dockerman
            /etc/init.d/dockerd enable
            /etc/init.d/dockerd start
            deps_installed=1
        fi
        if ! command -v curl &> /dev/null; then opkg install curl; deps_installed=1; fi
        if ! command -v jq &> /dev/null; then opkg install jq; deps_installed=1; fi
    else
        if ! command -v docker &> /dev/null; then
            echo -e "${YELLOW}Docker 未安装，正在安装...${NC}"
            case $OS_TYPE in
                debian)
                    $PKG_MANAGER update && $PKG_MANAGER install -y docker.io
                    systemctl start docker; systemctl enable docker ;;
                redhat)
                    $PKG_MANAGER install -y docker
                    systemctl start docker; systemctl enable docker ;;
                macos)
                    if ! command -v brew &> /dev/null; then
                        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                    fi
                    brew install docker ;;
            esac
            deps_installed=1
        fi

        if ! command -v curl &> /dev/null; then
            case $OS_TYPE in
                debian|redhat) $PKG_MANAGER install -y curl;;
                macos) brew install curl;;
            esac
            deps_installed=1
        fi
        
        if ! command -v jq &> /dev/null; then
            case $OS_TYPE in
                debian|redhat) $PKG_MANAGER install -y jq;;
                macos) brew install jq;;
            esac
            deps_installed=1
        fi
    fi

    touch "$DEPENDENCY_CHECK_FILE"
}

# 获取可用镜像版本并做老设备预警
get_available_tags() {
    echo -e "${BLUE}正在从 Docker Hub 获取可用版本...${NC}"
    TAGS=$(curl -s -m 10 "https://hub.docker.com/v2/repositories/b3log/siyuan/tags/?page_size=50" | \
           grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -v "latest" | sort -rV)
    TAGS="latest $TAGS"
    
    if [ -z "$TAGS" ] || [ "$TAGS" == "latest " ]; then
        echo -e "${RED}无法获取版本列表，使用默认版本 $DEFAULT_TAG${NC}"
        SELECTED_TAG="$DEFAULT_TAG"
    else
        echo -e "${BLUE}近期可用版本如下:${NC}"
        local i=1
        local tag_array=()
        for tag in $TAGS; do
            echo "$i) $tag"
            tag_array[$i]=$tag
            ((i++))
            [ $i -gt 15 ] && break
        done

        # 🤖 针对老 CPU 的智能预警
        if [[ "$ARCH_NAME" == *"arm"* ]] || [ "$OS_TYPE" == "openwrt" ]; then
            echo -e "\n${RED}================ [⚠️ 老设备兼容性警告] =================${NC}"
            echo -e "${YELLOW}检测到您正在使用 ARM 架构或软路由系统（如 N1、老电视盒子等）。${NC}"
            echo -e "${YELLOW}由于思源官方从 v3.1.0 开始引入了不支持老内核的底层组件，${NC}"
            echo -e "${GREEN}👉 强烈建议您使用最后一个稳定养老版: v3.0.17 ${NC}"
            echo -e "${RED}========================================================${NC}\n"
            echo -e "操作提示：您可以输入上方列表的编号，${YELLOW}也可以直接手打输入 v3.0.17 并回车。${NC}"
        fi

        read -p "请选择编号 或 直接手输版本号（回车默认 latest）: " TAG_CHOICE
        if [ -z "$TAG_CHOICE" ]; then
            SELECTED_TAG="$DEFAULT_TAG"
        elif [[ "$TAG_CHOICE" =~ ^[0-9]+$ ]] && [ -n "${tag_array[$TAG_CHOICE]}" ]; then
            SELECTED_TAG="${tag_array[$TAG_CHOICE]}"
        else
            # 允许用户直接手打输入 v3.0.17 等历史版本
            SELECTED_TAG="$TAG_CHOICE"
        fi
    fi
    echo -e "${GREEN}已确认目标版本: $SELECTED_TAG${NC}"
    IMAGE_NAME="$BASE_IMAGE_NAME:$SELECTED_TAG"
}

# 设置工作目录并暴力修复权限
setup_workspace() {
    echo -e "${BLUE}设置宿主机工作空间目录...${NC}"
    read -p "请输入宿主机数据存储路径（回车默认 $DEFAULT_WORKSPACE）: " WORKSPACE
    WORKSPACE=${WORKSPACE:-$DEFAULT_WORKSPACE}
    mkdir -p "$WORKSPACE"
    
    # 强制修改拥有者和权限，保障 1000 用户能绝对写入
    chown -R 1000:1000 "$WORKSPACE" 2>/dev/null || true
    chmod -R 777 "$WORKSPACE" 2>/dev/null || true
    echo -e "${GREEN}工作空间已就绪并赋权: $WORKSPACE${NC}"
}

get_user_input() {
    read -p "请输入访问授权码（直接回车使用默认值 $DEFAULT_AUTH_CODE）: " AUTH_CODE
    AUTH_CODE=${AUTH_CODE:-$DEFAULT_AUTH_CODE}
    
    read -p "请输入主机端口（直接回车使用默认值 $DEFAULT_PORT）: " HOST_PORT
    HOST_PORT=${HOST_PORT:-$DEFAULT_PORT}
}

check_port() {
    if [ "$OS_TYPE" == "openwrt" ]; then
        while netstat -tuln | grep -q ":$HOST_PORT "; do
            echo -e "${YELLOW}端口 $HOST_PORT 已被占用${NC}"
            read -p "请输入新的主机端口: " HOST_PORT
        done
    elif [ "$OS_TYPE" == "macos" ]; then
        while netstat -an | grep -q ":$HOST_PORT "; do
            echo -e "${YELLOW}端口 $HOST_PORT 已被占用${NC}"
            read -p "请输入新的主机端口: " HOST_PORT
        done
    else
        while ss -tuln | grep -q ":$HOST_PORT "; do
            echo -e "${YELLOW}端口 $HOST_PORT 已被占用${NC}"
            read -p "请输入新的主机端口: " HOST_PORT
        done
    fi
    echo -e "${GREEN}检测通过，将使用端口: $HOST_PORT${NC}"
}

select_network_mode() {
    echo -e "${BLUE}请选择网络模式:${NC}"
    echo "1) bridge (默认，最稳定)"
    echo "2) host (高性能，但 OpenWrt 可能端口冲突)"
    echo "3) macvlan (高级)"
    read -p "请输入选项 (1-3，直接回车使用默认值 1): " NETWORK_CHOICE
    
    case $NETWORK_CHOICE in
        2) 
            NETWORK_MODE="--network host"
            if [ "$OS_TYPE" == "openwrt" ]; then
                echo -e "${YELLOW}警告：Host 模式在 OpenWrt 上可能导致端口冲突${NC}"
            fi
            ;;
        3) 
            NETWORK_MODE="--network macvlan"
            echo -e "${YELLOW}注意：macvlan 需要手动配置网络${NC}"
            ;;
        *) 
            NETWORK_MODE="--network bridge"
            if [ "$OS_TYPE" == "openwrt" ]; then
                fix_openwrt_firewall
            fi
            ;;
    esac
}

pull_image() {
    echo -e "${BLUE}正在拉取镜像 $IMAGE_NAME...${NC}"
    for ((i=1; i<=RETRY_COUNT; i++)); do
        if docker pull "$IMAGE_NAME" >/dev/null 2>&1; then
            echo -e "${GREEN}镜像拉取成功${NC}"
            return 0
        fi
        echo -e "${YELLOW}第 $i 次拉取失败，重试中...${NC}"
        sleep 2
    done
    echo -e "${RED}镜像拉取失败，请检查网络或镜像名称${NC}"
    exit 1
}

# ================= 完美部署启动模块 =================
start_container() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${YELLOW}检测到同名容器 $CONTAINER_NAME 已存在${NC}"
        read -p "是否删除并重新创建？(y/n): " REMOVE
        if [[ "$REMOVE" =~ ^[Yy]$ ]]; then
            docker rm -f "$CONTAINER_NAME"
        else
            echo -e "${RED}请手动删除容器或更改容器名称${NC}"
            exit 1
        fi
    fi

    echo -e "${YELLOW}🤖 启用【底层护甲模式】: 特权提权 + 安全用户死锁...${NC}"

    CMD="docker run -d \
        --name \"$CONTAINER_NAME\" \
        $NETWORK_MODE \
        --privileged \
        --security-opt seccomp=unconfined \
        -v \"$WORKSPACE:$WORKSPACE\" \
        -p \"$HOST_PORT:6806\" \
        -e TZ=\"Asia/Shanghai\" \
        -e PUID=\"1000\" \
        -e PGID=\"1000\" \
        -e SIYUAN_ACCESS_AUTH_CODE=\"$AUTH_CODE\" \
        --restart unless-stopped \
        --log-opt max-size=\"$MAX_LOG_SIZE\" \
        \"$IMAGE_NAME\" \
        --workspace=\"$WORKSPACE\" \
        --accessAuthCode=\"$AUTH_CODE\""

    eval $CMD

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 容器 $CONTAINER_NAME 启动指令下发成功！${NC}"
        echo -e "${CYAN}访问地址: http://$(hostname -I | awk '{print $1}'):$HOST_PORT${NC}"
        echo -e "宿主机工作空间: $WORKSPACE"
        echo -e "登录授权码: $AUTH_CODE"
    else
        echo -e "${RED}❌ 容器启动失败，请运行 'docker logs $CONTAINER_NAME' 检查错误${NC}"
        exit 1
    fi
}

# ================= 一键无损更新模块 =================
upgrade_siyuan() {
    echo -e "\n${CYAN}--- 🔄 无损更新思源笔记容器 ---${NC}"
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}更新功能依赖 jq，请先安装 jq。${NC}"
        return 1
    fi
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${RED}未检测到名为 ${CONTAINER_NAME} 的容器，无法进行更新。请先安装部署！${NC}"
        return 1
    fi

    get_available_tags
    echo -e "\n${YELLOW}ℹ️ 您的旧容器所有配置（网络、端口、笔记挂载、密码）将被完美保留。${NC}"
    pull_image

    echo -e "${BLUE}📦 正在提取当前容器配置信息...${NC}"
    local c_info=$(docker inspect "$CONTAINER_NAME")

    local net_mode=$(echo "$c_info" | jq -r '.[0].HostConfig.NetworkMode')
    local restart_policy=$(echo "$c_info" | jq -r '.[0].HostConfig.RestartPolicy.Name')

    local -a run_args=("-d" "--name" "$CONTAINER_NAME" "--log-opt" "max-size=$MAX_LOG_SIZE")
    
    [[ -n "$restart_policy" && "$restart_policy" != "no" && "$restart_policy" != "null" ]] && run_args+=("--restart" "$restart_policy")
    [[ -n "$net_mode" && "$net_mode" != "default" && "$net_mode" != "null" ]] && run_args+=("--network" "$net_mode")

    run_args+=("--privileged" "--security-opt" "seccomp=unconfined")

    # 提取端口映射
    if [ "$net_mode" != "host" ]; then
        local -a ports
        mapfile -t ports < <(echo "$c_info" | jq -r 'if .[0].HostConfig.PortBindings then .[0].HostConfig.PortBindings | to_entries[] | "-p", "\(.value[0].HostPort):\(.key)" else empty end')
        (( ${#ports[@]} > 0 )) && run_args+=("${ports[@]}")
    fi

    # 提取卷挂载
    local -a mounts
    mapfile -t mounts < <(echo "$c_info" | jq -r '.[0].Mounts[]? | "-v", "\(.Source):\(.Destination)"')
    (( ${#mounts[@]} > 0 )) && run_args+=("${mounts[@]}")

    # 提取环境变量
    local -a envs
    mapfile -t envs < <(echo "$c_info" | jq -r '.[0].Config.Env[]? | select(test("^PATH=|^HOSTNAME=|^HOME=|PWD=") | not) | "-e", .')
    (( ${#envs[@]} > 0 )) && run_args+=("${envs[@]}")

    # 提取命令参数
    local -a cmd_args
    mapfile -t cmd_args < <(echo "$c_info" | jq -r 'if .[0].Config.Cmd then .[0].Config.Cmd[] else empty end')

    echo -e "${YELLOW}🗑️ 正在停止并删除旧容器...${NC}"
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1
    
    echo -e "${BLUE}🚀 正在使用新镜像重建容器...${NC}"
    docker run "${run_args[@]}" "$IMAGE_NAME" "${cmd_args[@]}" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 思源笔记已成功无损更新至 $SELECTED_TAG 并启动！${NC}"
    else
        echo -e "${RED}❌ 更新后容器启动失败，请使用菜单中的查看日志功能检查原因。${NC}"
    fi
}
# ==========================================================

# 容器启停与日志控制
control_container() {
    echo -e "\n${CYAN}--- ⚙️ 容器启停控制 ---${NC}"
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${RED}未检测到思源笔记容器，请先安装部署！${NC}"
        return
    fi
    echo "1) 启动容器"
    echo "2) 停止容器"
    echo "3) 重启容器"
    echo "4) 取消并返回"
    read -p "请输入选项 (1-4): " CTRL_CHOICE
    case $CTRL_CHOICE in
        1) docker start "$CONTAINER_NAME" >/dev/null && echo -e "${GREEN}✅ 容器已启动${NC}" ;;
        2) docker stop "$CONTAINER_NAME" >/dev/null && echo -e "${GREEN}✅ 容器已停止${NC}" ;;
        3) docker restart "$CONTAINER_NAME" >/dev/null && echo -e "${GREEN}✅ 容器已重启${NC}" ;;
        4) return ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
}

view_logs() {
    echo -e "\n${CYAN}--- 📜 容器运行日志 ---${NC}"
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${RED}未检测到思源笔记容器！${NC}"
        return
    fi
    echo -e "--------------------------------------------------------"
    docker logs "$CONTAINER_NAME" 2>&1 | head -n 50
    echo -e "--------------------------------------------------------"
    echo -e "${GREEN}顶部报错读取完毕。${NC}"
}

view_containers() {
    echo -e "\n${BLUE}当前思源容器状态:${NC}"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}" | grep "$CONTAINER_NAME" || echo -e "${YELLOW}未运行${NC}"
}

uninstall() {
    echo -e "${YELLOW}正在卸载 $CONTAINER_NAME...${NC}"

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker rm -f "$CONTAINER_NAME" 2>/dev/null
        echo -e "${GREEN}容器 $CONTAINER_NAME 已删除${NC}"
    fi

    read -p "是否删除镜像 ${BASE_IMAGE_NAME}？(y/N): " DELETE_IMAGE
    if [[ "$DELETE_IMAGE" =~ ^[Yy]$ ]]; then
        docker rmi $(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${BASE_IMAGE_NAME}") 2>/dev/null || true
        echo -e "${GREEN}相关镜像已删除${NC}"
    fi

    if [ -d "$DEFAULT_WORKSPACE" ]; then
        read -p "【高危】是否彻底删除宿主机的数据目录？这会丢失所有笔记！(y/N): " DELETE_DATA
        if [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
            local old_path=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].Mounts[0].Source')
            old_path=${old_path:-$DEFAULT_WORKSPACE}
            rm -rf "$old_path"
            echo -e "${GREEN}数据目录 $old_path 已清空${NC}"
        else
            echo -e "${YELLOW}保留工作空间数据${NC}"
        fi
    fi

    read -p "是否清理无用的 Docker 缓存？(y/N): " CLEAN_DOCKER
    if [[ "$CLEAN_DOCKER" =~ ^[Yy]$ ]]; then
        docker network prune -f 2>/dev/null
        docker volume prune -f 2>/dev/null
        echo -e "${GREEN}无用的 Docker 缓存已清理${NC}"
    fi
    echo -e "${GREEN}卸载完成${NC}"
}

main_menu() {
    detect_os
    detect_arch
    check_dependencies
    
    while true; do
        echo -e "\n${CYAN}=== 思源笔记部署管理脚本 (老设备兼容版) ===${NC}"
        echo -e "1) 安装并启动思源笔记"
        echo -e "2) 无损更新思源笔记容器 ${YELLOW}[保留笔记数据与配置]${NC}"
        echo -e "3) 启停控制 ${YELLOW}(启动/停止/重启)${NC}"
        echo -e "4) 查看容器顶部报错日志 ${YELLOW}(捉虫神器)${NC}"
        echo -e "5) 查看当前容器运行状态"
        echo -e "6) 卸载并清理思源笔记"
        echo -e "7) 修复 OpenWrt 网络 (仅限软路由)"
        echo -e "8) 退出"
        echo -e "${CYAN}===========================================${NC}"
        read -p "请选择操作 (1-8): " CHOICE
        
        case $CHOICE in
            1)
                check_root
                get_available_tags
                get_user_input
                setup_workspace
                check_port
                select_network_mode
                pull_image
                start_container
                ;;
            2) check_root; upgrade_siyuan ;;
            3) control_container ;;
            4) view_logs ;;
            5) view_containers ;;
            6) uninstall ;;
            7)
                if [ "$OS_TYPE" == "openwrt" ]; then fix_openwrt_firewall
                else echo -e "${RED}此功能仅适用于 OpenWrt 系统${NC}"; fi
                ;;
            8) echo -e "${GREEN}退出脚本，感谢使用！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选项，请重试${NC}" ;;
        esac
    done
}

main_menu
