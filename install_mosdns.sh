#!/bin/bash
set -uo pipefail
trap 'echo "[!] 已中断"; exit 1' INT

LOG_FILE=""
INSTALL_PATH=""
CONFIG_PATH=""
SERVICE_NAME="mosdns"

DEFAULT_DOMESTIC_DNS="https://223.5.5.5/dns-query"
DEFAULT_FOREIGN_DNS="https://1.1.1.1/dns-query"
DEFAULT_PORT="5335"
DEFAULT_IPV6="no"

RULES_URL_CN_DOMAIN="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt"
RULES_URL_PROXY_DOMAIN="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
RULES_URL_ADBLOCK="https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblockdns.txt"
RULES_URL_CN_IP="https://raw.githubusercontent.com/Hackl0us/GeoIP2-CN/release/CN-ip-cidr.txt"

GH_API_URL="https://api.github.com/repos/IrineSistiana/mosdns/releases"

GH_MIRRORS=(
  ""
  "https://gh-proxy.com/"
  "https://ghproxy.link/"
  "https://ghfast.top/"
  "https://ghps.cc/"
  "https://mirror.ghproxy.com/"
)

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

_need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    _err "该操作需要 root 权限"
    return 1
  fi
}

_have() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
  if _have apt-get; then
    PKG_MGR="apt-get"; PKG_UPDATE="apt-get update -qq"; PKG_INSTALL="apt-get install -y -qq"
  elif _have dnf; then
    PKG_MGR="dnf"; PKG_UPDATE="dnf makecache -q"; PKG_INSTALL="dnf install -y -q"
  elif _have yum; then
    PKG_MGR="yum"; PKG_UPDATE="yum makecache -q"; PKG_INSTALL="yum install -y -q"
  elif _have apk; then
    PKG_MGR="apk"; PKG_UPDATE="apk update -q"; PKG_INSTALL="apk add -q"
  elif _have pacman; then
    PKG_MGR="pacman"; PKG_UPDATE="pacman -Sy --noconfirm -q"; PKG_INSTALL="pacman -S --noconfirm -q"
  elif _have opkg; then
    PKG_MGR="opkg"; PKG_UPDATE="opkg update"; PKG_INSTALL="opkg install"
  else
    PKG_MGR="none"; PKG_UPDATE=":"; PKG_INSTALL=":"
    _warn "未检测到支持的包管理器"
  fi
}

detect_dig_pkg() {
  case "$PKG_MGR" in
    apt-get) echo "dnsutils" ;;
    apk)     echo "bind-tools" ;;
    dnf|yum) echo "bind-utils" ;;
    opkg)    echo "bind-dig" ;;
    *)       echo "dnsutils" ;;
  esac
}

detect_arch() {
  local raw_arch; raw_arch="$(uname -m)"
  case "$raw_arch" in
    x86_64|amd64)   ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    armv7l|armhf)   ARCH="armv7" ;;
    armv6l)         ARCH="armv6" ;;
    mips64le)       ARCH="mips64le" ;;
    mips64)         ARCH="mips64" ;;
    mipsle|mipsel)  ARCH="mipsle" ;;
    mips)           ARCH="mips" ;;
    i386|i686)      ARCH="386" ;;
    riscv64)        ARCH="riscv64" ;;
    loong64|loongarch64) ARCH="loong64" ;;
    *)
      _err "不支持的架构：$raw_arch"
      return 1
      ;;
  esac
  _info "系统架构：$raw_arch → $ARCH"
}

detect_init_system() {
  if _have systemctl && systemctl list-units >/dev/null 2>&1; then
    INIT_SYS="systemd"
  elif [[ -f /etc/init.d/rcS ]] && _have procd; then
    INIT_SYS="procd"
  elif [[ -d /etc/init.d ]] && _have update-rc.d; then
    INIT_SYS="sysv"
  elif [[ -d /etc/init.d ]] && _have chkconfig; then
    INIT_SYS="sysv"
  elif _have rc-update; then
    INIT_SYS="openrc"
  else
    INIT_SYS="none"
  fi
  _info "初始化系统：$INIT_SYS"
}

detect_paths() {
  if [[ -w "/usr/local/bin" ]]; then
    INSTALL_PATH="/usr/local/bin"
  elif [[ -w "/usr/bin" ]]; then
    INSTALL_PATH="/usr/bin"
  else
    INSTALL_PATH="$HOME/.local/bin"
    mkdir -p "$INSTALL_PATH"
  fi

  if [[ "$INIT_SYS" == "procd" ]] || _have opkg; then
    CONFIG_PATH="/etc/mosdns"
    LOG_FILE="/tmp/mosdns_install.log"
  else
    CONFIG_PATH="/etc/mosdns"
    LOG_FILE="/var/log/mosdns_install.log"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/mosdns_install.log"
  fi

  mkdir -p "$CONFIG_PATH"
}

detect_mihomo_env() {
  MIHOMO_RUNNING=false
  MIHOMO_TUN=false
  MIHOMO_DNS_PORT=""
  IPTABLES_53_HIJACK=false

  if pgrep -x "mihomo" >/dev/null 2>&1 || pgrep -x "clash" >/dev/null 2>&1; then
    MIHOMO_RUNNING=true

    local cfg_files=()
    if [[ -f "/etc/mihomo/config.yaml" ]]; then cfg_files+=("/etc/mihomo/config.yaml"); fi
    if [[ -f "/etc/clash/config.yaml" ]]; then cfg_files+=("/etc/clash/config.yaml"); fi
    if [[ -f "$HOME/.config/mihomo/config.yaml" ]]; then cfg_files+=("$HOME/.config/mihomo/config.yaml"); fi

    for cfg in "${cfg_files[@]}"; do
      if grep -q "tun:" "$cfg" 2>/dev/null && grep -q "enable: true" "$cfg" 2>/dev/null; then
        MIHOMO_TUN=true
      fi
      local dp; dp=$(grep -E "^[[:space:]]*listen:" "$cfg" 2>/dev/null | grep -oE '[0-9]+$' | head -n1 || true)
      [[ -n "$dp" ]] && MIHOMO_DNS_PORT="$dp"
    done
  fi

  if _have iptables; then
    if iptables -t nat -L PREROUTING 2>/dev/null | grep -q "dpt:53"; then
      IPTABLES_53_HIJACK=true
    fi
  fi
  if _have nft; then
    if nft list ruleset 2>/dev/null | grep -q "dport 53"; then
      IPTABLES_53_HIJACK=true
    fi
  fi
}

detect_port_53_occupant() {
  PORT_53_OCCUPANT=""
  if _have ss; then
    PORT_53_OCCUPANT=$(ss -tulpn 2>/dev/null | grep ':53 ' | awk '{print $NF}' | grep -oP 'pid=\K[0-9]+' | head -n1 || true)
    if [[ -n "$PORT_53_OCCUPANT" ]]; then
      PORT_53_OCCUPANT=$(cat "/proc/$PORT_53_OCCUPANT/comm" 2>/dev/null || echo "unknown")
    fi
  elif _have netstat; then
    PORT_53_OCCUPANT=$(netstat -tulpn 2>/dev/null | grep ':53 ' | awk '{print $NF}' | cut -d/ -f2 | head -n1 || true)
  fi
}

recommend_port() {
  detect_mihomo_env
  detect_port_53_occupant

  RECOMMENDED_PORT="$DEFAULT_PORT"
  DEPLOY_MODE="standalone"

  if [[ "$MIHOMO_RUNNING" == true ]]; then
    DEPLOY_MODE="mihomo_collab"
    RECOMMENDED_PORT="5335"
    _warn "检测到 Mihomo/Clash 正在运行"
    if [[ "$MIHOMO_TUN" == true ]]; then
      _warn "Mihomo TUN 模式已启用，53 端口可能被劫持"
    fi
    if [[ "$IPTABLES_53_HIJACK" == true ]]; then
      _warn "检测到 iptables/nftables 劫持 53 端口规则"
    fi
    _info "推荐使用端口 5335，并通过 dnsmasq 或 Mihomo upstream 转发"
  elif [[ -n "$PORT_53_OCCUPANT" ]]; then
    _warn "53 端口已被 $PORT_53_OCCUPANT 占用"
    RECOMMENDED_PORT="5335"
  fi
}

check_port_free() {
  local port="$1"
  if _have ss; then
    ss -tulpn 2>/dev/null | grep -q ":${port} " && return 1
  elif _have netstat; then
    netstat -tulpn 2>/dev/null | grep -q ":${port} " && return 1
  fi
  return 0
}

install_core_deps() {
  _need_root || return 1
  detect_pkg_manager
  local missing=()
  for dep in curl unzip; do
    _have "$dep" || missing+=("$dep")
  done
  if ! _have dig; then
    missing+=("$(detect_dig_pkg)")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    _info "安装依赖：${missing[*]}"
    eval "$PKG_UPDATE" 2>/dev/null || true
    eval "$PKG_INSTALL ${missing[*]}" || _warn "部分依赖安装失败，继续尝试..."
  fi
}

download_with_retry() {
  local url="$1"
  local output="$2"
  local label="${3:-$url}"

  _info "下载：$label"
  if curl -fsSL --connect-timeout 15 --max-time 120 -o "$output" "$url" 2>/dev/null; then
    local sz; sz=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo 0)
    if [[ "$sz" -gt 100 ]]; then
      return 0
    fi
    _warn "文件大小异常（${sz}字节），尝试镜像源..."
    rm -f "$output"
  fi

  for prefix in "${GH_MIRRORS[@]:1}"; do
    local mirror_url="${prefix}${url}"
    _info "尝试镜像：$prefix"
    if curl -fsSL --connect-timeout 15 --max-time 120 -o "$output" "$mirror_url" 2>/dev/null; then
      local sz; sz=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo 0)
      if [[ "$sz" -gt 100 ]]; then
        return 0
      fi
      rm -f "$output"
    fi
  done

  _err "下载失败：$label"
  return 1
}

get_mosdns_versions() {
  local raw=""
  local api_mirrors=(
    "$GH_API_URL"
    "https://gh-proxy.com/$GH_API_URL"
    "https://ghproxy.link/$GH_API_URL"
  )
  for url in "${api_mirrors[@]}"; do
    raw=$(curl -fsSL --connect-timeout 10 --max-time 20 "${url}?per_page=20" 2>/dev/null || true)
    if echo "$raw" | grep -q '"tag_name"'; then
      break
    fi
    raw=""
  done
  [[ -z "$raw" ]] && return 1
  echo "$raw" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | \
    sed -E 's/.*"(v[^"]+)".*/\1/' | head -n 15
}

choose_version() {
  MOSDNS_VERSION=""
  _info "获取版本列表..."
  local versions=()
  mapfile -t versions < <(get_mosdns_versions || true)

  if [[ ${#versions[@]} -eq 0 ]]; then
    _warn "无法获取版本列表，使用预置版本"
    versions=("v5.3.4" "v5.3.3" "v5.3.2" "v5.2.1" "v5.1.3")
  fi

  local default_ver="${versions[0]}"
  echo ""
  echo "可用版本（默认最新：$default_ver）："
  local i=1
  for v in "${versions[@]}"; do
    echo "  $i. $v"
    i=$((i + 1))
  done
  local manual_idx=$i
  echo "  $i. 手动输入"
  echo ""
  read -rp "请输入版本编号 [默认 1]: " ver_choice </dev/tty
  ver_choice="${ver_choice:-1}"

  if [[ "$ver_choice" =~ ^[0-9]+$ ]] && [[ "$ver_choice" -ge 1 && "$ver_choice" -lt "$manual_idx" ]]; then
    MOSDNS_VERSION="${versions[$((ver_choice - 1))]}"
  elif [[ "$ver_choice" == "$manual_idx" ]]; then
    read -rp "输入版本号（如 v5.3.4）: " MOSDNS_VERSION </dev/tty
    [[ "$MOSDNS_VERSION" =~ ^v ]] || MOSDNS_VERSION="v${MOSDNS_VERSION}"
  else
    MOSDNS_VERSION="$default_ver"
  fi
  _ok "选择版本：$MOSDNS_VERSION"
}

build_download_url() {
  local version="$1"
  local ver_num="${version#v}"
  MOSDNS_FILENAME="mosdns-linux-${ARCH}.zip"
  if [[ "$version" == "latest" ]]; then
    MOSDNS_DL_URL="https://github.com/IrineSistiana/mosdns/releases/latest/download/${MOSDNS_FILENAME}"
  else
    MOSDNS_DL_URL="https://github.com/IrineSistiana/mosdns/releases/download/${version}/${MOSDNS_FILENAME}"
  fi
}

download_mosdns_binary() {
  local tmp_dir="$1"
  build_download_url "$MOSDNS_VERSION"
  local zip_path="${tmp_dir}/${MOSDNS_FILENAME}"

  for prefix in "${GH_MIRRORS[@]}"; do
    local url="${prefix}${MOSDNS_DL_URL}"
    _info "下载 MosDNS：$url"
    if curl -fL --connect-timeout 15 --max-time 300 --progress-bar \
       -o "$zip_path" "$url" 2>/dev/null; then
      local sz; sz=$(stat -c%s "$zip_path" 2>/dev/null || stat -f%z "$zip_path" 2>/dev/null || echo 0)
      if [[ "$sz" -gt 10240 ]]; then
        echo "$zip_path"
        return 0
      fi
      _warn "文件过小（${sz}字节），换源重试..."
      rm -f "$zip_path"
    fi
  done
  return 1
}

choose_deploy_mode() {
  echo ""
  echo "请选择部署模式："
  echo "  1. 独立模式（MosDNS 直接监听，适合无透明代理环境）"
  echo "  2. Mihomo 协作模式（MosDNS 监听非 53 端口，国外流量转 Mihomo）"
  echo "  3. ADG 前端模式（AdGuard Home 作为前端，MosDNS 作为上游分流）"
  echo ""
  read -rp "选项 [默认 1]: " mode_choice </dev/tty
  mode_choice="${mode_choice:-1}"

  case "$mode_choice" in
    2) DEPLOY_MODE="mihomo_collab" ;;
    3) DEPLOY_MODE="adg_frontend" ;;
    *) DEPLOY_MODE="standalone" ;;
  esac
  _ok "部署模式：$DEPLOY_MODE"
}

collect_config_params() {
  echo ""
  recommend_port

  echo "当前推荐端口：$RECOMMENDED_PORT"
  read -rp "MosDNS 监听端口 [默认 $RECOMMENDED_PORT]: " input_port </dev/tty
  LISTEN_PORT="${input_port:-$RECOMMENDED_PORT}"

  if ! check_port_free "$LISTEN_PORT"; then
    _warn "端口 $LISTEN_PORT 已被占用，请确认或更换"
    read -rp "继续使用此端口？(y/N): " force_port </dev/tty
    [[ "${force_port,,}" == "y" ]] || return 1
  fi

  echo ""
  read -rp "国内 DNS（DoH/DoT/UDP） [默认 $DEFAULT_DOMESTIC_DNS]: " input_domestic </dev/tty
  DOMESTIC_DNS="${input_domestic:-$DEFAULT_DOMESTIC_DNS}"

  echo ""
  if [[ "$DEPLOY_MODE" == "mihomo_collab" ]]; then
    local default_foreign="127.0.0.1:${MIHOMO_DNS_PORT:-7874}"
    echo "Mihomo 协作模式：国外 DNS 将转发至 Mihomo 内部 DNS"
    read -rp "Mihomo DNS 端口地址 [默认 $default_foreign]: " input_foreign </dev/tty
    FOREIGN_DNS="${input_foreign:-$default_foreign}"
  else
    read -rp "国外 DNS（DoH/DoT/UDP） [默认 $DEFAULT_FOREIGN_DNS]: " input_foreign </dev/tty
    FOREIGN_DNS="${input_foreign:-$DEFAULT_FOREIGN_DNS}"
  fi

  echo ""
  read -rp "是否启用 IPv6 监听（::1）？(y/N) [默认 N]: " input_ipv6 </dev/tty
  if [[ "${input_ipv6,,}" == "y" ]]; then
    ENABLE_IPV6="yes"
  else
    ENABLE_IPV6="no"
  fi

  echo ""
  read -rp "是否启用 Prometheus 监控 API？(y/N) [默认 N]: " input_api </dev/tty
  if [[ "${input_api,,}" == "y" ]]; then
    ENABLE_API="yes"
    read -rp "API 监听地址 [默认 127.0.0.1:9090]: " input_api_addr </dev/tty
    API_ADDR="${input_api_addr:-127.0.0.1:9090}"
  else
    ENABLE_API="no"
    API_ADDR="127.0.0.1:9090"
  fi

  echo ""
  read -rp "是否启用 DNS 缓存？(Y/n) [默认 Y]: " input_cache </dev/tty
  if [[ "${input_cache,,}" == "n" ]]; then
    ENABLE_CACHE="no"
  else
    ENABLE_CACHE="yes"
  fi
}

download_rules() {
  local config_path="$1"
  _info "下载分流规则..."

  download_with_retry "$RULES_URL_CN_DOMAIN" \
    "${config_path}/cn_domains.txt" "国内域名列表" || return 1

  download_with_retry "$RULES_URL_PROXY_DOMAIN" \
    "${config_path}/proxy_domains.txt" "代理域名列表" || return 1

  download_with_retry "$RULES_URL_CN_IP" \
    "${config_path}/cn_ip.txt" "国内 IP CIDR" || return 1

  download_with_retry "$RULES_URL_ADBLOCK" \
    "${config_path}/adblock.txt" "广告过滤规则" || return 1

  _ok "规则下载完成"
}

generate_config() {
  local config_path="$1"
  local config_file="${config_path}/config.yaml"

  cat > "$config_file" << EOF
log:
  level: info
  file: "${config_path}/mosdns.log"

EOF

  if [[ "$ENABLE_API" == "yes" ]]; then
    cat >> "$config_file" << EOF
api:
  http: "${API_ADDR}"

EOF
  fi

  cat >> "$config_file" << EOF
plugins:
  - tag: cn_domain
    type: domain_set
    args:
      files:
        - "${config_path}/cn_domains.txt"

  - tag: proxy_domain
    type: domain_set
    args:
      files:
        - "${config_path}/proxy_domains.txt"

  - tag: cn_ip
    type: ip_set
    args:
      files:
        - "${config_path}/cn_ip.txt"

  - tag: ad_block
    type: adblock_set
    args:
      files:
        - "${config_path}/adblock.txt"

EOF

  if [[ "$ENABLE_CACHE" == "yes" ]]; then
    cat >> "$config_file" << EOF
  - tag: dns_cache
    type: cache
    args:
      size: 10240
      lazy_cache_ttl: 18000
      dump_file: "${config_path}/cache.dump"
      dump_interval: 600

EOF
  fi

  cat >> "$config_file" << EOF
  - tag: domestic_forward
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "${DOMESTIC_DNS}"
          enable_pipeline: true

  - tag: foreign_forward
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "${FOREIGN_DNS}"
          enable_pipeline: true

  - tag: domestic_sequence
    type: sequence
    args:
      - exec: \$domestic_forward

  - tag: foreign_sequence
    type: sequence
    args:
      - exec: \$foreign_forward

  - tag: main_sequence
    type: sequence
    args:
      - matches: "qname \$ad_block"
        exec: reject 3
EOF

  if [[ "$ENABLE_CACHE" == "yes" ]]; then
    cat >> "$config_file" << EOF
      - exec: \$dns_cache
EOF
  fi

  cat >> "$config_file" << EOF
      - matches: "qname \$cn_domain"
        exec: goto domestic_sequence
      - matches: "qname \$proxy_domain"
        exec: goto foreign_sequence
      - matches:
          - "!resp_ip \$cn_ip"
          - "has_resp_msg"
        exec: goto foreign_sequence
      - exec: goto foreign_sequence

  - type: udp_server
    args:
      entry: main_sequence
      listen: "127.0.0.1:${LISTEN_PORT}"

  - type: tcp_server
    args:
      entry: main_sequence
      listen: "127.0.0.1:${LISTEN_PORT}"
EOF

  if [[ "$ENABLE_IPV6" == "yes" ]]; then
    cat >> "$config_file" << EOF

  - type: udp_server
    args:
      entry: main_sequence
      listen: "[::1]:${LISTEN_PORT}"

  - type: tcp_server
    args:
      entry: main_sequence
      listen: "[::1]:${LISTEN_PORT}"
EOF
  fi

  _ok "配置文件已生成：$config_file"
}

validate_config() {
  local config_path="$1"
  _info "验证配置文件..."
  local tmp_log; tmp_log=$(mktemp)
  "$INSTALL_PATH/mosdns" start -c "${config_path}/config.yaml" > "$tmp_log" 2>&1 &
  local pid=$!
  sleep 3
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    rm -f "$tmp_log"
    _ok "配置文件验证通过"
    return 0
  else
    _err "配置文件验证失败："
    cat "$tmp_log"
    rm -f "$tmp_log"
    return 1
  fi
}

install_service_systemd() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=MosDNS DNS Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_PATH}
ExecStart=${INSTALL_PATH}/mosdns start -c ${CONFIG_PATH}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl restart "$SERVICE_NAME"
  sleep 3
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    _ok "systemd 服务启动成功"
    return 0
  fi
  _err "systemd 服务启动失败"
  journalctl -u "$SERVICE_NAME" --no-pager -n 20 2>/dev/null || true
  return 1
}

install_service_procd() {
  cat > "/etc/init.d/${SERVICE_NAME}" << EOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10

start_service() {
  procd_open_instance
  procd_set_param command ${INSTALL_PATH}/mosdns start -c ${CONFIG_PATH}/config.yaml
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
  chmod +x "/etc/init.d/${SERVICE_NAME}"
  "/etc/init.d/${SERVICE_NAME}" enable
  "/etc/init.d/${SERVICE_NAME}" start
  sleep 3
  if "/etc/init.d/${SERVICE_NAME}" status 2>/dev/null | grep -q "running"; then
    _ok "procd 服务启动成功"
    return 0
  fi
  _err "procd 服务启动失败"
  return 1
}

install_service_openrc() {
  cat > "/etc/init.d/${SERVICE_NAME}" << EOF
#!/sbin/openrc-run
command="${INSTALL_PATH}/mosdns"
command_args="start -c ${CONFIG_PATH}/config.yaml"
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"
depend() {
  need net
}
EOF
  chmod +x "/etc/init.d/${SERVICE_NAME}"
  rc-update add "$SERVICE_NAME" default
  rc-service "$SERVICE_NAME" start
  sleep 3
  if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started"; then
    _ok "OpenRC 服务启动成功"
    return 0
  fi
  _err "OpenRC 服务启动失败"
  return 1
}

install_service_sysv() {
  cat > "/etc/init.d/${SERVICE_NAME}" << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          mosdns
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: MosDNS Service
### END INIT INFO
DAEMON=${INSTALL_PATH}/mosdns
DAEMON_ARGS="start -c ${CONFIG_PATH}/config.yaml"
PIDFILE=/var/run/mosdns.pid
case "\$1" in
  start)
    start-stop-daemon --start --quiet --background --make-pidfile --pidfile \$PIDFILE --exec \$DAEMON -- \$DAEMON_ARGS
    ;;
  stop)
    start-stop-daemon --stop --quiet --pidfile \$PIDFILE
    rm -f \$PIDFILE
    ;;
  restart)
    \$0 stop; sleep 1; \$0 start
    ;;
  status)
    if [ -f \$PIDFILE ] && kill -0 \$(cat \$PIDFILE) 2>/dev/null; then
      echo "mosdns 正在运行"
    else
      echo "mosdns 未运行"
    fi
    ;;
esac
EOF
  chmod +x "/etc/init.d/${SERVICE_NAME}"
  _have update-rc.d && update-rc.d "$SERVICE_NAME" defaults >/dev/null 2>&1 || true
  _have chkconfig && chkconfig --add "$SERVICE_NAME" >/dev/null 2>&1 || true
  "/etc/init.d/${SERVICE_NAME}" start
  sleep 3
  if "/etc/init.d/${SERVICE_NAME}" status 2>/dev/null | grep -q "运行"; then
    _ok "SysV 服务启动成功"
    return 0
  fi
  _err "SysV 服务启动失败"
  return 1
}

install_service_fallback() {
  _warn "无法检测 init 系统，使用 nohup 后台运行"
  nohup "$INSTALL_PATH/mosdns" start -c "${CONFIG_PATH}/config.yaml" \
    >> "${LOG_FILE}" 2>&1 &
  echo $! > "/var/run/${SERVICE_NAME}.pid" 2>/dev/null || \
    echo $! > "/tmp/${SERVICE_NAME}.pid"
  sleep 3
  if pgrep -x mosdns >/dev/null; then
    _ok "MosDNS 已在后台运行（nohup 模式）"
    _warn "此模式重启后不会自动启动，请手动添加开机启动"
    return 0
  fi
  _err "MosDNS 启动失败"
  return 1
}

start_service() {
  case "$INIT_SYS" in
    systemd)
      install_service_systemd && return 0
      _warn "systemd 失败，降级尝试..."
      ;;
    procd)
      install_service_procd && return 0
      ;;
    openrc)
      install_service_openrc && return 0
      ;;
    sysv)
      install_service_sysv && return 0
      ;;
  esac

  if _have "$INSTALL_PATH/mosdns" && \
     "$INSTALL_PATH/mosdns" service install -c "${CONFIG_PATH}/config.yaml" >/dev/null 2>&1; then
    _ok "使用 mosdns service install 安装服务"
    "$INSTALL_PATH/mosdns" service start >/dev/null 2>&1
    sleep 3
    if pgrep -x mosdns >/dev/null; then
      _ok "服务启动成功"
      return 0
    fi
  fi

  install_service_fallback
}

stop_service() {
  case "$INIT_SYS" in
    systemd)
      systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
      ;;
    procd)
      "/etc/init.d/${SERVICE_NAME}" stop >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
      ;;
    sysv)
      "/etc/init.d/${SERVICE_NAME}" stop >/dev/null 2>&1 || true
      ;;
    *)
      pkill -x mosdns 2>/dev/null || true
      ;;
  esac
  sleep 1
}

service_status() {
  case "$INIT_SYS" in
    systemd)
      systemctl is-active "$SERVICE_NAME" 2>/dev/null
      ;;
    procd|sysv|openrc)
      pgrep -x mosdns >/dev/null 2>&1 && echo "active" || echo "inactive"
      ;;
    *)
      pgrep -x mosdns >/dev/null 2>&1 && echo "active" || echo "inactive"
      ;;
  esac
}

_get_mosdns_status() {
  local s; s=$(service_status 2>/dev/null || echo "inactive")
  if [[ "$s" == "active" ]]; then
    local ver; ver=$("$INSTALL_PATH/mosdns" version 2>/dev/null | head -n1 || echo "")
    echo "运行中${ver:+  [$ver]}"
  elif [[ -f "$INSTALL_PATH/mosdns" ]]; then
    echo "已停止"
  else
    echo "未安装"
  fi
}

configure_dnsmasq_forward() {
  local listen_port="$1"
  if ! _have dnsmasq; then
    _warn "未检测到 dnsmasq，跳过自动转发配置"
    _info "如需转发，请手动在 dnsmasq 配置中添加："
    _info "  server=127.0.0.1#${listen_port}"
    return 0
  fi

  local dnsmasq_conf_dir=""
  if [[ -d "/etc/dnsmasq.d" ]]; then
    dnsmasq_conf_dir="/etc/dnsmasq.d"
  elif [[ -d "/etc/NetworkManager/dnsmasq.d" ]]; then
    dnsmasq_conf_dir="/etc/NetworkManager/dnsmasq.d"
  fi

  if [[ -n "$dnsmasq_conf_dir" ]]; then
    cat > "${dnsmasq_conf_dir}/mosdns.conf" << EOF
no-resolv
server=127.0.0.1#${listen_port}
EOF
    _ok "已写入 dnsmasq 转发配置：${dnsmasq_conf_dir}/mosdns.conf"
    if _have systemctl; then
      systemctl restart dnsmasq 2>/dev/null || \
        service dnsmasq restart 2>/dev/null || true
    fi
  else
    if [[ -f /etc/dnsmasq.conf ]] && ! grep -q "server=127.0.0.1#${listen_port}" /etc/dnsmasq.conf; then
      echo "server=127.0.0.1#${listen_port}" >> /etc/dnsmasq.conf
      _ok "已追加 dnsmasq 转发配置"
      service dnsmasq restart 2>/dev/null || true
    fi
  fi
}

lock_resolv_conf() {
  _need_root || return 1
  _info "固化 /etc/resolv.conf..."

  if [[ -f /etc/resolv.conf ]] && [[ ! -f /etc/resolv.conf.mosdns.bak ]]; then
    cp /etc/resolv.conf /etc/resolv.conf.mosdns.bak
    _ok "已备份原 /etc/resolv.conf"
  fi

  chattr -i /etc/resolv.conf 2>/dev/null || true

  if _have resolvconf; then
    echo "nameserver 127.0.0.1" | resolvconf -a lo.mosdns 2>/dev/null || true
  fi

  echo "nameserver 127.0.0.1" > /etc/resolv.conf
  chmod 644 /etc/resolv.conf

  if chattr +i /etc/resolv.conf 2>/dev/null; then
    _ok "已固化 /etc/resolv.conf（chattr +i）"
  else
    _warn "无法使用 chattr 锁定（可能在容器中），已写入但不锁定"
  fi

  if grep -q "nameserver 127.0.0.1" /etc/resolv.conf; then
    _ok "DNS 已固化为 127.0.0.1"
  else
    _err "固化失败，请手动检查"
    return 1
  fi
}

restore_resolv_conf() {
  _need_root || return 1
  _info "还原 /etc/resolv.conf..."
  chattr -i /etc/resolv.conf 2>/dev/null || true

  if _have resolvconf; then
    resolvconf -d lo.mosdns 2>/dev/null || true
  fi

  if [[ -f /etc/resolv.conf.mosdns.bak ]]; then
    mv /etc/resolv.conf.mosdns.bak /etc/resolv.conf
    _ok "已还原原有 DNS 配置"
  else
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    _warn "未找到备份，已设置为 8.8.8.8"
  fi

  if _have nmcli; then
    local active_con; active_con=$(nmcli -t -f NAME con show --active 2>/dev/null | head -n1 || true)
    if [[ -n "$active_con" ]]; then
      nmcli con mod "$active_con" ipv4.ignore-auto-dns no 2>/dev/null || true
      nmcli con up "$active_con" >/dev/null 2>/dev/null || true
    fi
  fi
}

install_mosdns() {
  _need_root || return 1
  echo ""
  echo "===== 安装 MosDNS ====="

  install_core_deps || return 1
  detect_arch || return 1
  detect_init_system
  detect_paths

  if [[ -f "$INSTALL_PATH/mosdns" ]]; then
    _warn "检测到已安装的 MosDNS"
    read -rp "覆盖重装？(y/N): " ow </dev/tty
    [[ "${ow,,}" == "y" ]] || { _warn "已取消"; press_any_key; return; }
    stop_service
  fi

  choose_deploy_mode
  collect_config_params || { _err "参数配置失败"; press_any_key; return 1; }
  choose_version

  local tmp_dir; tmp_dir=$(mktemp -d)
  trap "rm -rf '$tmp_dir'" RETURN

  _info "下载 MosDNS 二进制..."
  local zip_path
  zip_path=$(download_mosdns_binary "$tmp_dir") || {
    _err "二进制下载失败"
    press_any_key; return 1
  }

  unzip -o "$zip_path" mosdns -d "$tmp_dir" >/dev/null 2>&1 || {
    _err "解压失败"
    press_any_key; return 1
  }

  local bin_src; bin_src=$(find "$tmp_dir" -name mosdns -type f | head -n1)
  if [[ -z "$bin_src" ]]; then
    _err "未找到 mosdns 二进制文件"
    press_any_key; return 1
  fi

  mkdir -p "$INSTALL_PATH"
  cp -f "$bin_src" "$INSTALL_PATH/mosdns"
  chmod +x "$INSTALL_PATH/mosdns"

  local ver; ver=$("$INSTALL_PATH/mosdns" version 2>/dev/null | head -n1 || echo "未知")
  _ok "MosDNS 安装完成，版本：$ver"

  download_rules "$CONFIG_PATH" || {
    _err "规则下载失败"
    press_any_key; return 1
  }

  generate_config "$CONFIG_PATH"

  validate_config "$CONFIG_PATH" || {
    _err "配置验证失败，请检查参数后重试"
    press_any_key; return 1
  }

  start_service || {
    _err "服务启动失败"
    press_any_key; return 1
  }

  if [[ "$LISTEN_PORT" != "53" ]]; then
    echo ""
    read -rp "是否配置 dnsmasq 自动转发 DNS 到 MosDNS？(y/N): " setup_dnsmasq </dev/tty
    if [[ "${setup_dnsmasq,,}" == "y" ]]; then
      configure_dnsmasq_forward "$LISTEN_PORT"
    fi
    echo ""
    read -rp "是否固化 /etc/resolv.conf 指向 127.0.0.1？(y/N): " setup_resolv </dev/tty
    if [[ "${setup_resolv,,}" == "y" ]]; then
      lock_resolv_conf
    fi
  else
    lock_resolv_conf
  fi

  echo ""
  _ok "MosDNS 安装完成！"
  _info "监听地址：127.0.0.1:${LISTEN_PORT}"
  _info "配置目录：${CONFIG_PATH}"
  if [[ "$ENABLE_API" == "yes" ]]; then
    _info "Prometheus API：http://${API_ADDR}/metrics"
  fi
  if [[ "$DEPLOY_MODE" == "mihomo_collab" ]]; then
    _info "协作模式：国外流量 → Mihomo DNS（${FOREIGN_DNS}）"
    _warn "请确认 Mihomo 的 dns.listen 端口与配置一致"
  fi
  press_any_key
}

upgrade_mosdns_core() {
  _need_root || return 1
  echo ""
  echo "===== 升级 MosDNS 核心（无损保留配置）====="

  if [[ ! -f "$INSTALL_PATH/mosdns" ]]; then
    _err "未检测到已安装的 MosDNS，请先安装"
    press_any_key; return 1
  fi

  detect_arch || return 1
  detect_init_system
  detect_paths

  local cur_ver; cur_ver=$("$INSTALL_PATH/mosdns" version 2>/dev/null | head -n1 || echo "未知")
  _info "当前版本：$cur_ver"

  choose_version

  local tmp_dir; tmp_dir=$(mktemp -d)
  trap "rm -rf '$tmp_dir'" RETURN

  local zip_path
  zip_path=$(download_mosdns_binary "$tmp_dir") || {
    _err "下载失败，升级中止"
    press_any_key; return 1
  }

  unzip -o "$zip_path" mosdns -d "$tmp_dir" >/dev/null 2>&1 || {
    _err "解压失败"
    press_any_key; return 1
  }

  local bin_src; bin_src=$(find "$tmp_dir" -name mosdns -type f | head -n1)
  if [[ -z "$bin_src" ]]; then
    _err "未找到 mosdns 二进制"
    press_any_key; return 1
  fi

  _info "停止服务..."
  stop_service

  cp -f "$bin_src" "$INSTALL_PATH/mosdns"
  chmod +x "$INSTALL_PATH/mosdns"

  local new_ver; new_ver=$("$INSTALL_PATH/mosdns" version 2>/dev/null | head -n1 || echo "未知")
  _ok "二进制已替换，新版本：$new_ver"

  _info "使用原配置重启服务..."
  start_service || {
    _err "重启失败，请检查新版本与现有配置的兼容性"
    _info "查看日志：journalctl -u mosdns -n 50"
    press_any_key; return 1
  }

  _ok "升级完成！配置已完整保留"
  press_any_key
}

update_rules() {
  _need_root || return 1
  echo ""
  echo "===== 更新分流规则 ====="

  detect_paths
  if [[ ! -d "$CONFIG_PATH" ]]; then
    _err "MosDNS 未安装"
    press_any_key; return 1
  fi

  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local bak_dir="${CONFIG_PATH}/rules_backup_${stamp}"
  mkdir -p "$bak_dir"

  for f in cn_domains.txt proxy_domains.txt cn_ip.txt adblock.txt; do
    [[ -f "${CONFIG_PATH}/$f" ]] && cp "${CONFIG_PATH}/$f" "${bak_dir}/$f" || true
  done
  _ok "规则已备份至：$bak_dir"

  local failed=false
  download_with_retry "$RULES_URL_CN_DOMAIN" "${CONFIG_PATH}/cn_domains.txt" "国内域名列表" || failed=true
  download_with_retry "$RULES_URL_PROXY_DOMAIN" "${CONFIG_PATH}/proxy_domains.txt" "代理域名列表" || failed=true
  download_with_retry "$RULES_URL_CN_IP" "${CONFIG_PATH}/cn_ip.txt" "国内 IP CIDR" || failed=true
  download_with_retry "$RULES_URL_ADBLOCK" "${CONFIG_PATH}/adblock.txt" "广告过滤规则" || failed=true

  if [[ "$failed" == "true" ]]; then
    _warn "部分规则下载失败，正在回滚..."
    for f in cn_domains.txt proxy_domains.txt cn_ip.txt adblock.txt; do
      [[ -f "${bak_dir}/$f" ]] && cp "${bak_dir}/$f" "${CONFIG_PATH}/$f" || true
    done
    _warn "规则已回滚至备份版本"
    press_any_key; return 1
  fi

  detect_init_system
  _info "重启服务以应用新规则..."
  stop_service
  sleep 1
  start_service || {
    _warn "服务重启失败，正在回滚规则..."
    for f in cn_domains.txt proxy_domains.txt cn_ip.txt adblock.txt; do
      [[ -f "${bak_dir}/$f" ]] && cp "${bak_dir}/$f" "${CONFIG_PATH}/$f" || true
    done
    start_service || true
    press_any_key; return 1
  }

  _ok "规则更新完成"
  rm -rf "$bak_dir"
  press_any_key
}

uninstall_mosdns() {
  _need_root || return 1
  echo ""
  echo "===== 卸载 MosDNS ====="
  read -rp "确认卸载？(y/N): " confirm </dev/tty
  [[ "${confirm,,}" == "y" ]] || { _warn "已取消"; press_any_key; return; }

  detect_init_system
  detect_paths

  _info "停止并移除服务..."
  stop_service

  case "$INIT_SYS" in
    systemd)
      systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    procd|sysv|openrc)
      "/etc/init.d/${SERVICE_NAME}" disable >/dev/null 2>&1 || true
      rm -f "/etc/init.d/${SERVICE_NAME}"
      ;;
  esac

  if _have "$INSTALL_PATH/mosdns"; then
    "$INSTALL_PATH/mosdns" service uninstall >/dev/null 2>&1 || true
  fi

  rm -f "${INSTALL_PATH}/mosdns"
  _ok "已删除二进制文件"

  read -rp "是否删除配置和规则目录 ${CONFIG_PATH}？(y/N): " del_conf </dev/tty
  if [[ "${del_conf,,}" == "y" ]]; then
    rm -rf "$CONFIG_PATH"
    _ok "配置目录已删除"
  fi

  rm -f /etc/dnsmasq.d/mosdns.conf 2>/dev/null || true
  rm -f /etc/NetworkManager/dnsmasq.d/mosdns.conf 2>/dev/null || true

  read -rp "是否还原 /etc/resolv.conf？(Y/n): " restore_r </dev/tty
  if [[ "${restore_r,,}" != "n" ]]; then
    restore_resolv_conf
  fi

  _ok "MosDNS 已完全卸载"
  press_any_key
}

_select_backup_root() {
  echo "" >&2
  echo "请选择备份存储位置：" >&2
  echo "  1. 主目录 ($HOME)" >&2
  echo "  2. /tmp 目录（重启后丢失）" >&2
  echo "  3. 手动输入路径" >&2
  read -rp "选项 [默认 1]: " bc </dev/tty
  local backup_root=""
  case "${bc:-1}" in
    2) backup_root="/tmp" ;;
    3)
      read -rp "请输入目录路径: " custom_dir </dev/tty
      backup_root="${custom_dir:-$HOME}"
      ;;
    *) backup_root="$HOME" ;;
  esac
  if ! mkdir -p "$backup_root" 2>/dev/null || ! touch "$backup_root/.wtest" 2>/dev/null; then
    _err "目录 $backup_root 不可写" >&2
    return 1
  fi
  rm -f "$backup_root/.wtest"
  _info "备份目录：$backup_root" >&2
  echo "$backup_root"
}

_scan_backup_files() {
  local scan_dirs=("$HOME" "/tmp" "/root" "/mnt" "/data")
  for d in "${scan_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 3 -name "mosdns-backup-*.tar.gz" 2>/dev/null
  done | sort -ru
}

backup_mosdns() {
  _need_root || return 1
  echo ""
  echo "===== MosDNS 数据备份 ====="

  detect_paths
  if [[ ! -d "$CONFIG_PATH" ]]; then
    _warn "配置目录不存在：$CONFIG_PATH"
    press_any_key; return
  fi

  local file_count; file_count=$(find "$CONFIG_PATH" -type f 2>/dev/null | wc -l || echo 0)
  _info "配置目录：$CONFIG_PATH（$file_count 个文件）"

  local avail_kb; avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
  if [[ "$avail_kb" -lt 102400 ]]; then
    _warn "磁盘可用空间较少（${avail_kb}KB）"
    read -rp "是否继续？(y/N): " cont </dev/tty
    [[ "${cont,,}" == "y" ]] || { press_any_key; return; }
  fi

  local backup_root
  backup_root=$(_select_backup_root) || { press_any_key; return 1; }

  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local backup_name="mosdns-backup-${stamp}"
  local backup_tmp="${backup_root}/${backup_name}"
  local backup_file="${backup_root}/${backup_name}.tar.gz"

  mkdir -p "${backup_tmp}/config"

  _info "停止服务以确保数据一致性..."
  detect_init_system
  local was_running=false
  if [[ "$(service_status)" == "active" ]]; then
    was_running=true
    stop_service
  fi

  if ! cp -a "${CONFIG_PATH}/." "${backup_tmp}/config/" 2>/dev/null; then
    _err "配置复制失败"
    [[ "$was_running" == true ]] && start_service || true
    rm -rf "$backup_tmp"
    press_any_key; return 1
  fi

  local cur_ver=""
  [[ -f "$INSTALL_PATH/mosdns" ]] && cur_ver=$("$INSTALL_PATH/mosdns" version 2>/dev/null | head -n1 || echo "未知")

  cat > "${backup_tmp}/backup_info.txt" << EOF
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
系统架构：$(uname -m)
初始化系统：${INIT_SYS:-unknown}
MosDNS 版本：${cur_ver}
配置目录：${CONFIG_PATH}
安装路径：${INSTALL_PATH}
EOF

  if [[ "$was_running" == true ]]; then
    _info "恢复服务..."
    start_service >/dev/null 2>&1 \
      && _ok "服务已恢复" \
      || _warn "请手动启动：请通过菜单启动"
  fi

  _info "打包压缩中..."
  if tar -czf "$backup_file" -C "$backup_root" "$backup_name" 2>/dev/null; then
    rm -rf "$backup_tmp"
    local size; size=$(du -sh "$backup_file" 2>/dev/null | cut -f1 || echo "未知")
    _ok "备份完成：$backup_file（$size）"
    echo ""
    echo "  备份文件：$backup_file"
    echo "  文件大小：$size"
    echo "  请将备份文件复制到安全位置"
  else
    _err "打包失败，临时目录：$backup_tmp"
    press_any_key; return 1
  fi
  press_any_key
}

restore_mosdns() {
  _need_root || return 1
  echo ""
  echo "===== MosDNS 数据恢复 ====="

  echo "请选择备份文件来源："
  echo "  1. 自动扫描"
  echo "  2. 手动输入路径"
  read -rp "选项 [默认 1]: " sc </dev/tty
  sc="${sc:-1}"

  local backup_file=""
  case "$sc" in
    2) read -rp "请输入备份文件路径: " backup_file </dev/tty ;;
    *)
      _info "扫描备份文件..."
      local found_files=()
      while IFS= read -r f; do found_files+=("$f"); done < <(_scan_backup_files)

      if [[ ${#found_files[@]} -eq 0 ]]; then
        _warn "未找到备份文件"
        read -rp "请手动输入路径: " backup_file </dev/tty
      else
        echo ""
        local i=1
        for f in "${found_files[@]}"; do
          local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
          local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | \
            sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
          printf "  %d. %-50s [%s] %s\n" "$i" "$f" "$sz" "$ts"
          i=$((i + 1))
        done
        echo ""
        read -rp "请输入编号（留空手动输入）: " fc </dev/tty
        if [[ -z "$fc" ]]; then
          read -rp "请输入路径: " backup_file </dev/tty
        elif [[ "$fc" =~ ^[0-9]+$ ]] && [[ "$fc" -ge 1 && "$fc" -le ${#found_files[@]} ]]; then
          backup_file="${found_files[$((fc-1))]}"
        else
          _err "无效选项"; press_any_key; return 1
        fi
      fi
      ;;
  esac

  if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
    _err "备份文件不存在：$backup_file"
    press_any_key; return 1
  fi

  local restore_tmp; restore_tmp=$(mktemp -d)
  trap "rm -rf '$restore_tmp'" RETURN

  _info "解压备份文件..."
  if ! tar -xzf "$backup_file" -C "$restore_tmp" 2>/dev/null; then
    _err "解压失败"; press_any_key; return 1
  fi

  local restore_info; restore_info=$(find "$restore_tmp" -maxdepth 3 -name "backup_info.txt" | head -n1)
  if [[ -z "$restore_info" ]]; then
    _err "备份包格式不正确"
    press_any_key; return 1
  fi
  local restore_base; restore_base=$(dirname "$restore_info")

  echo ""
  echo "---- 备份信息 ----"
  cat "$restore_base/backup_info.txt"
  echo "------------------"
  echo ""
  read -rp "确认恢复？(y/N): " confirm </dev/tty
  [[ "${confirm,,}" == "y" ]] || { _info "已取消"; press_any_key; return 0; }

  detect_init_system
  detect_paths
  _info "停止服务..."
  stop_service

  if [[ -d "$CONFIG_PATH" ]]; then
    local bak_old="${CONFIG_PATH}_old_$(date +%Y%m%d_%H%M%S)"
    mv "$CONFIG_PATH" "$bak_old" && _info "旧配置已保留：$bak_old" || {
      _err "无法移动旧配置目录"
      press_any_key; return 1
    }
  fi

  mkdir -p "$CONFIG_PATH"
  if cp -a "${restore_base}/config/." "$CONFIG_PATH/" 2>/dev/null; then
    local fc; fc=$(find "$CONFIG_PATH" -type f 2>/dev/null | wc -l || echo 0)
    _ok "配置恢复完成（$fc 个文件）"
  else
    _err "配置恢复失败"; press_any_key; return 1
  fi

  _info "重新启动服务..."
  start_service \
    && _ok "服务已启动" \
    || _warn "服务启动失败，请通过菜单手动启动"

  _ok "恢复完成"
  press_any_key
}

list_backups() {
  echo ""
  echo "---- MosDNS 备份文件列表 ----"
  local found=false
  while IFS= read -r f; do
    local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | \
      sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
    printf "  %-50s [%s] %s\n" "$f" "$sz" "$ts"
    found=true
  done < <(_scan_backup_files)
  [[ "$found" == false ]] && _warn "未找到任何备份文件"
  echo "-----------------------------"
  press_any_key
}

check_mosdns_status() {
  echo ""
  echo "===== MosDNS 状态 ====="
  detect_init_system
  detect_paths

  local svc_status; svc_status=$(service_status 2>/dev/null || echo "inactive")
  if [[ "$svc_status" == "active" ]]; then
    _ok "服务状态：运行中"
  else
    _warn "服务状态：未运行"
  fi

  if [[ -f "$INSTALL_PATH/mosdns" ]]; then
    local ver; ver=$("$INSTALL_PATH/mosdns" version 2>/dev/null | head -n1 || echo "未知")
    _info "版本：$ver"
    _info "安装路径：$INSTALL_PATH/mosdns"
  fi

  _info "配置目录：$CONFIG_PATH"

  if [[ -f "${CONFIG_PATH}/config.yaml" ]]; then
    local listen_port; listen_port=$(grep -E 'listen:' "${CONFIG_PATH}/config.yaml" | \
      grep -oE '[0-9]+$' | head -n1 || echo "未知")
    _info "监听端口：$listen_port"
  fi

  echo ""
  echo "---- DNS 解析测试 ----"
  local test_port="5335"
  if [[ -f "${CONFIG_PATH}/config.yaml" ]]; then
    test_port=$(grep -E 'listen:' "${CONFIG_PATH}/config.yaml" | \
      grep -oE '[0-9]+$' | head -n1 || echo "5335")
  fi

  if _have dig; then
    local result; result=$(dig @127.0.0.1 -p "$test_port" www.baidu.com +short +time=3 2>/dev/null | head -n3 || echo "")
    if [[ -n "$result" ]]; then
      _ok "国内域名解析正常：www.baidu.com → $result"
    else
      _warn "国内域名解析失败或超时"
    fi

    local gresult; gresult=$(dig @127.0.0.1 -p "$test_port" www.google.com +short +time=5 2>/dev/null | head -n1 || echo "")
    if [[ -n "$gresult" ]]; then
      _ok "国外域名解析正常：www.google.com → $gresult"
    else
      _warn "国外域名解析失败（可能需要代理支持）"
    fi

    local adresult; adresult=$(dig @127.0.0.1 -p "$test_port" doubleclick.net +short +time=3 2>/dev/null || echo "")
    if [[ -z "$adresult" ]]; then
      _ok "广告拦截正常：doubleclick.net 已拦截"
    else
      _warn "广告拦截异常：doubleclick.net → $adresult"
    fi
  else
    _warn "未安装 dig，跳过解析测试"
  fi

  detect_mihomo_env
  echo ""
  echo "---- 环境检测 ----"
  if [[ "$MIHOMO_RUNNING" == true ]]; then
    _info "Mihomo/Clash：运行中${MIHOMO_TUN:+（TUN 模式启用）}"
  else
    _info "Mihomo/Clash：未运行"
  fi
  if [[ "$IPTABLES_53_HIJACK" == true ]]; then
    _warn "检测到 iptables/nftables 53 端口劫持规则"
  fi

  echo ""
  echo "---- /etc/resolv.conf ----"
  cat /etc/resolv.conf 2>/dev/null || _warn "无法读取"

  press_any_key
}

manage_service() {
  detect_init_system
  detect_paths
  while true; do
    local status; status=$(service_status 2>/dev/null || echo "inactive")
    echo ""
    echo "===== MosDNS 服务管理 [$status] ====="
    echo "  1. 启动"
    echo "  2. 停止"
    echo "  3. 重启"
    echo "  4. 查看实时日志（Ctrl+C 退出）"
    echo "  5. 查看最近 100 行日志"
    echo "  0. 返回"
    echo "======================================="
    read -rp "选项: " op </dev/tty
    case "$op" in
      1)
        start_service && _ok "已启动" || _err "启动失败"
        press_any_key
        ;;
      2)
        stop_service && _ok "已停止" || _err "停止失败"
        press_any_key
        ;;
      3)
        stop_service; sleep 1; start_service && _ok "已重启" || _err "重启失败"
        press_any_key
        ;;
      4)
        case "$INIT_SYS" in
          systemd) journalctl -u "$SERVICE_NAME" -f --no-pager 2>/dev/null || true ;;
          *) tail -f "${CONFIG_PATH}/mosdns.log" 2>/dev/null || _warn "日志文件不存在" ;;
        esac
        ;;
      5)
        case "$INIT_SYS" in
          systemd) journalctl -u "$SERVICE_NAME" --no-pager -n 100 2>/dev/null || true ;;
          *) tail -n 100 "${CONFIG_PATH}/mosdns.log" 2>/dev/null || _warn "日志文件不存在" ;;
        esac
        press_any_key
        ;;
      0) return ;;
      *) _warn "无效输入" ;;
    esac
  done
}

_init_globals() {
  detect_pkg_manager
  detect_init_system
  detect_paths
}

_get_status_line() {
  if [[ ! -f "$INSTALL_PATH/mosdns" ]]; then
    echo "未安装"
    return
  fi
  local svc_status; svc_status=$(service_status 2>/dev/null || echo "inactive")
  local ver; ver=$("$INSTALL_PATH/mosdns" version 2>/dev/null | head -n1 || echo "")
  if [[ "$svc_status" == "active" ]]; then
    echo "运行中${ver:+  [$ver]}"
  else
    echo "已停止${ver:+  [$ver]}"
  fi
}

show_menu() {
  local mosdns_status; mosdns_status=$(_get_status_line)
  local mihomo_info=""
  detect_mihomo_env 2>/dev/null || true
  if [[ "$MIHOMO_RUNNING" == true ]]; then
    mihomo_info="  Mihomo   : 运行中${MIHOMO_TUN:+（TUN）}"
  fi

  echo ""
  echo "========== MosDNS 管理脚本 =========="
  echo "  MosDNS   : $mosdns_status"
  [[ -n "$mihomo_info" ]] && echo "$mihomo_info"
  echo "--------------------------------------"
  echo "  1. 安装 MosDNS"
  echo "  2. 升级 MosDNS 核心（无损保留配置）"
  echo "  3. 卸载 MosDNS"
  echo "  4. 更新分流规则"
  echo "  5. 服务管理（启动/停止/重启/日志）"
  echo "  6. 查看状态与 DNS 测试"
  echo "  7. 固化 /etc/resolv.conf"
  echo "  8. 还原 /etc/resolv.conf"
  echo "  9. 备份配置"
  echo " 10. 恢复配置"
  echo " 11. 查看备份列表"
  echo "  0. 退出"
  echo "======================================"
}

main() {
  if [[ "${EUID}" -ne 0 ]]; then
    _err "请以 root 权限运行此脚本"
    exit 1
  fi

  _init_globals

  while true; do
    show_menu
    read -rp "请输入选项: " choice </dev/tty
    case "$choice" in
      1)  install_mosdns ;;
      2)  upgrade_mosdns_core ;;
      3)  uninstall_mosdns ;;
      4)  update_rules ;;
      5)  manage_service ;;
      6)  check_mosdns_status ;;
      7)  lock_resolv_conf; press_any_key ;;
      8)  restore_resolv_conf; press_any_key ;;
      9)  backup_mosdns ;;
      10) restore_mosdns ;;
      11) list_backups ;;
      0)  _ok "再见"; exit 0 ;;
      *)  _warn "无效选项，请重新输入" ;;
    esac
  done
}

main "$@"
