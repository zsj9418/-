#!/bin/bash

DATA_DIR="$HOME/qinglong"
QL_IMAGE_BASE="whyour/qinglong"
DEFAULT_IMAGE_VER="latest"
DEFAULT_CONTAINER_NAME="qinglong"
DEFAULT_PORT=5700
LOG_FILE="$DATA_DIR/ql_script.log"
LOG_MAX_SIZE=1048576

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
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
  log "INFO" "必要目录已就绪"
}

check_dependencies() {
  if ! command -v docker >/dev/null 2>&1; then
    log ERROR "未安装 Docker，请先安装 Docker！"
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log WARN "未安装 'jq'，无损升级功能依赖它，正在尝试安装..."
    if command -v apt-get >/dev/null; then apt-get update && apt-get install -y jq
    elif command -v yum >/dev/null; then yum install -y epel-release && yum install -y jq
    elif command -v apk >/dev/null; then apk add jq
    elif command -v opkg >/dev/null; then opkg update && opkg install jq
    else
      log ERROR "无法自动安装 jq，请手动安装后重试！"
      exit 1
    fi
    log INFO "jq 安装完成。"
  fi
}

port_is_free() {
  local port=$1
  if command -v ss >/dev/null; then
      ss -tuln 2>/dev/null | grep -q ":$port\b" && return 1
  elif command -v netstat >/dev/null; then
      netstat -tuln 2>/dev/null | grep -q ":$port\b" && return 1
  elif command -v lsof >/dev/null; then
      lsof -i:"$port" 2>/dev/null | grep -q LISTEN && return 1
  fi
  return 0
}

prompt_port() {
  local prompt=$1 def=$2 input
  while true; do
    read -p "$prompt [$def]: " input
    input=${input:-$def}
    [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ] || {
      log WARN "端口号必须在1-65535之间"
      continue
    }
    if port_is_free "$input"; then
      echo "$input"
      return
    else
      log WARN "端口 $input 已被占用，请更换"
    fi
  done
}

prompt_container_name() {
  local prompt=$1 def=$2 input
  read -p "$prompt [$def]: " input
  input=${input:-$def}
  echo "$input"
}

get_container_port() {
  local cname=$1
  docker inspect --format='{{(index (index .NetworkSettings.Ports "5700/tcp") 0).HostPort}}' "$cname" 2>/dev/null
}

#===== 部署、备份、恢复 =====#

install_ql() {
  local name port image
  name=$(prompt_container_name "请输入容器名称" "$DEFAULT_CONTAINER_NAME")
  port=$(prompt_port "请输入 WebUI 端口" "$DEFAULT_PORT")
  image="$QL_IMAGE_BASE:$DEFAULT_IMAGE_VER"

  if docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    log WARN "容器 $name 已存在，不能重复部署"
    return
  fi

  log INFO "正在拉取青龙镜像 $image..."
  docker pull "$image" || { log ERROR "镜像拉取失败，请检查网络"; exit 1; }

  log INFO "正在启动容器 $name，映射端口 $port..."
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

  log INFO "🎉 青龙容器 $name 部署完成！"
  echo -e "${CYAN}访问面板: http://$(hostname -I | awk '{print $1}'):$port${NC}"
  echo -e "${CYAN}默认账号/密码: admin / admin (请在初始配置后及时修改)${NC}"
}

list_containers() {
  echo -e "\n${CYAN}--- 当前 Docker 容器列表 ---${NC}"
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"
  echo ""
}

uninstall_ql() {
  local name
  name=$(prompt_container_name "请输入要卸载的容器名" "$DEFAULT_CONTAINER_NAME")
  if docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    read -p "确定要停止并删除容器 $name 吗？数据目录不会被删除。(y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        docker stop "$name" >/dev/null 2>&1
        docker rm "$name" >/dev/null 2>&1
        log INFO "容器 $name 已成功删除"
    else
        log INFO "已取消卸载"
    fi
  else
    log WARN "找不到名为 $name 的容器"
  fi
}

backup_ql() {
  local ts backup_dir
  ts=$(date +%Y%m%d%H%M%S)
  backup_dir="$DATA_DIR/backup/ql_backup_$ts.tar.gz"
  log INFO "开始备份数据..."
  tar -czf "$backup_dir" -C "$DATA_DIR" config log db repo raw scripts jbot
  log INFO "🎉 数据已成功备份至: $backup_dir"
}

restore_ql() {
  local latest
  latest=$(ls -t "$DATA_DIR/backup"/ql_backup_*.tar.gz 2>/dev/null | head -n1)
  if [[ ! -f $latest ]]; then
    log WARN "找不到任何备份文件！"
    return
  fi
  read -p "检测到最新备份: $latest，是否恢复？(y/N): " choice
  if [[ "$choice" =~ ^[Yy]$ ]]; then
      log INFO "正在恢复数据..."
      tar -xzf "$latest" -C "$DATA_DIR"
      log INFO "🎉 数据恢复完成！请重启青龙容器生效。"
  else
      log INFO "已取消恢复"
  fi
}

#===== 核心：无损升级模块 =====#

get_ql_versions() {
    local versions=""
    for i in {1..3}; do
        # 抓取 Qinglong Docker Hub 的 tag，排除 debian/alpine 变体，仅取纯数字版本
        versions=$(curl -s -m 10 "https://hub.docker.com/v2/repositories/whyour/qinglong/tags/?page_size=30" 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV)
        if [ -n "$versions" ]; then break; fi
        sleep 2
    done
    if [ -n "$versions" ]; then echo "latest $versions"; else echo ""; fi
}

upgrade_ql() {
  local name
  name=$(prompt_container_name "请输入待升级的容器名" "$DEFAULT_CONTAINER_NAME")
  if ! docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    log ERROR "容器 <$name> 不存在，请先部署！"
    return
  fi

  echo -e "\n${CYAN}🔄 正在从 Docker Hub 获取青龙最新版本列表...${NC}"
  local versions_str=$(get_ql_versions)
  local versions=($versions_str)
  local num_versions=${#versions[@]}
  local target_version="latest"

  if [ $num_versions -eq 0 ]; then
      log WARN "由于网络问题无法获取版本列表。"
      read -p "请输入您要升级到的目标版本号 [直接回车默认: latest]: " manual_ver
      target_version=${manual_ver:-latest}
  else
      echo -e "${YELLOW}请选择要升级的目标版本：${NC}"
      for i in "${!versions[@]}"; do
          echo "$((i + 1)). ${versions[$i]}"
      done
      while true; do
          read -p "请输入版本编号 [直接回车默认选择 1 (latest)]: " ver_choice
          ver_choice=${ver_choice:-1}
          if [[ $ver_choice =~ ^[0-9]+$ ]] && [ "$ver_choice" -ge 1 ] && [ "$ver_choice" -le "$num_versions" ]; then
              target_version=${versions[$((ver_choice - 1))]}
              break
          else
              log ERROR "无效的选择，请重新输入"
          fi
      done
  fi

  local image="$QL_IMAGE_BASE:$target_version"
  echo -e "\n${YELLOW}ℹ️ 您的旧容器所有配置（端口、所有挂载目录、所有环境变量）将被完美保留。${NC}"
  log INFO "正在拉取新镜像: $image..."
  docker pull "$image" || { log ERROR "镜像拉取失败，请检查网络！"; return; }

  log INFO "正在提取当前容器 <$name> 的详细配置参数..."
  local c_info=$(docker inspect "$name")
  
  local net_mode=$(echo "$c_info" | jq -r '.[0].HostConfig.NetworkMode')
  local restart_policy=$(echo "$c_info" | jq -r '.[0].HostConfig.RestartPolicy.Name')
  
  # 初始化重建参数 (青龙默认需要 -dit 而不是仅仅 -d)
  local -a run_args=("-dit" "--name" "$name" "--hostname" "$name")
  
  [[ -n "$restart_policy" && "$restart_policy" != "no" && "$restart_policy" != "null" ]] && run_args+=("--restart" "$restart_policy")
  [[ -n "$net_mode" && "$net_mode" != "default" && "$net_mode" != "null" ]] && run_args+=("--network" "$net_mode")

  # 提取所有映射端口
  if [ "$net_mode" != "host" ]; then
      local -a ports
      mapfile -t ports < <(echo "$c_info" | jq -r 'if .[0].HostConfig.PortBindings then .[0].HostConfig.PortBindings | to_entries[] | "-p", "\(.value[0].HostPort):\(.key)" else empty end')
      (( ${#ports[@]} > 0 )) && run_args+=("${ports[@]}")
  fi

  # 提取所有挂载卷 (完美兼容用户自行添加的 Ninja、依赖等额外挂载)
  local -a mounts
  mapfile -t mounts < <(echo "$c_info" | jq -r '.[0].Mounts[]? | "-v", "\(.Source):\(.Destination)"')
  (( ${#mounts[@]} > 0 )) && run_args+=("${mounts[@]}")

  # 提取自定义环境变量 (过滤系统自带变量防止新版本冲突)
  local -a envs
  mapfile -t envs < <(echo "$c_info" | jq -r '.[0].Config.Env[]? | select(test("^PATH=|^HOSTNAME=|^HOME=|PWD=") | not) | "-e", .')
  (( ${#envs[@]} > 0 )) && run_args+=("${envs[@]}")

  log INFO "🗑️ 正在停止并销毁旧容器..."
  docker stop "$name" >/dev/null 2>&1
  docker rm "$name" >/dev/null 2>&1

  log INFO "🚀 正在使用新镜像和旧配置重建容器..."
  docker run "${run_args[@]}" "$image" >/dev/null 2>&1
  
  if [ $? -eq 0 ]; then
      log INFO "🎉 青龙容器 <$name> 已成功无损升级至 $target_version ！"
      local old_port=$(get_container_port "$name")
      [[ -n "$old_port" ]] && echo -e "${CYAN}访问面板: http://$(hostname -I | awk '{print $1}'):$old_port${NC}"
  else
      log ERROR "❌ 升级后容器启动失败，请运行 'docker logs $name' 检查原因。"
  fi
}

#===== 主菜单 =====#

show_menu() {
  while true; do
    echo -e "\n${CYAN}======== QL青龙面板 Docker 管家 =======${NC}"
    echo "1. 部署 QingLong 容器"
    echo -e "2. 无损升级 QingLong 面板 ${YELLOW}[保留全部高级配置]${NC}"
    echo "3. 查看当前运行的容器"
    echo "4. 卸载 QingLong 容器"
    echo "5. 一键数据备份"
    echo "6. 一键数据恢复"
    echo "7. 退出"
    echo -e "${CYAN}=======================================${NC}"
    read -p "请输入选项编号: " op
    case "$op" in
      1) install_ql ;;
      2) upgrade_ql ;;
      3) list_containers ;;
      4) uninstall_ql ;;
      5) backup_ql ;;
      6) restore_ql ;;
      7) echo -e "${GREEN}感谢使用，再见！${NC}"; exit 0 ;;
      *) log ERROR "无效输入，请重新输入" ;;
    esac
  done
}

main() {
  check_dependencies
  make_directories
  show_menu
}

main "$@"
