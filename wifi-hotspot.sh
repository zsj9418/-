#!/bin/bash
set -uo pipefail
trap 'echo "[!] 已中断"; exit 1' INT

SCRIPT_VERSION="0.2"
SCRIPT_FIXED_NAME="wifi-auto-switch"
SCRIPT_INSTALL_PATH="/usr/local/bin/${SCRIPT_FIXED_NAME}"
DISPATCHER_SCRIPT="/etc/NetworkManager/dispatcher.d/${SCRIPT_FIXED_NAME}.sh"
CONFIG_DIR="/var/lib/wifi_auto_switch"
INTERFACE_NAME_FILE="$CONFIG_DIR/eth_iface"
LOG_FILE="/var/log/wifi_auto_switch.log"
MAX_LOG_SIZE=1048576
HOTSPOT_PREFIX="AutoHotspot-"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'

_ok()   { echo -e "${GREEN}[✓]${RESET} $*"; }
_warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
_err()  { echo -e "${RED}[x]${RESET} $*" >&2; }
_info() { echo -e "[i] $*"; }

press_any_key() {
  echo ""
  read -rn1 -s -p "按任意键返回..." _junk </dev/tty || true
  echo ""
}

# ── 日志 ──────────────────────────────────────────────────
restrict_log_size() {
  if [[ -f "$LOG_FILE" ]]; then
    local log_size
    log_size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$log_size" -ge "$MAX_LOG_SIZE" ]]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') - 日志超过 1MB 已清空" > "$LOG_FILE"
    fi
  fi
}

log() {
  restrict_log_size
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

# ── Root 检查（最优先）──────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
  _err "请以 root 权限运行此脚本"
  exit 1
fi

mkdir -p "$CONFIG_DIR"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/wifi_auto_switch.log"
log "脚本启动，版本: $SCRIPT_VERSION"

# ── 系统与包管理器检测 ────────────────────────────────────
detect_os() {
  OS_ID=""
  PKG_UPDATE=""
  PKG_INSTALL=""

  if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  fi

  case "$OS_ID" in
    debian|ubuntu|raspbian|armbian)
      PKG_UPDATE="apt-get update -qq"
      PKG_INSTALL="apt-get install -y -qq"
      ;;
    centos|rhel|rocky|almalinux)
      PKG_UPDATE="yum makecache -q"
      PKG_INSTALL="yum install -y -q"
      ;;
    fedora)
      PKG_UPDATE="dnf makecache -q"
      PKG_INSTALL="dnf install -y -q"
      ;;
    arch|manjaro)
      PKG_UPDATE="pacman -Sy --noconfirm -q"
      PKG_INSTALL="pacman -S --noconfirm -q"
      ;;
    *)
      _warn "未完全识别的发行版: ${OS_ID:-unknown}，尝试自动检测包管理器"
      if command -v apt-get >/dev/null 2>&1; then
        PKG_UPDATE="apt-get update -qq"
        PKG_INSTALL="apt-get install -y -qq"
      elif command -v dnf >/dev/null 2>&1; then
        PKG_UPDATE="dnf makecache -q"
        PKG_INSTALL="dnf install -y -q"
      elif command -v yum >/dev/null 2>&1; then
        PKG_UPDATE="yum makecache -q"
        PKG_INSTALL="yum install -y -q"
      elif command -v pacman >/dev/null 2>&1; then
        PKG_UPDATE="pacman -Sy --noconfirm -q"
        PKG_INSTALL="pacman -S --noconfirm -q"
      else
        _err "无法检测包管理器，依赖安装可能失败"
        PKG_UPDATE=":"
        PKG_INSTALL=":"
      fi
      ;;
  esac

  log "操作系统: ${OS_ID:-unknown}"
}

detect_os

# ── 依赖检查与安装 ────────────────────────────────────────
ensure_nmcli() {
  if command -v nmcli >/dev/null 2>&1; then
    return 0
  fi
  _warn "nmcli 未安装，正在安装 NetworkManager..."
  eval "$PKG_UPDATE" 2>/dev/null || true
  eval "$PKG_INSTALL network-manager" || \
    eval "$PKG_INSTALL NetworkManager" || {
      _err "NetworkManager 安装失败，请手动安装"
      return 1
    }
  if ! command -v nmcli >/dev/null 2>&1; then
    _err "安装后仍找不到 nmcli"
    return 1
  fi
  _ok "NetworkManager 安装成功"
}

ensure_nm_running() {
  ensure_nmcli || return 1
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable NetworkManager >/dev/null 2>&1 || true
    systemctl start NetworkManager >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service NetworkManager start >/dev/null 2>&1 || true
  fi
  sleep 1
  if ! nmcli general status >/dev/null 2>&1; then
    _err "NetworkManager 未能正常启动"
    return 1
  fi
  return 0
}

# ── 接口检测 ──────────────────────────────────────────────
detect_wifi_interface() {
  nmcli -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}'
}

detect_ethernet_interface() {
  nmcli -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2=="ethernet"{print $1; exit}'
}

is_ethernet_connected() {
  local iface="$1"
  if [[ ! -f "/sys/class/net/${iface}/carrier" ]]; then
    log "接口 $iface 不存在，视为未连接"
    return 1
  fi
  local carrier
  carrier=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo "0")
  if [[ "$carrier" == "1" ]]; then
    log "网线状态: $iface 已连接（carrier=1）"
    return 0
  else
    log "网线状态: $iface 未连接（carrier=${carrier}）"
    return 1
  fi
}

get_current_mode() {
  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  if [[ -z "$wifi_iface" ]]; then
    echo "无线网卡未检测到"
    return
  fi
  local mode
  mode=$(nmcli -t -f DEVICE,MODE dev wifi 2>/dev/null | awk -F: -v d="$wifi_iface" '$1==d{print $2; exit}' || echo "")
  local active_con
  active_con=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v d="$wifi_iface" '$2==d{print $1; exit}' || echo "")

  if echo "$active_con" | grep -q "^${HOTSPOT_PREFIX}"; then
    echo "热点模式  [${active_con}]"
  elif [[ -n "$active_con" ]]; then
    echo "客户端模式  [${active_con}]"
  else
    echo "未连接"
  fi
}

# ── 热点管理 ──────────────────────────────────────────────
clear_old_hotspots() {
  local old_hotspots=()
  mapfile -t old_hotspots < <(
    nmcli -t -f NAME con show 2>/dev/null | grep "^${HOTSPOT_PREFIX}" || true
  )
  if [[ ${#old_hotspots[@]} -gt 0 ]]; then
    log "清理旧热点配置..."
    for hs in "${old_hotspots[@]}"; do
      nmcli con down "$hs" >/dev/null 2>&1 || true
      nmcli con delete "$hs" >/dev/null 2>&1 || true
      log "已清理热点：$hs"
    done
  fi
}

create_wifi_hotspot() {
  local iface="$1"
  local wifi_name="${2:-4G-WIFI}"
  local wifi_password="${3:-12345678}"
  local con_name="${HOTSPOT_PREFIX}${wifi_name}"

  clear_old_hotspots

  log "创建热点：SSID=$wifi_name"
  _info "创建热点：$wifi_name..."

  if ! nmcli con add type wifi ifname "$iface" con-name "$con_name" \
    ssid "$wifi_name" 802-11-wireless.mode ap >/dev/null 2>&1; then
    log "热点创建失败（add）"
    _err "热点创建失败，请检查无线网卡是否支持 AP 模式"
    return 1
  fi

  nmcli con modify "$con_name" 802-11-wireless-security.key-mgmt wpa-psk >/dev/null 2>&1
  nmcli con modify "$con_name" 802-11-wireless-security.psk "$wifi_password" >/dev/null 2>&1
  nmcli con modify "$con_name" ipv4.method shared >/dev/null 2>&1

  if nmcli con up "$con_name" >/dev/null 2>&1; then
    log "热点已启动：SSID=$wifi_name"
    _ok "热点已启动：SSID=$wifi_name，密码=$wifi_password"
    return 0
  else
    log "热点启动失败（up）"
    _err "热点启动失败"
    nmcli con delete "$con_name" >/dev/null 2>&1 || true
    return 1
  fi
}

# ── WiFi 客户端连接 ────────────────────────────────────────
connect_wifi_network() {
  local iface="$1"
  local ssid="$2"
  local password="$3"

  log "手动连接 WiFi：$ssid"
  _info "扫描网络中..."

  clear_old_hotspots
  sleep 2
  nmcli dev wifi rescan ifname "$iface" >/dev/null 2>&1 || true
  sleep 2

  _info "可见 WiFi 列表："
  nmcli -f SSID,SIGNAL,SECURITY dev wifi list ifname "$iface" 2>/dev/null | head -n 15 || true
  echo ""

  log "尝试连接：$ssid"
  if nmcli dev wifi connect "$ssid" password "$password" ifname "$iface" >/dev/null 2>&1; then
    log "连接成功：$ssid"
    _ok "已连接到：$ssid"
    return 0
  fi

  log "普通连接失败，尝试隐藏 SSID 方式..."
  if nmcli dev wifi connect "$ssid" password "$password" \
    ifname "$iface" hidden yes >/dev/null 2>&1; then
    log "隐藏 SSID 方式连接成功：$ssid"
    _ok "以隐藏 SSID 方式连接成功：$ssid"
    return 0
  fi

  log "连接失败：$ssid"
  _err "连接 $ssid 失败，请检查名称、密码或信号"
  return 1
}

# ── 智能 WiFi 连接 ─────────────────────────────────────────
smart_connect_wifi() {
  local iface="$1"
  local max_retries=3
  local wait_time=5
  local retry_cycle=2

  log "开始智能连接 WiFi..."

  clear_old_hotspots
  sleep 2

  local saved_cons=()
  mapfile -t saved_cons < <(
    nmcli -t -f NAME,TYPE con show 2>/dev/null | \
    awk -F: '$2=="802-11-wireless"{print $1}' | \
    grep -v "^${HOTSPOT_PREFIX}" || true
  )

  if [[ ${#saved_cons[@]} -gt 0 ]]; then
    log "找到已保存的非自建 WiFi 连接：${#saved_cons[@]} 个"
    local cycle
    for (( cycle=1; cycle<=retry_cycle; cycle++ )); do
      log "第 $cycle/$retry_cycle 轮尝试已保存网络..."
      for con in "${saved_cons[@]}"; do
        local attempt=0
        while [[ $attempt -lt $max_retries ]]; do
          log "尝试连接：$con（第 $((attempt+1))/$max_retries 次）"
          if nmcli con up "$con" ifname "$iface" >/dev/null 2>&1; then
            log "已连接：$con"
            return 0
          fi
          attempt=$((attempt + 1))
          sleep "$wait_time"
        done
      done
      if [[ $cycle -lt $retry_cycle ]]; then
        log "本轮失败，等待 10 秒后重试..."
        sleep 10
      fi
    done
  else
    log "无已保存的非自建 WiFi 连接"
  fi

  log "扫描附近 WiFi..."
  nmcli dev wifi rescan ifname "$iface" >/dev/null 2>&1 || true
  sleep 2

  local available_ssids=()
  mapfile -t available_ssids < <(
    nmcli -t -f SSID,SIGNAL dev wifi list ifname "$iface" 2>/dev/null | \
    grep -v "^${HOTSPOT_PREFIX}" | \
    grep -v "^:" | \
    sort -t: -k2 -rn | \
    awk -F: '$1!="" && $1!="--" {print $1}' | \
    head -n 5 || true
  )

  if [[ ${#available_ssids[@]} -gt 0 ]]; then
    for ssid in "${available_ssids[@]}"; do
      log "尝试无密码连接扫描到的网络：$ssid"
      if nmcli dev wifi connect "$ssid" ifname "$iface" >/dev/null 2>&1; then
        log "连接成功：$ssid"
        return 0
      fi
    done
  else
    log "未扫描到可用 WiFi"
  fi

  log "所有 WiFi 连接尝试均失败"
  return 1
}

# ── 自动切换逻辑 ───────────────────────────────────────────
auto_switch_wifi_mode() {
  log "触发自动切换..."

  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  local eth_iface; eth_iface=$(detect_ethernet_interface)

  if [[ -z "$wifi_iface" ]]; then
    log "未检测到无线网卡"
    _err "未检测到无线网卡，请检查硬件"
    return 1
  fi

  if [[ -z "$eth_iface" ]]; then
    log "未检测到有线网卡"
    _err "未检测到有线网卡，请检查硬件"
    return 1
  fi

  local hotspot_name="4G-WIFI"
  local hotspot_pass="12345678"

  if [[ -f "$CONFIG_DIR/hotspot_name" ]]; then
    hotspot_name=$(cat "$CONFIG_DIR/hotspot_name")
  fi
  if [[ -f "$CONFIG_DIR/hotspot_pass" ]]; then
    hotspot_pass=$(cat "$CONFIG_DIR/hotspot_pass")
  fi

  if is_ethernet_connected "$eth_iface"; then
    log "有线已连接，切换到热点模式"
    _info "有线已连接，创建 WiFi 热点..."
    create_wifi_hotspot "$wifi_iface" "$hotspot_name" "$hotspot_pass" || return 1
  else
    log "有线未连接，尝试连接 WiFi..."
    _info "有线未连接，尝试连接已知 WiFi..."
    if smart_connect_wifi "$wifi_iface"; then
      log "已连接 WiFi，保持客户端模式"
      _ok "已连接 WiFi，保持客户端模式"
    else
      log "WiFi 连接失败，切换到热点模式"
      _warn "未连接到任何 WiFi，切换到热点模式..."
      create_wifi_hotspot "$wifi_iface" "$hotspot_name" "$hotspot_pass" || return 1
    fi
  fi
}

# ── Dispatcher 后台服务 ────────────────────────────────────
install_dispatcher() {
  _info "安装 NetworkManager Dispatcher 服务..."

  local eth_iface; eth_iface=$(detect_ethernet_interface)
  if [[ -z "$eth_iface" ]]; then
    _err "未检测到有线网卡，无法安装 Dispatcher"
    return 1
  fi

  _info "检测到有线网卡：$eth_iface"
  echo "$eth_iface" > "$INTERFACE_NAME_FILE"

  cp -f "$0" "$SCRIPT_INSTALL_PATH" || {
    _err "无法复制脚本到 $SCRIPT_INSTALL_PATH"
    return 1
  }
  chmod +x "$SCRIPT_INSTALL_PATH"

  mkdir -p "$(dirname "$DISPATCHER_SCRIPT")"
  cat > "$DISPATCHER_SCRIPT" << EOF
#!/bin/bash
# WiFi 自动切换 Dispatcher 脚本
INTERFACE="\$1"
ACTION="\$2"
ETH_IFACE_FILE="${INTERFACE_NAME_FILE}"
LOG_FILE="${LOG_FILE}"

echo "\$(date '+%Y-%m-%d %H:%M:%S') - Dispatcher: iface=\$INTERFACE action=\$ACTION" >> "\$LOG_FILE"

if [[ ! -f "\$ETH_IFACE_FILE" ]]; then
  echo "\$(date '+%Y-%m-%d %H:%M:%S') - 错误：找不到接口配置文件 \$ETH_IFACE_FILE" >> "\$LOG_FILE"
  exit 1
fi

ETH_IFACE=\$(cat "\$ETH_IFACE_FILE")

should_trigger=false

if [[ "\$INTERFACE" == "\$ETH_IFACE" ]]; then
  case "\$ACTION" in
    up|down|pre-down|post-down) should_trigger=true ;;
  esac
elif [[ "\$INTERFACE" == "lo" && "\$ACTION" == "up" ]]; then
  should_trigger=true
fi

if [[ "\$should_trigger" == "true" ]]; then
  echo "\$(date '+%Y-%m-%d %H:%M:%S') - 触发自动切换（后台执行）" >> "\$LOG_FILE"
  ${SCRIPT_INSTALL_PATH} auto-switch-dispatcher >> "\$LOG_FILE" 2>&1 &
  disown
fi

exit 0
EOF

  chmod +x "$DISPATCHER_SCRIPT"
  _ok "Dispatcher 脚本已安装：$DISPATCHER_SCRIPT"
  _ok "主脚本已安装：$SCRIPT_INSTALL_PATH"

  _info "执行初始状态检测..."
  auto_switch_wifi_mode

  log "Dispatcher 服务安装完成"
}

# ── 卸载服务 ───────────────────────────────────────────────
uninstall_dispatcher() {
  echo ""
  echo "将删除以下内容："
  echo "  - Dispatcher 脚本：$DISPATCHER_SCRIPT"
  echo "  - 主脚本：$SCRIPT_INSTALL_PATH"
  echo "  - 配置目录：$CONFIG_DIR"
  echo ""
  read -rp "确认卸载？(y/N): " confirm </dev/tty
  [[ "${confirm,,}" == "y" ]] || { _warn "已取消"; return; }

  _info "清理热点连接..."
  clear_old_hotspots

  [[ -f "$DISPATCHER_SCRIPT" ]] && rm -f "$DISPATCHER_SCRIPT" && _ok "已删除 Dispatcher 脚本"
  [[ -f "$SCRIPT_INSTALL_PATH" ]] && rm -f "$SCRIPT_INSTALL_PATH" && _ok "已删除主脚本"
  [[ -d "$CONFIG_DIR" ]] && rm -rf "$CONFIG_DIR" && _ok "已删除配置目录"

  log "Dispatcher 服务已卸载"
  _ok "卸载完成"
}

# ── 管理已保存的 WiFi ─────────────────────────────────────
manage_saved_wifi() {
  echo ""
  echo "===== 已保存的 WiFi 网络 ====="
  nmcli -t -f NAME,TYPE con show 2>/dev/null | \
    awk -F: '$2=="802-11-wireless"{print "  "$1}' | \
    grep -v "^  ${HOTSPOT_PREFIX}" || echo "  （无）"
  echo "==============================="
  echo ""
  read -rp "是否添加新的 WiFi 网络？(y/N): " add_choice </dev/tty
  if [[ "${add_choice,,}" != "y" ]]; then
    return
  fi

  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  if [[ -z "$wifi_iface" ]]; then
    _err "未检测到无线网卡"
    return 1
  fi

  read -rp "请输入 WiFi 名称（SSID）: " new_ssid </dev/tty
  read -rsp "请输入 WiFi 密码: " new_pass </dev/tty
  echo ""

  if [[ -z "$new_ssid" ]]; then
    _err "SSID 不能为空"
    return 1
  fi

  connect_wifi_network "$wifi_iface" "$new_ssid" "$new_pass"
}

# ── 查看状态 ───────────────────────────────────────────────
show_status() {
  echo ""
  echo "===== 当前状态 ====="
  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  local eth_iface; eth_iface=$(detect_ethernet_interface)

  echo "  无线网卡：${wifi_iface:-未检测到}"
  echo "  有线网卡：${eth_iface:-未检测到}"

  if [[ -n "$eth_iface" ]]; then
    if is_ethernet_connected "$eth_iface" 2>/dev/null; then
      echo "  有线状态：已连接"
    else
      echo "  有线状态：未连接"
    fi
  fi

  if [[ -n "$wifi_iface" ]]; then
    local mode; mode=$(get_current_mode)
    echo "  WiFi 模式：$mode"
  fi

  echo ""
  echo "  Dispatcher 脚本：$( [[ -f "$DISPATCHER_SCRIPT" ]] && echo "已安装" || echo "未安装" )"
  echo "  热点配置名称：$( [[ -f "$CONFIG_DIR/hotspot_name" ]] && cat "$CONFIG_DIR/hotspot_name" || echo "4G-WIFI（默认）" )"
  echo "===================="
}

# ── 热点参数配置 ───────────────────────────────────────────
configure_hotspot_params() {
  echo ""
  echo "===== 配置热点参数 ====="
  local cur_name="4G-WIFI"
  local cur_pass="12345678"
  [[ -f "$CONFIG_DIR/hotspot_name" ]] && cur_name=$(cat "$CONFIG_DIR/hotspot_name")
  [[ -f "$CONFIG_DIR/hotspot_pass" ]] && cur_pass=$(cat "$CONFIG_DIR/hotspot_pass")

  read -rp "热点名称（SSID） [当前: $cur_name]: " new_name </dev/tty
  new_name="${new_name:-$cur_name}"

  read -rsp "热点密码（8位以上） [当前: $cur_pass]: " new_pass </dev/tty
  echo ""
  new_pass="${new_pass:-$cur_pass}"

  if [[ "${#new_pass}" -lt 8 ]]; then
    _err "密码至少需要 8 位"
    return 1
  fi

  echo "$new_name" > "$CONFIG_DIR/hotspot_name"
  echo "$new_pass" > "$CONFIG_DIR/hotspot_pass"
  chmod 600 "$CONFIG_DIR/hotspot_pass"
  _ok "热点参数已保存：SSID=$new_name"
}

# ── 参数模式（Dispatcher 调用）────────────────────────────
if [[ "${1:-}" == "auto-switch-dispatcher" ]]; then
  ensure_nm_running >/dev/null 2>&1 || true
  auto_switch_wifi_mode
  exit 0
fi

# ── 主菜单 ────────────────────────────────────────────────
ensure_nm_running || {
  _err "NetworkManager 启动失败，脚本无法继续"
  exit 1
}

while true; do
  wifi_iface=$(detect_wifi_interface)
  eth_iface=$(detect_ethernet_interface)
  current_mode=$(get_current_mode)
  eth_status="未连接"
  if [[ -n "$eth_iface" ]] && is_ethernet_connected "$eth_iface" 2>/dev/null; then
    eth_status="已连接"
  fi
  dispatcher_status="未安装"
  [[ -f "$DISPATCHER_SCRIPT" ]] && dispatcher_status="已安装"

  echo ""
  echo "========== WiFi 自动切换管理 =========="
  echo "  无线网卡：${wifi_iface:-未检测到}    有线网卡：${eth_iface:-未检测到}"
  echo "  有线状态：$eth_status    WiFi 模式：$current_mode"
  echo "  Dispatcher：$dispatcher_status"
  echo "---------------------------------------"
  echo "  1. 创建 WiFi 热点"
  echo "  2. 连接到指定 WiFi（切换客户端模式）"
  echo "  3. 手动触发自动切换"
  echo "  4. 安装 Dispatcher（开机自启动）"
  echo "  5. 卸载 Dispatcher"
  echo "  6. 配置热点参数（SSID/密码）"
  echo "  7. 管理已保存的 WiFi"
  echo "  8. 查看详细状态"
  echo "  0. 退出"
  echo "======================================="
  read -rp "请输入选项: " choice </dev/tty

  case "$choice" in
    1)
      wifi_iface=$(detect_wifi_interface)
      if [[ -z "$wifi_iface" ]]; then
        _err "未检测到无线网卡"
        press_any_key; continue
      fi
      configure_hotspot_params || { press_any_key; continue; }
      hn=$(cat "$CONFIG_DIR/hotspot_name" 2>/dev/null || echo "4G-WIFI")
      hp=$(cat "$CONFIG_DIR/hotspot_pass" 2>/dev/null || echo "12345678")
      create_wifi_hotspot "$wifi_iface" "$hn" "$hp"
      press_any_key
      ;;
    2)
      wifi_iface=$(detect_wifi_interface)
      if [[ -z "$wifi_iface" ]]; then
        _err "未检测到无线网卡"
        press_any_key; continue
      fi
      _info "先清理热点连接..."
      clear_old_hotspots
      sleep 2
      _info "扫描 WiFi 中..."
      nmcli dev wifi rescan ifname "$wifi_iface" >/dev/null 2>&1 || true
      sleep 2
      echo ""
      echo "附近可见的 WiFi："
      nmcli -f SSID,SIGNAL,SECURITY dev wifi list ifname "$wifi_iface" 2>/dev/null | head -n 15 || true
      echo ""
      read -rp "请输入要连接的 WiFi 名称（SSID）: " target_ssid </dev/tty
      read -rsp "请输入密码: " target_pass </dev/tty
      echo ""
      if [[ -z "$target_ssid" ]]; then
        _err "SSID 不能为空"
        press_any_key; continue
      fi
      connect_wifi_network "$wifi_iface" "$target_ssid" "$target_pass"
      press_any_key
      ;;
    3)
      _info "手动触发自动切换..."
      auto_switch_wifi_mode
      press_any_key
      ;;
    4)
      if [[ -f "$DISPATCHER_SCRIPT" ]]; then
        _warn "Dispatcher 已安装"
        read -rp "是否重新安装？(y/N): " reinstall </dev/tty
        [[ "${reinstall,,}" == "y" ]] || { press_any_key; continue; }
      fi
      install_dispatcher
      press_any_key
      ;;
    5)
      uninstall_dispatcher
      press_any_key
      ;;
    6)
      configure_hotspot_params
      press_any_key
      ;;
    7)
      manage_saved_wifi
      press_any_key
      ;;
    8)
      show_status
      press_any_key
      ;;
    0)
      _ok "退出脚本"
      exit 0
      ;;
    *)
      _warn "无效选项，请输入 0-8"
      ;;
  esac
done
