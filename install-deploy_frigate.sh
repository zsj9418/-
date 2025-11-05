#!/bin/bash
# --- 配置区 ---
SCRIPT_NAME="开源 NVR 部署平台"
SCRIPT_VERSION="1.0"
STATE_FILE="/etc/nvr_installer.state"
HOST_ARCH=""
PKG_MANAGER=""
declare -A PROJECTS=(
    ["frigate"]="Frigate AI智能NVR"
    ["shinobi"]="Shinobi 全功能NVR"
    ["go2rtc"]="go2rtc 流媒体网关"
)

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; RESET='\033[0m'

# --- 辅助函数 ---
check_root() { if [ "$(id -u)" != "0" ]; then echo -e "${RED}错误: 请以root权限运行此脚本。${RESET}"; exit 1; fi; }
get_host_ip() { HOST_IP=$(hostname -I | awk '{print $1}'); }
get_host_arch() { HOST_ARCH=$(uname -m); }
press_any_key() { read -n1 -s -r -p "按任意键返回主菜单..."; }

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then PKG_MANAGER="apt-get";
    elif command -v dnf &>/dev/null; then PKG_MANAGER="dnf";
    elif command -v yum &>/dev/null; then PKG_MANAGER="yum";
    else echo -e "${RED}❌ 未能识别您的系统包管理器 (apt, dnf, yum)。${RESET}"; exit 1; fi
    echo -e "${CYAN}ℹ️  检测到包管理器: ${PKG_MANAGER}${RESET}"
}

check_dependency() {
    local dep=$1
    if ! command -v $dep &>/dev/null; then
        read -p "$(echo -e ${YELLOW}"⚠️ 未检测到 ${dep}，是否自动安装？[Y/n]: "${RESET})" choice
        choice=${choice:-Y}
        if [[ "$choice" =~ [yY] ]]; then
            echo -e "${CYAN}🔧 正在安装 ${dep}...${RESET}"
            case $PKG_MANAGER in
                "apt-get") sudo apt-get update -y && sudo apt-get install -y $1 ;;
                "dnf") sudo dnf install -y $1 ;;
                "yum") sudo yum install -y $1 ;;
            esac
            if ! command -v $dep &>/dev/null; then echo -e "${RED}❌ 安装失败。${RESET}"; exit 1; fi
            echo -e "${GREEN}✅ ${dep} 安装成功。${RESET}"
        else echo -e "${RED}❌ 用户取消安装。${RESET}"; exit 1; fi
    fi
}

# 状态管理函数
read_state() { grep "^$1=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2; }
write_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    if grep -q "^$1=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" "$STATE_FILE"
    else
        echo "$1=$2" >> "$STATE_FILE"
    fi
}
remove_state() { sed -i "/^$1=/d" "$STATE_FILE" 2>/dev/null; }
get_installed_services() { INSTALLED_SERVICES=($(cut -d'=' -f1 "$STATE_FILE" 2>/dev/null)); }

check_port() {
    local port=$1
    if ss -tuln | grep -q ":${port} "; then
        echo -e "${YELLOW}⚠️ 端口 ${port} 已被占用。${RESET}"; return 1
    else
        return 0
    fi
}
prompt_for_port() {
    local service_name=$1
    local default_port=$2
    local host_port=$default_port
    while true; do
        read -p "请输入 ${service_name} 的主机端口 [默认: ${default_port}]: " input_port
        host_port=${input_port:-$default_port}
        if ! [[ "$host_port" =~ ^[0-9]+$ ]] || [ "$host_port" -lt 1 ] || [ "$host_port" -gt 65535 ]; then
            echo -e "${RED}❌ 请输入 1-65535 之间的有效端口号。${RESET}"; continue
        fi
        if check_port "$host_port"; then echo -e "${GREEN}✅ 端口 ${host_port} 可用。${RESET}"; break; else continue; fi
    done
    echo "$host_port"
}


# --- 部署逻辑 ---
deploy_menu() {
    # 省略菜单显示部分，与v5.2一致
    clear; echo -e "${GREEN}🚀 NVR 部署中心${RESET}\n------------------------------------------------------------------\n请选择您想要部署的NVR项目:\n"
    echo -e "${CYAN}1. Frigate${RESET} - ${YELLOW}AI智能识别NVR${RESET}\n   特点: 强大的AI物体识别，专为智能事件录像设计。\n"
    echo -e "${CYAN}2. Shinobi CCTV${RESET} - ${YELLOW}功能全面的传统NVR${RESET}\n   特点: 7x24录像、移动侦测、时间线回放、多用户管理。\n"
    echo -e "${CYAN}3. go2rtc${RESET} - ${YELLOW}极致轻量的流媒体网关${RESET}\n   特点: 极低资源占用，专注于流媒体接收与转换，${RED}无录像功能${RESET}。\n"
    echo "4. 返回\n------------------------------------------------------------------"; read -p "选择[1-4]: " choice
    case $choice in 1) deploy_frigate ;; 2) deploy_shinobi ;; 3) deploy_go2rtc ;; 4) return ;; *) echo -e "${RED}❌ 无效。${RESET}"; sleep 1 ;; esac
}

deploy_frigate() {
    echo -e "\n${GREEN}--- 部署 Frigate ---${RESET}"; local name="frigate"
    if [ -n "$(read_state ${name})" ]; then echo -e "${RED}❌ Frigate 已部署。${RESET}"; press_any_key; return; fi
    local image="ghcr.io/blakeblackshear/frigate:stable"; if [[ "$HOST_ARCH" == "aarch64" ]]; then image="ghcr.io/blakeblackshear/frigate:stable-arm64"; fi
    echo -e "${CYAN}镜像: ${YELLOW}${image}${RESET}"
    read -p "存储目录 [/root/frigate_config]: " STORAGE_PATH; STORAGE_PATH=${STORAGE_PATH:-/root/frigate_config}; mkdir -p "${STORAGE_PATH}/config" "${STORAGE_PATH}/media"
    local frigate_port=$(prompt_for_port "Frigate" 5000)
    read -p "为Frigate分配的共享内存大小? 1)小(64M) 2)中(256M) 3)大(512M) [1]: " shm_choice
    case $shm_choice in 2) shm="256mb";; 3) shm="512mb";; *) shm="64mb";; esac
    
    echo -e "${CYAN}---摄像头配置 (可添加多个)---${RESET}"
    local cameras_yaml=""
    local count=1
    while true; do
        echo -e "${BLUE}--- 添加第 ${count} 个摄像头 ---${RESET}"
        read -p "IP地址: " CAM_IP; while [ -z "$CAM_IP" ]; do read -p "${RED}IP不能为空: ${RESET}" CAM_IP; done
        read -p "用户名[admin]: " CAM_USER; CAM_USER=${CAM_USER:-admin}; read -p "密码[无]: " CAM_PASS
        read -p "RTSP端口[554]: " CAM_PORT; CAM_PORT=${CAM_PORT:-554}
        echo "RTSP路径模板: 1)/stream1 2)海康 3)大华 4)手动"; read -p "选择[1-4]: " p_choice
        case $p_choice in 1) p="/stream1";; 2) p="/ch1/main/av_stream";; 3) p="/cam/realmonitor?channel=1&subtype=0";; 4) read -p "路径: " p;; *) p="/stream1";; esac
        if [ -n "$CAM_PASS" ]; then RTSP_URL="rtsp://${CAM_USER}:${CAM_PASS}@${CAM_IP}:${CAM_PORT}${p}"; else RTSP_URL="rtsp://${CAM_USER}@${CAM_IP}:${CAM_PORT}${p}"; fi
        
        cameras_yaml+=$(cat <<EOF
  ${CAM_IP//./_}:
    ffmpeg:
      inputs:
        - path: ${RTSP_URL}
          roles:
            - record
            - detect
    detect:
      enabled: True
    record:
      enabled: True
EOF
)
        read -p "是否继续添加下一个摄像头？[y/N]: " add_more; if [[ ! "$add_more" =~ [yY] ]]; then break; fi; ((count++))
    done

    COMPOSE_FILE="${STORAGE_PATH}/docker-compose.yml"
    cat > "$COMPOSE_FILE" << EOF
version: "3.9"
services:
  frigate: {container_name: frigate, privileged: true, restart: unless-stopped, image: ${image}, shm_size: ${shm}, volumes: ["${STORAGE_PATH}/config:/config", "${STORAGE_PATH}/media:/media/frigate", "/etc/localtime:/etc/localtime:ro"], ports: ["${frigate_port}:5000", "8554:8554"]}
EOF
    cat > "${STORAGE_PATH}/config/config.yml" << EOF
mqtt: {enabled: False}
cameras:
${cameras_yaml}
EOF

    echo -e "${CYAN}🚀 启动中...${RESET}"; docker-compose -f "$COMPOSE_FILE" up -d
    if [ $? -eq 0 ]; then get_host_ip; write_state $name $STORAGE_PATH; echo -e "\n${GREEN}✅ 部署成功！\n${BLUE}📢 Web UI: ${GREEN}http://${HOST_IP}:${frigate_port}${RESET}"; else echo -e "\n${RED}❌ 失败。${RESET}"; fi; press_any_key
}

deploy_shinobi() {
    echo -e "\n${GREEN}--- 部署 Shinobi ---${RESET}"; local name="shinobi"
    if [ -n "$(read_state ${name})" ]; then echo -e "${RED}❌ Shinobi 已部署。${RESET}"; press_any_key; return; fi
    local image="shinobisystems/shinobi:dev"; echo -e "${CYAN}镜像: ${YELLOW}${image}${RESET}"
    read -p "存储目录 [/root/shinobi_config]: " STORAGE_PATH; STORAGE_PATH=${STORAGE_PATH:-/root/shinobi_config}; mkdir -p "$STORAGE_PATH/config" "$STORAGE_PATH/videos"; echo -e "${YELLOW}⚠️ 为确保权限，将对目录 ${STORAGE_PATH} 执行 'chmod -R 777'。${RESET}"; chmod -R 777 "$STORAGE_PATH"
    local shinobi_port=$(prompt_for_port "Shinobi" 8080)
    
    echo -e "${CYAN}🚀 启动中...${RESET}"
    docker run -d --name ${name} --restart=always -p ${shinobi_port}:8080 -v "${STORAGE_PATH}/config":/config -v "${STORAGE_PATH}/videos":/var/lib/shinobi/videos -v /dev/shm/shinobi-shm:/dev/shm ${image}
    
    if [ $? -eq 0 ]; then
        echo -e "${CYAN}⏳ 等待服务初始化...${RESET}"; sleep 15
        if ! docker ps --format '{{.Names}}' | grep -q "^${name}$"; then echo -e "\n${RED}❌ 容器启动后意外退出。${RESET}"; else
            get_host_ip; write_state $name $STORAGE_PATH; echo -e "\n${GREEN}✅ 部署成功！\n${BLUE}📢 超级面板: ${GREEN}http://${HOST_IP}:${shinobi_port}/super${RESET}"; fi
    else echo -e "\n${RED}❌ 部署失败。${RESET}"; fi
    press_any_key
}

deploy_go2rtc() {
    # 逻辑与Frigate类似，增加了多摄像头和端口选择
    echo -e "\n${GREEN}--- 部署 go2rtc ---${RESET}"; local name="go2rtc"
    if [ -n "$(read_state ${name})" ]; then echo -e "${RED}❌ go2rtc 已部署。${RESET}"; press_any_key; return; fi
    local image="alexxit/go2rtc:latest"; echo -e "${CYAN}镜像: ${YELLOW}${image}${RESET}"
    read -p "配置文件路径 [/root/go2rtc.yml]: " CONFIG_FILE; CONFIG_FILE=${CONFIG_FILE:-/root/go2rtc.yml}
    local go2rtc_port=$(prompt_for_port "go2rtc" 1984)

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${CYAN}---摄像头配置 (可添加多个)---${RESET}"
        local streams_yaml=""
        while true; do
            read -p "为此摄像头流命名 (如 living_room): " stream_name; [ -z "$stream_name" ] && continue
            read -p "输入摄像头RTSP地址: " rtsp_url; [ -z "$rtsp_url" ] && continue
            streams_yaml+=$(printf "\n  %s: %s" "$stream_name" "$rtsp_url")
            read -p "是否继续添加下一个？[y/N]: " add_more; if [[ ! "$add_more" =~ [yY] ]]; then break; fi
        done
        echo "streams:${streams_yaml}" > "$CONFIG_FILE"
        echo -e "${GREEN}✅ 配置文件已生成于 ${CONFIG_FILE}${RESET}"
    else
        echo -e "${YELLOW}⚠️ 检测到已有配置文件 ${CONFIG_FILE}，将直接使用。${RESET}"
    fi

    echo -e "${CYAN}🚀 启动中...${RESET}"
    docker run -d --name ${name} --restart=always -p ${go2rtc_port}:1984 -p 8555:8555/udp -v "${CONFIG_FILE}":/config.yml ${image}
    if [ $? -eq 0 ]; then get_host_ip; write_state $name $CONFIG_FILE; echo -e "\n${GREEN}✅ 部署成功！\n${BLUE}📢 Web UI: ${GREEN}http://${HOST_IP}:${go2rtc_port}${RESET}"; else echo -e "\n${RED}❌ 失败。${RESET}"; fi
    press_any_key
}


# --- 管理逻辑 ---
scan_network() { clear; echo -e "${BLUE}📡 扫描摄像头${RESET}..."; sleep 1; press_any_key; } # 省略，与v5.2一致

uninstall_menu() {
    clear; echo -e "${YELLOW}🗑️ 卸载服务${RESET}"; get_installed_services
    if [ ${#INSTALLED_SERVICES[@]} -eq 0 ]; then echo -e "${YELLOW}⚠️ 无已安装服务。${RESET}"; press_any_key; return; fi
    echo "选择要卸载的服务:"; for i in "${!INSTALLED_SERVICES[@]}"; do echo "$((i+1)). ${PROJECTS[${INSTALLED_SERVICES[$i]}]}"; done; echo "$(( ${#INSTALLED_SERVICES[@]} + 1 )). 返回"; read -p "选择: " choice
    if [[ "$choice" -gt 0 && "$choice" -le "${#INSTALLED_SERVICES[@]}" ]]; then
        local service_name=${INSTALLED_SERVICES[$((choice-1))]}
        read -p "$(echo -e ${RED}"确定卸载 ${service_name}？[y/N]: "${RESET})" confirm
        if [[ "$confirm" =~ [yY] ]]; then
            docker rm -f "$service_name" &>/dev/null; echo -e "${GREEN}✅ ${service_name} 已移除。${RESET}"
            read -p "删除其配置和数据？[y/N]: " del_data
            if [[ "$del_data" =~ [yY] ]]; then rm -rf "$(read_state "$service_name")"; remove_state "$service_name"; echo -e "${GREEN}✅ 数据已删除。${RESET}"; fi
        fi
    fi
    press_any_key
}

update_menu() {
    clear; echo -e "${BLUE}🔄 更新服务${RESET}"; get_installed_services
    if [ ${#INSTALLED_SERVICES[@]} -eq 0 ]; then echo -e "${YELLOW}⚠️ 无已安装服务。${RESET}"; press_any_key; return; fi
    echo "选择要更新的服务 (将拉取最新镜像并重建容器):"; for i in "${!INSTALLED_SERVICES[@]}"; do echo "$((i+1)). ${PROJECTS[${INSTALLED_SERVICES[$i]}]}"; done; echo "$(( ${#INSTALLED_SERVICES[@]} + 1 )). 返回"; read -p "选择: " choice
    if [[ "$choice" -gt 0 && "$choice" -le "${#INSTALLED_SERVICES[@]}" ]]; then
        local service_name=${INSTALLED_SERVICES[$((choice-1))]}
        echo -e "${CYAN}正在更新 ${service_name}...${RESET}"
        local config_path=$(read_state "$service_name")
        if [[ "$service_name" == "frigate" ]]; then
            docker-compose -f "${config_path}/docker-compose.yml" pull && docker-compose -f "${config_path}/docker-compose.yml" up -d
        else
            local image=$(docker inspect --format='{{.Config.Image}}' $service_name)
            docker pull "$image" && docker rm -f "$service_name"
            # 重新部署
            if [[ "$service_name" == "shinobi" ]]; then deploy_shinobi;
            elif [[ "$service_name" == "go2rtc" ]]; then deploy_go2rtc;
            fi
        fi
        echo -e "${GREEN}✅ ${service_name} 更新完成！${RESET}"
    fi
    press_any_key
}

status_menu() { clear; echo -e "${BLUE}🔍 查看状态${RESET}"; get_installed_services; if [ ${#INSTALLED_SERVICES[@]} -eq 0 ]; then echo -e "${YELLOW}⚠️ 无已安装服务。${RESET}"; press_any_key; return; fi; echo -e "${GREEN}当前服务状态:${RESET}"; docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | { read -r header; echo -e "${YELLOW}$header${RESET}"; grep -E "$(IFS="|"; echo "${INSTALLED_SERVICES[*]}")" || echo -e "${YELLOW}无正在运行的服务。${RESET}"; }; press_any_key; }
manage_menu() { clear; echo -e "${CYAN}⚙️ 管理服务${RESET}"; get_installed_services; if [ ${#INSTALLED_SERVICES[@]} -eq 0 ]; then echo -e "${YELLOW}⚠️ 无已安装服务。${RESET}"; press_any_key; return; fi; echo "选择要管理的服务:"; for i in "${!INSTALLED_SERVICES[@]}"; do echo "$((i+1)). ${PROJECTS[${INSTALLED_SERVICES[$i]}]}"; done; echo "$(( ${#INSTALLED_SERVICES[@]} + 1 )). 返回"; read -p "选择: " choice; if [[ "$choice" -gt 0 && "$choice" -le "${#INSTALLED_SERVICES[@]}" ]]; then local CONTAINER=${INSTALLED_SERVICES[$((choice-1))]}; echo "操作: 1.启动 2.停止 3.重启 4.日志"; read -p "选择[1-4]: " op; case $op in 1) docker start "$CONTAINER";; 2) docker stop "$CONTAINER";; 3) docker restart "$CONTAINER";; 4) docker logs -f "$CONTAINER";; esac; fi; press_any_key; }

# --- 主菜单与主逻辑 ---
main_menu() {
    clear
    echo -e "${BLUE}==========================================${RESET}"
    echo -e "      ${GREEN}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}"
    echo -e "      ${CYAN}System Arch: ${HOST_ARCH} | Pkg Manager: ${PKG_MANAGER}${RESET}"
    echo -e "${BLUE}==========================================${RESET}"
    echo -e " 1. ${GREEN}部署 NVR 服务${RESET}"
    echo -e " 2. ${BLUE}更新 NVR 服务${RESET}"
    echo -e " 3. ${CYAN}扫描 局域网摄像头${RESET}"
    echo -e " 4. ${RED}卸载 NVR 服务${RESET}"
    echo -e " 5. ${YELLOW}管理 NVR 服务${RESET} (启/停/日志)"
    echo -e " 6. ${BLUE}查看 运行状态${RESET}"
    echo -e " 7. ${RED}退出 脚本${RESET}"
    echo -e "${BLUE}==========================================${RESET}"
}

main() {
    check_root; clear; echo "正在初始化和检查环境..."; sleep 1
    detect_pkg_manager
    check_dependency "docker"
    check_dependency "docker-compose"
    check_dependency "nmap"
    get_host_arch
    
    while true; do
        main_menu
        read -p "请输入您的选择 [1-7]: " CHOICE
        case $CHOICE in
            1) deploy_menu ;; 2) update_menu ;; 3) scan_network ;;
            4) uninstall_menu ;; 5) manage_menu ;; 6) status_menu ;;
            7) echo -e "${GREEN}👋 感谢使用！${RESET}"; exit 0 ;;
            *) echo -e "${RED}❌ 无效选择。${RESET}"; sleep 1 ;;
        esac
    done
}

# --- 脚本入口 ---
main
