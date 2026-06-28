#!/bin/bash

DATA_DIR="$HOME/qinglong"
QL_IMAGE_BASE="whyour/qinglong"
DEFAULT_IMAGE_VER="latest"
INSTALL_DEFAULT_VER="2.20.2"
DEFAULT_CONTAINER_NAME="qinglong"
DEFAULT_PORT=5700
LOG_FILE="$DATA_DIR/ql_script.log"
LOG_MAX_SIZE=1048576
# 本地凭证缓存文件（避免每次重复输入）
CRED_CACHE_FILE="$DATA_DIR/config/.ql_api_creds"

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
    TIP)   echo -e "${BLUE}${BOLD}[TIP] $msg${NC}" >&2 ;;
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
    log ERROR "未安装 Docker，请先安装 Docker！"; exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log WARN "未安装 jq，正在尝试安装..."
    if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y jq
    elif command -v yum >/dev/null; then yum install -y epel-release && yum install -y jq
    elif command -v apk >/dev/null; then apk add -q jq
    elif command -v opkg >/dev/null; then opkg update && opkg install jq
    else log ERROR "无法自动安装 jq，请手动安装后重试！"; exit 1; fi
    log INFO "jq 安装完成"
  fi
}
# ── 存储空间检测（安装依赖前自动调用）──
check_disk_space() {
  local min_gb=3  # 最低要求 3GB 可用空间
  local warn_gb=5 # 建议 5GB 以上
  local target_dir="${1:-$DATA_DIR}"

  # 获取可用空间（MB）
  local avail_mb
  avail_mb=$(df -m "$target_dir" 2>/dev/null | awk 'NR==2{print $4}')

  if [[ -z "$avail_mb" ]]; then
    log WARN "无法检测磁盘空间，请确保有足够剩余空间"
    return 0
  fi

  local avail_gb=$(( avail_mb / 1024 ))

  echo -e "\n${CYAN}${BOLD}════ 磁盘空间检测 ════${NC}"
  echo -e "  目标路径 : $target_dir"
  echo -e "  当前可用 : ${avail_gb} GB (${avail_mb} MB)"
  echo -e "  最低需求 : ${min_gb} GB"
  echo -e "  推荐需求 : ${warn_gb} GB"

  if (( avail_mb < min_gb * 1024 )); then
    echo -e "  状态     : ${RED}${BOLD}❌ 空间严重不足！${NC}"
    echo -e "${RED}═══════════════════════${NC}\n"
    log ERROR "磁盘可用空间不足 ${min_gb}GB（当前 ${avail_gb}GB），安装可能失败！"
    read -p "空间不足，是否强制继续？风险自负 (y/N): " force
    [[ ! "${force:-N}" =~ ^[Yy]$ ]] && return 1
  elif (( avail_mb < warn_gb * 1024 )); then
    echo -e "  状态     : ${YELLOW}${BOLD}⚠️  空间偏低，建议清理后再安装${NC}"
    echo -e "${YELLOW}═══════════════════════${NC}\n"
    log WARN "磁盘可用空间 ${avail_gb}GB，建议至少 ${warn_gb}GB"
    read -p "空间偏低，是否继续？(Y/n): " cont
    [[ "${cont:-Y}" =~ ^[Nn]$ ]] && return 1
  else
    echo -e "  状态     : ${GREEN}${BOLD}✅ 空间充足${NC}"
    echo -e "${GREEN}═══════════════════════${NC}\n"
  fi

  # 显示各分区使用情况
  echo -e "${CYAN}── 磁盘使用详情 ──${NC}"
  df -h "$target_dir" | awk 'NR==1{print "  "$0} NR==2{print "  "$0}'

  # 检测青龙数据目录各子目录大小
  if [[ -d "$DATA_DIR" ]]; then
    echo -e "\n${CYAN}── 青龙数据目录占用 ──${NC}"
    du -sh "$DATA_DIR"/*/  2>/dev/null | \
      awk '{printf "  %-12s %s\n", $1, $2}'
    echo -e "  $(du -sh "$DATA_DIR" 2>/dev/null | awk '{print $1}')  合计"
  fi
  echo ""
  return 0
}
# ── Docker 镜像存储占用分析 ──
show_storage_report() {
  echo -e "\n${CYAN}${BOLD}════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}   💾 青龙面板存储占用分析报告               ${NC}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════${NC}"

  # Docker 镜像占用
  echo -e "\n${YELLOW}── Docker 镜像 ──${NC}"
  docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" \
    2>/dev/null | grep -E "qinglong|REPO" || echo "  无青龙相关镜像"

  # 容器层占用（运行中容器）
  echo -e "\n${YELLOW}── 运行中容器 ──${NC}"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" \
    2>/dev/null | grep -E "qinglong|NAMES" || echo "  无青龙容器在运行"

  # 宿主机数据目录
  echo -e "\n${YELLOW}── 宿主机数据目录 ($DATA_DIR) ──${NC}"
  if [[ -d "$DATA_DIR" ]]; then
    du -sh "$DATA_DIR"/*/  2>/dev/null | \
      sort -rh | awk '{printf "  %-10s  %s\n", $1, $2}'
    echo -e "  ──────────────────────"
    echo -e "  $(du -sh "$DATA_DIR" 2>/dev/null | awk '{print $1}')  总计"
  else
    echo "  数据目录不存在"
  fi

  # Docker 总体存储
  echo -e "\n${YELLOW}── Docker 全局存储 ──${NC}"
  docker system df 2>/dev/null || echo "  无法获取"

  echo -e "\n${CYAN}${BOLD}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}推荐预留空间: 个人使用 ≥5GB / 多库使用 ≥10GB${NC}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════${NC}\n"
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
      log WARN "端口号必须在1-65535之间"; continue
    }
    if port_is_free "$input"; then echo "$input"; return
    else log WARN "端口 $input 已被占用，请更换"; fi
  done
}

prompt_container_name() {
  local prompt=$1 def=$2 input
  read -p "$prompt [$def]: " input
  echo "${input:-$def}"
}

get_container_port() {
  local cname=$1
  docker inspect \
    --format='{{(index (index .NetworkSettings.Ports "5700/tcp") 0).HostPort}}' \
    "$cname" 2>/dev/null
}

# ======================= 版本选择 =======================
select_version() {
  local default_ver="${1:-latest}" show_count="${2:-5}"
  echo -e "\n${CYAN}🔄 正在从 Docker Hub 获取青龙版本列表...${NC}" >&2
  local raw_versions=""
  for i in {1..3}; do
    raw_versions=$(
      curl -s -m 10 \
        "https://hub.docker.com/v2/namespaces/whyour/repositories/qinglong/tags?page_size=50" \
      | jq -r '.results[].name' 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -rV | head -n "$show_count"
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
      else echo "  $((i+1)). ${versions[$i]}" >&2; fi
    done
    local choice num_versions=${#versions[@]}
    while true; do
      read -p "请输入版本编号 [默认 1]: " choice >&2
      choice=${choice:-1}
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= num_versions )); then
        echo "${versions[$((choice-1))]}"; return 0
      else log ERROR "无效选择，请输入 1~$num_versions 之间的数字" >&2; fi
    done
  else
    log WARN "无法获取远端版本列表，请手动输入版本号" >&2
    local manual_ver
    read -p "请输入版本号 [直接回车默认: $default_ver]: " manual_ver >&2
    echo "${manual_ver:-$default_ver}"
  fi
}

# ================================================================
#  ★★★ 核心修复：Open API 凭证获取（三路策略）★★★
#
#  策略优先级：
#  1. 读取本地缓存 ~/.ql_api_creds（上次成功保存的）
#  2. 从容器内 auth.json 自动解析（需面板已创建过应用）
#  3. 交互式手动输入（面板刚初始化，用户自己去面板复制）
# ================================================================

# ------ 保存凭证到本地缓存 ------
_save_creds() {
  local cname=$1 client_id=$2 client_secret=$3
  mkdir -p "$(dirname "$CRED_CACHE_FILE")"
  # 按容器名分组保存
  local tmp_file="${CRED_CACHE_FILE}.tmp"
  # 先移除旧的同名条目
  grep -v "^${cname}|" "$CRED_CACHE_FILE" 2>/dev/null > "$tmp_file" || true
  echo "${cname}|${client_id}|${client_secret}" >> "$tmp_file"
  mv "$tmp_file" "$CRED_CACHE_FILE"
  chmod 600 "$CRED_CACHE_FILE"
  log INFO "凭证已缓存到本地（下次无需重复输入）"
}

# ------ 从本地缓存读取凭证 ------
_load_cached_creds() {
  local cname=$1
  [[ ! -f "$CRED_CACHE_FILE" ]] && echo "" && return 1
  local line
  line=$(grep "^${cname}|" "$CRED_CACHE_FILE" 2>/dev/null | tail -1)
  [[ -z "$line" ]] && echo "" && return 1
  # 格式: cname|client_id|client_secret → 返回 client_id|client_secret
  echo "${line#*|}"
}

# ------ 从容器 auth.json 自动解析 ------
# 青龙 auth.json 中 applications 数组保存了已创建的 Open API 应用
_parse_auth_json() {
  local cname=$1
  local auth_json=""

  # 尝试多个可能路径（不同版本路径不同）
  for auth_path in \
    "/ql/data/config/auth.json" \
    "/ql/config/auth.json"; do
    auth_json=$(docker exec "$cname" bash -c \
      "cat '$auth_path' 2>/dev/null" 2>/dev/null)
    [[ -n "$auth_json" ]] && break
  done

  [[ -z "$auth_json" ]] && echo "" && return 1

  # 尝试从 applications 数组取第一个应用的凭证
  local client_id client_secret
  client_id=$(echo "$auth_json" | \
    jq -r '.applications[0].client_id // empty' 2>/dev/null)
  client_secret=$(echo "$auth_json" | \
    jq -r '.applications[0].client_secret // empty' 2>/dev/null)

  # 兼容旧版格式（直接存在根对象）
  if [[ -z "$client_id" ]]; then
    client_id=$(echo "$auth_json" | \
      jq -r '.tokens[0].client_id // .client_id // empty' 2>/dev/null)
    client_secret=$(echo "$auth_json" | \
      jq -r '.tokens[0].client_secret // .client_secret // empty' 2>/dev/null)
  fi

  if [[ -n "$client_id" && -n "$client_secret" ]]; then
    echo "${client_id}|${client_secret}"
  else
    echo "" && return 1
  fi
}

# ------ 显示 Open API 设置指引 ------
_show_openapi_guide() {
  local host_port="${1:-5700}"
  echo -e "\n${CYAN}${BOLD}════════════ Open API 应用创建指引 ════════════${NC}" >&2
  echo -e "${YELLOW}青龙 Open API 需要手动在面板创建应用才能使用！${NC}" >&2
  echo -e "" >&2
  echo -e "  ${BOLD}操作步骤：${NC}" >&2
  echo -e "  1. 浏览器访问面板：${CYAN}http://$(hostname -I | awk '{print $1}'):${host_port}${NC}" >&2
  echo -e "  2. 点击左下角 ${BOLD}「系统设置」${NC}（齿轮图标）" >&2
  echo -e "  3. 点击顶部 Tab → ${BOLD}「应用设置」${NC}" >&2
  echo -e "  4. 点击 ${GREEN}「添加应用」${NC} 按钮" >&2
  echo -e "  5. 填写名称（如 ${BOLD}ql-dep${NC}），权限 ${GREEN}全部勾选${NC}" >&2
  echo -e "  6. 点击 ${BOLD}「提交」${NC}" >&2
  echo -e "  7. 复制生成的 ${GREEN}Client ID${NC} 和 ${GREEN}Client Secret${NC}" >&2
  echo -e "" >&2
  echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════${NC}\n" >&2
}

# ------ 主函数：三路策略获取凭证 ------
# 返回格式: "client_id|client_secret"（通过 stdout）
# 同时自动缓存成功的凭证
_get_api_credentials() {
  local cname=$1 host_port="${2:-5700}"
  local creds=""

  # ── 策略1：读取本地缓存 ──
  creds=$(_load_cached_creds "$cname")
  if [[ -n "$creds" ]]; then
    log INFO "✅ 使用本地缓存凭证（如需更新请选择「清除凭证缓存」）"
    echo "$creds"
    return 0
  fi

  # ── 策略2：自动解析 auth.json ──
  log INFO "正在尝试自动读取容器 auth.json..."
  creds=$(_parse_auth_json "$cname")
  if [[ -n "$creds" ]]; then
    log OK "从 auth.json 自动读取凭证成功"
    _save_creds "$cname" "${creds%%|*}" "${creds##*|}"
    echo "$creds"
    return 0
  fi

  # ── 策略3：交互式手动输入 ──
  log WARN "无法自动获取凭证（auth.json 中未找到已创建的 API 应用）"
  _show_openapi_guide "$host_port"

  echo -e "${YELLOW}请选择操作：${NC}" >&2
  echo "  1. 我已在面板创建好应用，现在手动输入凭证" >&2
  echo "  2. 跳过 Open API（Linux依赖将降级为直接系统安装，面板不可见）" >&2
  read -p "请选择 [1/2，默认2]: " choice

  case "${choice:-2}" in
    1)
      local client_id client_secret
      echo -e "" >&2
      while true; do
        read -p "  请输入 Client ID: " client_id
        [[ -n "$client_id" ]] && break
        echo -e "  ${RED}Client ID 不能为空${NC}" >&2
      done
      while true; do
        read -p "  请输入 Client Secret: " client_secret
        [[ -n "$client_secret" ]] && break
        echo -e "  ${RED}Client Secret 不能为空${NC}" >&2
      done

      # 立即验证凭证是否有效
      log INFO "正在验证凭证有效性..."
      local test_token
      test_token=$(curl -s -m 10 \
        "http://localhost:${host_port}/open/auth/token?client_id=${client_id}&client_secret=${client_secret}" \
        2>/dev/null | jq -r '.data.token // empty' 2>/dev/null)

      if [[ -n "$test_token" ]]; then
        log OK "凭证验证成功！Token 已获取"
        _save_creds "$cname" "$client_id" "$client_secret"
        echo "${client_id}|${client_secret}"
        return 0
      else
        log ERROR "凭证验证失败！请检查 Client ID / Client Secret 是否正确"
        log WARN "降级为直接系统安装模式（面板 Linux 标签页不可见）"
        echo ""
        return 1
      fi
      ;;
    *)
      log WARN "跳过 Open API，Linux 依赖将直接系统安装（面板不可见）"
      echo ""
      return 1
      ;;
  esac
}

# ------ 获取 Bearer Token ------
_get_ql_token() {
  local cname=$1 host_port=$2
  local creds
  creds=$(_get_api_credentials "$cname" "$host_port")
  [[ -z "$creds" ]] && echo "" && return 1

  local client_id="${creds%%|*}"
  local client_secret="${creds##*|}"

  local token
  token=$(curl -s -m 10 \
    "http://localhost:${host_port}/open/auth/token?client_id=${client_id}&client_secret=${client_secret}" \
    2>/dev/null | jq -r '.data.token // empty' 2>/dev/null)

  if [[ -n "$token" ]]; then
    echo "$token"
  else
    # Token 失效，清除缓存，提示重新输入
    log WARN "Token 获取失败，已清除本地凭证缓存，请重新运行并输入凭证"
    grep -v "^${cname}|" "$CRED_CACHE_FILE" 2>/dev/null > "${CRED_CACHE_FILE}.bak" && \
      mv "${CRED_CACHE_FILE}.bak" "$CRED_CACHE_FILE" 2>/dev/null || true
    echo "" && return 1
  fi
}

# ================================================================
#  进度条
# ================================================================
_progress_bar() {
  local current=$1 total=$2 label="${3:-}" width=32
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  printf "\r  ${CYAN}[%s]${NC} %d/%d  %-20s" "$bar" "$current" "$total" "$label" >&2
}

# ================================================================
#  ★★★ 全依赖一键补全主函数 v3.2 ★★★
# ================================================================
install_all_deps() {
  check_disk_space || return 1
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name=$(prompt_container_name "请输入青龙容器名" "$DEFAULT_CONTAINER_NAME")
  fi

  if ! docker ps --format "{{.Names}}" | grep -qw "$name"; then
    log ERROR "容器 <$name> 不存在或未运行！"; return 1
  fi

  local host_port
  host_port=$(get_container_port "$name")
  [[ -z "$host_port" ]] && host_port="$DEFAULT_PORT"

  echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}   🐉 青龙全依赖环境补全 v3.2 - 2025 修复版            ${NC}"
  echo -e "${CYAN}${BOLD}   容器: $name  |  面板端口: $host_port                ${NC}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${NC}\n"

  # ── STEP 1：OS 检测 ──
  log STEP "[1/8] 检测容器系统环境..."
  local os_type="alpine"
  if docker exec "$name" bash -c "cat /etc/os-release 2>/dev/null" \
      | grep -qi "debian\|ubuntu"; then
    os_type="debian"
    log INFO "检测到 Debian 系镜像"
  else
    log INFO "检测到 Alpine 系镜像（官方 latest 默认）"
  fi

  # ── STEP 2：获取 Open API Token（核心修复点）──
  log STEP "[2/8] 获取青龙 Open API 授权凭证..."
  echo -e "" >&2

  # 等待面板 HTTP 服务就绪
  local wait_sec=0
  while (( wait_sec < 30 )); do
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -m 3 "http://localhost:$host_port" 2>/dev/null)
    [[ "$http_code" =~ ^[2-4] ]] && break
    log INFO "等待面板 HTTP 服务就绪... (${wait_sec}s)"
    sleep 5; (( wait_sec += 5 ))
  done

  local api_token="" api_available=0
  api_token=$(_get_ql_token "$name" "$host_port")
  if [[ -n "$api_token" ]]; then
    api_available=1
    log OK "Open API Token 获取成功 🎉"
    log INFO "Linux 依赖将通过 API 安装，面板 Linux 标签页可见 ✅"
  else
    log WARN "Open API 不可用，Linux 依赖将直接系统安装（面板不可见）"
    log TIP "执行完成后可从菜单选 [9] 重新注册 Linux 依赖到面板"
  fi

  # ── STEP 3：系统编译基础环境 ──
  log STEP "[3/8] 安装系统编译环境（修复 canvas/Pillow/bizCode 构建失败）..."
  if [[ "$os_type" == "alpine" ]]; then
    docker exec "$name" bash -c "
      apk update -q 2>/dev/null
      apk add --no-cache -q \
        alpine-sdk autoconf automake libtool \
        build-base g++ gcc make \
        cairo-dev pango-dev giflib-dev \
        python3-dev py3-pip \
        jpeg-dev zlib-dev freetype-dev \
        libxml2-dev libxslt-dev \
        musl-dev libffi-dev openssl-dev \
        tzdata curl wget git ca-certificates \
        libc-dev linux-headers \
        2>/dev/null
    " && log OK "Alpine 编译环境安装完成" || log WARN "部分系统包安装失败（不影响主要功能）"
  else
    docker exec "$name" bash -c "
      apt-get update -qq 2>/dev/null
      apt-get install -y -q \
        build-essential gcc g++ make autoconf automake libtool \
        libcairo2-dev libpango1.0-dev libgif-dev \
        python3-dev python3-pip \
        libjpeg-dev zlib1g-dev libfreetype6-dev \
        libxml2-dev libxslt1-dev libffi-dev libssl-dev \
        tzdata curl wget git ca-certificates \
        2>/dev/null
    " && log OK "Debian 编译环境安装完成" || log WARN "部分系统包安装失败"
  fi

  # ── STEP 4：修复 pnpm 源 ──
  log STEP "[4/8] 修复 pnpm/npm 镜像源（ERR_PNPM_REGISTRIES_MISMATCH）..."
  docker exec "$name" bash -c "
    pnpm config set registry https://registry.npmmirror.com 2>/dev/null
    npm config set registry https://registry.npmmirror.com 2>/dev/null
    rm -f /ql/scripts/node_modules/.modules.yaml 2>/dev/null
    cd /ql/scripts && pnpm install --prefer-offline 2>/dev/null || true
  " && log OK "pnpm/npm 源修复完成" || log WARN "源修复部分失败，将继续"

  # ── STEP 5：修复 pip ──
  log STEP "[5/8] 修复并升级 pip（解决 Python3 依赖安装失败）..."
  docker exec "$name" bash -c "
    curl -sS https://bootstrap.pypa.io/get-pip.py | python3 2>/dev/null
    pip3 install --upgrade pip setuptools wheel -q 2>/dev/null
    pip3 config set global.index-url \
      https://pypi.tuna.tsinghua.edu.cn/simple 2>/dev/null
    pip3 config set global.trusted-host \
      pypi.tuna.tsinghua.edu.cn 2>/dev/null
  " && log OK "pip 修复完成（清华源）" || log WARN "pip 修复部分失败，将继续"

  # ── STEP 6：NodeJS 依赖 ──
  log STEP "[6/8] 安装 NodeJS 依赖包..."
  local npm_pkgs=(
    "axios" "axios@0.27.2" "request" "got" "node-fetch"
    "https-proxy-agent" "tunnel"
    "crypto-js" "ts-md5" "jsencrypt" "node-jsencrypt"
    "node-rsa" "js-base64"
    "date-fns" "moment"
    "json5" "qs" "form-data" "dotenv"
    "jsdom" "cheerio" "xmldom"
    "tough-cookie"
    "typescript" "tslib" "ts-node" "@types/node"
    "ws@7.4.3"
    "global-agent"
    "png-js" "sharp"
    "prettytable" "jieba" "require" "fs" "common" "ds" "ql"
    "node-telegram-bot-api"
    "magic" "cjs" "http-server" "download"
    "juejin-helper"
  )

  local total_npm=${#npm_pkgs[@]}
  local ok_npm=0 fail_npm=0 failed_npm_list=()

  for i in "${!npm_pkgs[@]}"; do
    local pkg="${npm_pkgs[$i]}"
    _progress_bar $((i+1)) $total_npm "$pkg"
    local ok=0
    for attempt in 1 2; do
      docker exec "$name" bash -c \
        "cd /ql/scripts && pnpm add '$pkg' 2>/dev/null || \
         npm install '$pkg' 2>/dev/null" >/dev/null 2>&1 && ok=1 && break
      sleep 1
    done
    (( ok )) && (( ok_npm++ )) || { (( fail_npm++ )); failed_npm_list+=("$pkg"); }
  done
  echo "" >&2

  docker exec "$name" bash -c \
    "npm install -g typescript ts-node jieba 2>/dev/null || true" >/dev/null 2>&1

  log OK "NodeJS：成功 $ok_npm / 失败 $fail_npm / 共 $total_npm"
  (( ${#failed_npm_list[@]} > 0 )) && log WARN "失败包: ${failed_npm_list[*]}"

  # ── STEP 7：Python3 依赖 ──
  log STEP "[7/8] 安装 Python3 依赖包..."
  local pip_pkgs=(
    "requests" "httpx" "aiohttp"
    "pycryptodome" "rsa"
    "bs4" "lxml"
    "PyExecJS"
    "Pillow"
    "ping3" "jieba"
    "redis"
    "openai"
    "python-magic"
    "pytz" "pyyaml" "urllib3" "certifi"
  )

  local total_pip=${#pip_pkgs[@]}
  local ok_pip=0 fail_pip=0 failed_pip_list=()

  for i in "${!pip_pkgs[@]}"; do
    local pkg="${pip_pkgs[$i]}"
    _progress_bar $((i+1)) $total_pip "$pkg"
    local ok=0
    for attempt in 1 2; do
      docker exec "$name" bash -c \
        "pip3 install '$pkg' -q 2>/dev/null" >/dev/null 2>&1 && ok=1 && break
      [[ "$pkg" == "Crypto" ]] && \
        docker exec "$name" bash -c \
          "pip3 install pycryptodome -q 2>/dev/null" >/dev/null 2>&1 && \
        ok=1 && break
      sleep 1
    done
    (( ok )) && (( ok_pip++ )) || { (( fail_pip++ )); failed_pip_list+=("$pkg"); }
  done
  echo "" >&2

  log OK "Python3：成功 $ok_pip / 失败 $fail_pip / 共 $total_pip"
  (( ${#failed_pip_list[@]} > 0 )) && log WARN "失败包: ${failed_pip_list[*]}"

  # ── STEP 8：Linux 依赖（核心修复：通过 Open API 注入面板）──
  log STEP "[8/8] 安装 Linux 依赖..."

  # Linux 依赖包列表（兼容 Alpine）
  local linux_pkgs=(
    "alpine-sdk"
    "autoconf"
    "automake"
    "libtool"
    "gcc"
    "g++"
    "make"
    "python3-dev"
    "libffi-dev"
    "openssl-dev"
    "jpeg-dev"
    "zlib-dev"
    "libxml2-dev"
    "libxslt-dev"
    "cairo-dev"
    "pango-dev"
    "giflib-dev"
    "curl"
    "wget"
    "git"
    "ca-certificates"
    "tzdata"
    "lxml"
  )

  local total_linux=${#linux_pkgs[@]}
  local ok_linux=0 fail_linux=0 failed_linux_list=()

  if (( api_available == 1 )); then
    # ✅ 路径A：Open API 安装（面板数据库记录，标签页可见）
    echo -e "  ${GREEN}模式: Open API 安装（面板 Linux 标签页可见 ✅）${NC}" >&2

    for i in "${!linux_pkgs[@]}"; do
      local pkg="${linux_pkgs[$i]}"
      _progress_bar $((i+1)) $total_linux "$pkg"

      local api_resp api_code
      api_resp=$(curl -s -m 60 -X POST \
        "http://localhost:${host_port}/open/dependencies" \
        -H "Authorization: Bearer ${api_token}" \
        -H "Content-Type: application/json" \
        -d "{\"names\":[\"${pkg}\"],\"type\":\"linux\"}" 2>/dev/null)
      api_code=$(echo "$api_resp" | jq -r '.code // 0' 2>/dev/null)

      if [[ "$api_code" == "200" ]]; then
        (( ok_linux++ ))
      else
        # API 失败 → 降级直接系统安装
        local sys_ok=0
        if [[ "$os_type" == "alpine" ]]; then
          docker exec "$name" bash -c \
            "apk add --no-cache -q '$pkg' 2>/dev/null" >/dev/null 2>&1 && sys_ok=1
        else
          docker exec "$name" bash -c \
            "apt-get install -y -q '$pkg' 2>/dev/null" >/dev/null 2>&1 && sys_ok=1
        fi
        (( sys_ok )) && (( ok_linux++ )) || {
          (( fail_linux++ )); failed_linux_list+=("$pkg")
        }
      fi
    done

  else
    # ⚠️ 路径B：降级直接系统安装（面板不可见）
    echo -e "  ${YELLOW}模式: 系统直接安装（面板 Linux 标签页不可见）${NC}" >&2

    for i in "${!linux_pkgs[@]}"; do
      local pkg="${linux_pkgs[$i]}"
      _progress_bar $((i+1)) $total_linux "$pkg"
      local sys_ok=0
      if [[ "$os_type" == "alpine" ]]; then
        docker exec "$name" bash -c \
          "apk add --no-cache -q '$pkg' 2>/dev/null" >/dev/null 2>&1 && sys_ok=1
      else
        docker exec "$name" bash -c \
          "apt-get install -y -q '$pkg' 2>/dev/null" >/dev/null 2>&1 && sys_ok=1
      fi
      (( sys_ok )) && (( ok_linux++ )) || {
        (( fail_linux++ )); failed_linux_list+=("$pkg")
      }
    done
  fi
  echo "" >&2

  log OK "Linux：成功 $ok_linux / 失败 $fail_linux / 共 $total_linux"
  (( ${#failed_linux_list[@]} > 0 )) && {
    log WARN "失败包（部分包名在新版 Alpine 仓库已移除，可忽略）:"
    printf "    - %s\n" "${failed_linux_list[@]}" >&2
  }

  # ── canvas 单独编译 ──
  log INFO "尝试安装 canvas（编译可能耗时较长）..."
  local canvas_ok=0
  docker exec "$name" bash -c \
    "cd /ql/scripts && pnpm add canvas 2>/dev/null || \
     npm install canvas 2>/dev/null" >/dev/null 2>&1 && canvas_ok=1
  (( canvas_ok == 0 )) && \
    docker exec "$name" bash -c \
      "cd /ql/scripts && npm install canvas --build-from-source 2>/dev/null" \
      >/dev/null 2>&1 && canvas_ok=1
  (( canvas_ok )) && log OK "canvas 安装成功" || \
    log WARN "canvas 安装失败（除非脚本明确需要，可忽略）"

  # ── 汇总输出 ──
  echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════════════════${NC}" >&2
  echo -e "${GREEN}${BOLD}  ✅ 全依赖环境补全完成！${NC}" >&2
  printf "  %-10s 成功 %s${GREEN}%d${NC} / 失败 %s${RED}%d${NC} / 共 %d\n" \
    "NodeJS:" "" $ok_npm "" $fail_npm $total_npm >&2
  printf "  %-10s 成功 %s${GREEN}%d${NC} / 失败 %s${RED}%d${NC} / 共 %d\n" \
    "Python3:" "" $ok_pip "" $fail_pip $total_pip >&2
  if (( api_available )); then
    printf "  %-10s 成功 %s${GREEN}%d${NC} / 失败 %s${RED}%d${NC} / 共 %d  ${GREEN}[面板可见 ✅]${NC}\n" \
      "Linux:" "" $ok_linux "" $fail_linux $total_linux >&2
  else
    printf "  %-10s 成功 %s${GREEN}%d${NC} / 失败 %s${RED}%d${NC} / 共 %d  ${YELLOW}[面板不可见，选9重新注册]${NC}\n" \
      "Linux:" "" $ok_linux "" $fail_linux $total_linux >&2
  fi
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${NC}\n" >&2

  read -p "是否立即重启容器 $name 使依赖生效？(Y/n): " restart_choice
  if [[ ! "${restart_choice:-Y}" =~ ^[Nn]$ ]]; then
    log INFO "正在重启容器 $name ..."
    docker restart "$name" >/dev/null 2>&1
    sleep 3
    log OK "容器 $name 已重启，依赖全部生效！"
    local ap; ap=$(get_container_port "$name")
    [[ -n "$ap" ]] && \
      echo -e "${CYAN}面板访问: http://$(hostname -I | awk '{print $1}'):$ap${NC}"
  else
    log INFO "跳过重启，请手动执行: docker restart $name"
  fi
}

# ================================================================
#  Linux 依赖补充注册到面板（面板初始化后使用）
# ================================================================
register_linux_deps_to_panel() {
  local name
  name=$(prompt_container_name "请输入青龙容器名" "$DEFAULT_CONTAINER_NAME")

  if ! docker ps --format "{{.Names}}" | grep -qw "$name"; then
    log ERROR "容器 <$name> 不存在或未运行！"; return 1
  fi

  local host_port
  host_port=$(get_container_port "$name")
  [[ -z "$host_port" ]] && host_port="$DEFAULT_PORT"

  log STEP "获取 Open API Token..."
  local api_token
  api_token=$(_get_ql_token "$name" "$host_port")

  if [[ -z "$api_token" ]]; then
    log ERROR "获取 Token 失败！"
    _show_openapi_guide "$host_port"
    return 1
  fi

  log OK "Token 获取成功，开始注册 Linux 依赖到面板..."

  local linux_pkgs=(
    "alpine-sdk" "autoconf" "automake" "libtool"
    "gcc" "g++" "make" "python3-dev"
    "libffi-dev" "openssl-dev" "jpeg-dev" "zlib-dev"
    "libxml2-dev" "libxslt-dev" "cairo-dev" "pango-dev" "giflib-dev"
    "curl" "wget" "git" "ca-certificates" "tzdata" "lxml"
  )

  local ok=0 fail=0 total=${#linux_pkgs[@]}

  for i in "${!linux_pkgs[@]}"; do
    local pkg="${linux_pkgs[$i]}"
    _progress_bar $((i+1)) $total "$pkg"
    local resp code
    resp=$(curl -s -m 60 -X POST \
      "http://localhost:${host_port}/open/dependencies" \
      -H "Authorization: Bearer ${api_token}" \
      -H "Content-Type: application/json" \
      -d "{\"names\":[\"${pkg}\"],\"type\":\"linux\"}" 2>/dev/null)
    code=$(echo "$resp" | jq -r '.code // 0' 2>/dev/null)
    [[ "$code" == "200" ]] && (( ok++ )) || (( fail++ ))
  done
  echo "" >&2

  log OK "Linux 依赖注册完成：成功 $ok / 失败 $fail / 共 $total"
  log INFO "请刷新面板「依赖管理 → Linux」标签页查看"
}

# ================================================================
#  清除本地凭证缓存
# ================================================================
clear_cred_cache() {
  if [[ -f "$CRED_CACHE_FILE" ]]; then
    rm -f "$CRED_CACHE_FILE"
    log OK "本地 API 凭证缓存已清除，下次运行时需重新输入"
  else
    log INFO "本地缓存不存在，无需清除"
  fi
}

# ================================================================
#  专项修复工具
# ================================================================
repair_deps() {
  local name
  name=$(prompt_container_name "请输入要修复依赖的青龙容器名" "$DEFAULT_CONTAINER_NAME")
  if ! docker ps --format "{{.Names}}" | grep -qw "$name"; then
    log ERROR "容器 <$name> 不存在或未运行！"; return 1
  fi

  echo -e "\n${YELLOW}请选择修复模式：${NC}"
  echo "  1. 全量安装（所有依赖重新补全）"
  echo "  2. 仅修复 pnpm 源（ERR_PNPM_REGISTRIES_MISMATCH）"
  echo "  3. 仅修复 pip / Python3 依赖"
  echo "  4. 仅修复 canvas 编译"
  echo "  5. Linux 依赖重新注册到面板"
  echo "  6. 清除 API 凭证缓存（重新输入 client_id/secret）"
  read -p "请选择 [1-6，默认1]: " repair_mode

  case "${repair_mode:-1}" in
    1) install_all_deps "$name" ;;
    2)
      log STEP "修复 pnpm 源..."
      docker exec "$name" bash -c "
        pnpm config set registry https://registry.npmmirror.com
        npm config set registry https://registry.npmmirror.com
        rm -f /ql/scripts/node_modules/.modules.yaml
        cd /ql/scripts && pnpm install 2>/dev/null || true
      " && log OK "pnpm 源修复完成" || log ERROR "修复失败"
      ;;
    3)
      log STEP "修复 pip 并重装 Python3 依赖..."
      docker exec "$name" bash -c "
        curl -sS https://bootstrap.pypa.io/get-pip.py | python3
        pip3 install --upgrade pip setuptools wheel
        pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
        pip3 config set global.trusted-host pypi.tuna.tsinghua.edu.cn
        pip3 install requests httpx aiohttp pycryptodome rsa bs4 lxml \
                     PyExecJS ping3 jieba redis Pillow pytz pyyaml -q
      " && log OK "Python3 依赖修复完成" || log ERROR "修复失败"
      ;;
    4)
      log STEP "修复 canvas..."
      docker exec "$name" bash -c "
        apk add --no-cache build-base g++ cairo-dev pango-dev giflib-dev 2>/dev/null || \
        apt-get install -y build-essential libcairo2-dev libpango1.0-dev libgif-dev 2>/dev/null
        cd /ql/scripts && npm install canvas --build-from-source
      " && log OK "canvas 修复完成" || log ERROR "canvas 修复失败"
      ;;
    5) register_linux_deps_to_panel ;;
    6) clear_cred_cache ;;
    *) log ERROR "无效选择" ;;
  esac
}

# ======================= 部署 =======================
install_ql() {
  local name port target_version image image_variant

  name=$(prompt_container_name "请输入容器名称" "$DEFAULT_CONTAINER_NAME")
  port=$(prompt_port "请输入 WebUI 端口" "$DEFAULT_PORT")

  if docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    log WARN "容器 $name 已存在，不能重复部署"; return
  fi

  echo -e "\n${YELLOW}请选择镜像类型：${NC}"
  echo "  1. alpine（默认轻量版 latest）"
  echo "  2. debian （更好的依赖兼容性，复杂脚本首选）"
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
  docker pull "$image" || { log ERROR "镜像拉取失败"; return 1; }

  log INFO "正在启动容器 $name，端口 $port:5700 ..."
  docker run -dit \
    -v "$DATA_DIR/config:/ql/config" \
    -v "$DATA_DIR/log:/ql/log" \
    -v "$DATA_DIR/db:/ql/db" \
    -v "$DATA_DIR/repo:/ql/repo" \
    -v "$DATA_DIR/raw:/ql/raw" \
    -v "$DATA_DIR/scripts:/ql/scripts" \
    -v "$DATA_DIR/jbot:/ql/jbot" \
    -p "$port:5700" \
    --name "$name" --hostname "$name" \
    --restart unless-stopped \
    "$image" || { log ERROR "容器启动失败"; return 1; }

  log INFO "🎉 青龙容器 $name 部署完成！镜像: $image"
  echo -e "\n${GREEN}${BOLD}══ 下一步操作指引 ══${NC}"
  echo -e "  1. 浏览器访问: ${CYAN}http://$(hostname -I | awk '{print $1}'):$port${NC}"
  echo -e "  2. 完成账号密码初始化"
  echo -e "  3. ${BOLD}系统设置 → 应用设置 → 添加应用${NC}（全权限勾选，获取 client_id/secret）"
  echo -e "  4. 回到本脚本 → 选 ${GREEN}[7]${NC} 安装全依赖"
  echo -e "${GREEN}${BOLD}══════════════════════${NC}\n"
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
    read -p "确定要停止并删除容器 $name？数据目录不会被删除。(y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      docker stop "$name" >/dev/null 2>&1
      docker rm "$name" >/dev/null 2>&1
      log INFO "容器 $name 已成功删除"
    else log INFO "已取消卸载"; fi
  else log WARN "找不到名为 $name 的容器"; fi
}

backup_ql() {
  local ts="$(date +%Y%m%d%H%M%S)"
  local backup_file="$DATA_DIR/backup/ql_backup_$ts.tar.gz"
  log INFO "开始备份数据..."
  tar -czf "$backup_file" -C "$DATA_DIR" config log db repo raw scripts jbot
  log INFO "🎉 数据备份至: $backup_file"
}

restore_ql() {
  local latest
  latest=$(ls -t "$DATA_DIR/backup"/ql_backup_*.tar.gz 2>/dev/null | head -n1)
  if [[ ! -f "$latest" ]]; then log WARN "找不到任何备份文件！"; return; fi
  read -p "检测到最新备份: $latest，是否恢复？(y/N): " choice
  if [[ "$choice" =~ ^[Yy]$ ]]; then
    tar -xzf "$latest" -C "$DATA_DIR"
    log INFO "🎉 数据恢复完成！请重启青龙容器生效。"
  else log INFO "已取消恢复"; fi
}

# ======================= 无损升级 =======================
upgrade_ql() {
  local name
  name=$(prompt_container_name "请输入待升级的容器名" "$DEFAULT_CONTAINER_NAME")
  if ! docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
    log ERROR "容器 <$name> 不存在，请先部署！"; return
  fi

  local target_version
  target_version=$(select_version "$DEFAULT_IMAGE_VER" 5)
  local image="$QL_IMAGE_BASE:$target_version"

  echo -e "\n${YELLOW}ℹ️ 旧容器所有配置将被完美保留。${NC}"
  log INFO "正在拉取新镜像: $image ..."
  docker pull "$image" || { log ERROR "镜像拉取失败！"; return; }

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

  log INFO "🗑️ 停止并销毁旧容器..."
  docker stop "$name" >/dev/null 2>&1
  docker rm   "$name" >/dev/null 2>&1

  log INFO "🚀 使用新镜像和旧配置重建容器..."
  if docker run "${run_args[@]}" "$image" >/dev/null 2>&1; then
    log INFO "🎉 青龙容器 <$name> 已成功无损升级至 $target_version！"
    local old_port; old_port=$(get_container_port "$name")
    [[ -n "$old_port" ]] && \
      echo -e "${CYAN}访问面板: http://$(hostname -I | awk '{print $1}'):$old_port${NC}"
  else
    log ERROR "❌ 升级后容器启动失败，请运行 'docker logs $name' 检查原因。"
  fi
}

# ======================= 主菜单 =======================
show_menu() {
  while true; do
    echo -e "\n${CYAN}${BOLD}══════ QL青龙面板 Docker 管家 v3.2 ══════${NC}"
    echo "  1. 部署 QingLong 容器"
    echo -e "  2. 无损升级 QingLong 面板 ${YELLOW}[保留全部配置]${NC}"
    echo "  3. 查看当前运行的容器"
    echo "  4. 卸载 QingLong 容器"
    echo "  5. 一键数据备份"
    echo "  6. 一键数据恢复"
    echo -e "  ${GREEN}${BOLD}7. ★ 全依赖环境一键补全（NodeJS+Python3+Linux）${NC}"
    echo -e "  ${YELLOW}8. 依赖专项修复（pnpm源/pip/canvas/注册）${NC}"
    echo -e "  ${BLUE}9. Linux依赖补充注册到面板（初始化后使用）${NC}"
    echo -e "  ${RED}A. 清除 API 凭证缓存（重新输入凭证）${NC}"
    echo -e "  ${BLUE}B. 存储占用分析报告${NC}"
    echo "  0. 退出"
    echo -e "${CYAN}${BOLD}═════════════════════════════════════════${NC}"
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
      9) register_linux_deps_to_panel ;;
      [Aa]) clear_cred_cache ;;
      [Bb]) show_storage_report ;;
      0) echo -e "${GREEN}感谢使用，再见！${NC}"; exit 0 ;;
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
