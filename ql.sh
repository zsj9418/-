#!/bin/bash

DATA_DIR="$HOME/qinglong"
QL_IMAGE_BASE="whyour/qinglong"
DEFAULT_IMAGE_VER="2.17.9"
DEFAULT_CONTAINER_NAME="qinglong"
DEFAULT_PORT=5700
LOG_FILE="$DATA_DIR/ql_script.log"
LOG_MAX_SIZE=1048576

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() {
  local level=$1 msg=$2 timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  case "$level" in
    INFO)  echo -e "${GREEN}[INFO] $msg${NC}" >&2 ;;
    WARN)  echo -e "${YELLOW}[WARN] $msg${NC}" >&2 ;;
    ERROR) echo -e "${RED}[ERROR] $msg${NC}" >&2 ;;
    *)     echo -e "${NC}[LOG] $msg${NC}" >&2 ;;
  esac
  echo "[$level] $timestamp - $msg" >> "$LOG_FILE"
  if [[ -f "$LOG_FILE" && $(wc -c < "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
    > "$LOG_FILE"
    log "INFO" "日志超1M已清空"
  fi
}

make_directories() {
  mkdir -p "$DATA_DIR"/{config,log,db,repo,raw,scripts,jbot,backup}
  log "INFO" "必要目录已创建"
}

port_is_free() {
  local port=$1
  ss -tuln 2>/dev/null | grep -q ":$port\b" && return 1
  netstat -tuln 2>/dev/null | grep -q ":$port\b" && return 1
  lsof -i:"$port" 2>/dev/null | grep -q LISTEN && return 1
  return 0
}

prompt_port() {
  local prompt=$1 def=$2 input
  while true; do
    read -p "$prompt [$def]: " input
    input=${input:-$def}
    [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ] || {
      log WARN "端口号必须在1-65535"
      continue
    }
    if port_is_free "$input"; then
      echo "$input"
      return
    else
      log WARN "端口 $input 已被占用"
    fi
  done
}

prompt_container_name() {
  local prompt=$1 def=$2 input
  read -p "$prompt [$def]: " input
  input=${input:-$def}
  echo "$input"
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log ERROR "没安装Docker"
    exit 1
  fi
}

get_container_port() {
  # 获取指定容器的映射端口
  local cname=$1
  docker inspect --format='{{(index (index .NetworkSettings.Ports "5700/tcp") 0).HostPort}}' "$cname" 2>/dev/null
}

get_container_version() {
  local cname=$1
  docker inspect --format="{{.Config.Image}}" "$cname" 2>/dev/null | awk -F: '{print $2}'
}

#===== 部署、备份、恢复 =====#

install_ql() {
  check_docker
  make_directories

  local name port image
  name=$(prompt_container_name "容器名称" "$DEFAULT_CONTAINER_NAME")
  port=$(prompt_port "WebUI端口" "$DEFAULT_PORT")
  image="$QL_IMAGE_BASE:$DEFAULT_IMAGE_VER"

  if docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    log WARN "容器 $name 已存在，不能重复部署"
    return
  fi

  log INFO "拉取镜像 $image..."
  docker pull "$image" || { log ERROR "镜像拉取失败"; exit 1; }

  log INFO "启动容器 $name 端口 $port"
  docker run -dit \
    -v "$DATA_DIR/config:/ql/config" \
    -v "$DATA_DIR/log:/ql/log" \
    -v "$DATA_DIR/db:/ql/db" \
    -v "$DATA_DIR/repo:/ql/repo" \
    -v "$DATA_DIR/raw:/ql/raw" \
    -v "$DATA_DIR/scripts:/ql/scripts" \
    -v "$DATA_DIR/jbot:/ql/jbot" \
    -p "$port:5700" \
    --name "$name" \
    --hostname "$name" \
    --restart unless-stopped \
    "$image" || { log ERROR "容器启动失败"; exit 1; }

  log INFO "青龙容器 $name 部署完成，Web面板地址: http://$(hostname -I | awk '{print $1}'):$port"
}

list_containers() {
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"
}

uninstall_ql() {
  local name
  name=$(prompt_container_name "输入要卸载的容器名" "$DEFAULT_CONTAINER_NAME")
  if docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    docker stop "$name" && docker rm "$name"
    log INFO "容器 $name 已删除"
  else
    log WARN "不存在容器 $name"
  fi
}

backup_ql() {
  local ts backup_dir
  ts=$(date +%Y%m%d%H%M%S)
  backup_dir="$DATA_DIR/backup/ql_backup_$ts.tar.gz"
  tar -czf "$backup_dir" -C "$DATA_DIR" config log db repo raw scripts jbot
  log INFO "已备份到 $backup_dir"
}

restore_ql() {
  local latest
  latest=$(ls -t "$DATA_DIR/backup"/ql_backup_*.tar.gz 2>/dev/null | head -n1)
  if [[ ! -f $latest ]]; then
    log WARN "找不到备份文件"
    return
  fi
  tar -xzf "$latest" -C "$DATA_DIR"
  log INFO "已从 $latest 恢复"
}

#===== 升级模块 =====#

upgrade_ql() {
  check_docker
  local name old_image old_port new_version image
  name=$(prompt_container_name "待升级的容器名" "$DEFAULT_CONTAINER_NAME")
  if ! docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    log ERROR "容器 <$name> 不存在"
    return
  fi

  old_image=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
  old_port=$(get_container_port "$name")
  [[ -z "$old_port" ]] && old_port="$DEFAULT_PORT"

  echo "检测到容器 <$name> 当前镜像: $old_image"
  echo "选择升级模式："
  echo "1. 升级到最新版 (latest)"
  echo "2. 升级到指定版本 (如 2.17.9)"
  read -p "输入选项 [1/2, 默认为1]: " choice

  if [[ "$choice" == "2" ]]; then
    read -p "请输入目标版本号（如 2.17.9 ）: " new_version
    new_version=${new_version:-"latest"}
  else
    new_version="latest"
  fi
  image="$QL_IMAGE_BASE:$new_version"

  log INFO "拉取镜像 $image..."
  docker pull "$image" || { log ERROR "镜像拉取失败"; return; }

  log INFO "停止并移除容器 $name"
  docker stop "$name" && docker rm "$name"

  log INFO "重启新镜像容器 $name , 保持数据/端口不变"
  docker run -dit \
    -v "$DATA_DIR/config:/ql/config" \
    -v "$DATA_DIR/log:/ql/log" \
    -v "$DATA_DIR/db:/ql/db" \
    -v "$DATA_DIR/repo:/ql/repo" \
    -v "$DATA_DIR/raw:/ql/raw" \
    -v "$DATA_DIR/scripts:/ql/scripts" \
    -v "$DATA_DIR/jbot:/ql/jbot" \
    -p "$old_port:5700" \
    --name "$name" \
    --hostname "$name" \
    --restart unless-stopped \
    "$image" || { log ERROR "新容器启动失败"; return; }

  log INFO "青龙 <$name> 已升级至 $image，Web面板: http://$(hostname -I | awk '{print $1}'):$old_port"
}

#===== 主菜单 =====#

show_menu() {
  while true; do
    echo -e "\n======== QL青龙Docker管理 ======="
    echo "1. 部署QingLong容器"
    echo "2. 查看/已装容器"
    echo "3. 卸载QingLong"
    echo "4. 数据备份"
    echo "5. 数据恢复"
    echo "6. 升级青龙面板 (支持指定版本或最新版)"
    echo "7. 退出"
    read -p "输入编号选择功能: " op
    case "$op" in
      1) install_ql ;;
      2) list_containers ;;
      3) uninstall_ql ;;
      4) backup_ql ;;
      5) restore_ql ;;
      6) upgrade_ql ;;
      7) log INFO "Bye！"; exit 0 ;;
      *) log WARN "无效输入" ;;
    esac
  done
}

main() {
  make_directories
  check_docker
  show_menu
}

main "$@"
