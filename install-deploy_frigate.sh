#!/bin/bash
# ================================================
# 开源 NVR 部署平台 v2.0 - 最终稳定版
# 支持: Frigate | Shinobi (自带DB) | go2rtc
# 架构: x86_64 / aarch64 / armv7l
# 系统: Ubuntu/Debian/CentOS/Fedora
# ================================================

SCRIPT_NAME="开源 NVR 部署平台"
SCRIPT_VERSION="2.0"
declare -A PROJECTS
PROJECTS=(
    ["frigate"]="Frigate AI智能NVR"
    ["shinobi"]="Shinobi 全功能NVR"
    ["go2rtc"]="go2rtc 流媒体网关"
)

# 默认路径
DEFAULT_FRIGATE_CONFIG_DIR="/opt/frigate"
DEFAULT_SHINOBI_CONFIG_DIR="/opt/shinobi"
DEFAULT_GO2RTC_CONFIG_FILE="/opt/go2rtc.yaml"
SCAN_LOG_DIR="/tmp"

# 全局变量
HOST_ARCH=""
HOST_IP=""

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; RESET='\033[0m'

# --- 辅助函数 ---
check_root() { [[ "$(id -u)" -eq 0 ]] || { echo -e "${RED}错误: 请以 root 权限运行。${RESET}"; exit 1; }; }
get_host_ip() { HOST_IP=$(hostname -I | awk '{print $1}'); }
get_host_arch() { HOST_ARCH=$(uname -m); echo -e "${CYAN}系统架构: ${HOST_ARCH}${RESET}"; }

detect_package_manager() {
    if grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt update -y && apt install -y"
    elif grep -qiE 'centos|rhel|fedora' /etc/os-release 2>/dev/null; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y"
    else
        echo -e "${RED}不支持的系统。${RESET}"; exit 1
    fi
}

check_dependency() {
    local dep=$1; local pkg=$2
    command -v "$dep" &>/dev/null && return
    read -p "${YELLOW}未检测到 $dep，是否自动安装？[Y/n]: ${RESET}" choice
    choice=${choice:-Y}
    [[ "$choice" =~ ^[Yy] ]] || { echo -e "${RED}取消安装，退出。${RESET}"; exit 1; }
    echo -e "${CYAN}安装 $dep...${RESET}"
    if eval "$INSTALL_CMD $pkg"; then
        echo -e "${GREEN}$dep 安装成功。${RESET}"
    else
        echo -e "${RED}$dep 安装失败。${RESET}"; exit 1
    fi
}

press_any_key() { read -n1 -s -r -p "按任意键继续..."; echo; }

get_installed_containers() {
    INSTALLED_CONTAINERS=()
    for name in "${!PROJECTS[@]}"; do
        docker ps -a --format '{{.Names}}' | grep -q "^${name}$" && INSTALLED_CONTAINERS+=("$name")
    done
}

show_logs_on_failure() {
    local container=$1
    echo -e "${RED}启动失败，显示日志：${RESET}"
    docker logs --tail 15 "$container" 2>/dev/null || echo "无日志。"
}

port_in_use() {
    local port=$1
    ss -tuln | grep -q ":$port " && return 0 || return 1
}

# --- 部署逻辑 ---
deploy_menu() {
    clear
    echo -e "${GREEN}NVR 部署中心${RESET}\n$(printf '─%.0s' {1..60})\n"
    echo -e "${CYAN}1. Frigate${RESET} - AI智能识别NVR"
    echo "   特点: Coral TPU加速，事件录像，Home Assistant集成"
    echo -e "${CYAN}2. Shinobi${RESET} - 功能全面传统NVR"
    echo "   特点: 7x24录像，时间线，多用户，邮件警报"
    echo -e "${CYAN}3. go2rtc${RESET} - 轻量流媒体网关"
    echo "   特点: WebRTC/RTSP/HLS，极低延迟，无录像"
    echo "4. 返回主菜单"
    echo "$(printf '─%.0s' {1..60})"
    read -p "请选择 [1-4]: " choice
    case $choice in 1) deploy_frigate ;; 2) deploy_shinobi ;; 3) deploy_go2rtc ;; 4) return ;; *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;; esac
}

deploy_frigate() {
    clear; echo -e "${GREEN}部署 Frigate AI NVR${RESET}"
    local name="frigate"
    docker ps -a --format '{{.Names}}' | grep -q "^${name}$" && { echo -e "${RED}容器已存在${RESET}"; press_any_key; return; }

    [[ $(port_in_use 5000) == 0 ]] && { echo -e "${YELLOW}警告: 5000端口被占用${RESET}"; }

    local image="ghcr.io/blakeblackshear/frigate:stable"
    echo -e "${CYAN}镜像: ${YELLOW}$image (multi-arch)${RESET}"

    read -p "存储目录 [默认: $DEFAULT_FRIGATE_CONFIG_DIR]: " path
    path=${path:-$DEFAULT_FRIGATE_CONFIG_DIR}
    mkdir -p "$path/config" "$path/media"

    echo -e "${CYAN}配置摄像头 (支持多个，空行结束)${RESET}"
    declare -a CAMS
    while :; do
        read -p "IP (空行结束): " ip; [[ -z "$ip" ]] && break
        read -p "用户名 [admin]: " user; user=${user:-admin}
        read -s -p "密码: " pass; echo
        read -p "RTSP端口 [554]: " port; port=${port:-554}
        echo "路径模板: 1)通用 2)海康 3)大华 4)ONVIF 5)手动"
        read -p "选择[1-5]: " t
        case $t in 1) p="/stream1";; 2) p="/ch1/main/av_stream";; 3) p="/cam/realmonitor?channel=1&subtype=0";; 4) p="/onvif1";; 5) read -p "路径: " p;; *) p="/stream1";; esac
        url=$( [[ -n "$pass" ]] && echo "rtsp://$user:$pass@$ip:$port$p" || echo "rtsp://$user@$ip:$port$p" )
        CAMS+=("${ip//./_}:$url")
    done
    [[ ${#CAMS[@]} -eq 0 ]] && { echo -e "${RED}至少一个摄像头${RESET}"; press_any_key; return; }

    COMPOSE="$path/docker-compose.yml"
    cat > "$COMPOSE" << EOF
version: "3.9"
services:
  frigate:
    container_name: frigate
    privileged: true
    restart: unless-stopped
    image: $image
    shm_size: 128mb
    devices:
      - /dev/dri:/dev/dri
    volumes:
      - $path/config:/config
      - $path/media:/media/frigate
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
EOF

    cat > "$path/config/config.yml" << 'EOF'
mqtt: {enabled: false}
detectors:
  coral:
    type: edgetpu
    device: usb
cameras:
EOF
    for cam in "${CAMS[@]}"; do
        IFS=':' read -r name url <<< "$cam"
        cat >> "$path/config/config.yml" << EOF
  cam_$name:
    ffmpeg:
      inputs:
        - path: $url
          roles:
            - detect
            - record
    detect:
      width: 1280
      height: 720
      fps: 5
    record:
      enabled: true
      retain:
        days: 7
        mode: motion
EOF
    done

    docker-compose -f "$COMPOSE" up -d && {
        get_host_ip
        echo -e "\n${GREEN}Frigate 部署成功！${RESET}"
        echo -e "Web UI: ${GREEN}http://$HOST_IP:5000${RESET}"
    } || { echo -e "${RED}失败${RESET}"; show_logs_on_failure "$name"; }
    press_any_key
}

deploy_shinobi() {
    clear; echo -e "${GREEN}部署 Shinobi (自带数据库)${RESET}"
    local name="shinobi"
    docker ps -a --format '{{.Names}}' | grep -q "^${name}$" && { echo -e "${RED}容器已存在${RESET}"; press_any_key; return; }

    [[ $(port_in_use 8080) == 0 ]] && { echo -e "${YELLOW}警告: 8080端口被占用${RESET}"; }

    local image="registry.gitlab.com/shinobi-systems/shinobi:dev"
    echo -e "${CYAN}镜像: ${YELLOW}$image (自带 MariaDB)${RESET}"

    read -p "存储目录 [默认: $DEFAULT_SHINOBI_CONFIG_DIR]: " path
    path=${path:-$DEFAULT_SHINOBI_CONFIG_DIR}
    mkdir -p "$path/videos" "$path/config"
    chmod -R 777 "$path"

    # 随机密码
    ADMIN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    docker run -d --name "$name" --restart=always \
        -p 8080:8080 \
        -v "$path/videos":/home/Shinobi/videos \
        -v "$path/config":/config \
        -e ADMIN_USER=admin@shinobi.video \
        -e ADMIN_PASSWORD="$ADMIN_PASS" \
        "$image"

    if [ $? -eq 0 ]; then
        echo -e "${CYAN}初始化中... (约30秒)${RESET}"; sleep 30
        get_host_ip
        echo -e "\n${GREEN}Shinobi 部署成功！${RESET}"
        echo -e "超级登录: ${GREEN}http://$HOST_IP:8080/super${RESET}"
        echo -e "用户: ${YELLOW}admin@shinobi.video${RESET}"
        echo -e "密码: ${YELLOW}$ADMIN_PASS${RESET}"
        echo -e "${RED}请立即修改密码！${RESET}"
    else
        echo -e "${RED}失败${RESET}"; show_logs_on_failure "$name"
    fi
    press_any_key
}

deploy_go2rtc() {
    clear; echo -e "${GREEN}部署 go2rtc 流媒体网关${RESET}"
    local name="go2rtc"
    docker ps -a --format '{{.Names}}' | grep -q "^${name}$" && { echo -e "${RED}容器已存在${RESET}"; press_any_key; return; }

    local image="alexxit/go2rtc:latest"
    echo -e "${CYAN}镜像: ${YELLOW}$image (multi-arch)${RESET}"

    read -p "配置文件路径 [默认: $DEFAULT_GO2RTC_CONFIG_FILE]: " cfg
    cfg=${cfg:-$DEFAULT_GO2RTC_CONFIG_FILE}
    mkdir -p "$(dirname "$cfg")"

    if [ ! -f "$cfg" ]; then
        cat > "$cfg" << 'EOF'
api:
  port: 1984
streams:
  cam1:
    - rtsp://user:pass@192.168.1.100:554/stream1
  cam2:
    - rtsp://user:pass@192.168.1.101:554/stream1
webrtc:
  candidates:
    - host:1984
EOF
        echo -e "${GREEN}示例配置文件已创建: $cfg${RESET}"
    fi

    docker run -d --name "$name" --restart=always \
        -p 1984:1984 -p 8555:8555/udp \
        -v "$cfg":/config.yaml \
        "$image"

    if [ $? -eq 0 ]; then
        get_host_ip
        echo -e "\n${GREEN}go2rtc 部署成功！${RESET}"
        echo -e "Web UI: ${GREEN}http://$HOST_IP:1984${RESET}"
    else
        echo -e "${RED}失败${RESET}"; show_logs_on_failure "$name"
    fi
    press_any_key
}

# --- 扫描修复 ---
scan_network() {
    clear
    echo -e "${BLUE}扫描局域网摄像头${RESET}\n$(printf '─%.0s' {1..40})"
    DEFAULT_SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -1)
    read -p "网段 [默认: $DEFAULT_SUBNET]: " subnet
    subnet=${subnet:-$DEFAULT_SUBNET}

    if ! [[ $subnet =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]{1,2}$ ]]; then
        echo -e "${RED}网段格式错误${RESET}"; press_any_key; return
    fi

    echo -e "${CYAN}扫描 $subnet ...${RESET}"
    RAW=$(nmap -p 80,554,8000,37777,5544,8099 --open "$subnet" -oG -)
    RESULTS=$(echo "$RAW" | grep -E 'Host:.*Ports:' | \
        sed -E 's/.*Host: ([0-9.]+) \([^)]*\) *Ports: (.*)/\1 \2/' | \
        grep -oE '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ([0-9]+)' | sort -u)

    LOG="/tmp/nvr_scan_$(date +%Y%m%d_%H%M%S).txt"
    if [ -z "$RESULTS" ]; then
        echo -e "${RED}未发现设备${RESET}"
        echo "无结果" > "$LOG"
    else
        echo -e "${GREEN}发现设备：${RESET}"
        echo "IP              端口"
        echo "---------------------"
        echo "$RESULTS" | while read -r ip port; do
            [[ "$port" == "554" || "$port" == "5544" ]] && \
                printf "%-15s ${GREEN}%s (RTSP)${RESET}\n" "$ip" "$port" || \
                printf "%-15s ${YELLOW}%s${RESET}\n" "$ip" "$port"
        done
        echo "---------------------"
        echo -e "RTSP 端口: ${GREEN}554 / 5544${RESET}"
        echo "$RESULTS" > "$LOG"
        echo -e "${CYAN}日志: $LOG${RESET}"
    fi
    press_any_key
}

# --- 管理功能 ---
uninstall_menu() {
    clear; echo -e "${YELLOW}卸载服务${RESET}\n$(printf '─%.0s' {1..30})"
    get_installed_containers
    [[ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]] && { echo -e "${YELLOW}无服务${RESET}"; press_any_key; return; }
    for i in "${!INSTALLED_CONTAINERS[@]}"; do echo "$((i+1)). ${PROJECTS[${INSTALLED_CONTAINERS[i]}]}"; done
    echo "$(( ${#INSTALLED_CONTAINERS[@]} + 1 )). 返回"
    read -p "选择: " c
    [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -le "${#INSTALLED_CONTAINERS[@]}" ] || { press_any_key; return; }
    name=${INSTALLED_CONTAINERS[$((c-1))]}
    read -p "${RED}卸载 $name？[y/N]: ${RESET}" confirm
    [[ "$confirm" =~ ^[Yy] ]] || return
    docker stop "$name" &>/dev/null; docker rm "$name" &>/dev/null
    echo -e "${GREEN}容器已移除${RESET}"
    read -p "删除数据？[y/N]: " del
    [[ "$del" =~ ^[Yy] ]] && {
        case $name in
            frigate) rm -rf "$DEFAULT_FRIGATE_CONFIG_DIR" ;;
            shinobi) rm -rf "$DEFAULT_SHINOBI_CONFIG_DIR" ;;
            go2rtc) rm -f "$DEFAULT_GO2RTC_CONFIG_FILE" ;;
        esac
        echo -e "${GREEN}数据已删除${RESET}"
    }
    press_any_key
}

status_menu() {
    clear; echo -e "${BLUE}运行状态${RESET}\n$(printf '─%.0s' {1..40})"
    get_installed_containers
    [[ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]] && { echo -e "${YELLOW}无服务${RESET}"; press_any_key; return; }
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | \
        { read -r h; echo -e "${YELLOW}$h${RESET}"; grep -E "$(IFS="|"; echo "${INSTALLED_CONTAINERS[*]}")"; }
    press_any_key
}

manage_menu() {
    clear; echo -e "${CYAN}管理服务${RESET}\n$(printf '─%.0s' {1..30})"
    get_installed_containers
    [[ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]] && { echo -e "${YELLOW}无服务${RESET}"; press_any_key; return; }
    for i in "${!INSTALLED_CONTAINERS[@]}"; do echo "$((i+1)). ${PROJECTS[${INSTALLED_CONTAINERS[i]}]}"; done
    echo "$(( ${#INSTALLED_CONTAINERS[@]} + 1 )). 返回"
    read -p "选择: " c
    [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -le "${#INSTALLED_CONTAINERS[@]}" ] || { press_any_key; return; }
    name=${INSTALLED_CONTAINERS[$((c-1))]}
    echo "1.启动 2.停止 3.重启 4.日志"
    read -p "操作: " op
    case $op in
        1) docker start "$name" ;;
        2) docker stop "$name" ;;
        3) docker restart "$name" ;;
        4) docker logs -f "$name" ;;
    esac
    press_any_key
}

# --- 主菜单 ---
main_menu() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${RESET}"
    echo -e "  ${GREEN}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}"
    echo -e "  ${CYAN}Arch: $HOST_ARCH${RESET}"
    echo -e "${BLUE}╠══════════════════════════════════════╣${RESET}"
    echo -e "  1. ${GREEN}部署 NVR 服务${RESET}"
    echo -e "  2. ${CYAN}扫描局域网摄像头${RESET}"
    echo -e "  3. ${RED}卸载服务${RESET}"
    echo -e "  4. ${BLUE}查看状态${RESET}"
    echo -e "  5. ${YELLOW}管理服务${RESET}"
    echo -e "  6. ${RED}退出${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${RESET}"
}

main() {
    check_root
    detect_package_manager
    check_dependency "docker" "docker.io"
    check_dependency "docker-compose" "docker-compose"
    check_dependency "nmap" "nmap"
    get_host_arch

    while :; do
        main_menu
        read -p "选择 [1-6]: " choice
        case $choice in
            1) deploy_menu ;;
            2) scan_network ;;
            3) uninstall_menu ;;
            4) status_menu ;;
            5) manage_menu ;;
            6) echo -e "${GREEN}再见！${RESET}"; exit 0 ;;
            *) echo -e "${RED}无效${RESET}"; sleep 1 ;;
        esac
    done
}

main
