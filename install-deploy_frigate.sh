#!/bin/bash
# --- 配置区 ---
SCRIPT_NAME="开源 NVR 部署平台"
SCRIPT_VERSION="1.2"
declare -A PROJECTS
PROJECTS=(
    ["frigate"]="Frigate AI智能NVR"
    ["shinobi"]="Shinobi 全功能NVR"
    ["go2rtc"]="go2rtc 流媒体网关"
)
DEFAULT_FRIGATE_CONFIG_DIR="/root/frigate_config"
DEFAULT_SHINOBI_CONFIG_DIR="/root/shinobi_config"
DEFAULT_GO2RTC_CONFIG_FILE="/root/go2rtc.yml"
HOST_ARCH=""
HOST_IP=""
SCAN_LOG_DIR="/tmp"
# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; RESET='\033[0m'
# --- 辅助函数 ---
check_root() { if [ "$(id -u)" != "0" ]; then echo -e "${RED}错误: 请以root权限运行此脚本。${RESET}"; exit 1; fi; }
get_host_ip() { HOST_IP=$(hostname -I | awk '{print $1}'); }
get_host_arch() { HOST_ARCH=$(uname -m); echo -e "${CYAN}检测到您的系统架构为: ${HOST_ARCH}${RESET}"; }
detect_package_manager() {
    if grep -qi 'ubuntu\|debian' /etc/os-release 2>/dev/null; then
        PKG_MANAGER="apt-get"
        INSTALL_CMD="$PKG_MANAGER update -y && $PKG_MANAGER install -y"
    elif grep -qi 'centos\|rhel\|fedora' /etc/os-release 2>/dev/null; then
        PKG_MANAGER="yum"
        INSTALL_CMD="$PKG_MANAGER install -y"
    else
        echo -e "${RED}不支持的系统发行版。请手动安装依赖。${RESET}"; exit 1
    fi
}
check_dependency() {
    local dep=$1; local pkg=$2
    if ! command -v $dep &>/dev/null; then
        read -p "$(echo -e ${YELLOW}"未检测到 ${dep}，是否自动安装？[Y/n]: "${RESET})" choice
        choice=${choice:-Y}
        if [[ "$choice" =~ [yY] ]]; then
            echo -e "${CYAN}正在安装 ${dep}...${RESET}"
            if eval "$INSTALL_CMD $pkg"; then
                echo -e "${GREEN}${dep} 安装成功。${RESET}"
            else
                echo -e "${RED}${dep} 安装失败。${RESET}"; exit 1
            fi
        else
            echo -e "${RED}用户取消安装，脚本无法继续。${RESET}"; exit 1
        fi
    fi
}
press_any_key() { read -n1 -s -r -p "按任意键返回主菜单..."; echo; }
get_installed_containers() {
    INSTALLED_CONTAINERS=()
    for name in "${!PROJECTS[@]}"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
            INSTALLED_CONTAINERS+=("$name")
        fi
    done
}
show_logs_on_failure() {
    local container=$1
    echo -e "${RED}启动失败。显示最后10行日志：${RESET}"
    docker logs --tail 10 "$container" 2>/dev/null || echo "无日志可用。"
}
# --- 部署逻辑 ---
deploy_menu() {
    clear
    echo -e "${GREEN}NVR 部署中心${RESET}\n------------------------------------------------------------------\n请选择您想要部署的NVR项目:\n"
    echo -e "${CYAN}1. Frigate${RESET} - ${YELLOW}AI智能识别NVR${RESET}\n 特点: 强大的AI物体识别，专为智能事件录像设计。\n 适用: 追求高准确率智能侦测，构建自动化家庭安防。\n"
    echo -e "${CYAN}2. Shinobi CCTV${RESET} - ${YELLOW}功能全面的传统NVR${RESET}\n 特点: 7x24录像、移动侦测、时间线回放、多用户管理。\n 适用: 需要一个稳定、功能完整的传统网络硬盘录像机。\n"
    echo -e "${CYAN}3. go2rtc${RESET} - ${YELLOW}极致轻量的流媒体网关${RESET}\n 特点: 极低资源占用，专注于流媒体接收与转换，${RED}无录像功能${RESET}。\n 适用: 实时观看、解决协议兼容问题，或作为其他NVR的前端。\n"
    echo "4. 返回主菜单\n------------------------------------------------------------------"
    read -p "请输入您的选择 [1-4]: " choice
    case $choice in
        1) deploy_frigate ;;
        2) deploy_shinobi ;;
        3) deploy_go2rtc ;;
        4) return ;;
        *) echo -e "${RED}无效选择。${RESET}"; sleep 1 ;;
    esac
}
deploy_frigate() {
    echo -e "\n${GREEN}--- 正在为您部署 Frigate ---${RESET}"
    local name="frigate"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        echo -e "${RED}Frigate 容器已存在。${RESET}"; press_any_key; return
    fi
    local frigate_image="ghcr.io/blakeblackshear/frigate:stable"
    echo -e "${CYAN}为您选择的 Frigate 镜像: ${YELLOW}${frigate_image} (multi-arch, 自动适配 ${HOST_ARCH})${RESET}"
    read -p "请输入 Frigate 的存储目录 [默认: ${DEFAULT_FRIGATE_CONFIG_DIR}]: " STORAGE_PATH
    STORAGE_PATH=${STORAGE_PATH:-$DEFAULT_FRIGATE_CONFIG_DIR}
    mkdir -p "${STORAGE_PATH}/config" "${STORAGE_PATH}/media"

    echo -e "${CYAN}--- 请配置您的摄像头信息 (支持多个，按空行结束) ---${RESET}"
    declare -a CAMERAS
    while true; do
        read -p "IP地址 (空行结束): " CAM_IP
        [[ -z "$CAM_IP" ]] && break
        read -p "用户名 [admin]: " CAM_USER; CAM_USER=${CAM_USER:-admin}
        read -s -p "密码 [无]: " CAM_PASS; echo
        read -p "RTSP端口 [554]: " CAM_PORT; CAM_PORT=${CAM_PORT:-554}
        echo "RTSP路径模板: 1)/stream1 2)/ch1/main/av_stream(海康) 3)/cam/realmonitor?channel=1&subtype=0(大华) 4)/onvif1 5)手动"
        read -p "选择[1-5]: " p_choice
        case $p_choice in
            1) p="/stream1" ;;
            2) p="/ch1/main/av_stream" ;;
            3) p="/cam/realmonitor?channel=1&subtype=0" ;;
            4) p="/onvif1" ;;
            5) read -p "路径: " p ;;
            *) p="/stream1" ;;
        esac
        RTSP_URL=$( [[ -n "$CAM_PASS" ]] && echo "rtsp://${CAM_USER}:${CAM_PASS}@${CAM_IP}:${CAM_PORT}${p}" || echo "rtsp://${CAM_USER}@${CAM_IP}:${CAM_PORT}${p}" )
        echo -e "${GREEN}添加: ${YELLOW}${RTSP_URL}${RESET}"
        CAMERAS+=("${CAM_IP//./_}:${RTSP_URL}")
    done
    [[ ${#CAMERAS[@]} -eq 0 ]] && { echo -e "${RED}至少添加一个摄像头。${RESET}"; press_any_key; return; }

    COMPOSE_FILE="${STORAGE_PATH}/docker-compose.yml"
    cat > "$COMPOSE_FILE" << EOF
version: "3.9"
services:
  frigate:
    container_name: frigate
    privileged: true
    restart: unless-stopped
    image: ${frigate_image}
    shm_size: 64mb
    volumes:
      - ${STORAGE_PATH}/config:/config
      - ${STORAGE_PATH}/media:/media/frigate
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
EOF

    cat > "${STORAGE_PATH}/config/config.yml" << 'EOF'
mqtt: {enabled: False}
cameras:
EOF
    for cam in "${CAMERAS[@]}"; do
        IFS=':' read -r cam_name rtsp_url <<< "$cam"
        cat >> "${STORAGE_PATH}/config/config.yml" << EOF
  ${cam_name}:
    ffmpeg: {inputs: [{path: ${rtsp_url}, roles: [record, detect]}]}
    detect: {enabled: True, width: 1280, height: 720}
    record: {enabled: True, retain: {days: 7, mode: motion}}
EOF
    done

    echo -e "${CYAN}正在启动 Frigate 服务...${RESET}"
    docker-compose -f "$COMPOSE_FILE" up -d
    if [ $? -eq 0 ]; then
        get_host_ip
        echo -e "\n${GREEN}Frigate 部署成功！\n${BLUE}Web UI: ${GREEN}http://${HOST_IP}:5000${RESET}"
    else
        echo -e "\n${RED}部署失败。${RESET}"
        show_logs_on_failure "frigate"
    fi
    press_any_key
}
deploy_shinobi() {
    echo -e "\n${GREEN}--- 正在为您部署 Shinobi CCTV ---${RESET}"
    local name="shinobi"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        echo -e "${RED}Shinobi 容器已存在。${RESET}"; press_any_key; return
    fi

    local shinobi_image=""
    if [[ "$HOST_ARCH" == "x86_64" ]]; then
        shinobi_image="shinobisystems/shinobi:latest"
    elif [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "armv7l" ]]; then
        shinobi_image="migoller/shinobi:latest"
        echo -e "${YELLOW}ARM架构使用社区fork镜像（migoller），可能非官方最新版。${RESET}"
    else
        echo -e "${RED}不支持的系统架构: ${HOST_ARCH}。${RESET}"; press_any_key; return
    fi
    echo -e "${CYAN}为您选择的 Shinobi 镜像: ${YELLOW}${shinobi_image}${RESET}"

    read -p "请输入 Shinobi 的存储目录 [默认: ${DEFAULT_SHINOBI_CONFIG_DIR}]: " STORAGE_PATH
    STORAGE_PATH=${STORAGE_PATH:-$DEFAULT_SHINOBI_CONFIG_DIR}
    mkdir -p "$STORAGE_PATH/config" "$STORAGE_PATH/videos"
    chmod -R 777 "$STORAGE_PATH"

    echo -e "${CYAN}正在启动 Shinobi 服务...${RESET}"
    docker run -d --name ${name} --restart=always \
        -p 8080:8080 \
        -v "${STORAGE_PATH}/config":/config \
        -v "${STORAGE_PATH}/videos":/var/lib/shinobi/videos \
        -v /dev/shm/shinobi-shm:/dev/shm \
        ${shinobi_image}

    if [ $? -eq 0 ]; then
        echo -e "${CYAN}等待 Shinobi 服务初始化... (约15秒)${RESET}"; sleep 15
        if ! docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
            echo -e "\n${RED}Shinobi 容器启动后意外退出。${RESET}"
            show_logs_on_failure "shinobi"
        else
            get_host_ip
            echo -e "\n${GREEN}Shinobi 部署成功！\n${BLUE}首次访问超级面板:\n 地址: ${GREEN}http://${HOST_IP}:8080/super\n ${RESET}用户: ${YELLOW}admin@shinobi.video${RESET} | 密码: ${YELLOW}admin${RESET}\n${RED}请立即更改默认密码！${RESET}"
        fi
    else
        echo -e "\n${RED}Shinobi 部署失败。${RESET}"
        show_logs_on_failure "shinobi"
    fi
    press_any_key
}
deploy_go2rtc() {
    echo -e "\n${GREEN}--- 正在为您部署 go2rtc ---${RESET}"
    local name="go2rtc"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        echo -e "${RED}go2rtc 容器已存在。${RESET}"; press_any_key; return
    fi

    local go2rtc_image="alexxit/go2rtc:latest"
    echo -e "${CYAN}为您选择的 go2rtc 镜像: ${YELLOW}${go2rtc_image}${RESET} (多架构支持)"

    read -p "请输入 go2rtc 配置文件路径 [默认: ${DEFAULT_GO2RTC_CONFIG_FILE}]: " CONFIG_FILE
    CONFIG_FILE=${CONFIG_FILE:-$DEFAULT_GO2RTC_CONFIG_FILE}
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件不存在，将创建示例。${RESET}"
        cat > "$CONFIG_FILE" << 'EOF'
streams:
  example_cam:
    - rtsp://user:pass@192.168.1.100:554/stream1  # 请替换为实际地址
EOF
        echo -e "示例文件已创建于 ${GREEN}${CONFIG_FILE}${RESET}"
    fi

    echo -e "${CYAN}正在启动 go2rtc 服务...${RESET}"
    docker run -d --name ${name} --restart=always \
        -p 1984:1984 -p 8555:8555/udp \
        -v "${CONFIG_FILE}":/config.yml \
        ${go2rtc_image}

    if [ $? -eq 0 ]; then
        get_host_ip
        echo -e "\n${GREEN}go2rtc 部署成功！\n${BLUE}Web UI: ${GREEN}http://${HOST_IP}:1984${RESET}"
    else
        echo -e "\n${RED}go2rtc 部署失败。${RESET}"
        show_logs_on_failure "go2rtc"
    fi
    press_any_key
}
# --- 管理逻辑 ---
scan_network() {
    clear
    echo -e "${BLUE}扫描局域网摄像头${RESET}\n--------------------------------------"
    DEFAULT_SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -1)
    read -p "请输入要扫描的网段 [默认: ${DEFAULT_SUBNET}]: " SUBNET
    SUBNET=${SUBNET:-$DEFAULT_SUBNET}

    if ! [[ $SUBNET =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
        echo -e "${RED}无效网段格式，应为 x.x.x.x/24${RESET}"; press_any_key; return
    fi

    echo -e "${CYAN}正在扫描网段 ${SUBNET} ...${RESET}"

    RAW=$(nmap -p 80,554,8000,37777,5544,8099 --open "$SUBNET" -oG -)
    SCAN_RESULTS=$(echo "$RAW" | grep -E 'Host:.*Ports:' | \
        sed -E 's/.*Host: ([0-9.]+) \([^)]*\) *Ports: (.*)/\1 \2/' | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ [0-9]+' | sort -u)

    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    SCAN_LOG="/tmp/nvr_scan_${TIMESTAMP}.txt"

    if [ -z "$SCAN_RESULTS" ]; then
        echo -e "${RED}未发现开放常见摄像头端口的设备。${RESET}"
        echo "未发现设备" > "$SCAN_LOG"
    else
        echo -e "${GREEN}扫描完成！发现以下潜在设备：${RESET}"
        echo "--------------------------------------"
        echo -e "${YELLOW}IP 地址          开放端口${RESET}"
        echo "--------------------------------------"
        echo "$SCAN_RESULTS" | while read -r ip port; do
            if [[ "$port" == "554" || "$port" == "5544" ]]; then
                printf "%-16s ${GREEN}%s (RTSP)${RESET}\n" "$ip" "$port"
            else
                printf "%-16s ${YELLOW}%s${RESET}\n" "$ip" "$port"
            fi
        done
        echo "--------------------------------------"
        echo -e "常见的RTSP端口是 ${GREEN}554${RESET} 或 ${GREEN}5544${RESET}。"
        echo "$SCAN_RESULTS" > "$SCAN_LOG"
        echo -e "${CYAN}扫描结果已保存至: ${GREEN}${SCAN_LOG}${RESET}"
    fi
    press_any_key
}
uninstall_menu() {
    clear; echo -e "${YELLOW}卸载 NVR 服务${RESET}\n--------------------------------------"
    get_installed_containers
    [[ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]] && { echo -e "${YELLOW}未发现任何已安装的 NVR 服务。${RESET}"; press_any_key; return; }
    echo "请选择要卸载的服务:"
    for i in "${!INSTALLED_CONTAINERS[@]}"; do
        echo "$((i+1)). ${PROJECTS[${INSTALLED_CONTAINERS[$i]}]}"
    done
    echo "$(( ${#INSTALLED_CONTAINERS[@]} + 1 )). 返回"
    read -p "请选择: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#INSTALLED_CONTAINERS[@]}" ]; then
        CONTAINER_TO_UNINSTALL=${INSTALLED_CONTAINERS[$((choice-1))]}
        read -p "$(echo -e ${RED}"确定要卸载 ${CONTAINER_TO_UNINSTALL} 吗？[y/N]: "${RESET})" confirm
        if [[ "$confirm" =~ [yY] ]]; then
            docker stop "$CONTAINER_TO_UNINSTALL" &>/dev/null
            docker rm "$CONTAINER_TO_UNINSTALL" &>/dev/null
            echo -e "${GREEN}${CONTAINER_TO_UNINSTALL} 容器已移除。${RESET}"
            read -p "是否删除其所有配置文件和数据？[y/N]: " del_data
            if [[ "$del_data" =~ [yY] ]]; then
                case $CONTAINER_TO_UNINSTALL in
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
    clear; echo -e "${BLUE}查看运行状态${RESET}\n--------------------------------------"
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
    clear; echo -e "${CYAN}管理 NVR 服务${RESET}\n--------------------------------------"
    get_installed_containers
    [[ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]] && { echo -e "${YELLOW}未发现任何已安装的 NVR 服务。${RESET}"; press_any_key; return; }
    echo "请选择要管理的服务:"
    for i in "${!INSTALLED_CONTAINERS[@]}"; do
        echo "$((i+1)). ${PROJECTS[${INSTALLED_CONTAINERS[$i]}]}"
    done
    echo "$(( ${#INSTALLED_CONTAINERS[@]} + 1 )). 返回"
    read -p "请选择: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#INSTALLED_CONTAINERS[@]}" ]; then
        CONTAINER_TO_MANAGE=${INSTALLED_CONTAINERS[$((choice-1))]}
        echo "请选择操作: 1.启动 2.停止 3.重启 4.查看日志"
        read -p "操作[1-4]: " op
        case $op in
            1) docker start "$CONTAINER_TO_MANAGE" ;;
            2) docker stop "$CONTAINER_TO_MANAGE" ;;
            3) docker restart "$CONTAINER_TO_MANAGE" ;;
            4) echo -e "${BLUE}按 Ctrl+C 退出日志...${RESET}"; docker logs -f "$CONTAINER_TO_MANAGE" ;;
            *) echo -e "${RED}无效操作。${RESET}" ;;
        esac
    elif [ "$choice" != "$(( ${#INSTALLED_CONTAINERS[@]} + 1 ))" ]; then
        echo -e "${RED}无效选择。${RESET}"
    fi
    press_any_key
}
# --- 主菜单与主逻辑 ---
main_menu() {
    clear
    echo -e "${BLUE}==========================================${RESET}"
    echo -e " ${GREEN}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}"
    echo -e " ${CYAN}System Arch: ${HOST_ARCH}${RESET}"
    echo -e "${BLUE}==========================================${RESET}"
    echo -e " 1. ${GREEN}部署 NVR 服务${RESET} (Frigate, Shinobi...)"
    echo -e " 2. ${CYAN}扫描${RESET} 局域网摄像头"
    echo -e " 3. ${RED}卸载${RESET} NVR 服务"
    echo -e " 4. ${BLUE}查看${RESET} 运行状态"
    echo -e " 5. ${YELLOW}管理${RESET} NVR 服务 (启/停/日志)"
    echo -e " 6. ${RED}退出${RESET} 脚本"
    echo -e "${BLUE}==========================================${RESET}"
}
main() {
    check_root
    echo "正在初始化和检查环境..."; sleep 1
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
