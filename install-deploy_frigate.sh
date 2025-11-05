#!/bin/bash
# --- 配置区 ---
SCRIPT_NAME="Frigate NVR 终极部署管理器"
SCRIPT_VERSION="3.0"
CONTAINER_NAME="frigate"
IMAGE_NAME="ghcr.io/blakeblackshear/frigate:stable"
DEFAULT_CONFIG_DIR="/root/frigate_config"
FRIGATE_WEB_PORT=5000 # Frigate WebUI 端口

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

# --- 辅助函数 ---
check_root() {
    if [ "$(id -u)" != "0" ]; then
       echo -e "${RED}错误: 请使用 'sudo ./deploy_frigate_v3.sh' 以root权限运行此脚本。${RESET}" 1>&2
       exit 1
    fi
}

get_host_ip() {
    HOST_IP=$(hostname -I | awk '{print $1}')
}

check_dependency() {
    local dep_name=$1
    local install_cmd=$2
    if ! command -v $dep_name &> /dev/null; then
        echo -e "${YELLOW}⚠️ 未检测到 ${dep_name}，尝试自动安装...${RESET}"
        if eval $install_cmd; then
            echo -e "${GREEN}✅ ${dep_name} 安装成功。${RESET}"
        else
            echo -e "${RED}❌ ${dep_name} 安装失败，请手动安装后重试。${RESET}"
            exit 1
        fi
    fi
}

# --- 核心功能函数 ---

# 1. 扫描局域网摄像头
scan_network() {
    clear
    echo -e "${BLUE}📡 扫描局域网摄像头${RESET}"
    echo "--------------------------------------"
    echo "本功能将使用 nmap 扫描您指定的网段，"
    echo "寻找可能开放了摄像头常用端口的设备。"
    echo -e "${YELLOW}请记下扫描到的IP地址和端口，用于后续部署。${RESET}"
    echo ""

    DEFAULT_SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -1)
    read -p "请输入要扫描的网段 [默认: ${DEFAULT_SUBNET}]: " SUBNET
    SUBNET=${SUBNET:-$DEFAULT_SUBNET}

    echo -e "${CYAN}🚀 正在扫描网段 ${SUBNET} ... (这可能需要1-2分钟)${RESET}"
    
    # 使用nmap扫描常见的摄像头端口: 80(HTTP), 554(RTSP), 8000(海康), 37777(大华), 5544, 8099(ONVIF)
    SCAN_RESULTS=$(nmap -p 80,554,8000,37777,5544,8099 --open ${SUBNET} -oG - | awk '/Up$/{print $2, $4}')

    if [ -z "$SCAN_RESULTS" ]; then
        echo -e "${RED}❌ 在网段 ${SUBNET} 未发现开放了常见摄像头端口的设备。${RESET}"
        echo "请确认您的摄像头已连接网络，或尝试扫描其他网段。"
    else
        echo -e "${GREEN}✅ 扫描完成！发现以下潜在设备：${RESET}"
        echo "--------------------------------------"
        echo -e "${YELLOW}IP 地址\t\t开放的端口${RESET}"
        echo "$SCAN_RESULTS" | while read -r ip ports; do
            printf "%-16s\t%s\n" "$ip" "$(echo $ports | sed 's|/tcp(open)|,|g' | sed 's/,$//')"
        done
        echo "--------------------------------------"
        echo "常见的RTSP端口是 ${GREEN}554${RESET} 或 ${GREEN}5544${RESET}。"
    fi

    read -n1 -p "按任意键返回主菜单..."
}


# 2. 部署 Frigate
deploy_frigate() {
    clear
    echo -e "${GREEN}🚀 Frigate 容器部署${RESET}"
    echo "--------------------------------------"

    # ... 省略检查容器是否存在的代码，保留与v2版本一致 ...

    # --- 交互式获取配置 ---
    echo -e "${CYAN}--- 步骤 1: 设置存储目录 ---${RESET}"
    # ... 省略获取存储路径的代码，保留与v2版本一致 ...
    while true; do
        read -p "请输入用于存储录像的绝对路径 (默认: ${DEFAULT_CONFIG_DIR}): " STORAGE_PATH
        STORAGE_PATH=${STORAGE_PATH:-$DEFAULT_CONFIG_DIR}
        if [[ "$STORAGE_PATH" != /* ]]; then echo -e "${RED}❌ 请输入一个以'/'开头的绝对路径。${RESET}"; continue; fi
        if [ ! -d "$STORAGE_PATH" ]; then
            read -p "$(echo -e ${YELLOW}"目录 '${STORAGE_PATH}' 不存在，是否创建？[y/N]: "${RESET})" create_dir
            if [[ "$create_dir" =~ [yY] ]]; then mkdir -p "$STORAGE_PATH" || { echo -e "${RED}创建目录失败!${RESET}"; exit 1; }; echo -e "${GREEN}✅ 目录 '${STORAGE_PATH}' 已创建。${RESET}"; break; fi
        else echo -e "${GREEN}✅ 将使用现有目录 '${STORAGE_PATH}'。${RESET}"; break; fi
    done
    echo ""

    echo -e "${CYAN}--- 步骤 2: 配置您的摄像头信息 ---${RESET}"
    echo -e "${YELLOW}提示: 如果不清楚IP和端口，可先返回主菜单使用“扫描”功能。${RESET}"

    read -p "请输入摄像头的IP地址: " CAM_IP
    while [ -z "$CAM_IP" ]; do read -p "${RED}IP地址不能为空，请重新输入: ${RESET}" CAM_IP; done
    
    read -p "请输入登录用户名 [默认: admin]: " CAM_USER
    CAM_USER=${CAM_USER:-admin}
    
    read -p "请输入登录密码 [默认: 无密码]: " CAM_PASS
    
    read -p "请输入RTSP端口 [默认: 554]: " CAM_PORT
    CAM_PORT=${CAM_PORT:-554}

    echo ""
    echo "请选择一个适合您摄像头的RTSP路径模板:"
    echo " 1) /stream1                              (通用或雄迈方案)"
    echo " 2) /ch1/main/av_stream                   (海康威视 Hikvision)"
    echo " 3) /cam/realmonitor?channel=1&subtype=0  (大华 Dahua)"
    echo " 4) /onvif1                               (通用ONVIF)"
    echo " 5) 我要手动输入"

    read -p "请选择 [1-5]: " PATH_CHOICE
    case $PATH_CHOICE in
        1) CAM_PATH="/stream1" ;;
        2) CAM_PATH="/ch1/main/av_stream" ;;
        3) CAM_PATH="/cam/realmonitor?channel=1&subtype=0" ;;
        4) CAM_PATH="/onvif1" ;;
        5) read -p "请输入完整的RTSP路径 (以'/'开头): " CAM_PATH ;;
        *) echo "无效选择，将使用默认模板 /stream1"; CAM_PATH="/stream1" ;;
    esac

    # 动态构建RTSP地址
    if [ -n "$CAM_PASS" ]; then
        RTSP_URL="rtsp://${CAM_USER}:${CAM_PASS}@${CAM_IP}:${CAM_PORT}${CAM_PATH}"
    else
        RTSP_URL="rtsp://${CAM_USER}@${CAM_IP}:${CAM_PORT}${CAM_PATH}"
    fi

    echo -e "${GREEN}--------------------------------------${RESET}"
    echo -e "${GREEN}✅ 将使用以下RTSP地址进行连接:${RESET}"
    echo -e "${YELLOW}${RTSP_URL}${RESET}"
    echo -e "${GREEN}--------------------------------------${RESET}"
    read -p "确认无误请按回车继续..."

    # ... 后续生成配置文件和启动容器的代码与v2版本完全一致 ...
    echo -e "${CYAN}🔧 正在生成配置文件...${RESET}"
    CONFIG_PATH="$STORAGE_PATH/config"
    MEDIA_PATH="$STORAGE_PATH/media"
    COMPOSE_FILE="$STORAGE_PATH/docker-compose.yml"
    
    mkdir -p "$CONFIG_PATH"; mkdir -p "$MEDIA_PATH"

    cat > "$COMPOSE_FILE" << EOF
version: "3.9"
services:
  frigate:
    container_name: ${CONTAINER_NAME}
    privileged: true
    restart: unless-stopped
    image: ${IMAGE_NAME}
    shm_size: "64mb"
    volumes:
      - ${CONFIG_PATH}:/config
      - ${MEDIA_PATH}:/media/frigate
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "${FRIGATE_WEB_PORT}:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
EOF

    cat > "$CONFIG_PATH/config.yml" << EOF
mqtt:
  enabled: False
cameras:
  ${CAM_IP//./_}: # 使用IP地址作为摄像头名称，安全且唯一
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
    
    echo -e "${GREEN}✅ 配置文件已生成于 '${STORAGE_PATH}'。${RESET}"
    echo -e "${CYAN}🚀 正在启动 Frigate 服务...${RESET}"
    docker-compose -f "$COMPOSE_FILE" up -d
    
    if [ $? -eq 0 ]; then
        get_host_ip
        echo -e "\n${GREEN}✅ Frigate 部署成功！${RESET}"
        echo -e "\n${BLUE}📢 访问信息：${RESET}"
        echo -e "Web 管理界面: ${GREEN}http://${HOST_IP}:${FRIGATE_WEB_PORT}${RESET}"
    else
        echo -e "\n${RED}❌ 部署失败。请使用管理菜单中的“查看日志”功能排查问题。${RESET}"
    fi

    read -n1 -p "按任意键返回主菜单..."
}

# 3. 卸载 Frigate (与v2一致)
uninstall_frigate() {
    # 代码与v2版本完全一致，此处省略以保持简洁
    clear; echo -e "${YELLOW}🗑️ 卸载 Frigate 容器${RESET}"; echo "--------------------------------------"
    read -p "请输入Frigate配置文件所在目录 (默认: ${DEFAULT_CONFIG_DIR}): " STORAGE_PATH; STORAGE_PATH=${STORAGE_PATH:-$DEFAULT_CONFIG_DIR}
    COMPOSE_FILE="$STORAGE_PATH/docker-compose.yml"
    if [ -f "$COMPOSE_FILE" ]; then
        docker-compose -f "$COMPOSE_FILE" down; echo -e "${GREEN}✅ 容器已移除。${RESET}"
        read -p "$(echo -e ${YELLOW}"是否删除所有配置文件和录像数据？[y/N]: "${RESET})" DEL_CHOICE
        if [[ "$DEL_CHOICE" =~ [yY] ]]; then rm -rf "$STORAGE_PATH"; echo -e "${GREEN}✅ 数据目录 '${STORAGE_PATH}' 已删除。${RESET}"; fi
    else echo -e "${RED}⚠️ 在 '${STORAGE_PATH}' 未找到配置文件。${RESET}"; fi
    read -n1 -p "按任意键返回主菜单..."
}

# 4. 查看状态 (与v2一致)
show_status() {
    # 代码与v2版本完全一致，此处省略
    clear; echo -e "${BLUE}🔍 Frigate 状态查看${RESET}"; echo "--------------------------------------"
    read -p "请输入Frigate配置文件所在目录 (默认: ${DEFAULT_CONFIG_DIR}): " STORAGE_PATH; STORAGE_PATH=${STORAGE_PATH:-$DEFAULT_CONFIG_DIR}
    COMPOSE_FILE="$STORAGE_PATH/docker-compose.yml"
    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "配置文件: ${YELLOW}${COMPOSE_FILE}${RESET}"; docker-compose -f "$COMPOSE_FILE" ps; get_host_ip
        echo -e "\n${BLUE}📢 Web 访问: ${GREEN}http://${HOST_IP}:${FRIGATE_WEB_PORT}${RESET}"
    else echo -e "${YELLOW}⚠️ Frigate 未安装或配置文件路径不正确。${RESET}"; fi
    read -n1 -p "按任意键返回主菜单..."
}

# 5. 管理容器 (与v2一致)
manage_container() {
    # 代码与v2版本完全一致，此处省略
    clear; echo -e "${CYAN}⚙️ Frigate 容器管理${RESET}"; echo "--------------------------------------"
    read -p "请输入Frigate配置文件所在目录 (默认: ${DEFAULT_CONFIG_DIR}): " STORAGE_PATH; STORAGE_PATH=${STORAGE_PATH:-$DEFAULT_CONFIG_DIR}
    COMPOSE_FILE="$STORAGE_PATH/docker-compose.yml"
    if [ ! -f "$COMPOSE_FILE" ]; then echo -e "${YELLOW}⚠️ 配置文件路径不正确。${RESET}"; read -n1 -p "按任意键返回..."; return; fi
    echo "1.启动 2.停止 3.重启 4.查看日志 5.返回"; read -p "请选择[1-5]: " OP
    case $OP in
        1) docker-compose -f "$COMPOSE_FILE" start ;; 2) docker-compose -f "$COMPOSE_FILE" stop ;;
        3) docker-compose -f "$COMPOSE_FILE" restart ;; 4) docker-compose -f "$COMPOSE_FILE" logs -f ;;
        5) return ;; *) echo -e "${RED}❌ 无效输入。${RESET}" ;;
    esac
    read -n1 -p "按任意键继续..."
}


# 主菜单
main_menu() {
    clear
    echo -e "${BLUE}==========================================${RESET}"
    echo -e "      ${GREEN}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}"
    echo -e "${BLUE}==========================================${RESET}"
    echo -e " 1. ${CYAN}扫描${RESET} 局域网摄像头"
    echo -e " 2. ${GREEN}部署${RESET} 新的 Frigate 服务"
    echo -e " 3. ${RED}卸载${RESET} Frigate 服务"
    echo -e " 4. ${BLUE}查看${RESET} Frigate 运行状态"
    echo -e " 5. ${YELLOW}管理${RESET} Frigate 服务 (启/停/日志)"
    echo -e " 6. ${RED}退出${RESET} 脚本"
    echo -e "${BLUE}==========================================${RESET}"
}

# 主逻辑
main() {
    check_root
    
    echo "正在检查系统环境..."
    check_dependency "docker" "apt-get update && apt-get install -y docker.io"
    check_dependency "docker-compose" "apt-get install -y docker-compose"
    check_dependency "nmap" "apt-get install -y nmap"
    sleep 1
    
    while true; do
        main_menu
        read -p "请输入您的选择 [1-6]: " CHOICE

        case $CHOICE in
            1) scan_network ;;
            2) deploy_frigate ;;
            3) uninstall_frigate ;;
            4) show_status ;;
            5) manage_container ;;
            6) echo -e "${GREEN}👋 感谢使用，再见！${RESET}"; exit 0 ;;
            *) echo -e "${RED}❌ 无效选择，请重新输入。${RESET}"; sleep 1 ;;
        esac
    done
}

# --- 脚本入口 ---
main
