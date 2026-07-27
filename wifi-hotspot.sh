#!/bin/bash
set -uo pipefail
trap 'echo "[!] 已中断"; exit 1' INT

SCRIPT_VERSION="0.5"
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

if [[ "${EUID}" -ne 0 ]]; then
  _err "请以 root 权限运行此脚本"
  exit 1
fi

mkdir -p "$CONFIG_DIR"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/wifi_auto_switch.log"
log "脚本启动，版本: $SCRIPT_VERSION"

detect_os() {
  OS_ID=""
  PKG_UPDATE=""
  PKG_INSTALL=""

  if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  fi

  case "$OS_ID" in
    debian|ubuntu|raspbian|armbian)
      PKG_UPDATE="apt-get update -qq"; PKG_INSTALL="apt-get install -y -qq" ;;
    centos|rhel|rocky|almalinux)
      PKG_UPDATE="yum makecache -q"; PKG_INSTALL="yum install -y -q" ;;
    fedora)
      PKG_UPDATE="dnf makecache -q"; PKG_INSTALL="dnf install -y -q" ;;
    arch|manjaro)
      PKG_UPDATE="pacman -Sy --noconfirm -q"; PKG_INSTALL="pacman -S --noconfirm -q" ;;
    *)
      _warn "未完全识别的发行版: ${OS_ID:-unknown}，尝试自动检测包管理器"
      if command -v apt-get >/dev/null 2>&1; then
        PKG_UPDATE="apt-get update -qq"; PKG_INSTALL="apt-get install -y -qq"
      elif command -v dnf >/dev/null 2>&1; then
        PKG_UPDATE="dnf makecache -q"; PKG_INSTALL="dnf install -y -q"
      elif command -v yum >/dev/null 2>&1; then
        PKG_UPDATE="yum makecache -q"; PKG_INSTALL="yum install -y -q"
      elif command -v pacman >/dev/null 2>&1; then
        PKG_UPDATE="pacman -Sy --noconfirm -q"; PKG_INSTALL="pacman -S --noconfirm -q"
      else
        PKG_UPDATE=":"; PKG_INSTALL=":"
        _warn "无法检测包管理器"
      fi
      ;;
  esac
  log "操作系统: ${OS_ID:-unknown}"
}

detect_os

ensure_nmcli() {
  if command -v nmcli >/dev/null 2>&1; then return 0; fi
  _warn "nmcli 未安装，正在安装 NetworkManager..."
  eval "$PKG_UPDATE" 2>/dev/null || true
  eval "$PKG_INSTALL network-manager" || eval "$PKG_INSTALL NetworkManager" || {
    _err "NetworkManager 安装失败，请手动安装"
    return 1
  }
  command -v nmcli >/dev/null 2>&1 || { _err "安装后仍找不到 nmcli"; return 1; }
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
  nmcli general status >/dev/null 2>&1 || { _err "NetworkManager 未能正常启动"; return 1; }
}

_NM_DEV_CACHE=""
_NM_DEV_CACHE_TIME=0

_get_nm_dev_cache() {
  local now; now=$(date +%s)
  if [[ -z "$_NM_DEV_CACHE" ]] || [[ $((now - _NM_DEV_CACHE_TIME)) -gt 3 ]]; then
    _NM_DEV_CACHE=$(nmcli -t -f DEVICE,TYPE dev 2>/dev/null || true)
    _NM_DEV_CACHE_TIME=$now
  fi
  echo "$_NM_DEV_CACHE"
}

detect_wifi_interface() {
  _get_nm_dev_cache | awk -F: '$2=="wifi"{print $1; exit}'
}

detect_ethernet_interface() {
  _get_nm_dev_cache | awk -F: '$2=="ethernet"{print $1; exit}'
}

_invalidate_dev_cache() {
  _NM_DEV_CACHE=""
  _NM_DEV_CACHE_TIME=0
}

is_ethernet_connected() {
  local iface="$1"
  if [[ ! -f "/sys/class/net/${iface}/carrier" ]]; then
    log "接口 $iface 不存在，视为未连接"
    return 1
  fi
  local operstate
  operstate=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
  if [[ "$operstate" == "up" ]]; then
    log "网线状态: $iface 已连接（operstate=up）"
    return 0
  else
    log "网线状态: $iface 未连接（operstate=${operstate}）"
    return 1
  fi
}

get_current_mode() {
  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  if [[ -z "$wifi_iface" ]]; then echo "无线网卡未检测到"; return; fi

  local active_con
  active_con=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | \
    awk -F: -v d="$wifi_iface" '$2==d{print $1; exit}' || true)

  if [[ -z "$active_con" ]]; then
    echo "未连接"
  elif echo "$active_con" | grep -q "^${HOTSPOT_PREFIX}"; then
    echo "热点模式  [${active_con}]"
  else
    echo "客户端模式  [${active_con}]"
  fi
}

_get_iw_mode() {
  local iface="$1"
  if command -v iw >/dev/null 2>&1; then
    iw dev "$iface" info 2>/dev/null | awk '/^\s*type/{print $2}' || echo ""
  else
    echo ""
  fi
}

_is_in_ap_mode() {
  local iface="$1"
  local iw_mode; iw_mode=$(_get_iw_mode "$iface")
  if [[ -n "$iw_mode" ]]; then
    [[ "$iw_mode" == "AP" || "$iw_mode" == "__ap" ]]
    return $?
  fi
  local ap_active
  ap_active=$(nmcli -t -f NAME,DEVICE,STATE con show --active 2>/dev/null | \
    awk -F: -v d="$iface" '$2==d && $3=="activated"{print $1}' | \
    grep "^${HOTSPOT_PREFIX}" || true)
  [[ -n "$ap_active" ]]
}

_ensure_managed_mode() {
  local iface="$1"
  if _is_in_ap_mode "$iface"; then
    log "网卡 $iface 仍在 AP 模式，主动切换 managed..."
    nmcli dev disconnect "$iface" >/dev/null 2>&1 || true
    sleep 1
  fi
  nmcli dev set "$iface" managed yes >/dev/null 2>&1 || true
  log "已设置 $iface managed=yes"
}

wait_for_station_mode() {
  local iface="$1"
  local max_wait="${2:-20}"
  local waited=0

  if ! _is_in_ap_mode "$iface"; then
    log "网卡 $iface 已在 managed 模式，无需等待"
    return 0
  fi

  _info "等待无线网卡切换到 Station 模式（最多 ${max_wait} 秒）..."
  while [[ $waited -lt $max_wait ]]; do
    if ! _is_in_ap_mode "$iface"; then
      log "网卡 $iface 已切换到 Station 模式（${waited}s）"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "等待 Station 模式超时（${max_wait}s），继续尝试"
  return 0
}

_parse_nmcli_wifi_multiline() {
  local raw_output="$1"
  local hotspot_name="${2:-}"

  local ssid="" signal="" security="" mode=""

  while IFS= read -r line; do
    line="${line#"${line%%[! ]*}"}"
    case "$line" in
      SSID:*)
        ssid="${line#SSID:}"
        ssid="${ssid#"${ssid%%[! ]*}"}"
        ;;
      SIGNAL:*)
        signal="${line#SIGNAL:}"
        signal="${signal#"${signal%%[! ]*}"}"
        ;;
      SECURITY:*)
        security="${line#SECURITY:}"
        security="${security#"${security%%[! ]*}"}"
        ;;
      MODE:*)
        mode="${line#MODE:}"
        mode="${mode#"${mode%%[! ]*}"}"
        if [[ -n "$ssid" && \
              "$ssid" != "--" && \
              "$mode" != "Ap" && \
              "$mode" != "AP" && \
              "$ssid" != "$hotspot_name" ]]; then
          echo "${ssid}|${signal}|${security}"
        fi
        ssid=""; signal=""; security=""; mode=""
        ;;
    esac
  done <<< "$raw_output"
}

scan_wifi() {
  local iface="$1"
  local hotspot_name="4G-WIFI"
  [[ -f "$CONFIG_DIR/hotspot_name" ]] && hotspot_name=$(cat "$CONFIG_DIR/hotspot_name")

  local raw_output=""
  if nmcli dev wifi list ifname "$iface" --rescan yes >/dev/null 2>&1; then
    raw_output=$(nmcli --mode multiline -f SSID,SIGNAL,SECURITY,MODE \
      dev wifi list ifname "$iface" --rescan yes 2>/dev/null || true)
  else
    nmcli dev wifi rescan ifname "$iface" >/dev/null 2>&1 || true
    sleep 6
    raw_output=$(nmcli --mode multiline -f SSID,SIGNAL,SECURITY,MODE \
      dev wifi list ifname "$iface" 2>/dev/null || true)
  fi

  _parse_nmcli_wifi_multiline "$raw_output" "$hotspot_name" | sort -t'|' -k2 -rn
}

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
    _invalidate_dev_cache

    local wifi_iface; wifi_iface=$(detect_wifi_interface)
    if [[ -n "$wifi_iface" ]]; then
      _ensure_managed_mode "$wifi_iface"
    fi
  fi
}

create_wifi_hotspot() {
  local iface="$1"
  local wifi_name="${2:-4G-WIFI}"
  local wifi_password="${3:-12345678}"
  local con_name="${HOTSPOT_PREFIX}${wifi_name}"

  clear_old_hotspots

  log "创建热点：SSID=$wifi_name"
  _info "正在创建热点：$wifi_name..."

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
    _invalidate_dev_cache
    return 0
  else
    log "热点启动失败（up）"
    _err "热点启动失败"
    nmcli con delete "$con_name" >/dev/null 2>&1 || true
    return 1
  fi
}

_do_wifi_connect() {
  local iface="$1"
  local ssid="$2"
  local password="$3"
  local hidden="${4:-no}"

  local args=(dev wifi connect "$ssid" ifname "$iface")
  [[ -n "$password" ]] && args+=(password "$password")
  [[ "$hidden" == "yes" ]] && args+=(hidden yes)

  nmcli "${args[@]}" >/dev/null 2>&1
}

connect_wifi_network() {
  local iface="$1"
  local ssid="$2"
  local password="$3"
  local skip_clear="${4:-false}"

  log "手动连接 WiFi：$ssid（skip_clear=$skip_clear）"

  if [[ "$skip_clear" != "true" ]]; then
    clear_old_hotspots
    sleep 2
  fi

  if _is_in_ap_mode "$iface"; then
    _warn "网卡仍在 AP 模式，强制切换 managed..."
    _ensure_managed_mode "$iface"
    wait_for_station_mode "$iface" 20
  fi

  local nm_state
  nm_state=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | \
    awk -F: -v d="$iface" '$1==d{print $2; exit}' || echo "unknown")
  log "连接前 NM 状态：$nm_state"

  log "尝试连接：$ssid"
  if _do_wifi_connect "$iface" "$ssid" "$password" "no"; then
    log "连接成功：$ssid"
    _ok "已连接到：$ssid"
    _invalidate_dev_cache
    return 0
  fi

  log "普通连接失败，尝试隐藏 SSID 方式..."
  if _do_wifi_connect "$iface" "$ssid" "$password" "yes"; then
    log "隐藏 SSID 连接成功：$ssid"
    _ok "以隐藏 SSID 方式已连接：$ssid"
    _invalidate_dev_cache
    return 0
  fi

  log "连接失败：$ssid"
  _err "连接 $ssid 失败，请检查名称、密码或信号"

  local final_iw; final_iw=$(_get_iw_mode "$iface")
  local final_nm
  final_nm=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | \
    awk -F: -v d="$iface" '$1==d{print $2; exit}' || echo "未知")
  _info "网卡驱动模式：${final_iw:-未知}  NM 状态：$final_nm"
  return 1
}

smart_connect_wifi() {
  local iface="$1"
  local max_retries=3
  local wait_time=5
  local retry_cycle=2

  log "开始智能连接 WiFi..."

  clear_old_hotspots
  sleep 2
  wait_for_station_mode "$iface" 20

  local saved_cons=()
  mapfile -t saved_cons < <(
    nmcli -t -f NAME,TYPE con show 2>/dev/null | \
    awk -F: '$2=="802-11-wireless"{print $1}' | \
    grep -v "^${HOTSPOT_PREFIX}" || true
  )

  if [[ ${#saved_cons[@]} -gt 0 ]]; then
    log "找到已保存连接：${#saved_cons[@]} 个"
    local cycle
    for (( cycle=1; cycle<=retry_cycle; cycle++ )); do
      log "第 $cycle/$retry_cycle 轮尝试已保存网络..."
      for con in "${saved_cons[@]}"; do
        local attempt=0
        while [[ $attempt -lt $max_retries ]]; do
          log "尝试连接：$con（第 $((attempt+1))/$max_retries 次）"
          if nmcli con up "$con" ifname "$iface" >/dev/null 2>&1; then
            log "已连接：$con"
            _invalidate_dev_cache
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

  log "扫描附近 WiFi 尝试无密码连接..."
  local available_ssids=()
  mapfile -t available_ssids < <(
    scan_wifi "$iface" | awk -F'|' '{print $1}' | head -n 5 || true
  )

  if [[ ${#available_ssids[@]} -gt 0 ]]; then
    for ssid in "${available_ssids[@]}"; do
      [[ -z "$ssid" ]] && continue
      log "尝试无密码连接：$ssid"
      if nmcli dev wifi connect "$ssid" ifname "$iface" >/dev/null 2>&1; then
        log "连接成功：$ssid"
        _invalidate_dev_cache
        return 0
      fi
    done
  else
    log "未扫描到可用 WiFi"
  fi

  log "所有 WiFi 连接尝试均失败"
  return 1
}

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
  [[ -f "$CONFIG_DIR/hotspot_name" ]] && hotspot_name=$(cat "$CONFIG_DIR/hotspot_name")
  [[ -f "$CONFIG_DIR/hotspot_pass" ]] && hotspot_pass=$(cat "$CONFIG_DIR/hotspot_pass")

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
INTERFACE="\$1"
ACTION="\$2"
ETH_IFACE_FILE="${INTERFACE_NAME_FILE}"
LOG_FILE="${LOG_FILE}"

echo "\$(date '+%Y-%m-%d %H:%M:%S') - Dispatcher: iface=\$INTERFACE action=\$ACTION" >> "\$LOG_FILE"

if [[ ! -f "\$ETH_IFACE_FILE" ]]; then
  echo "\$(date '+%Y-%m-%d %H:%M:%S') - 错误：找不到接口配置文件" >> "\$LOG_FILE"
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

manage_saved_wifi() {
  echo ""
  echo "===== 已保存的 WiFi 网络 ====="
  nmcli -t -f NAME,TYPE con show 2>/dev/null | \
    awk -F: '$2=="802-11-wireless"{print "  "$1}' | \
    grep -v "^  ${HOTSPOT_PREFIX}" || echo "  （无）"
  echo "==============================="
  echo ""
  read -rp "是否添加新的 WiFi 网络？(y/N): " add_choice </dev/tty
  if [[ "${add_choice,,}" != "y" ]]; then return; fi

  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  if [[ -z "$wifi_iface" ]]; then
    _err "未检测到无线网卡"
    return 1
  fi

  read -rp "请输入 WiFi 名称（SSID）: " new_ssid </dev/tty
  read -rsp "请输入 WiFi 密码（无密码直接回车）: " new_pass </dev/tty
  echo ""

  if [[ -z "$new_ssid" ]]; then
    _err "SSID 不能为空"
    return 1
  fi

  connect_wifi_network "$wifi_iface" "$new_ssid" "$new_pass" "false"
}

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

scan_and_display_wifi() {
  local iface="$1"

  _info "清理热点模式中..."
  clear_old_hotspots
  sleep 2
  wait_for_station_mode "$iface" 20

  _info "正在扫描周边 WiFi（同步等待扫描完成）..."

  local hotspot_name="4G-WIFI"
  [[ -f "$CONFIG_DIR/hotspot_name" ]] && hotspot_name=$(cat "$CONFIG_DIR/hotspot_name")

  local raw_output=""
  if nmcli dev wifi list ifname "$iface" --rescan yes >/dev/null 2>&1; then
    raw_output=$(nmcli --mode multiline -f SSID,SIGNAL,SECURITY,MODE \
      dev wifi list ifname "$iface" --rescan yes 2>/dev/null || true)
    _info "（已使用同步扫描模式）"
  else
    nmcli dev wifi rescan ifname "$iface" >/dev/null 2>&1 || true
    _info "（异步扫描模式，等待 8 秒）..."
    sleep 8
    raw_output=$(nmcli --mode multiline -f SSID,SIGNAL,SECURITY,MODE \
      dev wifi list ifname "$iface" 2>/dev/null || true)
  fi

  echo ""
  echo "周边可见的 WiFi："
  printf "  %-32s %-8s %s\n" "SSID" "信号" "安全"
  echo "  ────────────────────────────────────────────────"

  local found=false
  local sorted_output
  sorted_output=$(_parse_nmcli_wifi_multiline "$raw_output" "$hotspot_name" | sort -t'|' -k2 -rn)

  while IFS='|' read -r ssid signal security; do
    [[ -z "$ssid" ]] && continue
    printf "  %-32s %-8s %s\n" "$ssid" "${signal:--}%" "${security:---}"
    found=true
  done <<< "$sorted_output"

  if [[ "$found" == false ]]; then
    _warn "未扫描到可用 WiFi 网络"
    local iw_mode; iw_mode=$(_get_iw_mode "$iface")
    local nm_state
    nm_state=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | \
      awk -F: -v d="$iface" '$1==d{print $2; exit}' || echo "未知")
    _info "网卡驱动模式：${iw_mode:-未知}  NM 状态：$nm_state"
    _info "建议等待 30 秒后重试，或确认周边有 2.4GHz 信号"
  fi
  echo ""
}

show_status() {
  echo ""
  echo "===== 详细状态 ====="
  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  local eth_iface; eth_iface=$(detect_ethernet_interface)

  echo "  无线网卡：${wifi_iface:-未检测到}"
  echo "  有线网卡：${eth_iface:-未检测到}"

  if [[ -n "$eth_iface" ]]; then
    local operstate
    operstate=$(cat "/sys/class/net/${eth_iface}/operstate" 2>/dev/null || echo "unknown")
    echo "  有线状态：$operstate"
  fi

  if [[ -n "$wifi_iface" ]]; then
    local mode; mode=$(get_current_mode)
    echo "  WiFi 模式：$mode"
    local iw_mode; iw_mode=$(_get_iw_mode "$wifi_iface")
    [[ -n "$iw_mode" ]] && echo "  驱动模式：$iw_mode"
    local nm_state
    nm_state=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | \
      awk -F: -v d="$wifi_iface" '$1==d{print $2; exit}' || echo "未知")
    echo "  NM 状态 ：$nm_state"
  fi

  echo ""
  echo "  Dispatcher：$( [[ -f "$DISPATCHER_SCRIPT" ]] && echo "已安装" || echo "未安装" )"
  echo "  热点名称  ：$( [[ -f "$CONFIG_DIR/hotspot_name" ]] && cat "$CONFIG_DIR/hotspot_name" || echo "4G-WIFI（默认）" )"
  echo "  日志文件  ：$LOG_FILE"
  echo ""
  echo "-- 最近 10 条日志 --"
  tail -n 10 "$LOG_FILE" 2>/dev/null || echo "（日志为空）"
  echo "===================="
}

if [[ "${1:-}" == "auto-switch-dispatcher" ]]; then
  ensure_nm_running >/dev/null 2>&1 || true
  auto_switch_wifi_mode
  exit 0
fi

ensure_nm_running || {
  _err "NetworkManager 启动失败，脚本无法继续"
  exit 1
}

while true; do
  _invalidate_dev_cache

  wifi_iface=$(detect_wifi_interface)
  eth_iface=$(detect_ethernet_interface)
  current_mode=$(get_current_mode)

  eth_status="未连接"
  if [[ -n "$eth_iface" ]]; then
    local_operstate=$(cat "/sys/class/net/${eth_iface}/operstate" 2>/dev/null || echo "unknown")
    [[ "$local_operstate" == "up" ]] && eth_status="已连接"
  fi

  dispatcher_status="未安装"
  [[ -f "$DISPATCHER_SCRIPT" ]] && dispatcher_status="已安装"

  echo ""
  echo "========== WiFi 自动切换管理 v${SCRIPT_VERSION} =========="
  echo "  无线网卡：${wifi_iface:-未检测到}    有线网卡：${eth_iface:-未检测到}"
  echo "  有线状态：$eth_status    WiFi 模式：$current_mode"
  echo "  Dispatcher：$dispatcher_status"
  echo "---------------------------------------------------"
  echo "  1. 创建 WiFi 热点"
  echo "  2. 连接到指定 WiFi（切换客户端模式）"
  echo "  3. 手动触发自动切换"
  echo "  4. 安装 Dispatcher（开机自启动）"
  echo "  5. 卸载 Dispatcher"
  echo "  6. 配置热点参数（SSID/密码）"
  echo "  7. 管理已保存的 WiFi"
  echo "  8. 查看详细状态"
  echo "  0. 退出"
  echo "==================================================="
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
      scan_and_display_wifi "$wifi_iface"
      read -rp "请输入要连接的 WiFi 名称（SSID，留空取消）: " target_ssid </dev/tty
      if [[ -z "$target_ssid" ]]; then
        _warn "已取消"
        press_any_key; continue
      fi
      read -rsp "请输入密码（无密码直接回车）: " target_pass </dev/tty
      echo ""
      connect_wifi_network "$wifi_iface" "$target_ssid" "$target_pass" "true"
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
