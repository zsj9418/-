#!/bin/bash
# --- 配置区 ---
SCRIPT_NAME="开源 NVR 部署平台"
SCRIPT_VERSION="1.0"
declare -A PROJECTS
PROJECTS=(
    ["frigate"]="Frigate AI智能NVR"
    ["shinobi"]="Shinobi 全功能NVR"
    ["go2rtc"]="go2rtc 流媒体网关"
)
DEFAULT_FRIGATE_CONFIG_DIR="/root/frigate_config"
DEFAULT_SHINOBI_CONFIG_DIR="/root/shinobi_config"
DEFAULT_GO2RTC_CONFIG_FILE="/root/go2rtc.yml"

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; RESET='\033[0m'

# --- 辅助函数 ---
check_root() { if [ "$(id -u)" != "0" ]; then echo -e "${RED}错误: 请以root权限运行此脚本。${RESET}"; exit 1; fi; }
get_host_ip() { HOST_IP=$(hostname -I | awk '{print $1}'); }
check_dependency() {
    local dep=$1; local cmd=$2
    if ! command -v $dep &>/dev/null; then
        read -p "$(echo -e ${YELLOW}"⚠️ 未检测到 ${dep}，是否自动安装？[Y/n]: "${RESET})" choice
        choice=${choice:-Y}
        if [[ "$choice" =~ [yY] ]]; then
            echo -e "${CYAN}🔧 正在安装 ${dep}...${RESET}"
            if eval $cmd; then echo -e "${GREEN}✅ ${dep} 安装成功。${RESET}"; else echo -e "${RED}❌ ${dep} 安装失败。${RESET}"; exit 1; fi
        else
            echo -e "${RED}❌ 用户取消安装，脚本无法继续。${RESET}"; exit 1
        fi
    fi
}
press_any_key() { read -n1 -s -r -p "按任意键返回主菜单..."; }
get_installed_containers() {
    INSTALLED_CONTAINERS=()
    for name in "${!PROJECTS[@]}"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
            INSTALLED_CONTAINERS+=("$name")
        fi
    done
}

# --- 部署逻辑 ---
deploy_menu() {
    clear
    echo -e "${GREEN}🚀 NVR 部署中心${RESET}\n------------------------------------------------------------------\n请选择您想要部署的NVR项目:\n"
    echo -e "${CYAN}1. Frigate${RESET} - ${YELLOW}AI智能识别NVR${RESET}\n   特点: 强大的AI物体识别（人、车、动物等），专为智能事件录像设计。\n   优点: 误报率极低，与Home Assistant等智能家居平台完美集成。\n   适用: 追求高准确率智能侦测，构建自动化家庭安防的用户。\n   资源: 中等 (推荐使用Google Coral TPU以获得最佳性能)。\n"
    echo -e "${CYAN}2. Shinobi CCTV${RESET} - ${YELLOW}功能全面的传统NVR${RESET}\n   特点: 7x24小时录像、移动侦测录像、时间线回放、多用户管理。\n   优点: 功能均衡，界面现代化，无需特殊硬件，比Frigate更轻量。\n   适用: 需要一个稳定、功能完整的传统网络硬盘录像机。\n   资源: 轻量至中等。\n"
    echo -e "${CYAN}3. go2rtc${RESET} - ${YELLOW}极致轻量的流媒体网关${RESET}\n   特点: 极低资源占用，专注于流媒体接收与转换，${RED}无录像功能${RESET}。\n   优点: 启动快，延迟低(WebRTC)，是将摄像头接入网页的最佳工具。\n   适用: 只需实时查看、解决协议兼容问题，或作为其他NVR的前端。\n"
    echo "4. 返回主菜单\n------------------------------------------------------------------"; read -p "请输入您的选择 [1-4]: " choice
    case $choice in 1) deploy_frigate ;; 2) deploy_shinobi ;; 3) deploy_go2rtc ;; 4) return ;; *) echo -e "${RED}❌ 无效选择。${RESET}"; sleep 1 ;; esac
}

deploy_frigate() {
    echo -e "\n${GREEN}--- 正在为您部署 Frigate ---${RESET}"
    local name="frigate"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then echo -e "${RED}❌ Frigate 容器已存在，请先卸载。${RESET}"; press_any_key; return; fi
    read -p "请输入 Frigate 的存储目录 [默认: ${DEFAULT_FRIGATE_CONFIG_DIR}]: " STORAGE_PATH; STORAGE_PATH=${STORAGE_PATH:-$DEFAULT_FRIGATE_CONFIG_DIR}
    mkdir -p "${STORAGE_PATH}/config"; mkdir -p "${STORAGE_PATH}/media"
    echo -e "${CYAN}--- 请配置您的摄像头信息 ---${RESET}"
    read -p "请输入摄像头的IP地址: " CAM_IP; while [ -z "$CAM_IP" ]; do read -p "${RED}IP地址不能为空: ${RESET}" CAM_IP; done
    read -p "登录用户名 [默认: admin]: " CAM_USER; CAM_USER=${CAM_USER:-admin}
    read -p "登录密码 [默认: 无]: " CAM_PASS
    read -p "RTSP端口 [默认: 554]: " CAM_PORT; CAM_PORT=${CAM_PORT:-554}
    echo "请选择RTSP路径模板: 1)/stream1(通用) 2)/ch1/main/av_stream(海康) 3)/cam/realmonitor?channel=1&subtype=0(大华) 4)/onvif1(ONVIF) 5)手动输入"; read -p "请选择[1-5]: " p_choice
    case $p_choice in 1) p="/stream1";; 2) p="/ch1/main/av_stream";; 3) p="/cam/realmonitor?channel=1&subtype=0";; 4) p="/onvif1";; 5) read -p "请输入路径: " p;; *) p="/stream1";; esac
    if [ -n "$CAM_PASS" ]; then RTSP_URL="rtsp://${CAM_USER}:${CAM_PASS}@${CAM_IP}:${CAM_PORT}${p}"; else RTSP_URL="rtsp://${CAM_USER}@${CAM_IP}:${CAM_PORT}${p}"; fi
    echo -e "${GREEN}将使用: ${YELLOW}${RTSP_URL}${RESET}"; read -p "确认无误请按回车..."
    
    COMPOSE_FILE="${STORAGE_PATH}/docker-compose.yml"
    # 【已修复】使用标准的多行YAML格式生成配置文件
    cat > "$COMPOSE_FILE" << EOF
version: "3.9"
services:
  frigate:
    container_name: frigate
    privileged: true
    restart: unless-stopped
    image: ghcr.io/blakeblackshear/frigate:stable
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

    # 【已修复】使用标准的多行YAML格式生成配置文件
    cat > "${STORAGE_PATH}/config/config.yml" << EOF
mqtt:
  enabled: False

cameras:
  ${CAM_IP//./_}:
    ffmpeg:
      inputs:
        - path: ${RTSP_URL}
          roles:
            - record
            - detect
    detect:
      enabled: True
      width: 1280
      height: 720
    record:
      enabled: True
      retain:
        days: 7
        mode: motion
EOF

    echo -e "${CYAN}🚀 正在启动 Frigate 服务...${RESET}"; docker-compose -f "$COMPOSE_FILE" up -d
    if [ $? -eq 0 ]; then get_host_ip; echo -e "\n${GREEN}✅ Frigate 部署成功！\n${BLUE}📢 Web UI: ${GREEN}http://${HOST_IP}:5000${RESET}"; else echo -e "\n${RED}❌ 部署失败，请使用管理菜单查看日志。${RESET}"; fi
    press_any_key
}

deploy_shinobi() {
    echo -e "\n${GREEN}--- 正在为您部署 Shinobi CCTV ---${RESET}"
    local name="shinobi"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then echo -e "${RED}❌ Shinobi 容器已存在，请先卸载。${RESET}"; press_any_key; return; fi
    read -p "请输入 Shinobi 的配置和视频存储目录 [默认: ${DEFAULT_SHINOBI_CONFIG_DIR}]: " STORAGE_PATH; STORAGE_PATH=${STORAGE_PATH:-$DEFAULT_SHINOBI_CONFIG_DIR}
    mkdir -p "$STORAGE_PATH/config"; mkdir -p "$STORAGE_PATH/videos"; chmod -R 777 "$STORAGE_PATH"
    echo -e "${CYAN}🚀 正在启动 Shinobi 服务...${RESET}"
    docker run -d --name ${name} --restart=always -p 8080:8080 -v ${STORAGE_PATH}/config:/config -v ${STORAGE_PATH}/videos:/var/lib/shinobi/videos -v /dev/shm/shinobi-shm:/dev/shm shinobisystems/shinobi:latest
    if [ $? -eq 0 ]; then get_host_ip; echo -e "\n${GREEN}✅ Shinobi 部署成功！\n${BLUE}📢 首次访问超级面板进行设置:\n   地址: ${GREEN}http://${HOST_IP}:8080/super\n   ${RESET}默认用户: ${YELLOW}admin@shinobi.video${RESET} | 密码: ${YELLOW}admin${RESET}"; else echo -e "\n${RED}❌ Shinobi 部署失败。${RESET}"; fi
    press_any_key
}

deploy_go2rtc() {
    echo -e "\n${GREEN}--- 正在为您部署 go2rtc ---${RESET}"
    local name="go2rtc"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then echo -e "${RED}❌ go2rtc 容器已存在，请先卸载。${RESET}"; press_any_key; return; fi
    read -p "请输入 go2rtc 的配置文件路径 [默认: ${DEFAULT_GO2RTC_CONFIG_FILE}]: " CONFIG_FILE; CONFIG_FILE=${CONFIG_FILE:-$DEFAULT_GO2RTC_CONFIG_FILE}
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${YELLOW}⚠️ 配置文件不存在，将创建示例文件。${RESET}"; cat > "$CONFIG_FILE" << EOF
streams:
  living_room:
    - rtsp://user:pass@192.168.1.123:554/stream1
EOF
    echo -e "✅ 示例文件已创建于 ${GREEN}${CONFIG_FILE}${RESET}。请部署后编辑它并重启容器。"; fi
    echo -e "${CYAN}🚀 正在启动 go2rtc 服务...${RESET}"
    docker run -d --name ${name} --restart=always -p 1984:1984 -p 8555:8555/udp -v ${CONFIG_FILE}:/config.yml alexxit/go2rtc
    if [ $? -eq 0 ]; then get_host_ip; echo -e "\n${GREEN}✅ go2rtc 部署成功！\n${BLUE}📢 Web UI: ${GREEN}http://${HOST_IP}:1984${RESET}"; else echo -e "\n${RED}❌ go2rtc 部署失败。${RESET}"; fi
    press_any_key
}

# --- 管理逻辑 ---
scan_network() {
    clear; echo -e "${BLUE}📡 扫描局域网摄像头${RESET}\n--------------------------------------";
    DEFAULT_SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -1)
    read -p "请输入要扫描的网段 [默认: ${DEFAULT_SUBNET}]: " SUBNET; SUBNET=${SUBNET:-$DEFAULT_SUBNET}
    echo -e "${CYAN}🚀 正在扫描网段 ${SUBNET} ...${RESET}"
    SCAN_RESULTS=$(nmap -p 80,554,8000,37777,5544,8099 --open ${SUBNET} -oG - | awk '/Up$/{print $2, $4}')
    if [ -z "$SCAN_RESULTS" ]; then echo -e "${RED}❌ 未发现开放了常见摄像头端口的设备。${RESET}"; else
        echo -e "${GREEN}✅ 扫描完成！发现以下潜在设备：${RESET}\n--------------------------------------\n${YELLOW}IP 地址\t\t开放的端口${RESET}";
        echo "$SCAN_RESULTS" | while read -r ip ports; do printf "%-16s\t%s\n" "$ip" "$(echo $ports | sed 's|/tcp(open)|,|g' | sed 's/,$//')"; done
        echo "--------------------------------------\n常见的RTSP端口是 ${GREEN}554${RESET} 或 ${GREEN}5544${RESET}。"; fi
    press_any_key
}

uninstall_menu() {
    clear; echo -e "${YELLOW}🗑️ 卸载 NVR 服务${RESET}\n--------------------------------------"; get_installed_containers
    if [ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]; then echo -e "${YELLOW}⚠️ 未发现任何已安装的 NVR 服务。${RESET}"; press_any_key; return; fi
    echo "请选择要卸载的服务:"
    for i in "${!INSTALLED_CONTAINERS[@]}"; do echo "$((i+1)). ${PROJECTS[${INSTALLED_CONTAINERS[$i]}]}"; done
    echo "$(( ${#INSTALLED_CONTAINERS[@]} + 1 )). 返回主菜单"; read -p "请选择: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#INSTALLED_CONTAINERS[@]}" ]; then
        CONTAINER_TO_UNINSTALL=${INSTALLED_CONTAINERS[$((choice-1))]}
        read -p "$(echo -e ${RED}"确定要卸载 ${CONTAINER_TO_UNINSTALL} 吗？[y/N]: "${RESET})" confirm
        if [[ "$confirm" =~ [yY] ]]; then
            docker stop "$CONTAINER_TO_UNINSTALL" &>/dev/null; docker rm "$CONTAINER_TO_UNINSTALL" &>/dev/null
            echo -e "${GREEN}✅ ${CONTAINER_TO_UNINSTALL} 容器已移除。${RESET}"
            read -p "是否删除其所有配置文件和数据？此操作不可逆！[y/N]: " del_data
            if [[ "$del_data" =~ [yY] ]]; then
                case $CONTAINER_TO_UNINSTALL in
                    frigate) rm -rf "$DEFAULT_FRIGATE_CONFIG_DIR" ;;
                    shinobi) rm -rf "$DEFAULT_SHINOBI_CONFIG_DIR" ;;
                    go2rtc) rm -f "$DEFAULT_GO2RTC_CONFIG_FILE" ;;
                esac
                echo -e "${GREEN}✅ 相关数据已删除。${RESET}"
            fi
        fi
    elif [ "$choice" != "$(( ${#INSTALLED_CONTAINERS[@]} + 1 ))" ]; then
        echo -e "${RED}❌ 无效选择。${RESET}"
    fi
    press_any_key
}

status_menu() {
    clear; echo -e "${BLUE}🔍 查看运行状态${RESET}\n--------------------------------------"; get_installed_containers
    if [ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]; then echo -e "${YELLOW}⚠️ 未发现任何已安装的 NVR 服务。${RESET}"; press_any_key; return; fi
    echo -e "${GREEN}当前已安装的服务状态:${RESET}"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | {
        read -r header; echo -e "${YELLOW}$header${RESET}";
        grep -E "$(IFS="|"; echo "${INSTALLED_CONTAINERS[*]}")" || echo -e "${YELLOW}没有正在运行的相关服务。${RESET}";
    }
    press_any_key
}

manage_menu() {
    clear; echo -e "${CYAN}⚙️ 管理 NVR 服务${RESET}\n--------------------------------------"; get_installed_containers
    if [ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]; then echo -e "${YELLOW}⚠️ 未发现任何已安装的 NVR 服务。${RESET}"; press_any_key; return; fi
    echo "请选择要管理的服务:"
    for i in "${!INSTALLED_CONTAINERS[@]}"; do echo "$((i+1)). ${PROJECTS[${INSTALLED_CONTAINERS[$i]}]}"; done
    echo "$(( ${#INSTALLED_CONTAINERS[@]} + 1 )). 返回主菜单"; read -p "请选择: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#INSTALLED_CONTAINERS[@]}" ]; then
        CONTAINER_TO_MANAGE=${INSTALLED_CONTAINERS[$((choice-1))]}
        echo "请选择操作: 1.启动 2.停止 3.重启 4.查看日志"; read -p "操作[1-4]: " op
        case $op in
            1) docker start "$CONTAINER_TO_MANAGE";; 2) docker stop "$CONTAINER_TO_MANAGE";; 3) docker restart "$CONTAINER_TO_MANAGE";;
            4) echo -e "${BLUE}📜 按 Ctrl+C 退出日志...${RESET}"; docker logs -f "$CONTAINER_TO_MANAGE";;
            *) echo -e "${RED}❌ 无效操作。${RESET}";;
        esac
    elif [ "$choice" != "$(( ${#INSTALLED_CONTAINERS[@]} + 1 ))" ]; then
        echo -e "${RED}❌ 无效选择。${RESET}"
    fi
    press_any_key
}

# --- 主菜单与主逻辑 ---
main_menu() {
    clear
    echo -e "${BLUE}==========================================${RESET}"
    echo -e "      ${GREEN}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}"
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
    echo "正在检查系统环境..."; sleep 1
    check_dependency "docker" "apt-get update -y && apt-get install -y docker.io"
    check_dependency "docker-compose" "apt-get install -y docker-compose"
    check_dependency "nmap" "apt-get install -y nmap"
    
    while true; do
        main_menu
        read -p "请输入您的选择 [1-6]: " CHOICE
        case $CHOICE in
            1) deploy_menu ;; 2) scan_network ;; 3) uninstall_menu ;;
            4) status_menu ;; 5) manage_menu ;;
            6) echo -e "${GREEN}👋 感谢使用！${RESET}"; exit 0 ;;
            *) echo -e "${RED}❌ 无效选择。${RESET}"; sleep 1 ;;
        esac
    done
}

# --- 脚本入口 ---
main
