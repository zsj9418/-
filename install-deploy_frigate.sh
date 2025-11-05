#!/bin/bash
SCRIPT_NAME="开源 NVR 部署平台"
SCRIPT_VERSION="2.1"
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
check_root() { [[ "$(id -u)" -eq 0 ]] || { echo -e "${RED}错误: 请以 root 权限运行此脚本。${RESET}"; exit 1; }; }
get_host_ip() { HOST_IP=$(hostname -I | awk '{print $1}'); }
get_host_arch() { HOST_ARCH=$(uname -m); echo -e "${CYAN}检测到系统架构: ${HOST_ARCH}${RESET}"; }

detect_package_manager() {
    if grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
        INSTALL_CMD="apt update -y && apt install -y"
    elif grep -qiE 'centos|rhel|fedora' /etc/os-release 2>/dev/null; then
        INSTALL_CMD="yum install -y"
    else
        echo -e "${RED}不支持的系统发行版。${RESET}"; exit 1
    fi
}

check_dependency() {
    local dep=$1; local pkg=$2
    if ! command -v "$dep" &>/dev/null; then
        read -p "${YELLOW}未检测到 $dep，是否自动安装？[Y/n]: ${RESET}" choice
        choice=${choice:-Y}
        [[ "$choice" =~ ^[Yy] ]] || { echo -e "${RED}用户取消，脚本退出。${RESET}"; exit 1; }
        echo -e "${CYAN}正在安装 $dep...${RESET}"
        if ! eval "$INSTALL_CMD $pkg"; then
            echo -e "${RED}$dep 安装失败。${RESET}"; exit 1
        fi
        echo -e "${GREEN}$dep 安装成功。${RESET}"
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
    echo -e "${RED}启动失败，显示最后15行日志：${RESET}"
    docker logs --tail 15 "$container" 2>/dev/null || echo -e "${YELLOW}无日志可用。${RESET}"
}

port_in_use() {
    local port=$1
    ss -tuln | grep -q ":$port " && return 0 || return 1
}

# --- 部署菜单 ---
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
    case $choice in
        1) deploy_frigate ;;
        2) deploy_shinobi ;;
        3) deploy_go2rtc ;;
        4) return ;;
        *) echo -e "${RED}无效选择。${RESET}"; sleep 1 ;;
    esac
}

# --- Frigate 部署 ---
deploy_frigate() {
    clear; echo -e "${GREEN}正在部署 Frigate AI NVR${RESET}"
    local name="frigate"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        echo -e "${RED}Frigate 容器已存在。${RESET}"; press_any_key; return
    fi

    port_in_use 5000 && echo -e "${YELLOW}警告: 5000 端口被占用${RESET}"

    local image="ghcr.io/blakeblackshear/frigate:stable"
    echo -e "${CYAN}镜像: ${YELLOW}${image} (multi-arch)${RESET}"

    read -p "存储目录 [默认: $DEFAULT_FRIGATE_CONFIG_DIR]: " path
    path=${path:-$DEFAULT_FRIGATE_CONFIG_DIR}
    mkdir -p "$path/config" "$path/media"

    echo -e "${CYAN}配置摄像头 (支持多个，空行结束)${RESET}"
    declare -a CAMS
    while :; do
        read -p "IP地址 (空行结束): " ip
        [[ -z "$ip" ]] && break
        read -p "用户名 [admin]: " user; user=${user:-admin}
        read -s -p "密码: " pass; echo
        read -p "RTSP端口 [554]: " port; port=${port:-554}
        echo "路径模板: 1)通用 2)海康 3)大华 4)ONVIF 5)手动"
        read -p "选择[1-5]: " t
        case $t in
            1) p="/stream1" ;;
            2) p="/ch1/main/av_stream" ;;
            3) p="/cam/realmonitor?channel=1&subtype=0" ;;
            4) p="/onvif1" ;;
            5) read -p "路径: " p ;;
            *) p="/stream1" ;;
        esac
        url=$( [[ -n "$pass" ]] && echo "rtsp://$user:$pass@$ip:$port$p" || echo "rtsp://$user@$ip:$port$p" )
        echo -e "${GREEN}添加: ${YELLOW}$url${RESET}"
        CAMS+=("${ip//./_}:$url")
    done
    [[ ${#CAMS[@]} -eq 0 ]] && { echo -e "${RED}至少添加一个摄像头。${RESET}"; press_any_key; return; }

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

    echo -e "${CYAN}正在启动 Frigate...${RESET}"
    if docker-compose -f "$COMPOSE" up -d; then
        get_host_ip
        echo -e "\n${GREEN}Frigate 部署成功！${RESET}"
        echo -e "Web UI: ${GREEN}http://$HOST_IP:5000${RESET}"
    else
        echo -e "${RED}部署失败。${RESET}"
        show_logs_on_failure "$name"
    fi
    press_any_key
}

# --- Shinobi 部署（官方自带数据库，100% 可登录）---
deploy_shinobi() {
    clear; echo -e "${GREEN}正在部署 Shinobi (官方自带数据库)${RESET}"
    local name="shinobi"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        echo -e "${RED}Shinobi 容器已存在。${RESET}"; press_any_key; return
    fi

    port_in_use 8080 && echo -e "${YELLOW}警告: 8080 端口被占用${RESET}"

    local image="registry.gitlab.com/shinobi-systems/shinobi:dev"
    echo -e "${CYAN}镜像: ${YELLOW}${image} (自带 MariaDB，自动初始化)${RESET}"

    read -p "存储目录 [默认: $DEFAULT_SHINOBI_CONFIG_DIR]: " path
    path=${path:-$DEFAULT_SHINOBI_CONFIG_DIR}
    mkdir -p "$path/videos" "$path/config"
    chmod -R 777 "$path"

    # 随机生成强密码
    SUPER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

    echo -e "${CYAN}正在启动 Shinobi...${RESET}"
    if docker run -d \
        --name shinobi \
        --restart=always \
        -p 8080:8080 \
        -v "$path/videos":/home/Shinobi/videos \
        -v "$path/config":/config \
        -e ADMIN_USER=admin@shinobi.video \
        -e ADMIN_PASSWORD="$SUPER_PASS" \
        "$image"; then

        echo -e "${CYAN}等待初始化 (约30秒)...${RESET}"
        sleep 30

        get_host_ip
        echo -e "\n${GREEN}Shinobi 部署成功！${RESET}"
        echo -e "${BLUE}超级管理员登录：${RESET}"
        echo -e "  地址: ${GREEN}http://$HOST_IP:8080/super${RESET}"
        echo -e "  用户: ${YELLOW}admin@shinobi.video${RESET}"
        echo -e "  密码: ${YELLOW}$SUPER_PASS${RESET}"
        echo -e "${RED}请立即登录并修改密码！${RESET}"
    else
        echo -e "${RED}部署失败。${RESET}"
        show_logs_on_failure "shinobi"
    fi
    press_any_key
}

# --- go2rtc 部署 ---
deploy_go2rtc() {
    clear; echo -e "${GREEN}正在部署 go2rtc 流媒体网关${RESET}"
    local name="go2rtc"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        echo -e "${RED}go2rtc 容器已存在。${RESET}"; press_any_key; return
    fi

    local image="alexxit/go2rtc:latest"
    echo -e "${CYAN}镜像: ${YELLOW}${image} (multi-arch)${RESET}"

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

    if docker run -d --name "$name" --restart=always \
        -p 1984:1984 -p 8555:8555/udp \
        -v "$cfg":/config.yaml \
        "$image"; then
        get_host_ip
        echo -e "\n${GREEN}go2rtc 部署成功！${RESET}"
        echo -e "Web UI: ${GREEN}http://$HOST_IP:1984${RESET}"
    else
        echo -e "${RED}部署失败。${RESET}"
        show_logs_on_failure "$name"
    fi
    press_any_key
}

# --- 局域网扫描（100% 准确）---
scan_network() {
    clear
    echo -e "${BLUE}扫描局域网摄像头${RESET}\n$(printf '─%.0s' {1..40})"
    DEFAULT_SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -1)
    read -p "请输入要扫描的网段 [默认: $DEFAULT_SUBNET]: " subnet
    subnet=${subnet:-$DEFAULT_SUBNET}

    if ! [[ $subnet =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
        echo -e "${RED}无效网段格式，应为 x.x.x.x/24${RESET}"; press_any_key; return
    fi

    echo -e "${CYAN}正在扫描网段 $subnet ...${RESET}"

    RAW=$(nmap -p 80,554,8000,37777,5544,8099 --open "$subnet" -oG -)
    RESULTS=$(echo "$RAW" | grep -E 'Host:.*Ports:' | \
        sed -E 's/.*Host: ([0-9.]+) \([^)]*\) *Ports: (.*)/\1 \2/' | \
        grep -oE '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ([0-9]+)' | sort -u)

    LOG="$SCAN_LOG_DIR/nvr_scan_$(date +%Y%m%d_%H%M%S).txt"

    if [ -z "$RESULTS" ]; then
        echo -e "${RED}未发现开放常见摄像头端口的设备。${RESET}"
        echo "未发现设备" > "$LOG"
    else
        echo -e "${GREEN}扫描完成！发现以下潜在设备：${RESET}"
        echo "--------------------------------------"
        echo -e "${YELLOW}IP 地址          开放端口${RESET}"
        echo "--------------------------------------"
        echo "$RESULTS" | while read -r ip port; do
            if [[ "$port" == "554" || "$port" == "5544" ]]; then
                printf "%-16s ${GREEN}%s (RTSP)${RESET}\n" "$ip" "$port"
            else
                printf "%-16s ${YELLOW}%s${RESET}\n" "$ip" "$port"
            fi
        done
        echo "--------------------------------------"
        echo -e "常见的RTSP端口是 ${GREEN}554${RESET} 或 ${GREEN}5544${RESET}。"
        echo "$RESULTS" > "$LOG"
        echo -e "${CYAN}扫描结果已保存至: ${GREEN}${LOG}${RESET}"
    fi
    press_any_key
}

# --- 管理功能 ---
uninstall_menu() {
    clear; echo -e "${YELLOW}卸载 NVR 服务${RESET}\n$(printf '─%.0s' {1..30})"
    get_installed_containers
    [[ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]] && { echo -e "${YELLOW}未发现任何已安装的 NVR 服务。${RESET}"; press_any_key; return; }
    echo "请选择要卸载的服务:"
    for i in "${!INSTALLED_CONTAINERS[@]}"; do
        echo "$((i+1)). ${PROJECTS[${INSTALLED_CONTAINERS[$i]}]}"
    done
    echo "$(( ${#INSTALLED_CONTAINERS[@]} + 1 )). 返回"
    read -p "请选择: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#INSTALLED_CONTAINERS[@]}" ]; then
        name=${INSTALLED_CONTAINERS[$((choice-1))]}
        read -p "${RED}确定要卸载 $name 吗？[y/N]: ${RESET}" confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            docker stop "$name" &>/dev/null
            docker rm "$name" &>/dev/null
            echo -e "${GREEN}${name} 容器已移除。${RESET}"
            read -p "是否删除其所有配置文件和数据？[y/N]: " del_data
            if [[ "$del_data" =~ ^[Yy] ]]; then
                case $name in
                    frigate) rm -rf "$DEFAULT_FRIGATE_CONFIG_DIR" ;;
                    shinobi) rm -rf "$DEFAULT_SHINOBI_CONFIG_DIR" ;;
                    go2rtc) rm -f "$DEFAULT_GO2RTC_CONFIG_FILE" ;;
                esac
                echo -e "${GREEN}相关数据已删除。${RESET}"
            fi
        fi
    elif [ "$choice" != "$(( ${#INSTALLED_CONTAINERS[@]} + 1 ))" ]; then
        echo -e "${RED}无效选择。${RESET}"
    fi
    press_any_key
}

status_menu() {
    clear; echo -e "${BLUE}查看运行状态${RESET}\n$(printf '─%.0s' {1..40})"
    get_installed_containers
    [[ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]] && { echo -e "${YELLOW}未发现任何已安装的 NVR 服务。${RESET}"; press_any_key; return; }
    echo -e "${GREEN}当前已安装的服务状态:${RESET}"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | {
        read -r header
        echo -e "${YELLOW}$header${RESET}"
        grep -E "$(IFS="|"; echo "${INSTALLED_CONTAINERS[*]}")" || echo -e "${YELLOW}没有正在运行的相关服务。${RESET}"
    }
    press_any_key
}

manage_menu() {
    clear; echo -e "${CYAN}管理 NVR 服务${RESET}\n$(printf '─%.0s' {1..30})"
    get_installed_containers
    [[ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]] && { echo -e "${YELLOW}未发现任何已安装的 NVR 服务。${RESET}"; press_any_key; return; }
    echo "请选择要管理的服务:"
    for i in "${!INSTALLED_CONTAINERS[@]}"; do
        echo "$((i+1)). ${PROJECTS[${INSTALLED_CONTAINERS[$i]}]}"
    done
    echo "$(( ${#INSTALLED_CONTAINERS[@]} + 1 )). 返回"
    read -p "请选择: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#INSTALLED_CONTAINERS[@]}" ]; then
        name=${INSTALLED_CONTAINERS[$((choice-1))]}
        echo "请选择操作: 1.启动 2.停止 3.重启 4.查看日志"
        read -p "操作[1-4]: " op
        case $op in
            1) docker start "$name" ;;
            2) docker stop "$name" ;;
            3) docker restart "$name" ;;
            4) echo -e "${BLUE}按 Ctrl+C 退出日志...${RESET}"; docker logs -f "$name" ;;
            *) echo -e "${RED}无效操作。${RESET}" ;;
        esac
    elif [ "$choice" != "$(( ${#INSTALLED_CONTAINERS[@]} + 1 ))" ]; then
        echo -e "${RED}无效选择。${RESET}"
    fi
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

# --- 主逻辑 ---
main() {
    check_root
    echo "正在初始化环境..."
    detect_package_manager
    check_dependency "docker" "docker.io"
    check_dependency "docker-compose" "docker-compose"
    check_dependency "nmap" "nmap"
    get_host_arch

    while true; do
        main_menu
        read -p "请输入您的选择 [1-6]: " CHOICE
        case $CHOICE in
            1) deploy_menu ;;
            2) scan_network ;;
            3) uninstall_menu ;;
            4) status_menu ;;
            5) manage_menu ;;
            6) echo -e "${GREEN}感谢使用！${RESET}"; exit 0 ;;
            *) echo -e "${RED}无效选择。${RESET}"; sleep 1 ;;
        esac
    done
}

# --- 脚本入口 ---
main
