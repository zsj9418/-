#!/bin/bash
set -o pipefail
REQ_DEPS=("curl" "wget" "jq")
OPT_DEPS=("fzf")
DOCKER_VERSIONS_URL="https://download.docker.com/linux/static/stable/"
COMPOSE_RELEASES_URL="https://api.github.com/repos/docker/compose/releases"
PROXY_PREFIXES=(
  "https://ghproxy.com/"
  "https://gitclone.com/"
  "https://gitdl.cn/"
  "https://gh.llkk.cc/"
)
REGISTRY_MIRRORS_DEFAULT=(
  "https://docker.1ms.run"
  "https://docker.xuanyuan.me"
  "https://docker.m.daocloud.io"
  "https://dockerproxy.net"
  "https://dockerproxy.link"
  "https://docker.1panel.live"
  "https://proxy.vvvv.ee"
  "https://docker.jiaxin.site"
  "https://registry.cyou"
  "https://hubfast.cn"
)
DOCKER_DIRECT_ENDPOINT="https://registry-1.docker.io/v2/"
DAEMON_BACKUP_DIR="/etc/docker/backups"
PROXY_MIRROR_URL=""
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
DOCKER_URL=""
DOCKER_INSTALL_DIR=""
ARCH=""
OS=""
PKG_MANAGER=""
FORCE_LEGACY_DOCKER="false"
RECOMMENDED_LEGACY_DOCKER_VERSION="27.5.1"
IPV6_AVAILABLE="true"
IS_LXC="false"
IS_OPENVZ="false"
APPARMOR_RESTRICTED="false"
SPEED_TEST_RESULTS=()
LOG_DIR="/var/log/docker_manager"
LOG_FILE="${LOG_DIR}/docker_manager.log"
LOG_MAX_SIZE_MB=5
LOG_MAX_BACKUPS=3
rotate_log() {
  [[ ! -f "$LOG_FILE" ]] && return 0
  local size_bytes
  size_bytes=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  local size_mb=$(( size_bytes / 1024 / 1024 ))
  (( size_mb < LOG_MAX_SIZE_MB )) && return 0
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 日志达到 ${size_mb}MB，触发轮转..." >> "$LOG_FILE"
  [[ -f "${LOG_FILE}.${LOG_MAX_BACKUPS}.gz" ]] && rm -f "${LOG_FILE}.${LOG_MAX_BACKUPS}.gz"
  for (( i = LOG_MAX_BACKUPS - 1; i >= 1; i-- )); do
    [[ -f "${LOG_FILE}.${i}.gz" ]] && mv "${LOG_FILE}.${i}.gz" "${LOG_FILE}.$((i+1)).gz"
  done
  gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz"
  : > "$LOG_FILE"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 轮转完成，已归档至 ${LOG_FILE}.1.gz" >> "$LOG_FILE"
}
init_log() {
  mkdir -p "$LOG_DIR"
  rotate_log
  {
    echo ""
    echo "════════════════════════════════════════"
    echo "  会话开始: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  PID: $$  |  用户: ${SUDO_USER:-$USER}"
    echo "════════════════════════════════════════"
  } >> "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}
cleanup() {
  echo -e "\n${YELLOW}检测到中断信号，正在清理临时文件...${NC}"
  [[ -n "$DOCKER_INSTALL_DIR" && -d "$DOCKER_INSTALL_DIR" ]] && rm -rf "$DOCKER_INSTALL_DIR"
  echo -e "${YELLOW}日志已保存至: ${LOG_FILE}${NC}"
  exit 130
}
trap cleanup INT TERM
check_sudo() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}此脚本需要 root 权限运行。请使用 sudo 或切换到 root。${NC}"
    exit 1
  fi
}
detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    echo -e "${RED}未检测到受支持的包管理器（apt-get/dnf/yum）。${NC}"
    exit 1
  fi
}
install_dependencies() {
  echo "正在检测并安装所有缺失的依赖..."
  local missing_req_deps=()
  for dep in "${REQ_DEPS[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing_req_deps+=("$dep")
  done
  local missing_opt_deps=()
  for dep in "${OPT_DEPS[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing_opt_deps+=("$dep")
  done
  if [[ ${#missing_req_deps[@]} -eq 0 && ${#missing_opt_deps[@]} -eq 0 ]]; then
    echo -e "${GREEN}所有依赖均已安装。${NC}"
    return 0
  fi
  case "$PKG_MANAGER" in
    apt-get)
      apt-get update -qq || true
      if [[ ${#missing_req_deps[@]} -gt 0 ]]; then
        echo "正在安装必需依赖: ${missing_req_deps[*]}"
        apt-get install -y --no-install-recommends "${missing_req_deps[@]}" || {
          echo -e "${RED}安装必需依赖失败${NC}"; exit 1; }
      fi
      if [[ ${#missing_opt_deps[@]} -gt 0 ]]; then
        apt-get install -y --no-install-recommends "${missing_opt_deps[@]}" 2>/dev/null || true
      fi
      ;;
    dnf|yum)
      if [[ ${#missing_req_deps[@]} -gt 0 ]]; then
        echo "正在安装必需依赖: ${missing_req_deps[*]}"
        "${PKG_MANAGER}" install -y "${missing_req_deps[@]}" || {
          echo -e "${RED}安装必需依赖失败${NC}"; exit 1; }
      fi
      if [[ ${#missing_opt_deps[@]} -gt 0 ]]; then
        "${PKG_MANAGER}" install -y "${missing_opt_deps[@]}" 2>/dev/null || true
      fi
      ;;
  esac
}
get_architecture() {
  local m
  m=$(uname -m)
  case "$m" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="aarch64" ;;
    armv7l)  ARCH="armv7" ;;
    armv6l)  ARCH="armv6" ;;
    *) echo -e "${RED}不支持的架构: $m${NC}" >&2; exit 1 ;;
  esac
  echo "$ARCH"
}
get_os_version() {
  if [[ -f /etc/os-release ]]; then
    local name ver
    name=$(grep ^ID= /etc/os-release | awk -F= '{print $2}' | tr -d '"')
    ver=$(grep ^VERSION_ID= /etc/os-release | awk -F= '{print $2}' | tr -d '"')
    echo "$name $ver"
  else
    echo -e "${YELLOW}警告: 无法读取 /etc/os-release${NC}" >&2
    echo "unknown"
  fi
}
check_and_set_install_dir() {
  local REQUIRED_SPACE=500
  local realpath_cmd
  realpath_cmd=$(command -v realpath 2>/dev/null || echo "readlink -f")
  local DIR
  if [[ "$0" == "bash" || "$0" == "-bash" || "$0" == "sh" || "$0" == "-sh" ]]; then
    DIR="/tmp"
  else
    DIR=$(dirname "$($realpath_cmd "$0" 2>/dev/null || echo "$0")")
  fi
  local DEFAULT_DIR="${DIR}/docker_install"
  mkdir -p "$DEFAULT_DIR" 2>/dev/null || {
    echo -e "${RED}无法创建默认目录 $DEFAULT_DIR${NC}"; exit 1; }
  local AVAILABLE_SPACE
  AVAILABLE_SPACE=$(df -m "$DEFAULT_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
  [[ -z "$AVAILABLE_SPACE" ]] && {
    echo -e "${RED}无法检测目录 $DEFAULT_DIR 的可用空间${NC}"; exit 1; }
  echo -e "${YELLOW}默认目录: $DEFAULT_DIR (可用: ${AVAILABLE_SPACE}MB, 需: ${REQUIRED_SPACE}MB)${NC}"
  read -r -p "是否指定自定义安装目录？(回车使用默认): " CUSTOM_DIR
  if [[ -n "$CUSTOM_DIR" ]]; then
    mkdir -p "$CUSTOM_DIR" 2>/dev/null || { echo -e "${RED}无法创建 $CUSTOM_DIR${NC}"; exit 1; }
    AVAILABLE_SPACE=$(df -m "$CUSTOM_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    [[ -z "$AVAILABLE_SPACE" ]] && { echo -e "${RED}无法检测 $CUSTOM_DIR 可用空间${NC}"; exit 1; }
    (( AVAILABLE_SPACE < REQUIRED_SPACE )) && {
      echo -e "${RED}$CUSTOM_DIR 空间不足${NC}"; exit 1; }
    DOCKER_INSTALL_DIR="$CUSTOM_DIR/docker_install"
    echo -e "${GREEN}使用自定义目录: $DOCKER_INSTALL_DIR${NC}"
  else
    (( AVAILABLE_SPACE < REQUIRED_SPACE )) && {
      echo -e "${RED}$DEFAULT_DIR 空间不足${NC}"; exit 1; }
    DOCKER_INSTALL_DIR="$DEFAULT_DIR"
    echo -e "${GREEN}使用默认目录: $DOCKER_INSTALL_DIR${NC}"
  fi
  mkdir -p "$DOCKER_INSTALL_DIR" || {
    echo -e "${RED}创建目录 $DOCKER_INSTALL_DIR 失败${NC}"; exit 1; }
}
check_docker_installed() {
  if command -v docker >/dev/null 2>&1; then
    echo -e "${GREEN}Docker 已安装：$(docker --version)${NC}"
    return 0
  fi
  echo -e "${YELLOW}Docker 未安装。${NC}"
  return 1
}
check_docker_compose_installed() {
  if command -v docker-compose >/dev/null 2>&1; then
    echo -e "${GREEN}docker-compose 已安装：$(docker-compose --version)${NC}"
    return 0
  fi
  if docker compose version >/dev/null 2>&1; then
    echo -e "${GREEN}Docker Compose 插件已安装：$(docker compose version | head -n1)${NC}"
    return 0
  fi
  echo -e "${YELLOW}Docker Compose 未安装。${NC}"
  return 1
}
download_with_fallback() {
  local url="$1" dest="$2"
  echo "下载: $url" >&2
  if curl -fSL --retry 3 --connect-timeout 20 "$url" -o "$dest"; then
    return 0
  fi
  echo -e "${YELLOW}直连失败，尝试代理...${NC}" >&2
  if [[ "$url" == *"github.com"* || "$url" == *"githubusercontent.com"* ]]; then
    for prefix in "${PROXY_PREFIXES[@]}"; do
      local proxy_url="${prefix}${url}"
      echo "代理下载: $proxy_url" >&2
      if curl -fSL --retry 3 --connect-timeout 20 "$proxy_url" -o "$dest"; then
        echo -e "${GREEN}代理下载成功${NC}" >&2
        return 0
      fi
      echo -e "${YELLOW}代理失败: $proxy_url${NC}" >&2
    done
  else
    echo -e "${YELLOW}非 GitHub 地址，无代理可用。${NC}" >&2
  fi
  return 1
}
configure_proxy_mirror() {
  echo -e "\n${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║      配置代理镜像源（后备 mirrors）       ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo -e "当前代理镜像源: ${YELLOW}${PROXY_MIRROR_URL:-未配置}${NC}"
  read -r -p "请输入代理镜像源 URL（留空=清空配置）: " input
  input=$(echo "$input" | tr -d '[:space:]')
  if [[ -z "$input" ]]; then
    PROXY_MIRROR_URL=""
    echo -e "${GREEN}已清空代理镜像源配置。${NC}"
    return 0
  fi
  if ! [[ "$input" =~ ^https?:// ]]; then
    echo -e "${RED}格式不正确：必须以 http:// 或 https:// 开头。${NC}"
    return 1
  fi
  input="${input%/}"
  PROXY_MIRROR_URL="$input"
  echo -e "${GREEN}已设置代理镜像源：${PROXY_MIRROR_URL}${NC}"
}
_probe_url() {
  local url="$1"
  local elapsed
  elapsed=$(curl -o /dev/null -s -w "%{time_total}" \
    --connect-timeout 5 --max-time 8 "$url" 2>/dev/null || echo "9.999")
  local ms
  ms=$(awk "BEGIN{printf \"%.0f\", ${elapsed} * 1000}")
  echo "$ms"
}
run_mirror_speed_test() {
  SPEED_TEST_RESULTS=()
  echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║          镜像源连通性测速                ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo -e "[INFO] 开始测速，请稍候...\n"
  local direct_ms
  direct_ms=$(_probe_url "$DOCKER_DIRECT_ENDPOINT")
  if (( direct_ms >= 8000 )); then
    printf "  ${RED}✗${NC} %-42s %s\n" "direct" "(不可达)"
    SPEED_TEST_RESULTS+=("9999|direct|${DOCKER_DIRECT_ENDPOINT}")
  else
    printf "  ${GREEN}✓${NC} %-42s : ${GREEN}%sms${NC}\n" "direct" "$direct_ms"
    SPEED_TEST_RESULTS+=("${direct_ms}|direct|${DOCKER_DIRECT_ENDPOINT}")
  fi
  for mirror in "${REGISTRY_MIRRORS_DEFAULT[@]}"; do
    local probe_url="${mirror}/v2/"
    local ms
    ms=$(_probe_url "$probe_url")
    if (( ms >= 8000 )); then
      printf "  ${RED}✗${NC} %-42s %s\n" "$mirror" "(不可达)"
      SPEED_TEST_RESULTS+=("9999|${mirror}|${probe_url}")
    else
      printf "  ${GREEN}✓${NC} %-42s : ${GREEN}%sms${NC}\n" "$mirror" "$ms"
      SPEED_TEST_RESULTS+=("${ms}|${mirror}|${probe_url}")
    fi
  done
  echo ""
  local sorted
  sorted=$(printf '%s\n' "${SPEED_TEST_RESULTS[@]}" | sort -t'|' -k1 -n)
  mapfile -t SPEED_TEST_RESULTS <<< "$sorted"
  local best_entry best_ms best_label
  best_entry="${SPEED_TEST_RESULTS[0]}"
  best_ms=$(echo "$best_entry" | cut -d'|' -f1)
  best_label=$(echo "$best_entry" | cut -d'|' -f2)
  if (( best_ms >= 8000 )); then
    echo -e "[${RED}WARN${NC}] 所有源均不可达，请检查网络连接。"
    return 1
  fi
  echo -e "[INFO] 最快源: ${GREEN}${best_label}${NC} (${best_ms}ms)"
  echo ""
  local direct_result direct_speed
  direct_result=$(printf '%s\n' "${SPEED_TEST_RESULTS[@]}" | grep '|direct|')
  direct_speed=$(echo "$direct_result" | cut -d'|' -f1)
  if (( direct_speed < 8000 )) && [[ "$best_label" == "direct" ]]; then
    echo -e "${GREEN}[INFO] 直连 Docker Hub 速度最快 (${direct_speed}ms)，无需配置镜像加速。${NC}"
  else
    if (( direct_speed >= 8000 )); then
      echo -e "${RED}[INFO] 直连 Docker Hub 不可达。${NC}"
    else
      local speedup=$(( direct_speed - best_ms ))
      echo -e "${YELLOW}[INFO] 直连: ${direct_speed}ms  最快镜像: ${best_ms}ms，可提速约 ${speedup}ms。${NC}"
    fi
  fi
  echo ""
  read -r -p "是否将可达镜像源（按速度排序）写入 daemon.json？(y/n): " DO_WRITE
  if [[ "$DO_WRITE" == "y" ]]; then
    _apply_speed_test_to_daemon
  else
    echo -e "${YELLOW}[INFO] 已跳过配置。${NC}"
  fi
}
_apply_speed_test_to_daemon() {
  local reachable_mirrors=()
  for entry in "${SPEED_TEST_RESULTS[@]}"; do
    local ms label
    ms=$(echo "$entry" | cut -d'|' -f1)
    label=$(echo "$entry" | cut -d'|' -f2)
    [[ "$label" == "direct" ]] && continue
    (( ms >= 8000 )) && continue
    reachable_mirrors+=("$label")
  done
  if [[ -n "$PROXY_MIRROR_URL" ]]; then
    local exists="false"
    for m in "${reachable_mirrors[@]}"; do
      [[ "$m" == "$PROXY_MIRROR_URL" ]] && exists="true" && break
    done
    if [[ "$exists" == "false" ]]; then
      reachable_mirrors+=("$PROXY_MIRROR_URL")
    fi
  fi
  if [[ ${#reachable_mirrors[@]} -eq 0 ]]; then
    echo -e "${RED}[WARN] 没有可达的镜像源，daemon.json 未修改。${NC}"
    return
  fi
  backup_daemon_json
  local mirrors_json
  mirrors_json=$(printf '%s\n' "${reachable_mirrors[@]}" | jq -R . | jq -s .)
  if [[ -f /etc/docker/daemon.json ]] && jq . /etc/docker/daemon.json >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp)
    jq --argjson mirrors "$mirrors_json" \
      '. + {"registry-mirrors": $mirrors}' \
      /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
  else
    _write_daemon_json "$mirrors_json"
  fi
  echo -e "[INFO] ${GREEN}镜像源已配置完成。${NC}"
  read -r -p "是否立即重启 Docker？(y/n): " DO_RESTART
  [[ "$DO_RESTART" == "y" ]] && _restart_docker
}
_check_module() {
  local mod="$1"
  local mod_safe="${mod//-/_}"
  if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$mod_safe"; then
    return 0
  fi
  if modprobe "$mod" 2>/dev/null; then
    return 0
  fi
  return 1
}
_check_ipv6_available() {
  if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    local v
    v=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "1")
    [[ "$v" == "0" ]] && return 0
  fi
  if ip -6 addr show 2>/dev/null | grep -q "inet6"; then
    return 0
  fi
  return 1
}
_detect_iptables_backend() {
  if ! command -v iptables >/dev/null 2>&1; then
    echo "none"; return
  fi
  local ver
  ver=$(iptables -V 2>/dev/null || true)
  if echo "$ver" | grep -qi 'nf_tables\|nft'; then
    echo "nft"
  elif echo "$ver" | grep -qi 'legacy'; then
    echo "legacy"
  else
    local real_iptables
    real_iptables=$(readlink -f "$(command -v iptables)" 2>/dev/null || true)
    if echo "$real_iptables" | grep -q 'nft'; then
      echo "nft"
    else
      echo "legacy"
    fi
  fi
}
_detect_virt_env() {
  IS_LXC="false"
  IS_OPENVZ="false"
  if [[ -f /proc/user_beancounters ]] || grep -qi 'openvz\|virtuozzo' /proc/version 2>/dev/null; then
    IS_OPENVZ="true"
    echo -e "  ${YELLOW}⚠${NC}  检测到 OpenVZ/Virtuozzo 虚拟化环境"
    return
  fi
  if grep -qa 'lxc' /proc/1/environ 2>/dev/null || \
     [[ -f /run/container_type ]] && grep -qi 'lxc' /run/container_type 2>/dev/null || \
     systemd-detect-virt --container 2>/dev/null | grep -qi 'lxc'; then
    IS_LXC="true"
    echo -e "  ${CYAN}[INFO]${NC} 检测到 LXC 容器环境"
    return
  fi
  if grep -qa 'docker\|podman' /proc/1/environ 2>/dev/null || \
     [[ -f /.dockerenv ]]; then
    echo -e "  ${YELLOW}⚠${NC}  检测到 Docker-in-Docker 环境，部分功能受限"
    return
  fi
  echo -e "  ${GREEN}✓${NC}  KVM/裸金属环境，完全兼容"
}
_check_apparmor() {
  APPARMOR_RESTRICTED="false"
  if ! command -v aa-status >/dev/null 2>&1 && \
     ! [[ -d /sys/kernel/security/apparmor ]]; then
    return 0
  fi
  if [[ ! -r /sys/kernel/security/apparmor/profiles ]]; then
    echo -e "  ${YELLOW}⚠${NC}  AppArmor 受限（无法读取 profiles），这是 Docker 29+ 在 LXC 中的已知问题"
    APPARMOR_RESTRICTED="true"
    return 0
  fi
  if aa-status >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC}  AppArmor 可访问"
  fi
}
ensure_docker_prereqs() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║      Docker 运行环境兼容性检测           ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
  FORCE_LEGACY_DOCKER="false"
  local compat_issues=()
  echo -e "\n[1/6] 检测虚拟化环境..."
  _detect_virt_env
  if [[ "$IS_OPENVZ" == "true" ]]; then
    echo -e "  ${RED}✗${NC}  OpenVZ 6 不支持 Docker，OpenVZ 7 支持有限"
    echo -e "  ${YELLOW}    如为 OpenVZ 7，脚本将尝试安装兼容版本${NC}"
    FORCE_LEGACY_DOCKER="true"
    compat_issues+=("OpenVZ 环境，降级至兼容版本")
  fi
  echo -e "\n[2/6] 加载基础内核模块..."
  for mod in overlay br_netfilter; do
    if _check_module "$mod"; then
      echo -e "  ${GREEN}✓${NC} $mod"
    else
      if [[ "$mod" == "overlay" ]] && grep -qw overlay /proc/filesystems 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $mod (宿主机内核已提供)"
      elif [[ "$mod" == "br_netfilter" ]] && \
           [[ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
        echo -e "  ${GREEN}✓${NC} $mod (宿主机内核已提供)"
      else
        echo -e "  ${YELLOW}⚠${NC}  $mod 无法加载 (容器环境由宿主机提供，继续)"
      fi
    fi
  done
  echo -e "\n[3/6] 检测 iptables 后端..."
  local backend
  backend=$(_detect_iptables_backend)
  echo -e "  当前后端: ${CYAN}${backend}${NC}"
  local iptables_ok="true"
  if [[ "$backend" == "nft" ]]; then
    echo -e "  ${GREEN}✓${NC} iptables-nft 兼容层 (Docker 28+ 支持)"
  elif [[ "$backend" == "legacy" ]]; then
    echo -e "  ${CYAN}[INFO]${NC} iptables-legacy，检测 raw/nat 表..."
    _check_module "iptable_nat" 2>/dev/null || true
    _check_module "nf_nat"      2>/dev/null || true
    _check_module "iptable_raw" 2>/dev/null || true
    if iptables -t raw -L >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} raw 表可用"
    else
      echo -e "  ${RED}✗${NC} raw 表不可用"
      compat_issues+=("iptables raw 表不可用（Docker 28 强依赖）")
      iptables_ok="false"
    fi
    if ! iptables -t nat -L >/dev/null 2>&1; then
      echo -e "  ${YELLOW}⚠${NC}  nat 表不可用（端口映射受限）"
    else
      echo -e "  ${GREEN}✓${NC} nat 表可用"
    fi
  else
    echo -e "  ${YELLOW}[FIX]${NC}  iptables 未找到，尝试安装..."
    case "$PKG_MANAGER" in
      apt-get) apt-get install -y --no-install-recommends iptables 2>/dev/null || true ;;
      dnf|yum) "${PKG_MANAGER}" install -y iptables 2>/dev/null || true ;;
    esac
    backend=$(_detect_iptables_backend)
    if [[ "$backend" == "none" ]]; then
      compat_issues+=("iptables 完全不可用")
      iptables_ok="false"
    else
      echo -e "  ${GREEN}✓${NC} iptables 安装成功，后端: ${backend}"
    fi
  fi
  echo -e "\n[4/6] 检测 ipset 内核支持（Docker 28+ 强依赖）..."
  local ipset_ok="false"
  _check_module "ip_set"          2>/dev/null || true
  _check_module "ip_set_hash_net" 2>/dev/null || true
  if command -v ipset >/dev/null 2>&1 && ipset list >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} ipset 可用"
    ipset_ok="true"
  else
    echo -e "  ${YELLOW}[FIX]${NC}  ipset 不可用，尝试安装..."
    case "$PKG_MANAGER" in
      apt-get) apt-get install -y --no-install-recommends ipset 2>/dev/null || true ;;
      dnf|yum) "${PKG_MANAGER}" install -y ipset 2>/dev/null || true ;;
    esac
    _check_module "ip_set"          2>/dev/null || true
    _check_module "ip_set_hash_net" 2>/dev/null || true
    if command -v ipset >/dev/null 2>&1 && ipset list >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} ipset 安装并验证成功"
      ipset_ok="true"
    else
      echo -e "  ${RED}✗${NC} ipset 不可用（内核缺少 ip_set 模块）"
      compat_issues+=("ipset/ip_set 内核模块不可用（Docker 28 强依赖）")
    fi
  fi
  echo -e "\n[5/6] 检测 IPv6 与 AppArmor..."
  if _check_ipv6_available; then
    echo -e "  ${GREEN}✓${NC} IPv6 可用"
    IPV6_AVAILABLE="true"
  else
    echo -e "  ${YELLOW}⚠${NC}  IPv6 不可用，daemon.json 将设置 ip6tables: false"
    IPV6_AVAILABLE="false"
  fi
  _check_apparmor
  echo -e "\n[6/6] 兼容性综合判断..."
  local need_downgrade="false"
  [[ "$ipset_ok" == "false" ]] && need_downgrade="true"
  [[ "$backend" == "legacy" && "$iptables_ok" == "false" ]] && need_downgrade="true"
  [[ "$FORCE_LEGACY_DOCKER" == "true" ]] && need_downgrade="true"
  if [[ "$need_downgrade" == "true" ]]; then
    FORCE_LEGACY_DOCKER="true"
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠  系统不满足 Docker 28+ 要求，将安装兼容版本      ║${NC}"
    for issue in "${compat_issues[@]}"; do
      printf "${YELLOW}║  • %-50s║${NC}\n" "$issue"
    done
    echo -e "${YELLOW}║  → 将自动安装 Docker ${RECOMMENDED_LEGACY_DOCKER_VERSION}（无 ipset/raw 依赖）  ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
  else
    echo -e "  ${GREEN}✓${NC} 系统满足 Docker 28+ 所有运行条件"
  fi
  {
    echo "overlay"
    echo "br_netfilter"
    if [[ "$FORCE_LEGACY_DOCKER" == "false" ]]; then
      echo "ip_set"
      echo "ip_set_hash_net"
      [[ "$backend" == "legacy" ]] && printf "iptable_filter\niptable_nat\niptable_raw\n"
    else
      [[ "$backend" == "legacy" ]] && printf "iptable_filter\niptable_nat\n"
    fi
  } > /etc/modules-load.d/docker.conf
  cat > /etc/sysctl.d/99-docker.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
  sysctl --system >/dev/null 2>&1 || true
  echo -e "\n${GREEN}Docker 运行环境检测完成。${NC}"
}
_write_daemon_json() {
  local mirrors_json="$1"
  local ip6tables_val="true"
  [[ "${IPV6_AVAILABLE}" == "false" ]] && ip6tables_val="false"
  local extra_opts="[]"
  if [[ "${APPARMOR_RESTRICTED}" == "true" ]]; then
    extra_opts='["apparmor=unconfined"]'
    echo -e "${YELLOW}[INFO] 检测到 AppArmor 受限（LXC/Docker 29 兼容），已注入 default-security-opt${NC}"
  fi
  local storage_driver_kv=""
  if ! grep -qw overlay /proc/filesystems 2>/dev/null; then
    case "$PKG_MANAGER" in
      apt-get) apt-get install -y fuse-overlayfs >/dev/null 2>&1 || true ;;
      dnf|yum) "${PKG_MANAGER}" install -y fuse-overlayfs >/dev/null 2>&1 || true ;;
    esac
    if command -v fuse-overlayfs >/dev/null 2>&1; then
      storage_driver_kv='"storage-driver": "fuse-overlayfs",'
      echo -e "${YELLOW}[INFO] overlay 不可用，已设置 storage-driver: fuse-overlayfs${NC}"
    fi
  fi
  mkdir -p /etc/docker
  local daemon_json
  daemon_json=$(jq -n \
    --argjson mirrors "$mirrors_json" \
    --argjson ip6t "$ip6tables_val" \
    --argjson secopt "$extra_opts" \
    '{
      "iptables": true,
      "ip6tables": $ip6t,
      "exec-opts": ["native.cgroupdriver=systemd"],
      "log-driver": "json-file",
      "log-opts": {"max-size": "10m", "max-file": "3"},
      "registry-mirrors": $mirrors,
      "default-security-opt": $secopt
    }')
  if [[ -n "$storage_driver_kv" ]]; then
    daemon_json=$(echo "$daemon_json" | jq '. + {"storage-driver": "fuse-overlayfs"}')
  fi
  if [[ "$extra_opts" == "[]" ]]; then
    daemon_json=$(echo "$daemon_json" | jq 'del(."default-security-opt")')
  fi
  echo "$daemon_json" > /etc/docker/daemon.json
  echo -e "${GREEN}daemon.json 已写入 (ip6tables: ${ip6tables_val})${NC}"
}
ensure_daemon_json() {
  mkdir -p /etc/docker
  if [[ ! -s /etc/docker/daemon.json ]]; then
    local mirrors=("${REGISTRY_MIRRORS_DEFAULT[@]}")
    if [[ -n "$PROXY_MIRROR_URL" ]]; then
      local exists="false"
      for m in "${mirrors[@]}"; do [[ "$m" == "$PROXY_MIRROR_URL" ]] && exists="true" && break; done
      [[ "$exists" == "false" ]] && mirrors+=("$PROXY_MIRROR_URL")
    fi
    local mirrors_json
    mirrors_json=$(printf '%s\n' "${mirrors[@]}" | jq -R . | jq -s .)
    _write_daemon_json "$mirrors_json"
  else
    if [[ "${IPV6_AVAILABLE}" == "false" ]] && jq . /etc/docker/daemon.json >/dev/null 2>&1; then
      local cur_ip6
      cur_ip6=$(jq -r '."ip6tables" // "true"' /etc/docker/daemon.json)
      if [[ "$cur_ip6" == "true" ]]; then
        echo -e "${YELLOW}[FIX] 系统无 IPv6，自动修正 ip6tables 为 false${NC}"
        backup_daemon_json
        local tmp; tmp=$(mktemp)
        jq '. + {"ip6tables": false}' /etc/docker/daemon.json > "$tmp" \
          && mv "$tmp" /etc/docker/daemon.json
      fi
    fi
    if [[ "${APPARMOR_RESTRICTED}" == "true" ]] && jq . /etc/docker/daemon.json >/dev/null 2>&1; then
      local cur_secopt
      cur_secopt=$(jq -r '."default-security-opt" // []' /etc/docker/daemon.json)
      if ! echo "$cur_secopt" | grep -q 'apparmor=unconfined'; then
        echo -e "${YELLOW}[FIX] 注入 apparmor=unconfined 到 default-security-opt${NC}"
        backup_daemon_json
        local tmp; tmp=$(mktemp)
        jq '. + {"default-security-opt": ["apparmor=unconfined"]}' \
          /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
      fi
    fi
    if ! grep -qw overlay /proc/filesystems 2>/dev/null; then
      case "$PKG_MANAGER" in
        apt-get) apt-get install -y fuse-overlayfs >/dev/null 2>&1 || true ;;
        dnf|yum) "${PKG_MANAGER}" install -y fuse-overlayfs >/dev/null 2>&1 || true ;;
      esac
      if command -v fuse-overlayfs >/dev/null 2>&1 && jq . /etc/docker/daemon.json >/dev/null 2>&1; then
        local cur_storage
        cur_storage=$(jq -r '."storage-driver" // ""' /etc/docker/daemon.json)
        if [[ -z "$cur_storage" ]]; then
          local tmp; tmp=$(mktemp)
          jq '. + {"storage-driver":"fuse-overlayfs"}' /etc/docker/daemon.json > "$tmp" \
            && mv "$tmp" /etc/docker/daemon.json
          echo -e "${YELLOW}[FIX] 已设置 storage-driver: fuse-overlayfs${NC}"
        fi
      fi
    fi
  fi
}
_write_docker_service() {
  cat > /etc/systemd/system/docker.service <<'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target
[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500
[Install]
WantedBy=multi-user.target
EOF
  echo -e "${GREEN}docker.service 已写入（静态二进制版，无 containerd 依赖）${NC}"
}
_write_docker_socket() {
  cat > /etc/systemd/system/docker.socket <<'EOF'
[Unit]
Description=Docker Socket for the API
PartOf=docker.service
[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker
[Install]
WantedBy=sockets.target
EOF
  echo -e "${GREEN}docker.socket 已写入${NC}"
}
fetch_docker_versions() {
  local CACHE_FILE="/tmp/docker_versions_cache"
  if [[ -f "$CACHE_FILE" && \
        $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) -gt $(( $(date +%s) - 3600 )) ]]; then
    cat "$CACHE_FILE"
    return
  fi
  ARCH=$(get_architecture)
  local VERSIONS
  VERSIONS=$(curl -s --connect-timeout 15 "${DOCKER_VERSIONS_URL}${ARCH}/" \
    | grep -oP 'docker-\K[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | uniq)
  if [[ -z "$VERSIONS" ]]; then
    echo -e "${RED}无法获取 Docker 版本列表，请检查网络。${NC}" >&2; exit 1
  fi
  echo "$VERSIONS" > "$CACHE_FILE"
  echo "$VERSIONS"
}
select_version() {
  local VERSIONS=("$@")
  if command -v fzf >/dev/null 2>&1; then
    local SELECTED
    SELECTED=$(printf "%s\n" "${VERSIONS[@]}" | fzf \
      --prompt="请选择版本 > " --header="选择版本（回车确认）" \
      --height=20 --reverse --border)
    if [[ -n "$SELECTED" ]]; then
      echo "$SELECTED"; return
    else
      echo -e "${YELLOW}未选择，使用最新版本...${NC}" >&2
      echo "${VERSIONS[0]}"; return
    fi
  fi
  echo "可用版本列表:" >&2
  local i=1
  for v in "${VERSIONS[@]}"; do
    printf "  %3d) %s\n" "$i" "$v" >&2
    ((i++))
  done
  read -r -p "请输入序号 (回车默认选 1 最新版): " REPLY
  if [[ -z "$REPLY" || "$REPLY" == "1" ]]; then
    echo "${VERSIONS[0]}"
  elif [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= ${#VERSIONS[@]} )); then
    echo "${VERSIONS[$((REPLY-1))]}"
  else
    echo -e "${YELLOW}无效选择，使用最新版本...${NC}" >&2
    echo "${VERSIONS[0]}"
  fi
}
fetch_docker_compose_versions() {
  local VERSIONS
  VERSIONS=$(curl -s --connect-timeout 15 "$COMPOSE_RELEASES_URL" \
    | jq -r '.[].tag_name' | sort -Vr | uniq)
  if [[ -z "$VERSIONS" ]]; then
    echo -e "${RED}无法获取 Docker Compose 版本列表。${NC}" >&2; exit 1
  fi
  echo "$VERSIONS"
}
backup_daemon_json() {
  [[ -f /etc/docker/daemon.json ]] || return 0
  mkdir -p "$DAEMON_BACKUP_DIR"
  local bak="${DAEMON_BACKUP_DIR}/daemon.json.$(date +%Y%m%d_%H%M%S)"
  if cp /etc/docker/daemon.json "$bak"; then
    echo -e "${GREEN}已备份 daemon.json 至: $bak${NC}"
  else
    echo -e "${RED}备份失败${NC}"
  fi
}
restore_daemon_json() {
  mkdir -p "$DAEMON_BACKUP_DIR"
  local backups=()
  while IFS= read -r -d '' f; do
    backups+=("$f")
  done < <(find "$DAEMON_BACKUP_DIR" -maxdepth 1 -name "daemon.json.*" -print0 2>/dev/null | sort -z)
  if [[ ${#backups[@]} -eq 0 ]]; then
    echo -e "${YELLOW}暂无备份文件。${NC}"; return
  fi
  echo -e "${CYAN}可用的备份列表：${NC}"
  local i=1
  for f in "${backups[@]}"; do
    echo "  $i) $(basename "$f")  ($(stat -c %y "$f" 2>/dev/null | cut -d. -f1))"
    ((i++))
  done
  read -r -p "请输入要回滚的备份编号 (回车取消): " IDX
  [[ -z "$IDX" ]] && { echo -e "${YELLOW}已取消。${NC}"; return; }
  if ! [[ "$IDX" =~ ^[0-9]+$ ]] || (( IDX < 1 || IDX > ${#backups[@]} )); then
    echo -e "${RED}无效编号。${NC}"; return
  fi
  local selected="${backups[$((IDX-1))]}"
  backup_daemon_json
  cp "$selected" /etc/docker/daemon.json && \
    echo -e "${GREEN}已回滚至: $(basename "$selected")${NC}" || \
    { echo -e "${RED}回滚失败${NC}"; return; }
  if jq . /etc/docker/daemon.json >/dev/null 2>&1; then
    echo -e "${GREEN}daemon.json 格式校验通过。${NC}"
    read -r -p "是否立即重启 Docker？(y/n): " DORESTART
    [[ "$DORESTART" == "y" ]] && _restart_docker
  else
    echo -e "${RED}警告：回滚后的 daemon.json 格式不正确！${NC}"
  fi
}
manage_daemon_json() {
  while true; do
    echo -e "\n${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       daemon.json 备份与回滚             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo "  1. 备份当前 daemon.json"
    echo "  2. 查看所有备份"
    echo "  3. 回滚到指定备份"
    echo "  4. 删除指定备份"
    echo "  0. 返回主菜单"
    read -r -p "请选择操作: " DCHOICE
    case "$DCHOICE" in
      1) backup_daemon_json ;;
      2)
        local backups=()
        while IFS= read -r -d '' f; do backups+=("$f")
        done < <(find "$DAEMON_BACKUP_DIR" -maxdepth 1 -name "daemon.json.*" -print0 2>/dev/null | sort -z)
        if [[ ${#backups[@]} -eq 0 ]]; then
          echo -e "${YELLOW}暂无备份。${NC}"
        else
          for f in "${backups[@]}"; do
            echo "  - $(basename "$f")  ($(stat -c %y "$f" 2>/dev/null | cut -d. -f1))"
          done
        fi
        ;;
      3) restore_daemon_json ;;
      4)
        local backups=()
        while IFS= read -r -d '' f; do backups+=("$f")
        done < <(find "$DAEMON_BACKUP_DIR" -maxdepth 1 -name "daemon.json.*" -print0 2>/dev/null | sort -z)
        if [[ ${#backups[@]} -eq 0 ]]; then
          echo -e "${YELLOW}暂无备份。${NC}"
        else
          local i=1
          for f in "${backups[@]}"; do echo "  $i) $(basename "$f")"; ((i++)); done
          read -r -p "请输入要删除的编号 (回车取消): " DIDX
          if [[ "$DIDX" =~ ^[0-9]+$ ]] && (( DIDX >= 1 && DIDX <= ${#backups[@]} )); then
            rm -f "${backups[$((DIDX-1))]}" && \
              echo -e "${GREEN}已删除。${NC}" || echo -e "${RED}删除失败。${NC}"
          else
            echo -e "${YELLOW}已取消。${NC}"
          fi
        fi
        ;;
      0) break ;;
      *) echo -e "${RED}无效选择。${NC}" ;;
    esac
  done
}
_start_docker() {
  echo -e "${CYAN}正在启动 Docker 服务...${NC}"
  if systemctl start docker; then
    echo -e "${GREEN}Docker 服务已启动。${NC}"
  else
    echo -e "${RED}Docker 服务启动失败，输出近期日志：${NC}"
    journalctl -u docker -n 40 --no-pager 2>/dev/null || true
  fi
}
_stop_docker() {
  read -r -p "停止 Docker 会中断所有运行中容器，确认？(y/n): " CONFIRM
  [[ "$CONFIRM" != "y" ]] && { echo -e "${YELLOW}已取消。${NC}"; return; }
  systemctl stop docker && echo -e "${GREEN}已停止。${NC}" || echo -e "${RED}停止失败。${NC}"
}
_restart_docker() {
  echo -e "${CYAN}正在重启 Docker 服务...${NC}"
  if systemctl restart docker; then
    echo -e "${GREEN}Docker 服务已重启。${NC}"
  else
    echo -e "${RED}重启失败，输出近期日志：${NC}"
    journalctl -u docker -n 40 --no-pager 2>/dev/null || true
  fi
}
manage_docker_service() {
  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}Docker 未安装，无法进行服务管理。${NC}"; return
  fi
  while true; do
    local svc_status svc_enabled
    svc_status=$(systemctl is-active docker 2>/dev/null || echo "inactive")
    svc_enabled=$(systemctl is-enabled docker 2>/dev/null || echo "disabled")
    echo -e "\n${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          Docker 服务管理                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    if [[ "$svc_status" == "active" ]]; then
      echo -e "  当前状态: ${GREEN}● 运行中${NC}  |  开机自启: ${svc_enabled}"
    else
      echo -e "  当前状态: ${RED}● ${svc_status}${NC}  |  开机自启: ${svc_enabled}"
    fi
    echo -e "${CYAN}──────────────────────────────────────────${NC}"
    echo "  1. 启动 Docker"
    echo "  2. 停止 Docker"
    echo "  3. 重启 Docker"
    echo "  4. 开启开机自启"
    echo "  5. 关闭开机自启"
    echo "  6. 查看服务日志（最近 50 行）"
    echo "  0. 返回主菜单"
    echo -e "${CYAN}──────────────────────────────────────────${NC}"
    read -r -p "请选择操作: " SCHOICE
    case "$SCHOICE" in
      1) _start_docker ;;
      2) _stop_docker ;;
      3) _restart_docker ;;
      4) systemctl enable docker >/dev/null 2>&1 && \
           echo -e "${GREEN}已开启开机自启。${NC}" || echo -e "${RED}操作失败。${NC}" ;;
      5) systemctl disable docker >/dev/null 2>&1 && \
           echo -e "${GREEN}已关闭开机自启。${NC}" || echo -e "${RED}操作失败。${NC}" ;;
      6) journalctl -u docker -n 50 --no-pager 2>/dev/null || \
           echo -e "${RED}无法读取 Docker 日志。${NC}" ;;
      0) break ;;
      *) echo -e "${RED}无效选择。${NC}" ;;
    esac
  done
}
show_docker_status() {
  echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║           Docker 状态仪表盘              ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo -e "\n${BOLD}[ 安装状态 ]${NC}"
  if command -v docker >/dev/null 2>&1; then
    echo -e "  Docker:         ${GREEN}已安装 $(docker --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)${NC}"
  else
    echo -e "  Docker:         ${RED}未安装${NC}"
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo -e "  Compose 独立版: ${GREEN}已安装 $(docker-compose --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)${NC}"
  else
    echo -e "  Compose 独立版: ${YELLOW}未安装${NC}"
  fi
  if docker compose version >/dev/null 2>&1; then
    echo -e "  Compose 插件:   ${GREEN}已安装 $(docker compose version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)${NC}"
  else
    echo -e "  Compose 插件:   ${YELLOW}未安装${NC}"
  fi
  echo -e "\n${BOLD}[ 环境速览 ]${NC}"
  echo -e "  虚拟化环境: LXC=${IS_LXC} / OpenVZ=${IS_OPENVZ}"
  echo -e "  AppArmor 受限: ${APPARMOR_RESTRICTED}"
  if command -v ipset >/dev/null 2>&1 && ipset list >/dev/null 2>&1; then
    echo -e "  ipset (Docker 28+): ${GREEN}✓ 可用${NC}"
  else
    echo -e "  ipset (Docker 28+): ${RED}✗ 不可用${NC}"
  fi
  if iptables -t raw -L >/dev/null 2>&1; then
    echo -e "  iptables raw 表:    ${GREEN}✓ 可用${NC}"
  else
    echo -e "  iptables raw 表:    ${YELLOW}⚠ 不可用${NC}"
  fi
  echo -e "  iptables 后端:      ${CYAN}$(_detect_iptables_backend)${NC}"
  if _check_ipv6_available; then
    echo -e "  IPv6:               ${GREEN}可用${NC}"
  else
    echo -e "  IPv6:               ${YELLOW}不可用${NC}"
  fi
  if grep -qw overlay /proc/filesystems 2>/dev/null; then
    echo -e "  overlay 文件系统:   ${GREEN}✓ 可用${NC}"
  else
    echo -e "  overlay 文件系统:   ${YELLOW}⚠ 不可用${NC}"
  fi
  echo -e "\n${BOLD}[ 服务状态 ]${NC}"
  local svc_status svc_enabled
  svc_status=$(systemctl is-active docker 2>/dev/null || echo "inactive")
  svc_enabled=$(systemctl is-enabled docker 2>/dev/null || echo "disabled")
  [[ "$svc_status" == "active" ]] \
    && echo -e "  服务:     ${GREEN}● 运行中${NC}" \
    || echo -e "  服务:     ${RED}● ${svc_status}${NC}"
  [[ "$svc_enabled" == "enabled" ]] \
    && echo -e "  开机自启: ${GREEN}已开启${NC}" \
    || echo -e "  开机自启: ${YELLOW}${svc_enabled}${NC}"
  if [[ "$svc_status" == "active" ]] && command -v docker >/dev/null 2>&1; then
    echo -e "\n${BOLD}[ 运行时资源 ]${NC}"
    local total_c running_c stopped_c
    total_c=$(docker ps -aq 2>/dev/null | wc -l)
    running_c=$(docker ps -q 2>/dev/null | wc -l)
    stopped_c=$(( total_c - running_c ))
    echo -e "  容器: ${GREEN}${running_c} 运行中${NC} / ${YELLOW}${stopped_c} 已停止${NC} / 共 ${total_c}"
    echo -e "  镜像: $(docker images -q 2>/dev/null | wc -l) 个"
    echo -e "  数据卷: $(docker volume ls -q 2>/dev/null | wc -l) 个"
    echo -e "  网络: $(docker network ls -q 2>/dev/null | wc -l) 个"
    echo -e "\n${BOLD}[ 磁盘占用 ]${NC}"
    docker system df 2>/dev/null | while IFS= read -r line; do echo "  $line"; done
    local running_list
    running_list=$(docker ps --format \
      "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null)
    if [[ -n "$running_list" ]]; then
      echo -e "\n${BOLD}[ 运行中容器 ]${NC}"
      echo "$running_list" | while IFS= read -r line; do echo "  $line"; done
    fi
  fi
  echo -e "\n${BOLD}[ daemon.json 配置 ]${NC}"
  if [[ -f /etc/docker/daemon.json ]]; then
    if jq . /etc/docker/daemon.json >/dev/null 2>&1; then
      echo -e "  状态: ${GREEN}存在，格式合法${NC}"
      local mirrors storage log_driver ip6t secopt
      mirrors=$(jq -r '.["registry-mirrors"][]? // empty' /etc/docker/daemon.json 2>/dev/null)
      storage=$(jq -r '."storage-driver" // "overlay2 (默认)"' /etc/docker/daemon.json 2>/dev/null)
      log_driver=$(jq -r '."log-driver" // "json-file (默认)"' /etc/docker/daemon.json 2>/dev/null)
      ip6t=$(jq -r '."ip6tables" // "true (默认)"' /etc/docker/daemon.json 2>/dev/null)
      secopt=$(jq -r '."default-security-opt" // [] | join(",")' /etc/docker/daemon.json 2>/dev/null)
      [[ -n "$mirrors" ]] && {
        echo -e "  镜像加速:"
        while IFS= read -r m; do echo -e "    ${CYAN}• ${m}${NC}"; done <<< "$mirrors"
      } || echo -e "  镜像加速: ${YELLOW}未配置${NC}"
      echo -e "  存储驱动: ${CYAN}${storage}${NC}"
      echo -e "  日志驱动: ${CYAN}${log_driver}${NC}"
      echo -e "  ip6tables: ${CYAN}${ip6t}${NC}"
      [[ -n "$secopt" ]] && echo -e "  default-security-opt: ${CYAN}${secopt}${NC}"
    else
      echo -e "  状态: ${RED}存在，但 JSON 格式错误！${NC}"
    fi
  else
    echo -e "  状态: ${YELLOW}daemon.json 不存在${NC}"
  fi
  echo -e "\n${BOLD}[ 系统信息 ]${NC}"
  echo -e "  架构: $(uname -m)  |  内核: $(uname -r)"
  echo -e "  系统: $(get_os_version 2>/dev/null)"
  local mem_total mem_free
  mem_total=$(free -m 2>/dev/null | awk '/^Mem/{print $2}')
  mem_free=$(free -m 2>/dev/null | awk '/^Mem/{print $4}')
  echo -e "  内存: 已用 $((mem_total - mem_free))MB / 共 ${mem_total}MB"
  echo -e "  根分区: $(df -h / 2>/dev/null | tail -1 | awk '{print "已用 "$3" / 共 "$2" ("$5" used)"}')"
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"
}
_human_size() {
  du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "未知"
}
manage_logs() {
  while true; do
    local current_size="N/A" backup_count=0 total_size="N/A"
    [[ -f "$LOG_FILE" ]] && current_size=$(_human_size "$LOG_FILE")
    backup_count=$(find "$LOG_DIR" -maxdepth 1 -name "*.gz" 2>/dev/null | wc -l)
    [[ -d "$LOG_DIR" ]] && total_size=$(_human_size "$LOG_DIR")
    echo -e "\n${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              日志管理                    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo -e "  日志目录: ${LOG_DIR}  当前: ${current_size}  备份: ${backup_count} 个  总计: ${total_size}"
    echo -e "${CYAN}──────────────────────────────────────────${NC}"
    echo "  1. 查看当前日志（最后 50 行）"
    echo "  2. 查看所有历史备份"
    echo "  3. 立即手动轮转日志"
    echo "  4. 清空当前日志"
    echo "  5. 删除所有历史备份（保留当前）"
    echo "  6. 删除全部日志（当前 + 历史）"
    echo "  7. 修改日志策略"
    echo "  0. 返回主菜单"
    echo -e "${CYAN}──────────────────────────────────────────${NC}"
    read -r -p "请选择操作: " LCHOICE
    case "$LCHOICE" in
      1)
        [[ ! -f "$LOG_FILE" ]] && { echo -e "${YELLOW}日志文件不存在。${NC}"; continue; }
        tail -n 50 "$LOG_FILE"
        ;;
      2)
        local backups=()
        while IFS= read -r -d '' f; do backups+=("$f")
        done < <(find "$LOG_DIR" -maxdepth 1 -name "*.gz" -print0 2>/dev/null | sort -z)
        if [[ ${#backups[@]} -eq 0 ]]; then
          echo -e "${YELLOW}暂无历史备份。${NC}"
        else
          local i=1
          for f in "${backups[@]}"; do
            printf "  %2d) %-45s  %s\n" "$i" "$(basename "$f")" "$(_human_size "$f")"
            ((i++))
          done
          read -r -p "输入编号查看内容（回车跳过）: " BIDX
          if [[ "$BIDX" =~ ^[0-9]+$ ]] && (( BIDX >= 1 && BIDX <= ${#backups[@]} )); then
            zcat "${backups[$((BIDX-1))]}" 2>/dev/null | tail -n 50
          fi
        fi
        ;;
      3)
        local old_max=$LOG_MAX_SIZE_MB
        LOG_MAX_SIZE_MB=0; rotate_log; LOG_MAX_SIZE_MB=$old_max
        echo -e "${GREEN}手动轮转完成。${NC}"
        ;;
      4)
        read -r -p "确认清空当前日志？(y/n): " CONFIRM
        if [[ "$CONFIRM" == "y" ]]; then
          : > "$LOG_FILE"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 日志已手动清空。" >> "$LOG_FILE"
          echo -e "${GREEN}已清空。${NC}"
        fi
        ;;
      5)
        local gz_files=()
        while IFS= read -r -d '' f; do gz_files+=("$f")
        done < <(find "$LOG_DIR" -maxdepth 1 -name "*.gz" -print0 2>/dev/null)
        if [[ ${#gz_files[@]} -eq 0 ]]; then
          echo -e "${YELLOW}没有历史备份。${NC}"
        else
          read -r -p "确认删除 ${#gz_files[@]} 个历史备份？(y/n): " CONFIRM
          [[ "$CONFIRM" == "y" ]] && rm -f "${gz_files[@]}" && echo -e "${GREEN}已删除。${NC}"
        fi
        ;;
      6)
        read -r -p "确认删除全部日志？不可恢复 (y/n): " CONFIRM
        if [[ "$CONFIRM" == "y" ]]; then
          find "$LOG_DIR" -maxdepth 1 -name "*.gz" -delete 2>/dev/null
          : > "$LOG_FILE"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 全部日志已清除。" >> "$LOG_FILE"
          echo -e "${GREEN}已清除。${NC}"
        fi
        ;;
      7)
        echo -e "${CYAN}当前: 单文件上限 ${LOG_MAX_SIZE_MB}MB，保留 ${LOG_MAX_BACKUPS} 个${NC}"
        read -r -p "新大小上限 MB（回车不改）: " NEW_SIZE
        [[ "$NEW_SIZE" =~ ^[1-9][0-9]*$ ]] && LOG_MAX_SIZE_MB=$NEW_SIZE && \
          echo -e "${GREEN}已更新为 ${LOG_MAX_SIZE_MB}MB${NC}"
        read -r -p "新保留数量（回车不改）: " NEW_BACKUPS
        [[ "$NEW_BACKUPS" =~ ^[1-9][0-9]*$ ]] && LOG_MAX_BACKUPS=$NEW_BACKUPS && \
          echo -e "${GREEN}已更新为 ${LOG_MAX_BACKUPS} 个${NC}"
        echo -e "${YELLOW}注意：仅本次会话有效，永久生效请修改脚本顶部变量。${NC}"
        ;;
      0) break ;;
      *) echo -e "${RED}无效选择。${NC}" ;;
    esac
  done
}
install_docker() {
  if check_docker_installed; then
    read -r -p "Docker 已安装，是否重新安装？(y/n): " REINSTALL
    [[ "$REINSTALL" != "y" ]] && { echo -e "${YELLOW}跳过 Docker 安装。${NC}"; return; }
  fi
  ensure_docker_prereqs
  ARCH=$(get_architecture)
  check_and_set_install_dir
  local VERSION
  if [[ "$FORCE_LEGACY_DOCKER" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}将安装兼容版本 Docker ${RECOMMENDED_LEGACY_DOCKER_VERSION}${NC}"
    VERSION="$RECOMMENDED_LEGACY_DOCKER_VERSION"
    local available_versions
    available_versions=$(fetch_docker_versions)
    if ! echo "$available_versions" | grep -qx "${VERSION}"; then
      echo -e "${YELLOW}${VERSION} 不在列表中，查找最近的 27.x 版本...${NC}"
      VERSION=$(echo "$available_versions" | grep "^27\." | head -1)
      if [[ -z "$VERSION" ]]; then
        echo -e "${RED}无法找到兼容的 27.x 版本，安装中止。${NC}"; exit 1
      fi
      echo -e "${YELLOW}将使用: ${VERSION}${NC}"
    fi
  else
    echo "获取可用 Docker 版本..."
    mapfile -t VERSIONS_ARR <<< "$(fetch_docker_versions)"
    VERSION=$(select_version "${VERSIONS_ARR[@]}")
    [[ -z "$VERSION" ]] && { echo -e "${RED}未获得版本号${NC}"; exit 1; }
  fi
  echo -e "${GREEN}选择的 Docker 版本：$VERSION${NC}"
  DOCKER_URL="${DOCKER_VERSIONS_URL}${ARCH}/docker-${VERSION}.tgz"
  if ! download_with_fallback "$DOCKER_URL" "$DOCKER_INSTALL_DIR/docker.tgz"; then
    echo -e "${RED}所有下载方式均失败。${NC}"; rm -rf "$DOCKER_INSTALL_DIR"; exit 1
  fi
  echo "解压 Docker 包..."
  tar -zxf "$DOCKER_INSTALL_DIR/docker.tgz" -C "$DOCKER_INSTALL_DIR" || {
    echo -e "${RED}解压失败${NC}"; rm -rf "$DOCKER_INSTALL_DIR"; exit 1; }
  echo "安装 Docker 二进制到 /usr/local/bin ..."
  chown root:root "$DOCKER_INSTALL_DIR/docker/"*
  mv "$DOCKER_INSTALL_DIR/docker/"* /usr/local/bin/ || {
    echo -e "${RED}移动文件失败${NC}"; exit 1; }
  groupadd -f docker
  CURRENT_USER="${SUDO_USER:-$USER}"
  if [[ -n "$CURRENT_USER" && "$CURRENT_USER" != "root" ]]; then
    gpasswd -a "$CURRENT_USER" docker >/dev/null 2>&1 || true
  fi
  ensure_daemon_json
  _write_docker_service
  _write_docker_socket
  systemctl daemon-reload
  systemctl enable docker.socket >/dev/null 2>&1 || true
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker.socket 2>/dev/null || true
  echo ""
  echo -e "${CYAN}正在启动 Docker...${NC}"
  if ! systemctl start docker; then
    echo -e "${RED}╔══════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  Docker 启动失败！详细错误如下：         ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}=== systemctl 状态 ===${NC}"
    systemctl status docker --no-pager -l 2>/dev/null || true
    echo -e "${YELLOW}=== journalctl 日志 ===${NC}"
    journalctl -u docker -n 50 --no-pager 2>/dev/null || true
    echo -e "${YELLOW}=== daemon.json ===${NC}"
    cat /etc/docker/daemon.json 2>/dev/null || true
    echo -e "${YELLOW}排查建议：${NC}"
    echo -e "  1. 日志含 'ipset'            → 内核不支持 ipset，请联系 VPS 提供商"
    echo -e "  2. 日志含 'raw table'         → 选择菜单 1 重新安装，将自动降级"
    echo -e "  3. 日志含 'ip6tables'         → daemon.json 中将 ip6tables 改为 false"
    echo -e "  4. 日志含 'apparmor/profiles' → daemon.json 中加入 default-security-opt: [apparmor=unconfined]"
    echo -e "  5. 日志含 'overlay'           → 联系 VPS 提供商开启 overlay 支持"
    exit 1
  fi
  sleep 1
  if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ Docker 安装并启动成功！               ║${NC}"
    local ver_str
    ver_str=$(docker --version | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo -e "${GREEN}║    版本: ${ver_str}${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}若需无 sudo 运行 docker，请重新登录以应用用户组变更。${NC}"
    echo ""
    echo -e "${CYAN}验证镜像源（拉取 hello-world）...${NC}"
    if docker pull hello-world >/dev/null 2>&1; then
      echo -e "${GREEN}✓ 镜像拉取成功，镜像源配置正常。${NC}"
      docker rmi hello-world >/dev/null 2>&1 || true
    else
      echo -e "${YELLOW}⚠ hello-world 拉取失败，请通过菜单选项 14 测速并重新配置镜像源。${NC}"
    fi
  else
    echo -e "${RED}Docker 二进制存在但无法通信，请查看上方日志。${NC}"; exit 1
  fi
  echo ""
  echo "清理临时文件..."
  rm -rf "$DOCKER_INSTALL_DIR"
}
install_docker_compose() {
  if check_docker_compose_installed; then
    read -r -p "Docker Compose 已安装，是否重新安装？(y/n): " REINSTALL
    [[ "$REINSTALL" != "y" ]] && { echo -e "${YELLOW}跳过。${NC}"; return; }
  fi
  echo "获取 Docker Compose 版本列表..."
  mapfile -t COMPOSE_ARR <<< "$(fetch_docker_compose_versions)"
  local COMPOSE_VERSION
  COMPOSE_VERSION=$(select_version "${COMPOSE_ARR[@]}")
  if [[ -z "$COMPOSE_VERSION" ]]; then
    COMPOSE_VERSION=$(curl -s --connect-timeout 15 \
      https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
  else
    COMPOSE_VERSION=$(echo "$COMPOSE_VERSION" | tr -d '[:space:]')
  fi
  echo -e "${GREEN}选择的 Docker Compose 版本：$COMPOSE_VERSION${NC}"
  local os_name arch_name compose_file
  os_name=$(uname -s); arch_name=$(uname -m)
  case "$os_name" in
    Linux)
      case "$arch_name" in
        x86_64)  compose_file="docker-compose-linux-x86_64" ;;
        aarch64) compose_file="docker-compose-linux-aarch64" ;;
        armv7l)  compose_file="docker-compose-linux-armv7" ;;
        armv6l)  compose_file="docker-compose-linux-armv6" ;;
        *) echo -e "${RED}不支持的架构: $arch_name${NC}"; exit 1 ;;
      esac ;;
    Darwin)
      case "$arch_name" in
        x86_64) compose_file="docker-compose-darwin-x86_64" ;;
        arm64)  compose_file="docker-compose-darwin-aarch64" ;;
        *) echo -e "${RED}不支持的 macOS 架构: $arch_name${NC}"; exit 1 ;;
      esac ;;
    *) echo -e "${RED}不支持的操作系统: $os_name${NC}"; exit 1 ;;
  esac
  local COMPOSE_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/${compose_file}"
  if ! download_with_fallback "$COMPOSE_URL" "/usr/local/bin/docker-compose"; then
    echo -e "${RED}Docker Compose 下载失败。${NC}"; exit 1
  fi
  chmod +x /usr/local/bin/docker-compose
  mkdir -p /usr/local/lib/docker/cli-plugins
  cp /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
  echo -e "${GREEN}Docker Compose 安装完成（支持 docker compose 与 docker-compose）。${NC}"
}
uninstall_docker() {
  echo "正在卸载 Docker..."
  if systemctl is-active --quiet docker 2>/dev/null; then
    read -r -p "是否清理所有容器/镜像/数据卷？(y/n): " DOPRUNE
    [[ "$DOPRUNE" == "y" ]] && docker system prune -a -f 2>/dev/null || true
  fi
  systemctl stop docker.service docker.socket 2>/dev/null || true
  systemctl disable docker.service docker.socket 2>/dev/null || true
  case "$PKG_MANAGER" in
    apt-get) apt-get remove -y --purge docker docker-engine docker.io \
               containerd runc docker-ce docker-ce-cli 2>/dev/null || true ;;
    dnf|yum) "${PKG_MANAGER}" remove -y docker docker-engine docker.io \
               containerd runc docker-ce docker-ce-cli 2>/dev/null || true ;;
  esac
  rm -rf /var/lib/docker /etc/docker /usr/local/bin/docker* \
    /usr/bin/docker* /usr/sbin/docker* /opt/docker
  rm -f /etc/systemd/system/docker.service /etc/systemd/system/docker.socket
  rm -f /etc/modules-load.d/docker.conf /etc/sysctl.d/99-docker.conf
  rm -rf /var/lib/containerd /run/containerd \
    /usr/local/bin/containerd* /usr/local/bin/runc 2>/dev/null || true
  groupdel docker 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
  echo -e "${GREEN}Docker 已卸载并清理。${NC}"
}
uninstall_docker_compose() {
  echo "正在卸载 Docker Compose..."
  rm -f /usr/local/bin/docker-compose
  rm -f /usr/local/lib/docker/cli-plugins/docker-compose
  rm -rf ~/.docker/compose 2>/dev/null || true
  echo -e "${GREEN}Docker Compose 已卸载。${NC}"
}
generate_daemon_config() {
  echo "正在生成 Docker daemon.json 配置文件..."
  backup_daemon_json
  local DEFAULT_DATA_ROOT="/var/lib/docker"
  read -r -p "请输入 Docker data-root 路径 (默认: ${DEFAULT_DATA_ROOT}): " DATA_ROOT_INPUT
  local DATA_ROOT="${DATA_ROOT_INPUT:-${DEFAULT_DATA_ROOT}}"
  read -r -p "是否先进行镜像源测速？(y/n，默认使用全部内置源): " DO_SPEEDTEST
  if [[ "$DO_SPEEDTEST" == "y" ]]; then
    run_mirror_speed_test; return
  fi
  local mirrors=("${REGISTRY_MIRRORS_DEFAULT[@]}")
  if [[ -n "$PROXY_MIRROR_URL" ]]; then
    local exists="false"
    for m in "${mirrors[@]}"; do [[ "$m" == "$PROXY_MIRROR_URL" ]] && exists="true" && break; done
    [[ "$exists" == "false" ]] && mirrors+=("$PROXY_MIRROR_URL")
  fi
  local mirrors_json
  mirrors_json=$(printf '%s\n' "${mirrors[@]}" | jq -R . | jq -s .)
  local ip6tables_val="true"
  if ! _check_ipv6_available; then
    ip6tables_val="false"
    echo -e "${YELLOW}[INFO] IPv6 不可用，已设置 ip6tables: false${NC}"
  fi
  local secopt_json="null"
  if [[ "${APPARMOR_RESTRICTED}" == "true" ]]; then
    secopt_json='["apparmor=unconfined"]'
  fi
  local DAEMON_CONFIG
  DAEMON_CONFIG=$(jq -n \
    --argjson mirrors "$mirrors_json" \
    --arg data_root "$DATA_ROOT" \
    --argjson ip6t "$ip6tables_val" \
    '{
      "iptables": true,
      "ip6tables": $ip6t,
      "exec-opts": ["native.cgroupdriver=systemd"],
      "registry-mirrors": $mirrors,
      "data-root": $data_root,
      "log-driver": "json-file",
      "log-opts": {"max-size": "10m", "max-file": "3"}
    }')
  if [[ "$secopt_json" != "null" ]]; then
    DAEMON_CONFIG=$(echo "$DAEMON_CONFIG" | \
      jq --argjson secopt "$secopt_json" '. + {"default-security-opt": $secopt}')
  fi
  echo "daemon.json 内容："
  echo "$DAEMON_CONFIG"
  mkdir -p /etc/docker
  echo "$DAEMON_CONFIG" > /etc/docker/daemon.json && \
    echo -e "${GREEN}/etc/docker/daemon.json 生成成功。${NC}" || \
    { echo -e "${RED}写入失败。${NC}"; return; }
  read -r -p "是否立即重启 Docker？(y/n): " DORESTART
  [[ "$DORESTART" == "y" ]] && _restart_docker
}
check_iptables_mode() {
  echo "正在检测 iptables / ipset / AppArmor 状态..."
  local backend
  backend=$(_detect_iptables_backend)
  echo -e "\niptables 后端: ${CYAN}${backend}${NC}"
  case "$backend" in
    nft)
      echo -e "${GREEN}✓ iptables-nft 兼容层，Docker 28+ 可正常工作。${NC}" ;;
    legacy)
      echo -e "${GREEN}✓ iptables-legacy，与 Docker 兼容性良好。${NC}"
      if iptables -t raw -L >/dev/null 2>&1; then
        echo -e "${GREEN}✓ raw 表可用（满足 Docker 28 要求）${NC}"
      else
        echo -e "${RED}✗ raw 表不可用（Docker 28 会报错）${NC}"
      fi ;;
    *)
      echo -e "${RED}✗ iptables 未找到${NC}" ;;
  esac
  echo ""
  echo -e "ipset 状态（Docker 28+ 必需）:"
  if command -v ipset >/dev/null 2>&1 && ipset list >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ ipset 可用${NC}"
  else
    echo -e "  ${RED}✗ ipset 不可用${NC}"
    echo -e "  ${YELLOW}提示：通过菜单选项 1 重新安装 Docker，脚本将自动处理。${NC}"
  fi
  echo ""
  echo -e "IPv6:"
  if _check_ipv6_available; then
    echo -e "  ${GREEN}✓ 可用${NC}"
  else
    echo -e "  ${YELLOW}⚠ 不可用（daemon.json 应设置 ip6tables: false）${NC}"
  fi
  echo ""
  echo -e "AppArmor（Docker 29 LXC 已知问题）:"
  if [[ ! -r /sys/kernel/security/apparmor/profiles ]]; then
    echo -e "  ${YELLOW}⚠ profiles 不可读，Docker 29 在此环境需要 default-security-opt: apparmor=unconfined${NC}"
  else
    echo -e "  ${GREEN}✓ AppArmor profiles 可访问${NC}"
  fi
  echo ""
  echo -e "虚拟化环境:"
  _detect_virt_env
}
print_menu() {
  echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║    Docker / Compose 智能管理脚本 v2.2    ║${NC}"
  echo -e "${BOLD}${CYAN}║    静态二进制 · AppArmor · 2026-08       ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo -e "  架构: ${ARCH}  |  系统: ${OS}  |  包管理: ${PKG_MANAGER}"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
  echo -e "  ${GREEN}1.${NC}  安装 Docker"
  echo -e "  ${GREEN}2.${NC}  安装 Docker Compose"
  echo -e "  ${GREEN}3.${NC}  安装 Docker 和 Docker Compose"
  echo -e "  ${RED}4.${NC}  卸载 Docker"
  echo -e "  ${RED}5.${NC}  卸载 Docker Compose"
  echo -e "  ${RED}6.${NC}  卸载 Docker 和 Docker Compose"
  echo -e "  ${YELLOW}7.${NC}  查询安装状态"
  echo -e "  ${YELLOW}8.${NC}  生成 daemon.json 配置文件"
  echo -e "  ${YELLOW}9.${NC}  查看 iptables / ipset / AppArmor 状态"
  echo -e "  ${BLUE}10.${NC} Docker 服务管理（启动 / 停止 / 重启）"
  echo -e "  ${BLUE}11.${NC} Docker 状态仪表盘"
  echo -e "  ${BLUE}12.${NC} daemon.json 备份与回滚"
  echo -e "  ${BLUE}13.${NC} 日志管理"
  echo -e "  ${BLUE}14.${NC} 镜像源测速 & 一键配置"
  echo -e "  ${BLUE}15.${NC} 配置代理镜像源（直连失败后备）"
  echo -e "  ${RED}0.${NC}  退出脚本"
  echo -e "  日志: ${LOG_FILE}"
}
main() {
  check_sudo
  detect_package_manager
  init_log
  install_dependencies
  echo "检测系统信息..."
  ARCH=$(get_architecture)
  OS=$(get_os_version)
  while true; do
    print_menu
    read -r -p "请输入数字 (0-15): " CHOICE
    if [[ -z "$CHOICE" ]]; then
      echo -e "${RED}请输入有效数字。${NC}"; continue
    fi
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}无效的选择，请输入数字。${NC}"; continue
    fi
    case "$CHOICE" in
      1)  install_docker ;;
      2)  install_docker_compose ;;
      3)  install_docker; install_docker_compose ;;
      4)  uninstall_docker ;;
      5)  uninstall_docker_compose ;;
      6)  uninstall_docker; uninstall_docker_compose ;;
      7)  check_docker_installed; check_docker_compose_installed ;;
      8)  generate_daemon_config ;;
      9)  check_iptables_mode ;;
      10) manage_docker_service ;;
      11) show_docker_status ;;
      12) manage_daemon_json ;;
      13) manage_logs ;;
      14) run_mirror_speed_test ;;
      15) configure_proxy_mirror ;;
      0)
        echo -e "${GREEN}退出脚本。日志已保存至: ${LOG_FILE}${NC}"
        break ;;
      *)
        echo -e "${RED}无效的选择，请输入 0-15 之间的数字。${NC}"; continue ;;
    esac
    [[ "$CHOICE" -ne 0 ]] && read -n 1 -s -r -p $'\n按任意键返回主菜单...'
  done
}
main
