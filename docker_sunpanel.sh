#!/bin/bash

# 配置区（默认值）
DATA_DIR="$HOME/docker/sun-panel/data"
BACKUP_DIR="$HOME/docker/sun-panel/backup"
LOG_FILE="/var/log/docker_management.log"
LOG_MAX_SIZE=1048576  # 1M
CONTAINER_NAME="sun-panel"
TIMEZONE="Asia/Shanghai"
SUN_PANEL_IMAGE_NAME="hslr/sun-panel"
DEFAULT_SUN_PANEL_PORT=3002

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 初始化日志
log() {
  local level=$1
  local message=$2
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  case $level in
    "INFO") echo -e "${GREEN}[INFO] $timestamp - $message${NC}" >&2 ;;
    "WARN") echo -e "${YELLOW}[WARN] $timestamp - $message${NC}" >&2 ;;
    "ERROR") echo -e "${RED}[ERROR] $timestamp - $message${NC}" >&2 ;;
  esac
  echo "[$level] $timestamp - $message" >> "$LOG_FILE"

  # 限制日志大小为 1M，超过后清空
  if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
    > "$LOG_FILE"
    log "INFO" "日志文件大小超过 1M，已清空日志。"
  fi
}

# 检测设备架构和操作系统
detect_system() {
  log "INFO" "正在检测设备架构和操作系统..."
  ARCH=$(uname -m)
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  fi
  log "INFO" "设备架构: $ARCH, 操作系统: $OS"
}

# 检测端口是否可用
check_port_available() {
  local port=$1
  if lsof -i:"$port" >/dev/null 2>&1; then
    return 1  # 端口被占用
  else
    return 0  # 端口可用
  fi
}

# 提示用户输入端口
prompt_for_port() {
  local prompt_message=$1
  local default_port=$2
  local port=""

  while true; do
    read -p "$prompt_message [$default_port]: " port
    port=${port:-$default_port}  # 如果用户未输入，使用默认端口
    if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 1 ] && [ $port -le 65535 ]; then
      if check_port_available "$port"; then
        echo "$port"
        return
      else
        log "WARN" "端口 $port 已被占用，请选择其他端口"
      fi
    else
      log "WARN" "无效的端口号，请输入1到65535之间的数字"
    fi
  done
}

# 安装依赖（根据系统和架构）
install_dependencies() {
  log "INFO" "正在安装依赖..."
  if ! command -v docker &> /dev/null; then
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
      apt update && apt install -y curl lsof || {
        log "ERROR" "依赖安装失败，请检查网络连接"
        exit 1
      }
      curl -fsSL https://get.docker.com | sh || {
        log "ERROR" "Docker安装失败"
        exit 1
      }
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
      yum install -y curl lsof || {
        log "ERROR" "依赖安装失败，请检查网络连接"
        exit 1
      }
      curl -fsSL https://get.docker.com | sh || {
        log "ERROR" "Docker安装失败"
        exit 1
      }
    else
      log "ERROR" "不支持的操作系统: $OS"
      exit 1
    fi
    systemctl enable --now docker
    log "INFO" "Docker 已成功安装"
  else
    log "INFO" "Docker 已存在，跳过安装"
  fi

  # 检查并安装 jq
  if ! command -v jq &> /dev/null; then
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
      apt install -y jq || {
        log "ERROR" "jq 安装失败"
        exit 1
      }
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
      yum install -y jq || {
        log "ERROR" "jq 安装失败"
        exit 1
      }
    else
      log "ERROR" "不支持的操作系统: $OS"
      exit 1
    fi
    log "INFO" "jq 已成功安装"
  else
    log "INFO" "jq 已存在，跳过安装"
  fi
}

# 获取 Sun-Panel 版本列表
get_sunpanel_versions() {
  local versions=""
  # 增加重试机制：最多尝试 3 次，每次超时 10 秒
  for i in {1..3}; do
    # 放宽正则：抓取包含数字的版本号，排除 latest，以便我们后面把它放在第一位
    versions=$(curl -s -m 10 "https://hub.docker.com/v2/repositories/hslr/sun-panel/tags/?page_size=30" | jq -r '.results[].name' 2>/dev/null | grep -E '^[0-9v]' | sort -r)
    
    if [ -n "$versions" ]; then
      break
    fi
    sleep 2
  done
  
  # 始终将 latest 作为首选项提供
  if [ -n "$versions" ]; then
    echo "latest $versions"
  else
    # 如果实在获取不到，返回空
    echo ""
  fi
}

# 提示用户选择版本
prompt_for_version() {
  log "INFO" "正在向 Docker Hub 请求 Sun-Panel 版本列表..."
  echo -e "${CYAN}正在获取可选版本列表，请稍候...${NC}"
  
  local versions_str=$(get_sunpanel_versions)
  local versions=($versions_str)
  local num_versions=${#versions[@]}

  # 降级方案：如果 API 完全不通，允许用户手动输入
  if [ $num_versions -eq 0 ]; then
    log "WARN" "无法从 Docker Hub 自动获取版本列表。"
    echo -e "${YELLOW}由于网络原因，无法自动获取版本列表。${NC}"
    read -p "请输入您要安装/升级的 Sun-Panel 版本 (直接回车默认使用: latest): " manual_version
    SUN_PANEL_VERSION=${manual_version:-latest}
    log "INFO" "用户手动输入版本: $SUN_PANEL_VERSION"
    return
  fi

  echo "请选择 Sun-Panel 版本（推荐直接回车选择 latest）："
  for i in "${!versions[@]}"; do
    echo "$((i + 1)). ${versions[$i]}"
  done

  while true; do
    read -p "请输入版本编号 [直接回车默认选择 1]: " version_choice
    version_choice=${version_choice:-1} # 如果直接回车，默认为 1
    
    if [[ $version_choice =~ ^[0-9]+$ ]] && [ "$version_choice" -ge 1 ] && [ "$version_choice" -le "$num_versions" ]; then
      SUN_PANEL_VERSION=${versions[$((version_choice - 1))]}
      break
    else
      log "WARN" "无效的选择，请重新输入"
      echo -e "${RED}错误：无效的编号，请输入 1 到 $num_versions 之间的数字。${NC}"
    fi
  done

  log "INFO" "选择的 Sun-Panel 版本: $SUN_PANEL_VERSION"
}

# 重置管理员密码
reset_admin_password() {
  log "INFO" "正在尝试重置管理员密码..."
  if docker ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${YELLOW}正在执行密码重置操作...${NC}"
    docker exec -it $CONTAINER_NAME ./sun-panel -password-reset
    log "INFO" "密码已重置为默认值"
    echo -e "\n${GREEN}密码重置成功！${NC}"
    echo -e "${CYAN}=================================${NC}"
    echo -e "${YELLOW}新的管理员凭据：${NC}"
    echo "账号：admin@sun.cc"
    echo "密码：12345678"
    echo -e "${CYAN}=================================${NC}"
    echo -e "${YELLOW}请及时登录并修改密码${NC}"
  else
    log "ERROR" "容器 $CONTAINER_NAME 未运行，无法重置密码"
    echo -e "${RED}错误：Sun-Panel 容器未运行${NC}"
  fi
}

# 部署 Sun-Panel
install_sunpanel() {
  prompt_for_version

  log "INFO" "正在拉取镜像 $SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION..."
  docker pull "$SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION" || {
    log "ERROR" "镜像拉取失败"
    exit 1
  }

  # 提示用户选择网络模式
  while true; do
    read -p "请选择网络模式 (bridge 或 host) [默认: bridge]: " network_mode
    network_mode=${network_mode:-bridge}
    if [[ "$network_mode" == "bridge" || "$network_mode" == "host" ]]; then
      NETWORK_MODE="$network_mode"
      break
    else
      log "WARN" "无效的网络模式，请重新输入"
    fi
  done

  log "INFO" "提示用户自定义端口..."
  HOST_PORT=$(prompt_for_port "请输入前端端口 (Web UI)" $DEFAULT_SUN_PANEL_PORT)

  log "INFO" "正在启动容器，网络模式: $NETWORK_MODE"
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker run -d \
      --network host \
      --name $CONTAINER_NAME \
      --restart=always \
      -v "${DATA_DIR}/conf:/app/conf" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -e TZ=${TIMEZONE} \
      "$SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION" || {
        log "ERROR" "容器启动失败"
        exit 1
      }
  else
    docker run -d \
      --name $CONTAINER_NAME \
      --restart=always \
      -p $HOST_PORT:3002 \
      -v "${DATA_DIR}/conf:/app/conf" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -e TZ=${TIMEZONE} \
      "$SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION" || {
        log "ERROR" "容器启动失败"
        exit 1
      }
  fi

  log "INFO" "Sun-Panel 部署成功"

  # 增强版部署完成提示
  echo -e "\n${GREEN}部署完成！以下是重要信息：${NC}"
  echo -e "${CYAN}=================================${NC}"
  echo -e "${YELLOW}默认管理员凭据（首次登录后请修改）${NC}"
  echo "账号：admin@sun.cc"
  echo "密码：12345678"
  echo -e "${CYAN}=================================${NC}"
  echo -e "访问地址："
  if [[ "$NETWORK_MODE" == "host" ]]; then
    echo "http://<你的服务器IP>:3002"
  else
    echo "http://<你的服务器IP>:$HOST_PORT"
  fi
  echo -e "\n${YELLOW}安全提示：${NC}"
  echo "1. 请确保防火墙允许 $HOST_PORT 端口的访问"
  echo "2. 首次登录后请立即修改默认密码"
  echo "3. 如需重置密码，请使用本脚本的'重置管理员密码'功能"
}

# 手动升级 Sun-Panel（保留原有配置）
manual_upgrade_sunpanel() {
  log "INFO" "正在准备升级 Sun-Panel..."

  # 1. 前置检查（判断容器是否存在）
  if ! docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    log "ERROR" "未检测到已部署的 Sun-Panel 容器，无法升级。"
    echo -e "${RED}错误：未检测到正在运行或已停止的 Sun-Panel 容器，无法升级。请先选择安装。${NC}"
    return
  fi

  # 2. 获取新版本并拉取镜像
  prompt_for_version
  
  log "INFO" "正在拉取镜像 $SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION..."
  docker pull "$SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION" || {
    log "ERROR" "镜像拉取失败"
    echo -e "${RED}错误：镜像拉取失败，请检查网络后重试。${NC}"
    return
  }

  # 3. 提取当前容器的配置 (核心步骤)
  log "INFO" "正在提取当前容器的配置参数..."
  local old_network_mode
  old_network_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")

  local host_port
  # 提取映射到宿主机的端口 (Sun-Panel 容器内使用的是 3002 端口)
  host_port=$(docker inspect "$CONTAINER_NAME" | jq -r '.[0].HostConfig.PortBindings["3002/tcp"][0].HostPort // empty')

  # 4. 停用并删除旧容器
  log "INFO" "正在停止并删除旧容器..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1

  # 5. 使用旧配置和新镜像重建容器
  log "INFO" "正在使用新镜像重建容器..."
  local docker_cmd=(
    docker run -d
    --name "$CONTAINER_NAME"
    --restart=always
    -v "${DATA_DIR}/conf:/app/conf"
    -v /var/run/docker.sock:/var/run/docker.sock
    -e TZ="${TIMEZONE}"
  )

  # 恢复网络模式和端口映射
  if [[ "$old_network_mode" == "host" ]]; then
    docker_cmd+=(--network host)
  else
    if [ -n "$host_port" ]; then
      docker_cmd+=(-p "${host_port}:3002")
    else
      # 容错处理：如果没提取到端口，回退到默认端口
      docker_cmd+=(-p "${DEFAULT_SUN_PANEL_PORT}:3002")
    fi
  fi

  # 加上镜像名作为最后参数
  docker_cmd+=("$SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION")

  # 执行拼接好的命令
  "${docker_cmd[@]}" || {
    log "ERROR" "升级后容器启动失败"
    echo -e "${RED}错误：容器启动失败，请检查日志。${NC}"
    return
  }
  
  log "INFO" "Sun-Panel 已升级到 $SUN_PANEL_VERSION 并自动恢复原有配置"
  echo -e "\n${GREEN}升级成功！Sun-Panel 已成功更新至 $SUN_PANEL_VERSION 版本。${NC}"
  echo -e "${YELLOW}您的网络模式、端口配置及数据均已完全保留。${NC}"
}

# 查看所有容器状态
check_all_containers_status() {
  log "INFO" "正在检查所有容器状态..."
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# 增强版卸载容器
uninstall_container() {
  local container_name=$1

  if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    log "INFO" "正在卸载容器 $container_name..."
    docker stop $container_name
    docker rm $container_name
    log "INFO" "容器 $container_name 已停止并移除"

    # 询问是否删除镜像
    read -p "是否删除镜像 $SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION? (y/n) [默认: n]: " remove_image
    remove_image=${remove_image:-n}
    if [[ "$remove_image" == "y" || "$remove_image" == "Y" ]]; then
      docker rmi "$SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION"
      log "INFO" "镜像 $SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION 已删除"
    fi

    # 询问是否清理卷
    read -p "是否清理相关数据卷 $DATA_DIR? (y/n) [默认: n]: " remove_volume
    remove_volume=${remove_volume:-n}
    if [[ "$remove_volume" == "y" || "$remove_volume" == "Y" ]] && [ "$container_name" == "$CONTAINER_NAME" ]; then
      rm -rf "$DATA_DIR"
      log "INFO" "数据卷 $DATA_DIR 已清理"
    fi
  else
    log "WARN" "容器 $container_name 未运行，跳过卸载"
  fi
}

# 数据备份
backup_data() {
  if [ -d "$DATA_DIR" ]; then
    log "INFO" "正在备份数据..."
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/backup_$TIMESTAMP.tar.gz"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$BACKUP_FILE" -C "$DATA_DIR" .
    log "INFO" "数据已备份到: $BACKUP_FILE"
    echo -e "${GREEN}备份成功！${NC}"
    echo "备份文件位置: $BACKUP_FILE"
  else
    log "WARN" "未找到数据目录，跳过备份"
    echo -e "${YELLOW}警告：未找到数据目录${NC}"
  fi
}

# 数据恢复
restore_data() {
  local latest_backup=$(ls -t $BACKUP_DIR/*.tar.gz 2>/dev/null | head -n 1)
  if [ -z "$latest_backup" ]; then
    log "WARN" "未找到备份文件，跳过恢复"
    echo -e "${YELLOW}未找到备份文件${NC}"
    return
  fi

  log "INFO" "正在恢复数据..."
  mkdir -p "$DATA_DIR"
  tar -xzf "$latest_backup" -C "$DATA_DIR"
  log "INFO" "数据已从 $latest_backup 恢复"
  echo -e "${GREEN}数据恢复成功！${NC}"
  echo "恢复来源: $latest_backup"
}

# 交互式菜单
interactive_menu() {
  while true; do
    echo -e "\n${CYAN}Sun-Panel 管理脚本${NC}"
    echo -e "${YELLOW}===================${NC}"
    echo "1. 部署 Sun-Panel"
    echo "2. 手动升级现有的 Sun-Panel"
    echo "3. 查看所有容器状态"
    echo "4. 卸载 Sun-Panel"
    echo "5. 数据备份"
    echo "6. 数据恢复"
    echo "7. 重置管理员密码"
    echo "8. 退出"
    echo -e "${YELLOW}===================${NC}"
    read -p "请输入选项编号: " choice

    case $choice in
      1) install_sunpanel ;;
      2) manual_upgrade_sunpanel ;;
      3) check_all_containers_status ;;
      4) uninstall_container $CONTAINER_NAME ;;
      5) backup_data ;;
      6) restore_data ;;
      7) reset_admin_password ;;
      8)
        log "INFO" "退出脚本"
        echo -e "${GREEN}感谢使用 Sun-Panel 管理脚本${NC}"
        exit 0
        ;;
      *)
        log "WARN" "无效输入，请重新选择"
        echo -e "${RED}错误：无效选项${NC}"
        ;;
    esac
  done
}

# 主流程
main() {
  # 显示欢迎信息
  echo -e "${CYAN}"
  echo "======================================"
  echo " Sun-Panel Docker 管理脚本 v2.1"
  echo " 支持部署、更新、管理和维护 Sun-Panel"
  echo "======================================"
  echo -e "${NC}"
  
  detect_system
  install_dependencies
  interactive_menu
}

# 执行入口
main "$@"
