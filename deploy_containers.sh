#!/bin/bash
set -euo pipefail
trap 'echo "脚本被中断"; exit 1' INT

LOG_FILE="/var/log/deploy_script.log"
LOG_MAX_SIZE=1048576
if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
  > "$LOG_FILE"
fi
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# 常量
LOBE_CHAT_IMAGE="lobehub/lobe-chat:latest"
WEBSSH_IMAGE_V1="jrohy/webssh"
WEBSSH_IMAGE_V2="cmliu/webssh"
LOOKING_GLASS_IMAGE="wikihostinc/looking-glass-server"
SPEEDTEST_IMAGE="ghcr.io/librespeed/speedtest"

WEBSSH_CONTAINER_NAME_V1="webssh_v1"
WEBSSH_CONTAINER_NAME_V2="webssh_v2"
WEBSSH_DEFAULT_TAG_V2="latest"
WEBSSH_DEFAULT_PORT_V1="5032"
WEBSSH_DEFAULT_PORT_V2="8888"
WEBSSH_DEFAULT_DATA_V2="/opt/webssh/data"
WEBSSH_MAX_LOG_SIZE="1m"
WEBSSH_RETRY_COUNT=3
WEBSSH_DEPENDENCY_CHECK_FILE_V2="/tmp/websshv2_dep_check"
LOG_DIVIDER="--------------------------------------------------"

function green() { echo -e "\e[32m$1\e[0m"; }
function red() { echo -e "\e[31m$1\e[0m"; }
function yellow() { echo -e "\e[33m$1\e[0m"; }

function detect_architecture() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64 | amd64) PLATFORM="linux/amd64" ;;
    armv7l | armhf) PLATFORM="linux/arm/v7" ;;
    aarch64 | arm64) PLATFORM="linux/arm64" ;;
    mips | mipsel) PLATFORM="linux/mips" ;;
    *) red "不支持的架构 ($ARCH)" && exit 1 ;;
  esac
  green "设备架构：$ARCH，适配平台：$PLATFORM"
}

function detect_os() {
  if [[ -f /etc/openwrt_release ]]; then
    OS="OpenWrt"
    PACKAGE_MANAGER="opkg"
    IS_OPENWRT=true
  elif [[ -f /etc/debian_version ]]; then
    OS="Debian/Ubuntu"
    PACKAGE_MANAGER="apt"
    IS_OPENWRT=false
  elif [[ -f /etc/redhat-release ]]; then
    OS="CentOS/RHEL"
    PACKAGE_MANAGER="yum"
    IS_OPENWRT=false
  else
    red "不支持的操作系统" && exit 1
  fi
  green "操作系统：$OS"
}

function install_dependency() {
  local cmd=$1
  local install_cmd=$2
  if ! command -v $cmd &>/dev/null; then
    yellow "正在安装 $cmd..."
    eval "$install_cmd"
    if command -v $cmd &>/dev/null; then
      green "$cmd 安装成功。"
    else
      red "$cmd 安装失败，请手动安装。"
      exit 1
    fi
  fi
}

function check_dependencies() {
  if [[ ! -f "/var/log/deploy_dependencies_checked" ]]; then
    if $IS_OPENWRT; then
      install_dependency "docker" "opkg install docker"
      install_dependency "lsof" "opkg install lsof"
      /etc/init.d/dockerd enable
      /etc/init.d/dockerd start
    else
      install_dependency "docker" "sudo $PACKAGE_MANAGER install -y docker.io"
      install_dependency "lsof" "sudo $PACKAGE_MANAGER install -y lsof"
    fi
    touch "/var/log/deploy_dependencies_checked"
  fi
}

function check_user_permission() {
  if $IS_OPENWRT; then
    if [[ $(id -u) -ne 0 ]]; then
      red "OpenWrt 建议用 root 用户运行脚本"
      exit 1
    fi
  else
    if ! id -nG "$(whoami)" | grep -qw "docker"; then
      yellow "当前用户未加入 Docker 用户组，尝试解决权限问题..."
      sudo usermod -aG docker "$(whoami)"
      red "已将当前用户加入 Docker 用户组，请重新登录后再运行脚本，或使用 'sudo' 运行脚本。"
      exit 1
    fi
  fi
}

# --------- 公共端口选择 ----------
function find_available_port() {
  local start_port=${1:-2001}
  while :; do
    if $IS_OPENWRT; then
      if ! netstat -tuln | grep -q ":$start_port "; then break; fi
    else
      if ! lsof -i:$start_port &>/dev/null; then break; fi
    fi
    ((start_port++))
  done
  echo $start_port
}

function validate_port() {
  local suggested_port=$(find_available_port $1)
  green "建议端口：$suggested_port"
  read -p "请输入端口（默认 $suggested_port）： " port
  PORT=${port:-$suggested_port}
  if ! [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]]; then
    red "端口号无效，请输入 1-65535。" ; exit 1
  fi
}

# -------- Lobe Chat ---------
function lobe_chat_menu() {
  while true; do
    echo -e "\n【Lobe Chat 管理】"
    echo "1. 部署"
    echo "2. 卸载"
    echo "3. 查看状态"
    echo "4. 返回主菜单"
    read -p "请选择: " sel
    case $sel in
      1)
        validate_port 3210
        deploy_panel_service "lobe-chat" "$LOBE_CHAT_IMAGE" 3210 "$PORT"
        ;;
      2)
        uninstall_panel_service "lobe-chat"
        ;;
      3)
        check_panel_status "lobe-chat"
        ;;
      4)
        break
        ;;
      *) red "无效选项。" ;;
    esac
    echo -e "\n$LOG_DIVIDER\n已返回 Lobe Chat 子菜单。"
  done
}

# ---------- WebSSH 二级选择 ----------
function webssh_menu() {
  while true; do
    echo -e "\n【WebSSH 版本选择】"
    echo "1. V1 (jrohy/webssh, 端口:5032, 无持久化)"
    echo "2. V2 (cmliu/webssh, 端口/卷可定制, 推荐)"
    echo "3. 返回主菜单"
    read -p "请选择: " subver
    case $subver in
      1) webssh_v1_menu ;;
      2) webssh_v2_menu ;;
      3) break ;;
      *) red "无效选项。" ;;
    esac
  done
}

function webssh_v1_menu() {
  while true; do
    echo -e "\n【WebSSH V1 管理】"
    echo "1. 部署"
    echo "2. 卸载"
    echo "3. 查看状态"
    echo "4. 返回上级"
    read -p "请选择: " op
    case $op in
      1)
        validate_port $WEBSSH_DEFAULT_PORT_V1
        # 部署
        if docker ps -a --format '{{.Names}}' | grep -q "^$WEBSSH_CONTAINER_NAME_V1$"; then
          yellow "容器 $WEBSSH_CONTAINER_NAME_V1 已存在。"
          echo "请先卸载或手动删除。"
        else
          choose_network_mode
          docker pull $WEBSSH_IMAGE_V1
          if [[ "$NETWORK_MODE" == "host" ]]; then
            docker run -d --name $WEBSSH_CONTAINER_NAME_V1 \
              --network host \
              --restart always $WEBSSH_IMAGE_V1
          else
            docker run -d --name $WEBSSH_CONTAINER_NAME_V1 \
              --network bridge \
              -p $PORT:5032 \
              --restart always $WEBSSH_IMAGE_V1
          fi
          green "WebSSH V1 部署成功。访问：http://<你的IP>:$PORT"
        fi
        ;;
      2)
        # 卸载
        if docker ps -a --format '{{.Names}}' | grep -q "^$WEBSSH_CONTAINER_NAME_V1$"; then
          docker stop $WEBSSH_CONTAINER_NAME_V1 && docker rm $WEBSSH_CONTAINER_NAME_V1
          green "WebSSH V1 已卸载"
        else
          yellow "未发现 WebSSH V1 容器"
        fi
        docker network prune -f || true; docker volume prune -f || true
        ;;
      3)
        docker ps -a --filter "name=$WEBSSH_CONTAINER_NAME_V1"
        docker logs --tail 20 $WEBSSH_CONTAINER_NAME_V1 2>/dev/null || true
        ;;
      4) break ;;
      *) red "无效选项。" ;;
    esac
    echo -e "\n$LOG_DIVIDER\n已返回 WebSSH V1 子菜单。"
  done
}

function webssh_v2_menu() {
  while true; do
    echo -e "\n【WebSSH V2 管理】"
    echo "1. 部署"
    echo "2. 卸载"
    echo "3. 查看状态"
    echo "4. 返回上级"
    read -p "请选择: " op
    case $op in
      1)
        websshv2_check_dependencies
        websshv2_get_available_tags
        websshv2_setup_data_dir
        websshv2_get_port
        websshv2_select_network_mode
        websshv2_pull_image
        if docker ps -a --format '{{.Names}}' | grep -q "^$WEBSSH_CONTAINER_NAME_V2$"; then
          yellow "WebSSH V2 容器已存在。"
          echo "请先卸载或手动删除。"
        else
          if [[ "$WEBSSH_NETWORK_MODE_V2" == "--network host" ]]; then
            MAP_PORT=""
          else
            MAP_PORT="-p $WEBSSH_HOST_PORT_V2:8888"
          fi
          docker run -d --name "$WEBSSH_CONTAINER_NAME_V2" $WEBSSH_NETWORK_MODE_V2 $MAP_PORT \
            -v "$WEBSSH_DATA_DIR_V2:/root" \
            --restart always --log-opt max-size="$WEBSSH_MAX_LOG_SIZE" \
            "$WEBSSH_IMAGE_TAGGED_V2"
          green "WebSSH V2 部署成功。访问：http://<你的IP>:$WEBSSH_HOST_PORT_V2"
        fi
        ;;
      2)
        if docker ps -a --format '{{.Names}}' | grep -q "^$WEBSSH_CONTAINER_NAME_V2$"; then
          docker rm -f "$WEBSSH_CONTAINER_NAME_V2"
          green "WebSSH V2 容器已删除"
        fi
        if [ -d "$WEBSSH_DATA_DIR_V2" ]; then
          read -p "是否删除挂载目录 $WEBSSH_DATA_DIR_V2？(y/n): " hdd
          [ "$hdd" = "y" ] && rm -rf "$WEBSSH_DATA_DIR_V2"
        fi
        rm -f "$WEBSSH_DEPENDENCY_CHECK_FILE_V2"
        docker network prune -f >/dev/null 2>&1 || true
        docker volume prune -f >/dev/null 2>&1 || true
        ;;
      3)
        docker ps -a --filter "name=$WEBSSH_CONTAINER_NAME_V2"
        docker logs --tail 20 $WEBSSH_CONTAINER_NAME_V2 2>/dev/null || true
        ;;
      4) break ;;
      *) red "无效选项。" ;;
    esac
    echo -e "\n$LOG_DIVIDER\n已返回 WebSSH V2 子菜单。"
  done
}
# v2专用子功能
function websshv2_check_dependencies() {
    if [ -f "$WEBSSH_DEPENDENCY_CHECK_FILE_V2" ]; then
        return 0
    fi
    if $IS_OPENWRT; then
        install_dependency "curl" "opkg install curl"
    else
        install_dependency "curl" "sudo $PACKAGE_MANAGER install -y curl"
    fi
    touch "$WEBSSH_DEPENDENCY_CHECK_FILE_V2"
}
function websshv2_get_available_tags() {
    local repo="${WEBSSH_IMAGE_V2}"
    local api_url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=50"
    TAGS_RAW=$(curl -fsSL "$api_url" 2>/dev/null || echo "")
    # 解析tag名
    TAGS=$(echo "$TAGS_RAW" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    # 只保留数字版本tag
    NUMERIC_TAGS=$(echo "$TAGS" | grep -E '^[0-9\.]+$' || true)
    # 总是将 latest 置于最前
    FINAL_TAGS="latest"
    if [[ -n "$NUMERIC_TAGS" ]]; then
        FINAL_TAGS="latest $NUMERIC_TAGS"
    fi

    # 如果最终没有其他tag，只给latest时，也仍然展示，可被选择
    i=1
    for tag in $FINAL_TAGS; do
        echo "$i) $tag"
        ((i++))
    done
    read -p "请选择 WebSSH V2 镜像版本（回车=latest）: " t
    if [ -z "$t" ]; then
        WEBSSH_SELECTED_TAG_V2="latest"
    else
        cnt=$(echo "$FINAL_TAGS" | wc -w)
        if [[ "$t" =~ ^[0-9]+$ ]] && (( t >= 1 && t <= cnt )); then
            WEBSSH_SELECTED_TAG_V2=$(echo "$FINAL_TAGS" | awk "{if(NR==$t)print}")
        else
            yellow "输入无效，已自动选择 [latest] 作为版本。"
            WEBSSH_SELECTED_TAG_V2="latest"
        fi
    fi
    WEBSSH_IMAGE_TAGGED_V2="$WEBSSH_IMAGE_V2:$WEBSSH_SELECTED_TAG_V2"
}
function websshv2_setup_data_dir() {
    read -p "请输入 WebSSH V2 持久化数据目录（留空为$WEBSSH_DEFAULT_DATA_V2）: " data
    WEBSSH_DATA_DIR_V2=${data:-$WEBSSH_DEFAULT_DATA_V2}
    mkdir -p "$WEBSSH_DATA_DIR_V2"
    chown -R 0:0 "$WEBSSH_DATA_DIR_V2" 2>/dev/null
    chmod 755 "$WEBSSH_DATA_DIR_V2"
}
function websshv2_get_port() {
    read -p "请输入映射端口（主机端口, 默认$WEBSSH_DEFAULT_PORT_V2）: " p
    WEBSSH_HOST_PORT_V2=${p:-$WEBSSH_DEFAULT_PORT_V2}
    if $IS_OPENWRT; then
        while netstat -tuln | grep -q ":$WEBSSH_HOST_PORT_V2 "; do
            yellow "端口 $WEBSSH_HOST_PORT_V2 已被占用"
            read -p "请输入新的端口: " WEBSSH_HOST_PORT_V2
        done
    elif [[ "$OS" == "macOS" ]]; then
        while netstat -an | grep -q ":$WEBSSH_HOST_PORT_V2 "; do
            yellow "端口 $WEBSSH_HOST_PORT_V2 已被占用"
            read -p "请输入新的端口: " WEBSSH_HOST_PORT_V2
        done
    else
        while ss -tuln | grep -q ":$WEBSSH_HOST_PORT_V2 "; do
            yellow "端口 $WEBSSH_HOST_PORT_V2 已被占用"
            read -p "请输入新的端口: " WEBSSH_HOST_PORT_V2
        done
    fi
}
function websshv2_select_network_mode() {
    echo -e "请选择网络模式："
    echo "1) bridge（推荐/OpenWrt推荐）"
    echo "2) host"
    echo "3) macvlan（进阶）"
    read -p "请输入选项(1-3,默认1): " wnet
    case $wnet in
        2) WEBSSH_NETWORK_MODE_V2="--network host" ;;
        3) WEBSSH_NETWORK_MODE_V2="--network macvlan" ;;
        *)  WEBSSH_NETWORK_MODE_V2="--network bridge" ;;
    esac
}
function websshv2_pull_image() {
    for ((i=1;i<=WEBSSH_RETRY_COUNT;i++)); do
        if docker pull "$WEBSSH_IMAGE_TAGGED_V2"; then return 0; fi
        sleep 2
    done
    red "WebSSH V2 镜像拉取失败" && exit 1
}

# ---------- Looking Glass ----------
function looking_glass_menu() {
  while true; do
    echo -e "\n【Looking Glass 管理】"
    echo "1. 部署"
    echo "2. 卸载"
    echo "3. 查看状态"
    echo "4. 返回主菜单"
    read -p "请选择: " sel
    case $sel in
      1)
        validate_port 80
        deploy_panel_service "looking-glass" "$LOOKING_GLASS_IMAGE" 80 "$PORT"
        ;;
      2)
        uninstall_panel_service "looking-glass"
        ;;
      3)
        check_panel_status "looking-glass"
        ;;
      4)
        break
        ;;
      *) red "无效选项。" ;;
    esac
    echo -e "\n$LOG_DIVIDER\n已返回 Looking Glass 子菜单。"
  done
}
# ------- Speedtest -------------
function speedtest_menu() {
  while true; do
    echo -e "\n【Speedtest 管理】"
    echo "1. 部署"
    echo "2. 卸载"
    echo "3. 查看状态"
    echo "4. 返回主菜单"
    read -p "请选择: " sel
    case $sel in
      1)
        validate_port 8080
        deploy_panel_service "speedtest" "$SPEEDTEST_IMAGE" 8080 "$PORT"
        ;;
      2)
        uninstall_panel_service "speedtest"
        ;;
      3)
        check_panel_status "speedtest"
        ;;
      4)
        break
        ;;
      *) red "无效选项。" ;;
    esac
    echo -e "\n$LOG_DIVIDER\n已返回 Speedtest 子菜单。"
  done
}

# -------- 通用 服务管理 ---------
function deploy_panel_service() {
  local cname=$1; local image=$2; local intport=$3; local hostport=$4
  if docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then
    yellow "容器 $cname 已存在。"
    echo "请先卸载或手动删除。"
    return
  fi
  choose_network_mode
  docker pull $image
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker run -d --name $cname --network host --restart always $image
  else
    docker run -d --name $cname --network bridge -p $hostport:$intport --restart always $image
  fi
  green "服务 $cname 部署成功, 访问：http://<你的IP>:$hostport"
}
function uninstall_panel_service() {
  local cname=$1
  if docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then
    docker stop $cname && docker rm $cname
    green "容器 $cname 已卸载"
  else
    yellow "未发现 $cname 容器"
  fi
  docker network prune -f || true
  docker volume prune -f || true
}
function check_panel_status() {
  local cname=$1
  docker ps -a --filter "name=$cname"
  docker logs --tail 20 $cname 2>/dev/null || true
}
function choose_network_mode() {
  echo "请选择网络模式："
  echo "1. bridge（推荐）"
  echo "2. host（使用主机网络）"
  read -p "请输入选项（1 或 2，默认1）： " mode
  case $mode in
    2) NETWORK_MODE="host" ;;
    *) NETWORK_MODE="bridge" ;;
  esac
}
# --------------------- 主菜单 ---------------------
function main_menu() {
  detect_architecture
  detect_os
  check_dependencies
  check_user_permission
  while true; do
    echo -e "\n=== 一键部署主菜单 ==="
    echo "1. Lobe Chat"
    echo "2. WebSSH"
    echo "3. Looking Glass"
    echo "4. Speedtest"
    echo "5. 查看全部容器状态"
    echo "6. 退出"
    read -p "请选择服务： " main_choice
    case $main_choice in
      1) lobe_chat_menu ;;
      2) webssh_menu ;;
      3) looking_glass_menu ;;
      4) speedtest_menu ;;
      5) docker ps -a ;;
      6) green "感谢您的使用，脚本退出。" && exit 0 ;;
      *) red "无效选项。" ;;
    esac
    echo -e "\n$LOG_DIVIDER\n已返回主菜单。"
  done
}

main_menu
