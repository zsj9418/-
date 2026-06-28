#!/bin/bash

DATA_DIR="$HOME/qinglong"
QL_IMAGE_BASE="whyour/qinglong"
DEFAULT_IMAGE_VER="latest"
INSTALL_DEFAULT_VER="2.20.2"
DEFAULT_CONTAINER_NAME="qinglong"
DEFAULT_PORT=5700
LOG_FILE="$DATA_DIR/ql_script.log"
LOG_MAX_SIZE=1048576

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ======================= 日志 =======================
log() {
  local level=$1 msg=$2 timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  case "$level" in
    INFO)  echo -e "${GREEN}[INFO] $msg${NC}" >&2 ;;
    WARN)  echo -e "${YELLOW}[WARN] $msg${NC}" >&2 ;;
    ERROR) echo -e "${RED}[ERROR] $msg${NC}" >&2 ;;
    STEP)  echo -e "${CYAN}${BOLD}[STEP] $msg${NC}" >&2 ;;
    OK)    echo -e "${GREEN}${BOLD}[✓ OK] $msg${NC}" >&2 ;;
    SKIP)  echo -e "${YELLOW}[SKIP] $msg${NC}" >&2 ;;
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
    if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y jq
    elif command -v yum >/dev/null; then yum install -y epel-release && yum install -y jq
    elif command -v apk >/dev/null; then apk add -q jq
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

# ======================= 版本选择 =======================
select_version() {
  local default_ver="${1:-latest}"
  local show_count="${2:-5}"

  echo -e "\n${CYAN}🔄 正在从 Docker Hub 获取青龙版本列表...${NC}" >&2

  local raw_versions=""
  for i in {1..3}; do
    raw_versions=$(
      curl -s -m 10 \
        "https://hub.docker.com/v2/namespaces/whyour/repositories/qinglong/tags?page_size=50" \
        2>/dev/null \
      | jq -r '.results[].name' 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -rV \
      | head -n "$show_count"
    )
    [[ -n "$raw_versions" ]] && break
    log WARN "第 $i 次获取版本列表失败，重试中..." >&2
    sleep 2
  done

  local -a versions=()
  if [[ -n "$raw_versions" ]]; then
    versions+=("$default_ver")
    while IFS= read -r ver; do
      [[ "$ver" != "$default_ver" ]] && versions+=("$ver")
    done <<< "$raw_versions"

    echo -e "${YELLOW}请选择版本（直接回车默认选 1: $default_ver）：${NC}" >&2
    for i in "${!versions[@]}"; do
      if [[ "${versions[$i]}" == "$default_ver" ]]; then
        echo -e "  $((i+1)). ${versions[$i]}  ${GREEN}← 默认推荐${NC}" >&2
      else
        echo "  $((i+1)). ${versions[$i]}" >&2
      fi
    done

    local choice num_versions=${#versions[@]}
    while true; do
      read -p "请输入版本编号 [默认 1]: " choice >&2
      choice=${choice:-1}
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= num_versions )); then
        echo "${versions[$((choice-1))]}"
        return 0
      else
        log ERROR "无效选择，请输入 1~$num_versions 之间的数字" >&2
      fi
    done
  else
    log WARN "无法获取远端版本列表，请手动输入版本号" >&2
    local manual_ver
    read -p "请输入版本号 [直接回车默认: $default_ver]: " manual_ver >&2
    echo "${manual_ver:-$default_ver}"
  fi
}

# ======================= 部署 =======================
install_ql() {
  local name port target_version image image_variant

  name=$(prompt_container_name "请输入容器名称" "$DEFAULT_CONTAINER_NAME")
  port=$(prompt_port "请输入 WebUI 端口" "$DEFAULT_PORT")

  if docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    log WARN "容器 $name 已存在，不能重复部署"
    return
  fi

  # 新增：镜像变体选择（修复 Alpine 下某些依赖编译失败的问题）
  echo -e "\n${YELLOW}请选择镜像类型：${NC}"
  echo "  1. alpine (默认轻量版，latest)"
  echo "  2. debian  (兼容更多依赖，推荐复杂脚本环境)"
  read -p "请选择 [1/2，默认1]: " img_choice
  case "${img_choice:-1}" in
    2) image_variant="debian" ;;
    *) image_variant="" ;;
  esac

  target_version=$(select_version "$INSTALL_DEFAULT_VER" 5)

  if [[ -n "$image_variant" ]]; then
    image="$QL_IMAGE_BASE:$image_variant"
  else
    image="$QL_IMAGE_BASE:$target_version"
  fi

  log INFO "正在拉取青龙镜像 $image ..."
  docker pull "$image" || { log ERROR "镜像拉取失败，请检查网络"; return 1; }

  log INFO "正在启动容器 $name，端口映射 $port:5700 ..."
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
    "$image" || { log ERROR "容器启动失败"; return 1; }

  log INFO "🎉 青龙容器 $name 部署完成！版本/类型: $image"
  echo -e "${CYAN}访问面板: http://$(hostname -I | awk '{print $1}'):$port${NC}"
  echo ""

  # 部署完成后询问是否立即安装全依赖
  read -p "$(echo -e ${GREEN})是否立即执行全依赖环境补全？强烈推荐！(Y/n): $(echo -e ${NC})" do_dep
  if [[ ! "${do_dep:-Y}" =~ ^[Nn]$ ]]; then
    log INFO "⏳ 等待容器就绪（15秒）..."
    sleep 15
    install_all_deps "$name"
  fi
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

# ======================= 无损升级 =======================
upgrade_ql() {
  local name
  name=$(prompt_container_name "请输入待升级的容器名" "$DEFAULT_CONTAINER_NAME")
  if ! docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    log ERROR "容器 <$name> 不存在，请先部署！"
    return
  fi

  local target_version
  target_version=$(select_version "$DEFAULT_IMAGE_VER" 5)
  local image="$QL_IMAGE_BASE:$target_version"

  echo -e "\n${YELLOW}ℹ️ 旧容器所有配置（端口、挂载目录、环境变量）将被完美保留。${NC}"
  log INFO "正在拉取新镜像: $image ..."
  docker pull "$image" || { log ERROR "镜像拉取失败，请检查网络！"; return; }

  log INFO "正在提取当前容器 <$name> 的配置参数..."
  local c_info
  c_info=$(docker inspect "$name")

  local net_mode restart_policy
  net_mode=$(echo "$c_info" | jq -r '.[0].HostConfig.NetworkMode')
  restart_policy=$(echo "$c_info" | jq -r '.[0].HostConfig.RestartPolicy.Name')

  local -a run_args=("-dit" "--name" "$name" "--hostname" "$name")

  [[ -n "$restart_policy" && "$restart_policy" != "no" && "$restart_policy" != "null" ]] \
    && run_args+=("--restart" "$restart_policy")
  [[ -n "$net_mode" && "$net_mode" != "default" && "$net_mode" != "null" ]] \
    && run_args+=("--network" "$net_mode")

  if [[ "$net_mode" != "host" ]]; then
    local -a ports
    mapfile -t ports < <(
      echo "$c_info" | jq -r \
        'if .[0].HostConfig.PortBindings
         then .[0].HostConfig.PortBindings | to_entries[]
              | "-p", "\(.value[0].HostPort):\(.key)"
         else empty end'
    )
    (( ${#ports[@]} > 0 )) && run_args+=("${ports[@]}")
  fi

  local -a mounts
  mapfile -t mounts < <(
    echo "$c_info" | jq -r '.[0].Mounts[]? | "-v", "\(.Source):\(.Destination)"'
  )
  (( ${#mounts[@]} > 0 )) && run_args+=("${mounts[@]}")

  local -a envs
  mapfile -t envs < <(
    echo "$c_info" | jq -r \
      '.[0].Config.Env[]? | select(test("^PATH=|^HOSTNAME=|^HOME=|^PWD=") | not) | "-e", .'
  )
  (( ${#envs[@]} > 0 )) && run_args+=("${envs[@]}")

  log INFO "🗑️ 正在停止并销毁旧容器..."
  docker stop "$name" >/dev/null 2>&1
  docker rm   "$name" >/dev/null 2>&1

  log INFO "🚀 正在使用新镜像和旧配置重建容器..."
  if docker run "${run_args[@]}" "$image" >/dev/null 2>&1; then
    log INFO "🎉 青龙容器 <$name> 已成功无损升级至 $target_version ！"
    local old_port
    old_port=$(get_container_port "$name")
    [[ -n "$old_port" ]] && \
      echo -e "${CYAN}访问面板: http://$(hostname -I | awk '{print $1}'):$old_port${NC}"
  else
    log ERROR "❌ 升级后容器启动失败，请运行 'docker logs $name' 检查原因。"
  fi
}

# ================================================================
#  ★★★ 核心新增：全依赖环境一键补全模块 ★★★
#  修复来源：2025-2026 网友反馈问题汇总
#  覆盖：Alpine 系统编译环境 / pip修复 / pnpm源修复 /
#        NodeJS 全依赖 / Python3 全依赖 / canvas 编译 / 失败重试
# ================================================================

# ------ 内部：进度条打印 ------
_progress_bar() {
  local current=$1 total=$2 width=40
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  printf "\r  ${CYAN}[%s]${NC} %d/%d" "$bar" "$current" "$total" >&2
}

# ------ 内部：单包安装（pnpm 优先，npm 降级，带重试）------
_install_npm_pkg() {
  local pkg=$1 cname=$2
  local ok=0
  for attempt in 1 2; do
    if docker exec "$cname" bash -c "cd /ql/scripts && pnpm install '$pkg' --prefer-offline 2>/dev/null || pnpm add '$pkg' 2>/dev/null" >/dev/null 2>&1; then
      ok=1; break
    fi
    # pnpm 失败降级到 npm
    if docker exec "$cname" bash -c "npm install '$pkg' --prefix /ql/scripts 2>/dev/null" >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep 1
  done
  return $(( 1 - ok ))
}

# ------ 内部：单包安装 pip（带重试）------
_install_pip_pkg() {
  local pkg=$1 cname=$2
  local ok=0
  for attempt in 1 2; do
    if docker exec "$cname" bash -c "pip3 install '$pkg' -q 2>/dev/null" >/dev/null 2>&1; then
      ok=1; break
    fi
    # 尝试 pycryptodome 替代 Crypto
    if [[ "$pkg" == "Crypto" ]]; then
      if docker exec "$cname" bash -c "pip3 install pycryptodome -q 2>/dev/null" >/dev/null 2>&1; then
        ok=1; break
      fi
    fi
    sleep 1
  done
  return $(( 1 - ok ))
}

# ------ 主函数：全依赖一键补全 ------
install_all_deps() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name=$(prompt_container_name "请输入青龙容器名" "$DEFAULT_CONTAINER_NAME")
  fi

  # 验证容器是否存在且运行中
  if ! docker ps --format "{{.Names}}" | grep -qw "$name"; then
    log ERROR "容器 <$name> 不存在或未运行，请先部署并启动！"
    return 1
  fi

  echo -e "\n${CYAN}${BOLD}════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}   🐉 青龙全依赖环境补全 2025-2026 Edition      ${NC}"
  echo -e "${CYAN}${BOLD}   容器: $name${NC}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════${NC}\n"

  # ────────────────────────────────────────────────
  # STEP 1：检测容器内 OS 类型（Alpine / Debian）
  # ────────────────────────────────────────────────
  log STEP "[1/7] 检测容器系统环境..."
  local os_type="alpine"
  if docker exec "$name" bash -c "cat /etc/os-release 2>/dev/null" | grep -qi "debian\|ubuntu"; then
    os_type="debian"
    log INFO "检测到 Debian/Ubuntu 系镜像"
  else
    log INFO "检测到 Alpine 系镜像"
  fi

  # ────────────────────────────────────────────────
  # STEP 2：安装系统级编译环境（修复 Pillow/canvas/lxml 编译失败）
  # ────────────────────────────────────────────────
  log STEP "[2/7] 安装系统编译依赖（修复 canvas / Pillow / lxml 构建失败）..."

  if [[ "$os_type" == "alpine" ]]; then
    docker exec "$name" bash -c "
      apk update -q 2>/dev/null
      apk add --no-cache -q \
        build-base g++ gcc make \
        cairo-dev pango-dev giflib-dev \
        python3-dev py3-pip \
        jpeg-dev zlib-dev freetype-dev \
        libxml2-dev libxslt-dev \
        musl-dev libffi-dev \
        tzdata curl wget git \
        libc-dev linux-headers \
        2>/dev/null
    " && log OK "Alpine 系统依赖安装完成" || log WARN "部分系统依赖安装失败（不影响主要功能）"
  else
    docker exec "$name" bash -c "
      apt-get update -qq 2>/dev/null
      apt-get install -y -q \
        build-essential gcc g++ make \
        libcairo2-dev libpango1.0-dev libgif-dev \
        python3-dev python3-pip \
        libjpeg-dev zlib1g-dev libfreetype6-dev \
        libxml2-dev libxslt1-dev \
        libffi-dev \
        tzdata curl wget git \
        2>/dev/null
    " && log OK "Debian 系统依赖安装完成" || log WARN "部分系统依赖安装失败（不影响主要功能）"
  fi

  # ────────────────────────────────────────────────
  # STEP 3：修复 pnpm 源（ERR_PNPM_REGISTRIES_MISMATCH 修复）
  # ────────────────────────────────────────────────
  log STEP "[3/7] 修复 pnpm / npm 镜像源（修复 ERR_PNPM_REGISTRIES_MISMATCH）..."
  docker exec "$name" bash -c "
    # 重置 pnpm store 和 registry（修复 v2.13+ 版本 registries 冲突）
    pnpm config set registry https://registry.npmmirror.com 2>/dev/null
    npm config set registry https://registry.npmmirror.com 2>/dev/null
    # 删除残留的 pnpm modules 元数据锁（防止 mismatch 错误）
    rm -f /ql/scripts/node_modules/.modules.yaml 2>/dev/null
    cd /ql/scripts && pnpm install 2>/dev/null || true
  " && log OK "pnpm/npm 源修复完成（已切换至 npmmirror）" || log WARN "源修复部分失败，将继续安装"

  # ────────────────────────────────────────────────
  # STEP 4：修复 pip（解决 Python3 依赖装不上的根因）
  # ────────────────────────────────────────────────
  log STEP "[4/7] 修复并升级 pip（解决 Python3 依赖安装失败）..."
  docker exec "$name" bash -c "
    # 官方方式重装最新 pip（最稳妥）
    curl -sS https://bootstrap.pypa.io/get-pip.py | python3 2>/dev/null
    # 升级 pip setuptools wheel（Pillow 编译必需）
    pip3 install --upgrade pip setuptools wheel 2>/dev/null
    # 切换为清华镜像源（规避阿里云证书不信任问题 v2.17.9+）
    pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple 2>/dev/null
    pip3 config set global.trusted-host pypi.tuna.tsinghua.edu.cn 2>/dev/null
  " && log OK "pip 修复并升级完成（已切换清华源）" || log WARN "pip 修复部分失败，将继续"

  # ────────────────────────────────────────────────
  # STEP 5：安装 NodeJS 全依赖
  # ────────────────────────────────────────────────
  log STEP "[5/7] 安装 NodeJS 依赖包..."

  # 完整依赖列表（根据2025年社区反馈整合）
  local npm_pkgs=(
    # 核心网络/请求
    "axios" "axios@0.27.2" "request" "got" "node-fetch" "https-proxy-agent" "tunnel"
    # 加解密
    "crypto-js" "ts-md5" "jsencrypt" "node-jsencrypt" "node-rsa" "js-base64"
    # 时间处理
    "date-fns" "moment"
    # 数据处理
    "json5" "qs" "form-data" "dotenv"
    # DOM/爬虫
    "jsdom" "cheerio" "xmldom"
    # Cookie
    "tough-cookie"
    # TypeScript 相关
    "typescript" "tslib" "ts-node" "@types/node"
    # WebSocket
    "ws@7.4.3"
    # 网络代理
    "global-agent"
    # 图像处理
    "png-js" "sharp"
    # 工具类
    "prettytable" "jieba" "require" "fs" "common" "ds" "ql"
    # 通知/Bot
    "node-telegram-bot-api"
    # 其他常用
    "magic" "cjs" "http-server" "download"
    # 京东系常用
    "juejin-helper" "yml2213-utils"
  )

  local total_npm=${#npm_pkgs[@]}
  local ok_npm=0 fail_npm=0
  local failed_npm_list=()

  for i in "${!npm_pkgs[@]}"; do
    _progress_bar $((i+1)) $total_npm
    pkg="${npm_pkgs[$i]}"
    if _install_npm_pkg "$pkg" "$name"; then
      (( ok_npm++ ))
    else
      (( fail_npm++ ))
      failed_npm_list+=("$pkg")
    fi
  done
  echo "" >&2  # 换行

  # 安装全局包（TypeScript / jieba 需要全局）
  docker exec "$name" bash -c "
    npm install -g typescript ts-node jieba jsdom 2>/dev/null || true
  " >/dev/null 2>&1

  log OK "NodeJS 依赖安装完成：成功 $ok_npm / 失败 $fail_npm（总 $total_npm）"
  if (( ${#failed_npm_list[@]} > 0 )); then
    log WARN "以下 npm 包安装失败（通常不影响主要功能）："
    printf "    %s\n" "${failed_npm_list[@]}" >&2
  fi

  # ────────────────────────────────────────────────
  # STEP 6：安装 canvas（单独处理，需从源码编译）
  # ────────────────────────────────────────────────
  log STEP "[6/7] 安装 canvas（需从源码编译，可能耗时较长）..."
  local canvas_ok=0
  # 先尝试预编译包（快）
  if docker exec "$name" bash -c "
    cd /ql/scripts
    pnpm install canvas 2>/dev/null || npm install canvas 2>/dev/null
  " >/dev/null 2>&1; then
    log OK "canvas 安装成功（预编译包）"
    canvas_ok=1
  fi

  # 预编译失败则尝试源码编译
  if [[ $canvas_ok -eq 0 ]]; then
    log WARN "预编译包失败，尝试源码编译 canvas（需要约2-5分钟）..."
    if docker exec "$name" bash -c "
      cd /ql/scripts
      npm install canvas --build-from-source 2>/dev/null
    " >/dev/null 2>&1; then
      log OK "canvas 源码编译安装成功"
    else
      log WARN "canvas 安装失败（可忽略，除非脚本明确需要它）"
    fi
  fi

  # ────────────────────────────────────────────────
  # STEP 7：安装 Python3 全依赖
  # ────────────────────────────────────────────────
  log STEP "[7/7] 安装 Python3 依赖包..."

  local pip_pkgs=(
    # 网络请求
    "requests" "httpx" "aiohttp"
    # 加解密
    "pycryptodome" "rsa"
    # HTML解析
    "bs4" "lxml"
    # 执行JS
    "PyExecJS"
    # 图像
    "Pillow"
    # 网络检测
    "ping3"
    # 中文分词
    "jieba"
    # 缓存
    "redis"
    # AI相关
    "openai"
    # 文件魔数
    "python-magic"
    # 其他常用
    "pytz" "pyyaml" "urllib3" "certifi"
  )

  local total_pip=${#pip_pkgs[@]}
  local ok_pip=0 fail_pip=0
  local failed_pip_list=()

  for i in "${!pip_pkgs[@]}"; do
    _progress_bar $((i+1)) $total_pip
    pkg="${pip_pkgs[$i]}"
    if _install_pip_pkg "$pkg" "$name"; then
      (( ok_pip++ ))
    else
      (( fail_pip++ ))
      failed_pip_list+=("$pkg")
    fi
  done
  echo "" >&2

  log OK "Python3 依赖安装完成：成功 $ok_pip / 失败 $fail_pip（总 $total_pip）"
  if (( ${#failed_pip_list[@]} > 0 )); then
    log WARN "以下 pip 包安装失败（通常不影响主要功能）："
    printf "    %s\n" "${failed_pip_list[@]}" >&2
  fi

  # ────────────────────────────────────────────────
  # 最终：重启容器使所有依赖生效
  # ────────────────────────────────────────────────
  echo -e "\n${CYAN}${BOLD}════════════════════════════════════════════════${NC}" >&2
  echo -e "${GREEN}${BOLD}  ✅ 全依赖环境补全完成！${NC}" >&2
  echo -e "  NodeJS : 成功 ${GREEN}$ok_npm${NC} / 失败 ${RED}$fail_npm${NC}" >&2
  echo -e "  Python3: 成功 ${GREEN}$ok_pip${NC} / 失败 ${RED}$fail_pip${NC}" >&2
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════${NC}\n" >&2

  read -p "是否立即重启容器 $name 使依赖生效？(Y/n): " restart_choice
  if [[ ! "${restart_choice:-Y}" =~ ^[Nn]$ ]]; then
    log INFO "正在重启容器 $name ..."
    docker restart "$name" >/dev/null 2>&1
    log OK "容器 $name 已重启，依赖全部生效！"
    local access_port
    access_port=$(get_container_port "$name")
    [[ -n "$access_port" ]] && \
      echo -e "${CYAN}面板访问: http://$(hostname -I | awk '{print $1}'):$access_port${NC}"
  else
    log INFO "跳过重启，请手动执行: docker restart $name"
  fi
}

# ======================= 依赖修复（独立入口）=======================
repair_deps() {
  local name
  name=$(prompt_container_name "请输入要修复依赖的青龙容器名" "$DEFAULT_CONTAINER_NAME")

  if ! docker ps --format "{{.Names}}" | grep -qw "$name"; then
    log ERROR "容器 <$name> 不存在或未运行！"
    return 1
  fi

  echo -e "\n${YELLOW}请选择修复模式：${NC}"
  echo "  1. 全量安装（所有依赖重新补全，推荐首次或大规模修复）"
  echo "  2. 仅修复 pnpm 源错误（ERR_PNPM_REGISTRIES_MISMATCH）"
  echo "  3. 仅修复 pip / Python3 依赖"
  echo "  4. 仅修复 canvas 编译失败"
  read -p "请选择 [1-4，默认1]: " repair_mode

  case "${repair_mode:-1}" in
    1) install_all_deps "$name" ;;
    2)
      log STEP "修复 pnpm 源..."
      docker exec "$name" bash -c "
        pnpm config set registry https://registry.npmmirror.com
        npm config set registry https://registry.npmmirror.com
        rm -f /ql/scripts/node_modules/.modules.yaml
        cd /ql/scripts && pnpm install 2>/dev/null || true
      " && log OK "pnpm 源修复完成" || log ERROR "修复失败，请手动检查"
      ;;
    3)
      log STEP "修复 pip 并重装 Python3 依赖..."
      docker exec "$name" bash -c "
        curl -sS https://bootstrap.pypa.io/get-pip.py | python3
        pip3 install --upgrade pip setuptools wheel
        pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
        pip3 config set global.trusted-host pypi.tuna.tsinghua.edu.cn
        pip3 install requests httpx aiohttp pycryptodome rsa bs4 lxml PyExecJS ping3 jieba redis Pillow pytz pyyaml
      " && log OK "Python3 依赖修复完成" || log ERROR "Python3 修复失败"
      ;;
    4)
      log STEP "修复 canvas 编译..."
      docker exec "$name" bash -c "
        apk add --no-cache build-base g++ cairo-dev pango-dev giflib-dev 2>/dev/null || \
        apt-get install -y build-essential libcairo2-dev libpango1.0-dev libgif-dev 2>/dev/null
        cd /ql/scripts && npm install canvas --build-from-source
      " && log OK "canvas 修复完成" || log ERROR "canvas 修复失败（可能不支持当前平台）"
      ;;
    *)
      log ERROR "无效选择"
      ;;
  esac
}

# ======================= 主菜单 =======================
show_menu() {
  while true; do
    echo -e "\n${CYAN}${BOLD}======== QL青龙面板 Docker 管家 v3.0 =======${NC}"
    echo "  1. 部署 QingLong 容器"
    echo -e "  2. 无损升级 QingLong 面板 ${YELLOW}[保留全部高级配置]${NC}"
    echo "  3. 查看当前运行的容器"
    echo "  4. 卸载 QingLong 容器"
    echo "  5. 一键数据备份"
    echo "  6. 一键数据恢复"
    echo -e "  ${GREEN}${BOLD}7. ★ 全依赖环境一键补全（新增核心功能）${NC}"
    echo -e "  ${YELLOW}8. 依赖修复工具（源/pip/canvas 专项修复）${NC}"
    echo "  9. 退出"
    echo -e "${CYAN}${BOLD}===========================================${NC}"
    read -p "请输入选项编号: " op
    case "$op" in
      1) install_ql ;;
      2) upgrade_ql ;;
      3) list_containers ;;
      4) uninstall_ql ;;
      5) backup_ql ;;
      6) restore_ql ;;
      7) install_all_deps ;;
      8) repair_deps ;;
      9) echo -e "${GREEN}感谢使用，再见！${NC}"; exit 0 ;;
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
