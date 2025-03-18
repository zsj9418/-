#!/bin/bash

# 配置区
BASE_CONTAINER_NAME="cloudflared"
IMAGE_NAME="cloudflare/cloudflared:latest" # 默认镜像，后续会根据架构调整
LOG_FILE="/var/log/cloudflared_deploy.log"
LOG_MAX_SIZE=1048576  # 1M

# 健康检查时间间隔和初始等待时间 (保持一致)
HEALTHCHECK_INTERVAL=30
HEALTHCHECK_START_PERIOD=60
HEALTHCHECK_TIMEOUT=10
HEALTHCHECK_RETRIES=3

# 颜色定义 (保持一致)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 系统类型检测
IS_OPENWRT=false
if [ -f "/etc/openwrt_release" ]; then
  IS_OPENWRT=true
  SYSTEM_TYPE="OpenWrt"
elif grep -q "Debian" /etc/os-release 2>/dev/null || grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
  SYSTEM_TYPE="Debian/Ubuntu"
elif grep -q "CentOS" /etc/os-release 2>/dev/null || grep -q "Red Hat" /etc/os-release 2>/dev/null; then
  SYSTEM_TYPE="CentOS/RedHat"
else
  SYSTEM_TYPE="Unknown"
fi
echo "Detected System: ${SYSTEM_TYPE}"

# 初始化日志 (修改日志大小检查方式为 wc -c)
log() {
  local level=$1
  local message=$2
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  case $level in
    "INFO") echo -e "${GREEN}[INFO] $timestamp - $message${NC}" ;;
    "WARN") echo -e "${YELLOW}[WARN] $timestamp - $message${NC}" ;;
    "ERROR") echo -e "${RED}[ERROR] $timestamp - $message${NC}" ;;
  esac
  echo "[$level] $timestamp - $message" >> "$LOG_FILE"

  # 限制日志大小为 1M，超过后清空 (使用 wc -c 检查日志大小)
  if [[ -f "$LOG_FILE" && $(wc -c < "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
    > "$LOG_FILE"
    log "INFO" "日志文件大小超过 1M，已清空日志。"
  fi
}

# 检查 Docker 是否安装 (保持一致)
check_docker() {
  if ! command -v docker &> /dev/null; then
    log "ERROR" "Docker 未安装，请先安装 Docker 后再运行此脚本。"
    echo -e "${RED}Docker 未安装，请先安装 Docker 后再运行此脚本。${NC}"
    exit 1
  fi
}

# 检查架构并选择合适的镜像 (保持一致)
check_architecture() {
  ARCH=$(uname -m)
  case $ARCH in
    "x86_64"|"amd64")
      IMAGE_NAME="cloudflare/cloudflared:latest"
      ;;
    "armv7l"|"armhf")
      IMAGE_NAME="cloudflare/cloudflared:latest-arm"
      ;;
    "aarch64"|"arm64")
      IMAGE_NAME="cloudflare/cloudflared:latest-arm64"
      ;;
    *)
      log "ERROR" "不支持的架构: $ARCH"
      echo -e "${RED}不支持的架构: $ARCH${NC}"
      exit 1
      ;;
  esac
  log "INFO" "检测到架构: $ARCH, 使用镜像: $IMAGE_NAME"
}

# 提示用户输入 Cloudflare Token (保持一致)
prompt_for_token() {
  while true; do
    read -p "请输入 Cloudflare Tunnel Token（必填项，留空则退出脚本）: " TOKEN
    if [[ -z "$TOKEN" ]]; then
      log "ERROR" "Token 为空，退出脚本。"
      echo -e "${RED}Token 为空，退出脚本。${NC}"
      exit 1
    fi
    log "INFO" "用户输入的 Token: $TOKEN"
    break
  done
}

# 生成唯一的容器名称 (保持一致，确保多实例部署)
generate_unique_container_name() {
  local base_name="$BASE_CONTAINER_NAME"
  local suffix=1
  local container_name="$base_name"
  while docker ps -a --filter "name=$container_name" --format "{{.Names}}" | grep -q "^$container_name$"; do
    container_name="${base_name}_${suffix}"
    suffix=$((suffix + 1))
  done
  echo "$container_name"
}

# 调整 UDP 缓冲区大小 (条件化执行，并确保 sudo 命令在条件块内)
adjust_udp_buffer() {
  if [[ "$IS_OPENWRT" == false ]]; then # 只在非 OpenWRT 系统上执行
    log "INFO" "正在调整 UDP 缓冲区大小..."
    sudo sysctl -w net.core.rmem_max=8388608
    sudo sysctl -w net.core.rmem_default=8388608
    log "INFO" "UDP 缓冲区大小调整完成。"
  else
    log "INFO" "OpenWRT 系统，跳过 UDP 缓冲区调整。"
  fi
}

# 部署 Cloudflared 容器 (强制使用 --network host 模式)
deploy_cloudflared() {
  local container_name=$(generate_unique_container_name)
  log "INFO" "正在部署 Cloudflared 容器: $container_name..."
  DOCKER_RUN_CMD="docker run -d --name \"$container_name\" --restart=always --network host" # 强制 --network host
  DOCKER_RUN_CMD="$DOCKER_RUN_CMD \"$IMAGE_NAME\" tunnel --no-autoupdate run --protocol http2 --token \"$TOKEN\""

  eval "$DOCKER_RUN_CMD" && {
    log "INFO" "Cloudflared 容器 $container_name 部署成功。"
    echo -e "${GREEN}Cloudflared 容器 $container_name 部署成功。${NC}"
    return 0
  }
  log "ERROR" "Cloudflared 容器 $container_name 部署失败。"
  echo -e "${RED}Cloudflared 容器 $container_name 部署失败。${NC}"
  exit 1
}

# 检查容器运行状态和健康检查结果 (保持一致)
check_status() {
  log "INFO" "正在检查 Cloudflared 容器状态..."
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || {
    log "ERROR" "无法获取容器状态。"
    echo -e "${RED}无法获取容器状态。${NC}"
  }

  log "INFO" "正在检查 Cloudflared 容器健康检查状态..."
  docker ps --format "{{.Names}}" | grep "^$BASE_CONTAINER_NAME" | while read -r container_name; do
    docker inspect --format "{{json .State.Health }}" "$container_name" | jq || {
      log "ERROR" "无法获取容器 $container_name 的健康检查状态。"
      echo -e "${RED}无法获取容器 $container_name 的健康检查状态。${NC}"
    }
  done
}

# 重启容器 (保持一致)
restart_container() {
  log "INFO" "正在重启 Cloudflared 容器..."
  docker ps --format "{{.Names}}" | grep "^$BASE_CONTAINER_NAME" | while read -r container_name; do
    docker restart "$container_name" || {
      log "ERROR" "Cloudflared 容器 $container_name 重启失败。"
      echo -e "${RED}Cloudflared 容器 $container_name 重启失败。${NC}"
      exit 1
    }
    log "INFO" "Cloudflared 容器 $container_name 重启成功。"
    echo -e "${GREEN}Cloudflared 容器 $container_name 重启成功。${NC}"
  done
}

# 卸载容器 (保持一致)
uninstall_container() {
  log "INFO" "正在卸载 Cloudflared 容器..."
  docker ps --format "{{.Names}}" | grep "^$BASE_CONTAINER_NAME" | while read -r container_name; do
    docker stop "$container_name"
    docker rm "$container_name"
    log "INFO" "Cloudflared 容器 $container_name 已卸载。"
  done

  # 询问是否删除镜像 (保持一致)
  read -p "是否删除 Cloudflared 镜像? (y/n) [默认: n]: " remove_image
  remove_image=${remove_image:-n}
  if [[ "$remove_image" == "y" || "$remove_image" == "Y" ]]; then
    docker rmi "$IMAGE_NAME"
    log "INFO" "Cloudflared 镜像已删除。"
    echo -e "${GREEN}Cloudflared 镜像已删除。${NC}"
  fi
}


# 交互式菜单 (保持一致)
interactive_menu() {
  while true; do
    echo -e "\n选择操作："
    echo "1. 部署 Cloudflared 容器"
    echo "2. 查看容器运行状态和健康检查结果"
    echo "3. 重启容器"
    echo "4. 卸载容器"
    echo "5. 调整 UDP 缓冲区大小 (仅限非 OpenWRT 系统)"
    echo "6. 退出脚本"
    read -p "请输入选项编号: " choice

    case $choice in
      1)
        prompt_for_token
        deploy_cloudflared
        ;;
      2) check_status ;;
      3) restart_container ;;
      4) uninstall_container ;;
      5) adjust_udp_buffer ;;
      6)
        log "INFO" "退出脚本。"
        echo -e "${GREEN}退出脚本。${NC}"
        exit 0
        ;;
      *)
        log "WARN" "无效输入，请重新选择。"
        echo -e "${YELLOW}无效输入，请重新选择。${NC}"
        ;;
    esac
  done
}

# 主流程
main() {
  check_docker
  check_architecture
  adjust_udp_buffer # 在 OpenWRT 上会跳过
  interactive_menu
}

# 执行入口
main "$@"
