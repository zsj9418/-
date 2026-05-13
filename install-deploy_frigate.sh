#!/bin/bash

# ==============================================================================
# 全能 NVR 部署与运维平台 (Frigate / Shinobi / go2rtc)
# 版本: 5.0 终极融合版
# 特性: 动态硬件加速检测、智能端口防冲突、磁盘预警、多平台兼容、局域网探测
# ==============================================================================

SCRIPT_NAME="全能 NVR 部署与运维平台"
SCRIPT_VERSION="5.0 Pro"

# --- 默认全局变量 ---
declare -A PROJECTS
PROJECTS=(
    ["frigate"]="Frigate AI智能NVR"
    ["shinobi"]="Shinobi 全功能NVR"
    ["go2rtc"]="go2rtc 流媒体网关"
)

DEFAULT_FRIGATE_DIR="/opt/frigate"
DEFAULT_SHINOBI_DIR="/opt/shinobi"
DEFAULT_GO2RTC_DIR="/opt/go2rtc"
BACKUP_DIR="/opt/nvr_backups"

HOST_ARCH=""
HOST_IP=""
DOCKER_COMPOSE_CMD=""
INSTALL_CMD=""

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; RESET='\033[0m'

# ==========================================
# 底层系统与环境检查
# ==========================================

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo -e "${RED}[错误] 请使用 sudo 或 root 权限运行此脚本。${RESET}"
        exit 1
    fi
}

get_host_info() {
    HOST_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    [[ -z "$HOST_IP" ]] && HOST_IP="<获取失败>"
    HOST_ARCH=$(uname -m)
}

press_any_key() {
    echo ""
    read -n1 -s -r -p "按任意键返回菜单..."
    echo ""
}

detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        INSTALL_CMD="apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y"
    elif command -v yum &>/dev/null; then
        INSTALL_CMD="yum install -y"
    else
        echo -e "${RED}[错误] 不支持的系统发行版 (仅支持 Ubuntu/Debian/CentOS/RHEL)。${RESET}"
        exit 1
    fi
}

check_dependency() {
    local cmd=$1
    local pkg=$2
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${YELLOW}[系统] 未检测到 $cmd，正在自动安装...${RESET}"
        eval "$INSTALL_CMD $pkg" >/dev/null 2>&1
    fi
}

ensure_docker() {
    # 检测 Docker
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}[系统] 未检测到 Docker，正在使用官方脚本自动安装 (请耐心等待)...${RESET}"
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi
    
    # 启动检测
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        systemctl start docker || { echo -e "${RED}[错误] Docker 守护进程启动失败！${RESET}"; exit 1; }
    fi

    # 动态适配 Compose 插件
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo -e "${YELLOW}[系统] 未检测到 Docker Compose，正在安装插件...${RESET}"
        eval "$INSTALL_CMD docker-compose-plugin" >/dev/null 2>&1
        DOCKER_COMPOSE_CMD="docker compose"
    fi
}

set_docker_mirror() {
    clear
    echo -e "${CYAN}========================================${RESET}"
    echo -e "${CYAN}      配置 Docker 国内加速源            ${RESET}"
    echo -e "${CYAN}========================================${RESET}"
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://hub-mirror.c.163.com",
    "https://docker.mirrors.sjtug.sjtu.edu.cn"
  ]
}
EOF
    systemctl daemon-reload
    systemctl restart docker
    echo -e "${GREEN}[成功] Docker 加速源配置完成，已重启 Docker 服务。${RESET}"
    echo -e "${YELLOW}如果之前部署拉取镜像卡住，请现在重新尝试部署。${RESET}"
    press_any_key
}

# ==========================================
# 辅助工具包
# ==========================================

check_port() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 1 # 被占用
    else
        return 0 # 可用
    fi
}

show_logs_on_failure() {
    local container=$1
    echo -e "\n${RED}>>> 容器启动失败，显示最后 15 行错误日志：${RESET}"
    echo "---------------------------------------------------"
    docker logs --tail 15 "$container" 2>/dev/null || echo -e "${YELLOW}无日志可用。${RESET}"
    echo "---------------------------------------------------"
}

get_installed_containers() {
    INSTALLED_CONTAINERS=()
    for name in "${!PROJECTS[@]}"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
            INSTALLED_CONTAINERS+=("$name")
        fi
    done
}

# ==========================================
# 核心部署模块
# ==========================================

deploy_shinobi() {
    clear
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}      部署 Shinobi (全功能监控 NVR)      ${RESET}"
    echo -e "${GREEN}========================================${RESET}"

    if docker ps -a --format '{{.Names}}' | grep -q "^shinobi$"; then
        echo -e "${RED}[提示] Shinobi 容器已存在，请先卸载或使用管理菜单。${RESET}"
        press_any_key; return
    fi

    # 1. 镜像选择防故障
    echo -e "\n${CYAN}[步骤 1/3] 选择镜像版本${RESET}"
    echo "1) 官方最新镜像 (shinobisystems/shinobi) - 推荐标准 x86 服务器"
    echo "2) 社区兼容镜像 (migoller/shinobi) - 推荐 ARM 设备、树莓派，或官方镜像报错时备用"
    read -p "请输入选择 [1-2, 默认1]: " img_choice
    local image="registry.gitlab.com/shinobi-systems/shinobi:dev"
    [[ "$img_choice" == "2" ]] && image="migoller/shinobi:latest"
    echo -e "${GREEN}--> 已选择镜像: $image${RESET}"

    # 2. 端口防冲突
    echo -e "\n${CYAN}[步骤 2/3] 配置 Web 访问端口${RESET}"
    local port=8080
    while true; do
        if check_port "$port"; then
            echo -e "${GREEN}--> 端口 $port 检查可用。${RESET}"
            break
        else
            echo -e "${YELLOW}[警告] 端口 $port 已被系统其他服务占用！${RESET}"
            read -p "请输入一个新的可用端口号 (例如 8888, 8081): " input_port
            if [[ "$input_port" =~ ^[0-9]+$ ]]; then
                port=$input_port
            fi
        fi
    done

    # 3. 存储与磁盘预警
    echo -e "\n${CYAN}[步骤 3/3] 配置录像存储路径${RESET}"
    read -p "请输入录像保存目录 (直接回车默认: $DEFAULT_SHINOBI_DIR): " path
    path=${path:-$DEFAULT_SHINOBI_DIR}
    mkdir -p "$path/videos" "$path/config"
    chmod -R 777 "$path"
    
    local avail_space=$(df -BG "$path" | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ "$avail_space" -lt 10 ]; then
        echo -e "${RED}[警告] 目标磁盘剩余空间不足 10GB (${avail_space}GB)！录像极易写满导致宕机！${RESET}"
        read -p "您确定要继续部署吗？[y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "已取消部署。"; press_any_key; return; }
    fi

    # 生成配置文件
    local super_pass=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
    cat > "$path/docker-compose.yml" << EOF
version: '3.8'
services:
  shinobi:
    image: $image
    container_name: shinobi
    restart: unless-stopped
    ports:
      - "$port:8080"
    volumes:
      - ./config:/config
      - ./videos:/home/Shinobi/videos
      - /dev/shm:/dev/shm
    environment:
      - ADMIN_USER=admin@shinobi.video
      - ADMIN_PASSWORD=$super_pass
      - TZ=Asia/Shanghai
EOF

    echo -e "\n${BLUE}正在拉取镜像并启动容器... (如果下载卡住，请按 Ctrl+C，去主菜单选4配置加速源)${RESET}"
    cd "$path"
    if $DOCKER_COMPOSE_CMD up -d; then
        echo -e "${CYAN}--> 等待内部数据库初始化 (约20秒)...${RESET}"
        sleep 20
        echo -e "\n${GREEN}========================================${RESET}"
        echo -e "${GREEN}      Shinobi 部署成功!                 ${RESET}"
        echo -e "${GREEN}========================================${RESET}"
        echo -e "${BLUE}访问地址: ${GREEN}http://$HOST_IP:$port/super${RESET}"
        echo -e "${BLUE}超级账号: ${YELLOW}admin@shinobi.video${RESET}"
        echo -e "${BLUE}初始密码: ${YELLOW}$super_pass${RESET}"
        echo -e "${RED}(安全提示: 请立即登录并修改密码)${RESET}"
    else
        show_logs_on_failure "shinobi"
    fi
    press_any_key
}

deploy_frigate() {
    clear
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}      部署 Frigate (AI 智能识别 NVR)     ${RESET}"
    echo -e "${GREEN}========================================${RESET}"

    if docker ps -a --format '{{.Names}}' | grep -q "^frigate$"; then
        echo -e "${RED}[提示] Frigate 容器已存在。${RESET}"; press_any_key; return
    fi
    if ! check_port 5000; then echo -e "${YELLOW}[警告] Frigate 需要的 5000 端口已被占用！部署可能失败。${RESET}"; fi

    read -p "请输入存储目录 (直接回车默认: $DEFAULT_FRIGATE_DIR): " path
    path=${path:-$DEFAULT_FRIGATE_DIR}
    mkdir -p "$path/config" "$path/media"
    
    # 动态检测硬件加速 (解决无核显设备崩溃痛点)
    local hw_accel=""
    if [ -d "/dev/dri" ]; then
        echo -e "${GREEN}--> 检测到 /dev/dri，已为您自动启用显卡硬件加速。${RESET}"
        hw_accel="    devices:\n      - /dev/dri:/dev/dri"
    else
        echo -e "${YELLOW}--> 未检测到显卡设备，将使用 CPU 进行处理。${RESET}"
    fi

    cat > "$path/docker-compose.yml" << EOF
version: "3.9"
services:
  frigate:
    container_name: frigate
    privileged: true
    restart: unless-stopped
    image: ghcr.io/blakeblackshear/frigate:stable
    shm_size: 128mb
$(echo -e "$hw_accel")
    volumes:
      - ./config:/config
      - ./media:/media/frigate
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
EOF

    # 初始化配置以防无法启动
    if [ ! -f "$path/config/config.yml" ]; then
        cat > "$path/config/config.yml" << 'EOF'
mqtt: {enabled: false}
detectors:
  cpu1:
    type: cpu
cameras:
  dummy_camera: # 示例占位符，请在此处修改你的真实RTSP流
    ffmpeg:
      inputs:
        - path: rtsp://admin:password@192.168.1.100:554/stream1
          roles:
            - detect
            - record
EOF
    fi

    echo -e "\n${BLUE}正在拉取镜像并启动容器...${RESET}"
    cd "$path"
    if $DOCKER_COMPOSE_CMD up -d; then
        echo -e "\n${GREEN}[成功] Frigate 部署成功！${RESET}"
        echo -e "配置文件位置: ${YELLOW}$path/config/config.yml${RESET} (添加摄像头后需重启容器)"
        echo -e "访问地址: ${GREEN}http://$HOST_IP:5000${RESET}"
    else
        show_logs_on_failure "frigate"
    fi
    press_any_key
}

deploy_go2rtc() {
    clear
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}      部署 go2rtc (低延迟流媒体网关)     ${RESET}"
    echo -e "${GREEN}========================================${RESET}"

    if docker ps -a --format '{{.Names}}' | grep -q "^go2rtc$"; then
        echo -e "${RED}[提示] go2rtc 容器已存在。${RESET}"; press_any_key; return
    fi

    read -p "请输入存储目录 (直接回车默认: $DEFAULT_GO2RTC_DIR): " path
    path=${path:-$DEFAULT_GO2RTC_DIR}
    mkdir -p "$path"
    
    if [ ! -f "$path/go2rtc.yaml" ]; then
        echo -e "api:\n  port: 1984\nstreams:\n  cam1:\n    - rtsp://user:pass@ip:554/stream" > "$path/go2rtc.yaml"
    fi

    cat > "$path/docker-compose.yml" << EOF
version: '3.8'
services:
  go2rtc:
    image: alexxit/go2rtc:latest
    container_name: go2rtc
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./go2rtc.yaml:/config/go2rtc.yaml
EOF

    echo -e "\n${BLUE}正在启动容器...${RESET}"
    cd "$path"
    if $DOCKER_COMPOSE_CMD up -d; then
        echo -e "\n${GREEN}[成功] go2rtc 部署成功！${RESET}"
        echo -e "访问地址: ${GREEN}http://$HOST_IP:1984${RESET} (使用 host 网络模式，无需映射端口)"
    else
        show_logs_on_failure "go2rtc"
    fi
    press_any_key
}

# ==========================================
# 运维与工具模块
# ==========================================

scan_network() {
    clear
    check_dependency "nmap" "nmap"
    echo -e "${BLUE}========================================${RESET}"
    echo -e "${BLUE}      局域网摄像头嗅探器 (RTSP)         ${RESET}"
    echo -e "${BLUE}========================================${RESET}"
    
    local default_subnet=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | grep -v '127.0.0.1' | head -1)
    read -p "请输入要扫描的网段 (直接回车默认: $default_subnet): " subnet
    subnet=${subnet:-$default_subnet}

    echo -e "\n${CYAN}正在全速扫描 $subnet，这可能需要几十秒，请稍候...${RESET}"
    
    # 仅探测 NVR 常见端口，提升扫描速度
    local raw=$(nmap -p 80,554,8000,37777,5544,8099 --open "$subnet" -oG - 2>/dev/null)
    local results=$(echo "$raw" | awk '/Ports:/ {
        ip=$2; 
        for(i=4; i<=NF; i++) {
            if($i ~ /open/) {
                split($i, a, "/"); 
                print ip " " a[1]
            }
        }
    }' | sort -u)

    if [ -z "$results" ]; then
        echo -e "${RED}[结果] 未在该网段发现开放相关端口的设备。${RESET}"
    else
        echo -e "\n${GREEN}扫描完成！发现以下潜在的摄像头/NVR设备：${RESET}"
        echo "------------------------------------------------"
        echo -e "${YELLOW}IP 地址          开放端口及设备推测${RESET}"
        echo "------------------------------------------------"
        echo "$results" | while read -r ip port; do
            if [[ "$port" == "554" || "$port" == "5544" ]]; then
                printf "%-16s ${GREEN}%s (标准 RTSP 视频流)${RESET}\n" "$ip" "$port"
            elif [[ "$port" == "37777" ]]; then
                printf "%-16s ${CYAN}%s (大华 Dahua 私有端口)${RESET}\n" "$ip" "$port"
            elif [[ "$port" == "8000" ]]; then
                printf "%-16s ${CYAN}%s (海康 Hikvision 私有端口)${RESET}\n" "$ip" "$port"
            else
                printf "%-16s ${YELLOW}%s (可能是 Web 面板)${RESET}\n" "$ip" "$port"
            fi
        done
        echo "------------------------------------------------"
    fi
    press_any_key
}

manage_and_backup() {
    clear
    echo -e "${CYAN}========================================${RESET}"
    echo -e "${CYAN}      服务管理与备份中心                ${RESET}"
    echo -e "${CYAN}========================================${RESET}"
    
    get_installed_containers
    if [[ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}当前未检测到任何由本脚本管理的 NVR 服务运行。${RESET}"
        press_any_key; return
    fi

    echo -e "${GREEN}当前系统中的容器列表:${RESET}"
    for i in "${!INSTALLED_CONTAINERS[@]}"; do
        echo " - ${INSTALLED_CONTAINERS[$i]} (${PROJECTS[${INSTALLED_CONTAINERS[$i]}]})"
    done
    echo "----------------------------------------"
    echo "1. 启动容器"
    echo "2. 停止容器"
    echo "3. 重启容器"
    echo "4. 实时查看容器日志 (按 Ctrl+C 退出)"
    echo "5. 一键打包备份所有 NVR 配置文件"
    echo "0. 返回主菜单"
    echo "----------------------------------------"
    read -p "请选择操作 [0-5]: " op

    if [[ "$op" == "5" ]]; then
        echo -e "\n${BLUE}正在执行备份...${RESET}"
        mkdir -p "$BACKUP_DIR"
        local timestamp=$(date +"%Y%m%d_%H%M%S")
        
        [ -d "$DEFAULT_SHINOBI_DIR/config" ] && { tar -czf "$BACKUP_DIR/shinobi_cfg_$timestamp.tar.gz" -C "$DEFAULT_SHINOBI_DIR" config; echo -e "${GREEN}[成功] Shinobi 配置已备份!${RESET}"; }
        [ -d "$DEFAULT_FRIGATE_DIR/config" ] && { tar -czf "$BACKUP_DIR/frigate_cfg_$timestamp.tar.gz" -C "$DEFAULT_FRIGATE_DIR" config; echo -e "${GREEN}[成功] Frigate 配置已备份!${RESET}"; }
        [ -f "$DEFAULT_GO2RTC_DIR/go2rtc.yaml" ] && { cp "$DEFAULT_GO2RTC_DIR/go2rtc.yaml" "$BACKUP_DIR/go2rtc_$timestamp.yaml"; echo -e "${GREEN}[成功] go2rtc 配置已备份!${RESET}"; }
        
        echo -e "所有备份文件存放在: ${YELLOW}$BACKUP_DIR${RESET}"
        press_any_key
        return
    elif [[ "$op" =~ ^[1-4]$ ]]; then
        read -p "请输入要操作的容器名称 (如 shinobi, frigate): " name
        if ! docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
            echo -e "${RED}[错误] 找不到容器 $name ${RESET}"; press_any_key; return
        fi
        
        case $op in
            1) docker start "$name" && echo -e "${GREEN}已启动 $name${RESET}" ;;
            2) docker stop "$name" && echo -e "${GREEN}已停止 $name${RESET}" ;;
            3) docker restart "$name" && echo -e "${GREEN}已重启 $name${RESET}" ;;
            4) echo -e "${BLUE}>> 正在输出日志，按 Ctrl+C 退出...${RESET}"; docker logs -f "$name" ;;
        esac
    fi
    press_any_key
}

uninstall_menu() {
    clear
    echo -e "${RED}========================================${RESET}"
    echo -e "${RED}      服务安全卸载                      ${RESET}"
    echo -e "${RED}========================================${RESET}"
    
    get_installed_containers
    if [[ ${#INSTALLED_CONTAINERS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}当前未检测到任何服务。${RESET}"; press_any_key; return
    fi

    echo "发现以下服务:"
    for i in "${!INSTALLED_CONTAINERS[@]}"; do
        echo "$((i+1)). ${INSTALLED_CONTAINERS[$i]} (${PROJECTS[${INSTALLED_CONTAINERS[$i]}]})"
    done
    echo "$(( ${#INSTALLED_CONTAINERS[@]} + 1 )). 取消并返回"
    
    read -p "请选择要卸载的服务编号: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#INSTALLED_CONTAINERS[@]}" ]; then
        local name=${INSTALLED_CONTAINERS[$((choice-1))]}
        read -p "确定要彻底停止并删除容器 [$name] 吗？[y/N]: " confirm1
        if [[ "$confirm1" =~ ^[Yy]$ ]]; then
            docker rm -f "$name" >/dev/null 2>&1
            echo -e "${GREEN}[成功] 容器 $name 已被删除。${RESET}"
            
            echo -e "${YELLOW}警告: 接下来将询问是否删除配置和所有录像文件！${RESET}"
            read -p "是否同步删除配置目录和关联的录像文件？(不可恢复!) [y/N]: " confirm2
            if [[ "$confirm2" =~ ^[Yy]$ ]]; then
                case $name in
                    frigate) rm -rf "$DEFAULT_FRIGATE_DIR" ;;
                    shinobi) rm -rf "$DEFAULT_SHINOBI_DIR" ;;
                    go2rtc) rm -rf "$DEFAULT_GO2RTC_DIR" ;;
                esac
                echo -e "${GREEN}[成功] 相关数据已彻底清理。${RESET}"
            else
                echo -e "${BLUE}[提示] 配置文件和录像已为您保留在硬盘上。${RESET}"
            fi
        fi
    fi
    press_any_key
}

# ==========================================
# 主程序入口
# ==========================================

main_menu() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "  ${GREEN}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}"
    echo -e "  ${CYAN}本机 IP: ${HOST_IP} | 架构: ${HOST_ARCH}${RESET}"
    echo -e "${BLUE}╠══════════════════════════════════════════════╣${RESET}"
    echo -e "  1. ${GREEN}🚀 部署监控服务${RESET} (Frigate / Shinobi / go2rtc)"
    echo -e "  2. ${CYAN}📡 扫描局域网摄像头${RESET} (自动寻找 RTSP 端口)"
    echo -e "  3. ${YELLOW}⚙️  服务管理与备份${RESET} (启停、日志、打包配置)"
    echo -e "  4. ${RED}🗑️  卸载服务${RESET} (完全清理)"
    echo -e "  5. ${BLUE}⚡ 修复环境${RESET} (一键配置 Docker 国内加速源)"
    echo -e "  0. ${RED}❌ 退出脚本${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════════════╝${RESET}"
}

main() {
    # 初始化环境
    check_root
    echo -e "${CYAN}正在初始化环境并检查系统依赖，请稍候...${RESET}"
    get_host_info
    detect_package_manager
    ensure_docker

    # 主循环
    while true; do
        main_menu
        read -p "请输入操作序号 [0-5]: " CHOICE
        case $CHOICE in
            1)  
                clear
                echo -e "${CYAN}请选择要部署的服务:${RESET}"
                echo "1) Frigate (重度依赖 Coral/核显，AI 强)"
                echo "2) Shinobi (适用广，无脑部署录像好用)"
                echo "3) go2rtc  (仅仅需要极低延迟流媒体转发)"
                echo "0) 返回主菜单"
                read -p "选择: " sub
                case $sub in 
                    1) deploy_frigate ;; 
                    2) deploy_shinobi ;; 
                    3) deploy_go2rtc ;; 
                esac 
                ;;
            2) scan_network ;;
            3) manage_and_backup ;;
            4) uninstall_menu ;;
            5) set_docker_mirror ;;
            0) echo -e "${GREEN}感谢使用！再见。${RESET}"; exit 0 ;;
            *) echo -e "${RED}无效选择，请重试。${RESET}"; sleep 1 ;;
        esac
    done
}

# 启动脚本
main
