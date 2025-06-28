#!/bin/bash
# QingLong 青龙面板Docker管理脚本
# 支持自定义容器名/端口、日志、备份恢复、状态查询

#===== 默认配置 =====#

DATA_DIR="$HOME/qinglong"
QL_IMAGE="whyour/qinglong:2.11.3"
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

#===== 功能模块 =====#

install_ql() {
  check_docker
  make_directories

  local name port
  name=$(prompt_container_name "容器名称" "$DEFAULT_CONTAINER_NAME")
  port=$(prompt_port "WebUI端口" "$DEFAULT_PORT")

  if docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    log WARN "容器 $name 已存在，不能重复部署"
    return
  fi

  log INFO "拉取镜像 $QL_IMAGE..."
  docker pull "$QL_IMAGE" || { log ERROR "镜像拉取失败"; exit 1; }

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
    "$QL_IMAGE" || { log ERROR "容器启动失败"; exit 1; }

  log INFO "青龙容器 $name 部署完成，Web面板地址: http://$(hostname -I | awk '{print $1}'):$port"
}

# 看状态
list_containers() {
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# 卸载
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

# 备份
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

show_menu() {
  while true; do
    echo -e "\n======== QL青龙面板Docker管理 ======="
    echo "1. 部署QingLong容器"
    echo "2. 查看/已装容器"
    echo "3. 卸载QingLong"
    echo "4. 数据备份"
    echo "5. 数据恢复"
    echo "6. 退出"
    read -p "输入编号选择功能: " op
    case "$op" in
      1) install_ql ;;
      2) list_containers ;;
      3) uninstall_ql ;;
      4) backup_ql ;;
      5) restore_ql ;;
      6) log INFO "Bye！"; exit 0 ;;
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
