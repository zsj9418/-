#!/usr/bin/env bash
set -uo pipefail
SCRIPT_VERSION="v2.3.0"
OPENCLAW_PORT=18789
OPENCLAW_CONFIG_DIR="$HOME/.openclaw"
OPENCLAW_JSON="$OPENCLAW_CONFIG_DIR/openclaw.json"
OPENCLAW_LOG_DIR="$OPENCLAW_CONFIG_DIR/logs"
OPENCLAW_AGENTS_DIR="$OPENCLAW_CONFIG_DIR/agents"
DOCKER_CONTAINER="openclaw-core"
DOCKER_DATA_DIR="$HOME/openclaw"
DOCKER_UID=1000
NODE_MIN_VERSION=22
NODE_RECOMMENDED_VERSION=24
LOG_FILE="/tmp/openclaw_install_$(date +%Y%m%d_%H%M%S).log"
GITHUB_REPO="https://github.com/openclaw/openclaw"
OPENCLAW_INSTALL_URL="https://openclaw.ai/install.sh"
WECHAT_PLUGIN_PKG="@tencent-weixin/openclaw-weixin"
FEISHU_PLUGIN_PKG="@m1heng-clawd/feishu"
VALID_BIND_VALUES=("auto" "lan" "loopback" "custom" "tailnet")
OPENCLAW_SERVICE_CANDIDATES=("openclaw" "openclaw-gateway")
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
WHITE=$'\033[1;37m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'
DOCKER_IMAGES_GHCR="ghcr.io/openclaw/openclaw"
DOCKER_IMAGES_OFFICIAL="openclaw/openclaw"
DOCKER_IMAGES_1PANEL="1panel/openclaw"
DOCKER_IMAGES_DR34M="dr34m/openclaw"
DOCKER_IMAGES_ALPINE="alpine/openclaw"
NPM_MIRROR_CN="https://registry.npmmirror.com"
GHCR_MIRROR_CN="ghcr.milu.moe"
NODE_MIRROR_CN="https://npmmirror.com/mirrors/node"
NODE_MIRROR_OFFICIAL="https://nodejs.org/dist"
declare -gA G_API_KEYS=()
declare -gA G_API_MODELS=()
declare -gA G_API_TYPES=()
declare -gA G_API_URLS=()
declare -g G_DEFAULT_PROVIDER=""
declare -g G_REGION=""
declare -g G_DOCKER_IMAGE=""
declare -g OS="" PKG_MANAGER="" INSTALL_CMD="" UPDATE_CMD=""
declare -g SERVICE_MANAGER="" PRETTY_NAME="" ARCH="" ARCH_LABEL=""
declare -g SUDO="" IS_ROOT=false
init_privilege() {
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
        IS_ROOT=true
    elif command -v sudo &>/dev/null; then
        SUDO="sudo"
        IS_ROOT=false
        if ! sudo -n true 2>/dev/null; then
            printf "${YELLOW}[WARN]${NC} sudo 可能需要密码,如遇卡顿请手动输入\n" >&2
        fi
    elif command -v doas &>/dev/null; then
        SUDO="doas"
        IS_ROOT=false
    else
        printf "${RED}[FAIL]${NC} 无 root 权限,且未找到 sudo/doas 命令\n" >&2
        printf "${CYAN}当前用户:${NC} $(whoami) (UID: $EUID)\n\n" >&2
        printf "${BOLD}解决方案:${NC}\n" >&2
        printf "  1) 切换 root:      ${YELLOW}su -${NC}\n" >&2
        printf "  2) 安装 sudo(需root): ${YELLOW}apt install sudo${NC}\n" >&2
        printf "  3) 安装 doas(Alpine): ${YELLOW}apk add doas${NC}\n\n" >&2
        exit 1
    fi
    export SUDO IS_ROOT
}
print_line() { printf "${DIM}"; printf '=%.0s' {1..60}; printf "${NC}\n"; }
msg_ok()   { local f="$1"; shift; printf "${GREEN}[OK]${NC} ${f}\n" "$@"; }
msg_fail() { local f="$1"; shift; printf "${RED}[FAIL]${NC} ${f}\n" "$@"; }
msg_warn() { local f="$1"; shift; printf "${YELLOW}[WARN]${NC} ${f}\n" "$@"; }
msg_info() { local f="$1"; shift; printf "${CYAN}[INFO]${NC} ${f}\n" "$@"; }
msg_step() { local f="$1"; shift; printf "\n${BLUE}${BOLD}=>${NC} ${BOLD}${f}${NC}\n" "$@"; }
msg_ok_err()   { local f="$1"; shift; printf "${GREEN}[OK]${NC} ${f}\n" "$@" >&2; }
msg_fail_err() { local f="$1"; shift; printf "${RED}[FAIL]${NC} ${f}\n" "$@" >&2; }
msg_warn_err() { local f="$1"; shift; printf "${YELLOW}[WARN]${NC} ${f}\n" "$@" >&2; }
msg_info_err() { local f="$1"; shift; printf "${CYAN}[INFO]${NC} ${f}\n" "$@" >&2; }
msg_step_err() { local f="$1"; shift; printf "\n${BLUE}${BOLD}=>${NC} ${BOLD}${f}${NC}\n" "$@" >&2; }
msg_title() {
    local title="$1"
    printf "\n${MAGENTA}${BOLD}"
    printf '=%.0s' {1..60}
    printf "\n  %s\n" "$title"
    printf '=%.0s' {1..60}
    printf "${NC}\n\n"
}
wait_and_return() {
    local wait_time="${1:-3}"
    printf "\n${DIM}%d 秒后返回...${NC}" "$wait_time"
    sleep "$wait_time"
    printf "\n"
}
log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }
has_cmd() { command -v "$1" &>/dev/null; }
read_input() {
    local varname="$1" default_val="${2:-}" input=""
    read -r input </dev/tty 2>/dev/null || input=""
    input="${input:-$default_val}"
    printf -v "$varname" '%s' "$input"
}
read_input_silent() {
    local varname="$1" default_val="${2:-}" input=""
    read -rs input </dev/tty 2>/dev/null || input=""
    printf "\n" >&2
    input="${input:-$default_val}"
    printf -v "$varname" '%s' "$input"
}
confirm() {
    local fmt="${1:-确认操作}"; shift 2>/dev/null || true
    local prompt
    printf -v prompt "$fmt" "$@"
    local answer
    printf "${YELLOW}[?]${NC} %s [y/N]: " "$prompt"
    read -r answer </dev/tty 2>/dev/null || answer="n"
    [[ "$answer" =~ ^[Yy]$ ]]
}
confirm_err() {
    local fmt="${1:-确认操作}"; shift 2>/dev/null || true
    local prompt
    printf -v prompt "$fmt" "$@"
    local answer
    printf "${YELLOW}[?]${NC} %s [y/N]: " "$prompt" >&2
    read -r answer </dev/tty 2>/dev/null || answer="n"
    [[ "$answer" =~ ^[Yy]$ ]]
}
safe_run() {
    local desc="$1"; shift
    if "$@" >> "$LOG_FILE" 2>&1; then
        msg_ok "%s" "$desc"
        return 0
    else
        local rc=$?
        msg_warn "%s 失败 (退出码: %d)" "$desc" "$rc"
        printf "${DIM}--- 日志最后 5 行 (%s) ---${NC}\n" "$LOG_FILE"
        tail -5 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || printf "  (无日志)\n"
        printf "${DIM}--- 结束 ---${NC}\n"
        return $rc
    fi
}
get_local_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip=$(ipconfig getifaddr en0 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(ipconfig getifaddr en1 2>/dev/null)
    [[ -z "$ip" ]] && ip="127.0.0.1"
    printf "%s" "$ip"
}
detect_region() {
    [[ -n "$G_REGION" ]] && return
    if [[ "${OPENCLAW_REGION:-}" == "cn" ]] || [[ "${OPENCLAW_REGION:-}" == "china" ]]; then
        G_REGION="china"; return
    fi
    if [[ "${OPENCLAW_REGION:-}" == "overseas" ]] || [[ "${OPENCLAW_REGION:-}" == "global" ]]; then
        G_REGION="overseas"; return
    fi
    if curl -s --max-time 3 --connect-timeout 2 https://www.google.com &>/dev/null; then
        G_REGION="overseas"
    elif curl -s --max-time 3 --connect-timeout 2 https://www.baidu.com &>/dev/null; then
        G_REGION="china"
    else
        G_REGION="unknown"
    fi
    log "Region: $G_REGION"
}
is_china() { [[ "$G_REGION" == "china" ]]; }
detect_system() {
    [[ -n "$OS" ]] && return
    init_privilege
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"; SERVICE_MANAGER="launchd"
        PRETTY_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
        if has_cmd brew; then
            PKG_MANAGER="brew"; INSTALL_CMD="brew install"; UPDATE_CMD="brew update"
        else
            PKG_MANAGER="none"
        fi
    elif [[ -f /etc/os-release ]]; then
        source /etc/os-release
        PRETTY_NAME="${PRETTY_NAME:-$ID}"
        case "${ID:-}" in
            ubuntu|debian|linuxmint|pop|kali|raspbian)
                OS="debian"; PKG_MANAGER="apt"
                INSTALL_CMD="$SUDO apt-get install -y"
                UPDATE_CMD="$SUDO apt-get update -qq" ;;
            centos|rhel|rocky|almalinux|ol)
                OS="rhel"; PKG_MANAGER="yum"
                INSTALL_CMD="$SUDO yum install -y"
                UPDATE_CMD="$SUDO yum update -y" ;;
            fedora)
                OS="fedora"; PKG_MANAGER="dnf"
                INSTALL_CMD="$SUDO dnf install -y"
                UPDATE_CMD="$SUDO dnf update -y" ;;
            arch|manjaro|endeavouros)
                OS="arch"; PKG_MANAGER="pacman"
                INSTALL_CMD="$SUDO pacman -S --noconfirm"
                UPDATE_CMD="$SUDO pacman -Sy" ;;
            alpine)
                OS="alpine"; PKG_MANAGER="apk"
                INSTALL_CMD="$SUDO apk add"
                UPDATE_CMD="$SUDO apk update" ;;
            *)
                OS="unknown"; PKG_MANAGER="unknown" ;;
        esac
        SERVICE_MANAGER="systemd"
        [[ "$OS" == "alpine" ]] && SERVICE_MANAGER="openrc"
    else
        OS="unknown"
    fi
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   ARCH_LABEL="x86_64 (64-bit)" ;;
        aarch64|arm64)  ARCH_LABEL="ARM64 (64-bit)" ;;
        armv7l|armv6l)  ARCH_LABEL="ARMv7 (32-bit)" ;;
        i386|i686)      ARCH_LABEL="x86 (32-bit)" ;;
        *)              ARCH_LABEL="$ARCH" ;;
    esac
}
print_sysinfo() {
    detect_system
    detect_region
    printf "${CYAN}${BOLD}系统信息${NC}\n"
    print_line
    printf "  ${BOLD}操作系统${NC}    : %s (%s)\n" "${OS^^}" "$PRETTY_NAME"
    printf "  ${BOLD}架构${NC}        : %s\n" "$ARCH_LABEL"
    printf "  ${BOLD}用户${NC}        : %s (UID: %s)\n" "$(whoami)" "$EUID"
    printf "  ${BOLD}提权方式${NC}    : %s\n" "$($IS_ROOT && printf 'root(无需)' || printf "%s" "${SUDO:-none}")"
    printf "  ${BOLD}包管理器${NC}    : %s\n" "$PKG_MANAGER"
    printf "  ${BOLD}服务管理${NC}    : %s\n" "$SERVICE_MANAGER"
    printf "  ${BOLD}主机名${NC}      : %s\n" "$(hostname)"
    printf "  ${BOLD}内存${NC}        : %s\n" "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || sysctl hw.memsize 2>/dev/null | awk '{printf "%.1fGB",$2/1073741824}' || echo '?')"
    printf "  ${BOLD}CPU${NC}         : %s 核\n" "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')"
    printf "  ${BOLD}磁盘可用${NC}    : %s\n" "$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo '?')"
    printf "  ${BOLD}Node.js${NC}     : %s\n" "$(node -v 2>/dev/null || echo '未安装')"
    printf "  ${BOLD}npm${NC}         : %s\n" "$(npm -v 2>/dev/null | sed 's/^/v/' || echo '未安装')"
    printf "  ${BOLD}Docker${NC}      : %s\n" "$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo '未安装')"
    printf "  ${BOLD}OpenClaw${NC}    : %s\n" "$(openclaw_cmd --version 2>/dev/null || echo '未安装')"
    printf "  ${BOLD}部署方式${NC}    : %s\n" "$(_detect_deploy_mode)"
    printf "  ${BOLD}网络环境${NC}    : %s\n" "$G_REGION"
    printf "  ${BOLD}配置路径${NC}    : %s\n" "$(get_active_config_path)"
    local cfg_path; cfg_path=$(get_active_config_path)
    local cfg_status="未创建"
    if [[ -f "$cfg_path" ]]; then
        json_is_valid "$cfg_path" && cfg_status="${GREEN}有效${NC}" || cfg_status="${RED}损坏${NC}"
    fi
    printf "  ${BOLD}配置状态${NC}    : %b\n" "$cfg_status"
    if [[ -n "${G_DEFAULT_PROVIDER:-}" ]]; then
        printf "  ${BOLD}默认 AI${NC}     : ${GREEN}%s${NC}\n" "$G_DEFAULT_PROVIDER"
    fi
    print_line
}
_detect_deploy_mode() {
    if is_docker_mode; then
        printf "Docker 容器"
    elif has_cmd openclaw; then
        printf "本地安装 (npm)"
    else
        printf "未部署"
    fi
}
is_docker_mode() {
    ! has_cmd openclaw && docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"
}
is_openclaw_installed() {
    has_cmd openclaw || docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"
}
get_active_config_path() {
    if is_docker_mode; then
        printf "%s" "${DOCKER_DATA_DIR}/.openclaw/openclaw.json"
    else
        printf "%s" "$OPENCLAW_JSON"
    fi
}
openclaw_cmd() {
    if has_cmd openclaw; then
        openclaw "$@"
    elif docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        docker exec "$DOCKER_CONTAINER" openclaw "$@"
    else
        return 1
    fi
}
fix_docker_ownership() {
    if is_docker_mode && [[ -d "$DOCKER_DATA_DIR" ]]; then
        chown -R "${DOCKER_UID}:${DOCKER_UID}" "${DOCKER_DATA_DIR}" 2>/dev/null \
            || $SUDO chown -R "${DOCKER_UID}:${DOCKER_UID}" "${DOCKER_DATA_DIR}" 2>/dev/null || true
    fi
}
json_is_valid() {
    local cfg="${1:-$(get_active_config_path)}"
    [[ ! -f "$cfg" ]] && return 1
    if has_cmd python3; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$cfg" 2>/dev/null
    elif has_cmd jq; then
        jq empty "$cfg" 2>/dev/null
    else
        return 0
    fi
}
backup_config() {
    local cfg="${1:-$(get_active_config_path)}"
    [[ ! -f "$cfg" ]] && return 0
    local bk="${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$cfg" "$bk" 2>/dev/null && printf "%s" "$bk"
}
atomic_write_json() {
    local cfg="$1" content="$2"
    local tmp="${cfg}.tmp.$$"
    mkdir -p "$(dirname "$cfg")"
    ( umask 077; printf '%s' "$content" > "$tmp" )
    if has_cmd python3; then
        if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp" 2>/dev/null; then
            rm -f "$tmp"; return 1
        fi
    fi
    mv "$tmp" "$cfg"
    chmod 600 "$cfg"
    fix_docker_ownership
}
sanitize_config_for_schema() {
    local cfg="${1:-$(get_active_config_path)}"
    [[ ! -f "$cfg" ]] && return 1
    has_cmd python3 || return 1
    json_is_valid "$cfg" || return 1
    python3 - "$cfg" << 'PYEOF'
import json, sys, os
cfg_path = sys.argv[1]
VALID_BIND = ["auto", "lan", "loopback", "custom", "tailnet"]
BAD_ROOT_KEYS = ["ui", "defaultProvider"]
try:
    with open(cfg_path, 'r') as f:
        cfg = json.load(f)
except Exception:
    sys.exit(1)
changed = []
gw = cfg.setdefault("gateway", {})
if gw.get("bind") == "localhost":
    gw["bind"] = "loopback"; changed.append("gateway.bind: localhost -> loopback")
elif gw.get("bind") not in VALID_BIND:
    gw["bind"] = "loopback"; changed.append("gateway.bind: invalid -> loopback")
if not gw.get("mode"):
    gw["mode"] = "local"; changed.append("gateway.mode -> local")
for bad_key in BAD_ROOT_KEYS:
    if bad_key in cfg:
        del cfg[bad_key]; changed.append(f"removed {bad_key}")
if "agents" in cfg and isinstance(cfg["agents"], dict):
    agents = cfg["agents"]
    for bad_agent_key in list(agents.keys()):
        if bad_agent_key not in ["defaults", "list"]:
            del agents[bad_agent_key]; changed.append(f"removed agents.{bad_agent_key}")
    if "defaults" in agents and isinstance(agents["defaults"], dict):
        defaults = agents["defaults"]
        if "model" in defaults:
            model_cfg = defaults["model"]
            if isinstance(model_cfg, str):
                defaults["model"] = {"primary": model_cfg}
                changed.append("agents.defaults.model -> object")
        if not defaults:
            del agents["defaults"]; changed.append("removed empty agents.defaults")
    if not agents:
        del cfg["agents"]; changed.append("removed empty agents")
models = cfg.get("models", {})
if isinstance(models, dict):
    providers = models.get("providers", {})
    if isinstance(providers, dict):
        for name, p in list(providers.items()):
            if isinstance(p, dict) and not p.get("api"):
                p["api"] = "openai-completions"
                changed.append(f"providers.{name}.api -> openai-completions")
if changed:
    tmp = cfg_path + ".tmp"
    with open(tmp, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.replace(tmp, cfg_path)
    for c in changed:
        print(c)
else:
    print("NOCHANGE")
PYEOF
    chmod 600 "$cfg" 2>/dev/null
    fix_docker_ownership
}
convert_urls_for_docker_mode() {
    local cfg="${1:-$(get_active_config_path)}"
    [[ ! -f "$cfg" ]] && return 1
    has_cmd python3 || return 1
    json_is_valid "$cfg" || return 1
    python3 - "$cfg" << 'PYEOF'
import json, sys, os, re
cfg_path = sys.argv[1]
try:
    with open(cfg_path, 'r') as f:
        cfg = json.load(f)
except Exception:
    sys.exit(1)
changed = []
pattern = re.compile(r'^(https?://)(127\.0\.0\.1|localhost|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(1[6-9]|2[0-9]|3[0-1])\.\d+\.\d+)')
providers = cfg.get("models", {}).get("providers", {})
for name, p in providers.items():
    if not isinstance(p, dict):
        continue
    url = p.get("baseUrl", "")
    if pattern.match(url):
        new_url = pattern.sub(r'\1host.docker.internal', url)
        if new_url != url:
            p["baseUrl"] = new_url
            changed.append(f"providers.{name}: LAN -> host.docker.internal")
if changed:
    tmp = cfg_path + ".tmp"
    with open(tmp, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.replace(tmp, cfg_path)
    for c in changed:
        print(c)
else:
    print("NOCHANGE")
PYEOF
    chmod 600 "$cfg" 2>/dev/null
    fix_docker_ownership
}
load_config_from_file() {
    local cfg; cfg=$(get_active_config_path)
    [[ ! -f "$cfg" ]] && return 0
    json_is_valid || return 0
    has_cmd python3 || return 0
    local line key val
    while IFS='|' read -r key val; do
        [[ -z "$key" ]] && continue
        case "$key" in
            KEY:*)     G_API_KEYS["${key#KEY:}"]="$val" ;;
            MODEL:*)   G_API_MODELS["${key#MODEL:}"]="$val" ;;
            TYPE:*)    G_API_TYPES["${key#TYPE:}"]="$val" ;;
            URL:*)     G_API_URLS["${key#URL:}"]="$val" ;;
            DEFAULT)   G_DEFAULT_PROVIDER="$val" ;;
        esac
    done < <(python3 - "$cfg" << 'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)
for provider in ["anthropic", "openai", "google", "deepseek", "groq", "mistral"]:
    p_cfg = cfg.get(provider, {})
    if isinstance(p_cfg, dict):
        key = p_cfg.get("apiKey", "")
        model = p_cfg.get("model", "")
        models = p_cfg.get("models", "")
        if key: print(f"KEY:{provider}|{key}")
        if models: print(f"MODEL:{provider}|{models}")
        elif model: print(f"MODEL:{provider}|{model}")
models_cfg = cfg.get("models", {})
providers = models_cfg.get("providers", {})
first_custom = ""
for name, p_cfg in providers.items():
    if not isinstance(p_cfg, dict):
        continue
    base_url = p_cfg.get("baseUrl", "")
    api_key = p_cfg.get("apiKey", "")
    api_type = p_cfg.get("api", "")
    model_list = p_cfg.get("models", [])
    if isinstance(model_list, list) and model_list:
        model_ids = [m.get("id", "") for m in model_list if isinstance(m, dict) and m.get("id")]
        models_str = ",".join(model_ids)
    else:
        models_str = ""
    if base_url: print(f"URL:{name}|{base_url}")
    if api_key:  print(f"KEY:{name}|{api_key}")
    if api_type: print(f"TYPE:{name}|{api_type}")
    if models_str: print(f"MODEL:{name}|{models_str}")
    if not first_custom:
        first_custom = name
if first_custom:
    print(f"DEFAULT|{first_custom}")
PYEOF
) || true
}
get_gateway_token() {
    local cfg; cfg=$(get_active_config_path)
    [[ ! -f "$cfg" ]] && return 1
    json_is_valid || return 1
    has_cmd python3 || return 1
    python3 - "$cfg" << 'PYEOF' 2>/dev/null
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    t = c.get('gateway', {}).get('auth', {}).get('token', '')
    print(t)
except: pass
PYEOF
}
create_minimal_config() {
    local cfg; cfg=$(get_active_config_path)
    mkdir -p "$(dirname "$cfg")"
    local content='{
  "gateway": {
    "mode": "local",
    "bind": "loopback"
  },
  "models": {
    "mode": "merge",
    "providers": {}
  },
  "agents": {
    "defaults": {
      "workspace": "~/.openclaw/workspace"
    },
    "list": [
      {"id": "main", "default": true}
    ]
  }
}'
    atomic_write_json "$cfg" "$content" && msg_ok "最小配置已创建" || msg_fail "配置创建失败"
}
ensure_config() {
    local cfg; cfg=$(get_active_config_path)
    mkdir -p "$(dirname "$cfg")"
    if [[ ! -f "$cfg" ]]; then
        create_minimal_config; return
    fi
    if ! json_is_valid; then
        msg_warn "配置损坏,备份并重建"
        backup_config
        create_minimal_config
        return
    fi
    sanitize_config_for_schema >/dev/null 2>&1 || true
}
_install_node_binary() {
    local version="${1:-$NODE_RECOMMENDED_VERSION}"
    detect_region
    msg_step "尝试二进制包安装 Node.js v%s..." "$version"
    local arch_suffix
    case "$ARCH" in
        x86_64|amd64)   arch_suffix="linux-x64" ;;
        aarch64|arm64)  arch_suffix="linux-arm64" ;;
        armv7l)         arch_suffix="linux-armv7l" ;;
        *) msg_fail "不支持的架构: %s" "$ARCH"; return 1 ;;
    esac
    local mirror
    if is_china; then
        mirror="$NODE_MIRROR_CN"
    else
        mirror="$NODE_MIRROR_OFFICIAL"
    fi
    msg_info "从 %s 获取最新 v%s 版本..." "$mirror" "$version"
    local latest
    latest=$(curl -s --max-time 10 "${mirror}/latest-v${version}.x/" 2>/dev/null \
        | grep -oE "node-v${version}\.[0-9]+\.[0-9]+-${arch_suffix}\.tar\.[gx]z" \
        | head -1)
    if [[ -z "$latest" ]]; then
        msg_warn "无法获取版本列表,使用 latest"
        latest=$(curl -s --max-time 10 "${mirror}/latest/" 2>/dev/null \
            | grep -oE "node-v[0-9]+\.[0-9]+\.[0-9]+-${arch_suffix}\.tar\.[gx]z" \
            | head -1)
        [[ -z "$latest" ]] && { msg_fail "获取失败"; return 1; }
    fi
    local url="${mirror}/latest-v${version}.x/${latest}"
    [[ ! "$latest" =~ ^node-v${version} ]] && url="${mirror}/latest/${latest}"
    local tmp_dir="/tmp/node_install_$$"
    mkdir -p "$tmp_dir"
    msg_info "下载: %s" "$url"
    if ! curl -fL --max-time 120 --progress-bar -o "${tmp_dir}/node.tar.gz" "$url"; then
        msg_fail "下载失败"
        rm -rf "$tmp_dir"
        return 1
    fi
    msg_info "解压..."
    if ! tar -xzf "${tmp_dir}/node.tar.gz" -C "$tmp_dir" 2>/dev/null \
        && ! tar -xf "${tmp_dir}/node.tar.gz" -C "$tmp_dir" 2>/dev/null; then
        msg_fail "解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi
    local node_dir; node_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "node-v*" | head -1)
    [[ -z "$node_dir" ]] && { msg_fail "解压产物未找到"; rm -rf "$tmp_dir"; return 1; }
    msg_info "安装到 /usr/local ..."
    $SUDO cp -rf "${node_dir}/bin/"* /usr/local/bin/ 2>/dev/null || \
        cp -rf "${node_dir}/bin/"* /usr/local/bin/ 2>/dev/null || return 1
    $SUDO cp -rf "${node_dir}/include/"* /usr/local/include/ 2>/dev/null || \
        cp -rf "${node_dir}/include/"* /usr/local/include/ 2>/dev/null || true
    $SUDO cp -rf "${node_dir}/lib/"* /usr/local/lib/ 2>/dev/null || \
        cp -rf "${node_dir}/lib/"* /usr/local/lib/ 2>/dev/null || true
    $SUDO cp -rf "${node_dir}/share/"* /usr/local/share/ 2>/dev/null || \
        cp -rf "${node_dir}/share/"* /usr/local/share/ 2>/dev/null || true
    rm -rf "$tmp_dir"
    hash -r 2>/dev/null || true
    if has_cmd node; then
        msg_ok "Node.js %s 安装成功 (二进制)" "$(node -v)"
        return 0
    fi
    msg_fail "二进制安装失败"
    return 1
}
_install_node_nodesource() {
    local version="$1"
    case "$OS" in
        debian)
            safe_run "NodeSource GPG" bash -c "curl -fsSL https://deb.nodesource.com/setup_${version}.x | $SUDO -E bash -"
            safe_run "nodejs (apt)" $SUDO apt-get install -y nodejs ;;
        rhel|fedora)
            safe_run "NodeSource GPG" bash -c "curl -fsSL https://rpm.nodesource.com/setup_${version}.x | $SUDO bash -"
            safe_run "nodejs" $SUDO "$PKG_MANAGER" install -y nodejs ;;
        arch)
            safe_run "nodejs" $SUDO pacman -S --noconfirm nodejs npm ;;
        alpine)
            safe_run "nodejs" $SUDO apk add nodejs npm ;;
        macos)
            has_cmd brew || { msg_fail "需要 Homebrew"; return 1; }
            safe_run "node@${version}" brew install "node@${version}"
            brew link --force --overwrite "node@${version}" 2>/dev/null || true ;;
    esac
}
_install_node_nvm() {
    local version="$1"
    local nvm_ver; nvm_ver=$(get_nvm_latest_version)
    safe_run "nvm" bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_ver}/install.sh | bash"
    export NVM_DIR="$HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" || return 1
    safe_run "node v${version}" nvm install "$version"
    nvm use "$version" >> "$LOG_FILE" 2>&1 || true
    nvm alias default "$version" >> "$LOG_FILE" 2>&1 || true
}
_install_node_native() {
    case "$OS" in
        debian)
            safe_run "apt" $SUDO apt-get update -qq
            safe_run "nodejs" $SUDO apt-get install -y nodejs npm ;;
        rhel)
            safe_run "nodejs" $SUDO yum install -y nodejs npm ;;
        fedora)
            safe_run "nodejs" $SUDO dnf install -y nodejs npm ;;
        arch)
            safe_run "nodejs" $SUDO pacman -S --noconfirm nodejs npm ;;
        alpine)
            safe_run "nodejs" $SUDO apk add nodejs npm ;;
        macos)
            has_cmd brew && safe_run "node" brew install node || return 1 ;;
    esac
}
_refresh_node_path() {
    local nd=""
    [[ -d "$HOME/.nvm/versions/node" ]] && nd=$(ls -d "$HOME/.nvm/versions/node/"v* 2>/dev/null | sort -V | tail -1)
    for p in "${nd:+${nd}/bin}" "$HOME/.local/bin" "/usr/local/bin"; do
        [[ -n "$p" && -d "$p" ]] && export PATH="$p:$PATH"
    done
    export NVM_DIR="$HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
    hash -r 2>/dev/null || true
}
install_nodejs() {
    msg_step "检测 Node.js..."
    if has_cmd node; then
        local ver; ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$ver" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js %s 已满足要求 (>= v%s)" "$(node -v)" "$NODE_MIN_VERSION"
            return 0
        else
            msg_warn "Node.js %s 过低,需 >= v%s" "$(node -v)" "$NODE_MIN_VERSION"
        fi
    else
        msg_info "Node.js 未安装"
    fi
    local tv="$NODE_RECOMMENDED_VERSION"
    printf "\n"
    printf "  ${BOLD}1)${NC} NodeSource 官方仓库 ${GREEN}(推荐)${NC}\n"
    printf "  ${BOLD}2)${NC} nvm 版本管理\n"
    printf "  ${BOLD}3)${NC} 系统包管理器\n"
    printf "  ${BOLD}4)${NC} 官方二进制包 ${YELLOW}(网络问题时用)${NC}\n"
    printf "  ${BOLD}5)${NC} 跳过\n\n"
    printf "${BOLD}选择 [1-5] (默认: 1): ${NC}"
    local nc; read_input nc "1"
    if [[ "$nc" =~ ^[1-4]$ ]]; then
        printf "\n${BOLD}Node.js 主版本号 (默认: %s): ${NC}" "$tv"
        local custom_ver; read_input custom_ver "$tv"
        custom_ver=$(printf "%s" "$custom_ver" | tr -d 'vV ')
        [[ "$custom_ver" =~ ^[0-9]+$ ]] && tv="$custom_ver"
    fi
    msg_info "安装 Node.js v%s ..." "$tv"
    case "$nc" in
        1) _install_node_nodesource "$tv" || { msg_warn "NodeSource 失败,回退二进制"; _install_node_binary "$tv"; } ;;
        2) _install_node_nvm "$tv" ;;
        3) _install_node_native ;;
        4) _install_node_binary "$tv" ;;
        5) return 1 ;;
        *) _install_node_nodesource "$tv" || _install_node_binary "$tv" ;;
    esac
    _refresh_node_path
    if has_cmd node; then
        local iv; iv=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$iv" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js %s 安装成功" "$(node -v)"
            return 0
        fi
    fi
    msg_fail "Node.js 安装失败"
    return 1
}
get_nvm_latest_version() { printf "v0.40.1"; }
get_openclaw_latest_version() {
    curl -s --max-time 5 --connect-timeout 3 "https://registry.npmjs.org/openclaw/latest" 2>/dev/null \
        | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || printf ""
}
install_openclaw() {
    msg_title "安装 OpenClaw"
    detect_system
    detect_region
    printf "${CYAN}环境:${NC} ${BOLD}%s %s${NC}  ${DIM}[SUDO=%s]${NC}\n" "$OS" "$ARCH_LABEL" "${SUDO:-<root>}"
    is_china && printf "${YELLOW}国内网络,自动使用镜像加速${NC}\n"
    printf "\n"
    if has_cmd openclaw; then
        local iv; iv=$(openclaw --version 2>/dev/null || printf "未知")
        msg_warn "已安装 (%s)" "$iv"
        confirm "重新安装?" || { wait_and_return 2; return 0; }
    fi
    msg_step "步骤 1/5: 系统依赖..."
    case "$OS" in
        debian)
            safe_run "apt update" $SUDO apt-get update -qq
            safe_run "依赖" $SUDO apt-get install -y curl wget git build-essential ca-certificates gnupg python3 jq ;;
        rhel|fedora)
            safe_run "更新" bash -c "$UPDATE_CMD"
            safe_run "依赖" bash -c "$INSTALL_CMD curl wget git gcc gcc-c++ make python3 jq" ;;
        arch)
            safe_run "pacman" $SUDO pacman -Sy --noconfirm
            safe_run "依赖" $SUDO pacman -S --noconfirm curl wget git base-devel python jq ;;
        alpine)
            safe_run "apk update" $SUDO apk update
            safe_run "依赖" $SUDO apk add curl wget git build-base python3 jq ;;
        macos)
            has_cmd brew || safe_run "Homebrew" bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            safe_run "工具" brew install curl wget git jq ;;
    esac
    msg_ok "依赖完成"
    msg_step "步骤 2/5: Node.js..."
    install_nodejs || { msg_fail "Node.js 安装失败"; wait_and_return 3; return 1; }
    msg_step "步骤 3/5: 安装 OpenClaw..."
    printf "  ${BOLD}1)${NC} 官方脚本 ${GREEN}[推荐]${NC}\n"
    printf "  ${BOLD}2)${NC} npm 安装\n"
    printf "  ${BOLD}3)${NC} GitHub 源码编译\n\n"
    printf "${BOLD}选择 [1-3] (默认: 1): ${NC}"
    local ic; read_input ic "1"
    msg_info "安装中,请稍候..."
    local npm_args=""
    is_china && npm_args="--registry=${NPM_MIRROR_CN}"
    case "$ic" in
        2)
            msg_info "npm install -g openclaw@latest %s" "$npm_args"
            if npm install -g openclaw@latest $npm_args >> "$LOG_FILE" 2>&1; then
                msg_ok "npm 安装成功"
            else
                msg_fail "npm 安装失败 (详见 %s)" "$LOG_FILE"
                tail -10 "$LOG_FILE" | sed 's/^/  /'
            fi
            ;;
        3)
            printf "${BOLD}仓库地址 (默认: %s): ${NC}" "$GITHUB_REPO"
            local repo; read_input repo "$GITHUB_REPO"
            local tmp="/tmp/oc_src_$$"
            msg_info "克隆 %s ..." "$repo"
            git clone "$repo" "$tmp" >> "$LOG_FILE" 2>&1 || { msg_fail "clone 失败"; return 1; }
            pushd "$tmp" > /dev/null
            has_cmd pnpm || npm install -g pnpm $npm_args >> "$LOG_FILE" 2>&1 || true
            msg_info "编译..."
            pnpm install >> "$LOG_FILE" 2>&1 || true
            pnpm run build >> "$LOG_FILE" 2>&1 || true
            pnpm install -g . >> "$LOG_FILE" 2>&1 || true
            popd > /dev/null
            rm -rf "$tmp"
            ;;
        *)
            msg_info "下载官方脚本..."
            if curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 --connect-timeout 10 "$OPENCLAW_INSTALL_URL" 2>/dev/null | bash >> "$LOG_FILE" 2>&1; then
                msg_ok "官方脚本成功"
            else
                msg_warn "官方脚本失败,回退 npm..."
                npm install -g openclaw@latest $npm_args >> "$LOG_FILE" 2>&1 || true
            fi
            ;;
    esac
    _refresh_node_path
    has_cmd openclaw || { msg_fail "安装失败 (详见 %s)" "$LOG_FILE"; tail -10 "$LOG_FILE" | sed 's/^/  /'; wait_and_return 5; return 1; }
    msg_ok "OpenClaw %s 安装成功" "$(openclaw --version 2>/dev/null)"
    msg_step "步骤 4/5: 配置..."
    ensure_config
    printf "\n${CYAN}下一步:${NC}\n"
    printf "  ${BOLD}1)${NC} 配置自定义 API ${GREEN}(推荐)${NC}\n"
    printf "  ${BOLD}2)${NC} 配置内置 Provider\n"
    printf "  ${BOLD}3)${NC} 跳过\n\n"
    printf "${BOLD}选择: ${NC}"
    local next; read_input next "3"
    case "$next" in
        1) configure_custom_api ;;
        2) configure_builtin_providers ;;
    esac
    msg_step "步骤 5/5: 启动..."
    openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
    service_start
    wait_gateway_ready 30
    printf "\n"
    confirm "配置局域网访问?" && configure_lan_access || show_dashboard_info
    log "Installation completed"
    wait_and_return 3
    return 0
}
repair_broken_config() {
    msg_title "修复配置文件"
    local cfg; cfg=$(get_active_config_path)
    if [[ ! -f "$cfg" ]]; then
        msg_info "配置不存在,创建最小配置"
        create_minimal_config
        wait_and_return 2
        return 0
    fi
    if json_is_valid; then
        msg_ok "JSON 格式有效"
        printf "\n"
        msg_step "运行 schema 兼容清理..."
        local result
        result=$(sanitize_config_for_schema 2>&1)
        if [[ "$result" == "NOCHANGE" ]]; then
            msg_ok "无需修改"
        else
            printf "%s\n" "$result" | sed 's/^/  /'
            msg_ok "已清理"
        fi
        wait_and_return 3
        return 0
    fi
    msg_fail "JSON 格式损坏"
    printf "${CYAN}文件:${NC} %s\n\n" "$cfg"
    if has_cmd python3; then
        local err
        err=$(python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$cfg" 2>&1 | tail -1)
        printf "${YELLOW}错误:${NC} %s\n\n" "$err"
    fi
    printf "${BOLD}修复方案:${NC}\n"
    printf "  ${BOLD}1)${NC} 备份并重建 ${GREEN}(推荐)${NC}\n"
    printf "  ${BOLD}2)${NC} 手动编辑\n"
    printf "  ${BOLD}3)${NC} 智能修剪\n"
    printf "  ${BOLD}0)${NC} 取消\n\n"
    printf "${BOLD}选择: ${NC}"
    local rc; read_input rc "0"
    case "$rc" in
        1)
            local backup; backup=$(backup_config)
            [[ -n "$backup" ]] && msg_ok "已备份: %s" "$backup"
            create_minimal_config
            msg_ok "已重建"
            ;;
        2)
            local backup; backup=$(backup_config)
            [[ -n "$backup" ]] && msg_ok "已备份: %s" "$backup"
            local editor="${EDITOR:-nano}"
            has_cmd "$editor" || editor="vi"
            $editor "$cfg" </dev/tty
            if json_is_valid; then
                msg_ok "修复成功"
                sanitize_config_for_schema
            else
                msg_fail "仍无效"
            fi
            ;;
        3)  _smart_repair_config ;;
        0)  msg_info "已取消" ;;
    esac
    wait_and_return 3
    return 0
}
_smart_repair_config() {
    has_cmd python3 || { msg_fail "需要 python3"; return 1; }
    local cfg; cfg=$(get_active_config_path)
    local backup; backup=$(backup_config)
    [[ -n "$backup" ]] && msg_ok "已备份: %s" "$backup"
    python3 - "$cfg" << 'PYEOF'
import json, re, sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
lines = content.split('\n')
cleaned = []
for line in lines:
    if re.search(r':\s*(fa|tr|nu|un)\s*$', line.strip()):
        continue
    if re.search(r':\s*[a-z]+\s*$', line.strip()) and not re.search(r':\s*(true|false|null)\s*[,}\]]?\s*$', line.strip()):
        continue
    cleaned.append(line)
content = '\n'.join(cleaned)
try:
    cfg = json.loads(content)
    with open(path, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print("SMART_OK")
except json.JSONDecodeError:
    minimal = {
        "gateway": {"mode": "local", "bind": "loopback"},
        "models": {"mode": "merge", "providers": {}},
        "agents": {"defaults": {"workspace": "~/.openclaw/workspace"}, "list": [{"id": "main", "default": True}]}
    }
    with open(path, 'w') as f:
        json.dump(minimal, f, indent=2, ensure_ascii=False)
    print("FALLBACK")
PYEOF
    if json_is_valid; then
        sanitize_config_for_schema
        fix_docker_ownership
        msg_ok "修复完成"
    else
        msg_fail "修复失败"
    fi
}
validate_config() {
    local cfg; cfg=$(get_active_config_path)
    msg_step "验证配置..."
    if [[ ! -f "$cfg" ]]; then
        msg_fail "配置不存在"
        return 1
    fi
    if ! json_is_valid; then
        msg_fail "JSON 无效"
        return 1
    fi
    if is_openclaw_installed; then
        local out
        out=$(openclaw_cmd config validate 2>&1)
        if printf "%s" "$out" | grep -qiE "Invalid input|invalid config"; then
            msg_fail "Schema 验证失败:"
            printf "%s\n" "$out" | grep -iE "×|invalid|allowed" | head -10 | sed 's/^/  /'
            printf "\n"
            if confirm "自动清理不兼容字段?"; then
                sanitize_config_for_schema | sed 's/^/  /'
                openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
                printf "\n"
                msg_info "重新验证..."
                out=$(openclaw_cmd config validate 2>&1)
                if printf "%s" "$out" | grep -qiE "Invalid input"; then
                    msg_fail "仍失败"
                    return 1
                else
                    msg_ok "验证通过"
                    return 0
                fi
            fi
            return 1
        else
            msg_ok "验证通过"
            return 0
        fi
    fi
    msg_ok "JSON 格式正确"
    return 0
}
show_token_manager() {
    msg_title "网关令牌管理"
    if ! json_is_valid; then
        msg_fail "配置无效,请先修复"
        wait_and_return 3
        return 0
    fi
    local token local_ip
    token=$(get_gateway_token)
    local_ip=$(get_local_ip)
    printf "${CYAN}${BOLD}令牌状态${NC}\n"
    print_line
    if [[ -n "$token" ]]; then
        printf "  ${BOLD}状态:${NC}   ${GREEN}已设置${NC}\n"
        printf "  ${BOLD}Token:${NC}  ${YELLOW}%s${NC}\n" "$token"
        printf "\n  ${BOLD}访问 URL:${NC}\n"
        printf "  ${CYAN}http://%s:%s?token=%s${NC}\n" "$local_ip" "$OPENCLAW_PORT" "$token"
    else
        printf "  ${BOLD}状态:${NC}   ${DIM}未设置${NC}\n"
        printf "  ${CYAN}http://%s:%s${NC}\n" "$local_ip" "$OPENCLAW_PORT"
    fi
    print_line
    printf "\n  ${BOLD}1)${NC} 查看令牌\n"
    printf "  ${BOLD}2)${NC} 生成新令牌\n"
    printf "  ${BOLD}3)${NC} 手动设置\n"
    printf "  ${BOLD}4)${NC} 删除令牌\n"
    printf "  ${BOLD}5)${NC} 获取 Dashboard URL\n"
    printf "  ${BOLD}0)${NC} 返回\n\n"
    printf "${BOLD}选择: ${NC}"
    local tc; read_input tc "0"
    case "$tc" in
        1)
            if [[ -n "$token" ]]; then
                printf "\n${YELLOW}%s${NC}\n" "$token"
            else
                msg_warn "未设置"
            fi
            ;;
        2)
            local new_token
            new_token=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null | tr -d '\n' || printf "%s" "$(date +%s%N)")
            _set_gateway_token "$new_token"
            ;;
        3)
            printf "\n${BOLD}令牌 (至少 16 字符): ${NC}"
            local ct; read_input ct ""
            if [[ ${#ct} -lt 16 ]]; then
                msg_fail "太短"
            else
                _set_gateway_token "$ct"
            fi
            ;;
        4)  confirm "确认删除?" && _remove_gateway_token ;;
        5)  is_openclaw_installed && openclaw_cmd dashboard --no-open 2>&1 | tail -20 || msg_fail "未安装" ;;
        0)  return 0 ;;
    esac
    wait_and_return 3
    return 0
}
_set_gateway_token() {
    local new_token="$1"
    local cfg; cfg=$(get_active_config_path)
    if has_cmd python3; then
        python3 - "$cfg" "$new_token" << 'PYEOF'
import json, sys, os
cfg_path, token = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
gw = cfg.setdefault("gateway", {})
gw.setdefault("mode", "local")
if gw.get("bind") not in ["auto", "lan", "loopback", "custom", "tailnet"]:
    gw["bind"] = "loopback"
auth = gw.setdefault("auth", {})
auth["mode"] = "token"
auth["token"] = token
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print("OK")
PYEOF
        chmod 600 "$cfg"
        fix_docker_ownership
        msg_ok "令牌已更新"
        printf "\n${GREEN}${BOLD}新令牌:${NC} ${YELLOW}%s${NC}\n" "$new_token"
        confirm "重启 Gateway?" && { service_restart; wait_gateway_ready 15; }
    fi
}
_remove_gateway_token() {
    local cfg; cfg=$(get_active_config_path)
    if has_cmd python3; then
        python3 - "$cfg" << 'PYEOF'
import json, sys
cfg_path = sys.argv[1]
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)
gw = cfg.get("gateway", {})
auth = gw.get("auth", {})
auth.pop("token", None)
if auth.get("mode") == "token":
    auth.pop("mode", None)
if not auth:
    gw.pop("auth", None)
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PYEOF
        chmod 600 "$cfg"
        fix_docker_ownership
        msg_ok "已删除"
    fi
}
sync_agent_auth() {
    local provider_name="$1"
    local base_url="$2"
    local api_key="$3"
    local api_type="$4"
    local agent_name="${5:-main}"
    is_openclaw_installed || return 1
    if _write_agent_auth_file "$agent_name" "$provider_name" "$base_url" "$api_key" "$api_type"; then
        msg_ok "Agent [%s] <- %s" "$agent_name" "$provider_name"
        return 0
    else
        msg_warn "Agent 认证写入失败 (%s)" "$provider_name"
        return 1
    fi
}
_write_agent_auth_file() {
    local agent_name="$1" provider="$2" base_url="$3" api_key="$4" api_type="$5"
    local base_dir
    if is_docker_mode; then
        base_dir="${DOCKER_DATA_DIR}/.openclaw/agents"
    else
        base_dir="$OPENCLAW_AGENTS_DIR"
    fi
    local agent_dir="${base_dir}/${agent_name}/agent"
    local auth_json="${agent_dir}/auth-profiles.json"
    mkdir -p "$agent_dir"
    if has_cmd python3; then
        python3 - "$auth_json" "$provider" "$base_url" "$api_key" "$api_type" << 'PYEOF'
import json, sys, os
path, provider, base_url, api_key, api_type = sys.argv[1:6]
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}
entry = {
    "provider": provider, "apiKey": api_key, "baseUrl": base_url,
    "api": api_type, "kind": "static", "portable": True
}
if "profiles" in data and isinstance(data["profiles"], dict):
    data["profiles"][provider] = entry
elif "providers" in data and isinstance(data["providers"], dict):
    data["providers"][provider] = entry
else:
    data[provider] = entry
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
with open(tmp) as f:
    json.load(f)
os.replace(tmp, path)
print("OK")
PYEOF
        chmod 600 "$auth_json" 2>/dev/null
        fix_docker_ownership
        return 0
    fi
    return 1
}
fix_agent_auth_menu() {
    msg_title "修复 Agent 认证"
    if ! is_openclaw_installed; then
        msg_fail "未安装"; wait_and_return 2; return 0
    fi
    if ! json_is_valid; then
        msg_fail "配置损坏,请先修复"; wait_and_return 3; return 0
    fi
    load_config_from_file
    if [[ ${#G_API_URLS[@]} -eq 0 && ${#G_API_KEYS[@]} -eq 0 ]]; then
        msg_fail "无 Provider 配置,请先配置 API"; wait_and_return 3; return 0
    fi
    printf "${CYAN}当前 Agents:${NC}\n"
    openclaw_cmd agents list 2>&1 | head -15 | sed 's/^/  /' || printf "  (无法列出)\n"
    printf "\n${BOLD}Agent 名 (默认: main): ${NC}"
    local agent_name; read_input agent_name "main"
    printf "\n${CYAN}将同步:${NC}\n"
    for p in "${!G_API_URLS[@]}"; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        printf "  - ${BOLD}%s${NC} -> %s\n" "$p" "${G_API_URLS[$p]}"
    done
    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        printf "  - ${BOLD}%s${NC} (内置)\n" "$p"
    done
    printf "\n"
    local inject_openai_alias=false
    if [[ ${#G_API_URLS[@]} -gt 0 ]] && [[ -z "${G_API_KEYS[openai]:-}" ]]; then
        printf "${YELLOW}检测到自定义 Provider 但无 openai${NC}\n"
        confirm "以 openai 别名注入?" && inject_openai_alias=true
        printf "\n"
    fi
    confirm "确认同步?" || { wait_and_return 2; return 0; }
    local ok=0 fail=0 first_custom=""
    for p in "${!G_API_URLS[@]}"; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        [[ -z "$first_custom" ]] && first_custom="$p"
        local url="${G_API_URLS[$p]}"
        if is_docker_mode && is_lan_url "$url"; then
            url=$(convert_url_for_docker "$url")
        fi
        sync_agent_auth "$p" "$url" "${G_API_KEYS[$p]}" "${G_API_TYPES[$p]:-openai-completions}" "$agent_name" && ((ok++)) || ((fail++))
    done
    if $inject_openai_alias && [[ -n "$first_custom" ]]; then
        local url="${G_API_URLS[$first_custom]}"
        if is_docker_mode && is_lan_url "$url"; then
            url=$(convert_url_for_docker "$url")
        fi
        sync_agent_auth "openai" "$url" "${G_API_KEYS[$first_custom]}" "${G_API_TYPES[$first_custom]:-openai-completions}" "$agent_name" && ((ok++)) || ((fail++))
    fi
    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        [[ "$p" == "openai" ]] && $inject_openai_alias && continue
        local built_url=""
        case "$p" in
            anthropic) built_url="https://api.anthropic.com" ;;
            openai)    built_url="https://api.openai.com/v1" ;;
            google)    built_url="https://generativelanguage.googleapis.com" ;;
            deepseek)  built_url="https://api.deepseek.com/v1" ;;
            groq)      built_url="https://api.groq.com/openai/v1" ;;
            mistral)   built_url="https://api.mistral.ai/v1" ;;
        esac
        sync_agent_auth "$p" "$built_url" "${G_API_KEYS[$p]}" "openai-completions" "$agent_name" && ((ok++)) || ((fail++))
    done
    msg_step "重启 Gateway..."
    service_restart
    wait_gateway_ready 15
    printf "\n"
    print_line
    printf "${BOLD}结果:${NC} 成功 ${GREEN}%d${NC}  失败 ${RED}%d${NC}\n" "$ok" "$fail"
    print_line
    printf "\n${YELLOW}提示: 浏览器 Ctrl+Shift+R 硬刷新${NC}\n"
    wait_and_return 5
    return 0
}
is_lan_url() {
    local url="$1"
    [[ "$url" =~ ^https?://(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.|localhost) ]]
}
convert_url_for_docker() {
    local url="$1"
    if [[ "$url" =~ ^(https?://)(127\.0\.0\.1|localhost)(:[0-9]+)?(.*)$ ]]; then
        printf "%s%s%s%s" "${BASH_REMATCH[1]}" "host.docker.internal" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    elif [[ "$url" =~ ^(https?://)(192\.168\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+)(:[0-9]+)?(.*)$ ]]; then
        printf "%s%s%s%s" "${BASH_REMATCH[1]}" "host.docker.internal" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
    else
        printf "%s" "$url"
    fi
}
gateway_health_check() {
    local urls=(
        "http://127.0.0.1:${OPENCLAW_PORT}"
        "http://127.0.0.1:${OPENCLAW_PORT}/health"
        "http://127.0.0.1:${OPENCLAW_PORT}/healthz"
        "http://localhost:${OPENCLAW_PORT}"
    )
    for url in "${urls[@]}"; do
        local code
        code=$(curl -s -o /dev/null --max-time 2 --connect-timeout 2 -w "%{http_code}" "$url" 2>/dev/null || printf "000")
        if [[ "$code" =~ ^(200|401|403|404)$ ]]; then return 0; fi
    done
    if is_docker_mode; then
        if docker logs --tail 50 "$DOCKER_CONTAINER" 2>&1 | grep -qE "\[gateway\] ready|http server listening"; then
            return 0
        fi
    fi
    if has_cmd ss; then
        ss -lntp 2>/dev/null | grep -q ":${OPENCLAW_PORT}\b" && return 0
    fi
    if has_cmd nc; then
        nc -z -w 2 127.0.0.1 "$OPENCLAW_PORT" 2>/dev/null && return 0
    fi
    return 1
}
wait_gateway_ready() {
    local timeout="${1:-30}"
    local i=0
    printf "  等待就绪"
    while (( i < timeout )); do
        sleep 1
        printf "."
        if gateway_health_check; then
            printf "\n"; msg_ok "Gateway 已启动"; return 0
        fi
        ((i++))
    done
    printf "\n"; msg_warn "Gateway 未响应"; return 1
}
persist_default_model() {
    local provider="$1" model="$2"
    is_openclaw_installed || return 1
    local full_model="${provider}/${model}"
    if openclaw_cmd config set agents.defaults.model.primary "$full_model" >/dev/null 2>&1; then
        return 0
    fi
    if has_cmd python3; then
        local cfg; cfg=$(get_active_config_path)
        if [[ -f "$cfg" ]] && json_is_valid; then
            python3 - "$cfg" "$full_model" << 'PYEOF'
import json, sys, os
cfg_path = sys.argv[1]
full_model = sys.argv[2]
try:
    with open(cfg_path) as f:
        c = json.load(f)
except Exception:
    sys.exit(1)
agents = c.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
model_cfg = defaults.setdefault("model", {})
model_cfg["primary"] = full_model
if "list" not in agents:
    agents["list"] = [{"id": "main", "default": True}]
tmp = cfg_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
os.replace(tmp, cfg_path)
print("OK")
PYEOF
            chmod 600 "$cfg"
            fix_docker_ownership
            return 0
        fi
    fi
    return 1
}
auto_detect_api_type() {
    local url="$1" key="$2"
    if [[ "$url" =~ :11434 ]]; then printf "ollama"; return; fi
    if [[ "$url" =~ api\.anthropic\.com ]]; then printf "anthropic-messages"; return; fi
    local resp
    if [[ "$key" != "local" && -n "$key" ]]; then
        resp=$(curl -s --max-time 5 -H "Authorization: Bearer ${key}" "${url}/v1/models" 2>/dev/null || printf "")
    else
        resp=$(curl -s --max-time 5 "${url}/v1/models" 2>/dev/null || printf "")
    fi
    if printf "%s" "$resp" | grep -q '"data"' 2>/dev/null; then printf "openai-completions"; return; fi
    resp=$(curl -s --max-time 5 "${url}/api/tags" 2>/dev/null || printf "")
    if printf "%s" "$resp" | grep -q '"models"' 2>/dev/null; then printf "ollama"; return; fi
    printf "openai-completions"
}
auto_detect_models() {
    local url="$1" key="$2" api_type="$3"
    if [[ "$api_type" == "ollama" ]]; then
        local resp; resp=$(curl -s --max-time 5 "${url}/api/tags" 2>/dev/null || printf "")
        if has_cmd python3 && printf "%s" "$resp" | grep -q '"models"'; then
            python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    ms=[m['name'] for m in d.get('models',[])][:10]
    print(','.join(ms))
except: pass
" <<< "$resp" 2>/dev/null
            return
        fi
    fi
    local resp
    if [[ "$key" != "local" && -n "$key" ]]; then
        resp=$(curl -s --max-time 5 -H "Authorization: Bearer ${key}" "${url}/v1/models" 2>/dev/null || printf "")
    else
        resp=$(curl -s --max-time 5 "${url}/v1/models" 2>/dev/null || printf "")
    fi
    if has_cmd python3 && printf "%s" "$resp" | grep -q '"data"'; then
        python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    ms=[m['id'] for m in d.get('data',[])][:10]
    print(','.join(ms))
except: pass
" <<< "$resp" 2>/dev/null
        return
    fi
    printf ""
}
test_api_connection() {
    local url="$1" key="$2"
    msg_info "测试 API 连接..."
    local code
    if [[ "$key" != "local" && -n "$key" ]]; then
        code=$(curl -s -o /dev/null --max-time 10 --connect-timeout 5 -w "%{http_code}" -H "Authorization: Bearer ${key}" "${url}/v1/models" 2>/dev/null || printf "000")
    else
        code=$(curl -s -o /dev/null --max-time 10 --connect-timeout 5 -w "%{http_code}" "${url}/v1/models" 2>/dev/null || printf "000")
    fi
    if [[ "$code" =~ ^(200|401|403)$ ]]; then
        msg_ok "API 可达 (HTTP %s)" "$code"
        return 0
    else
        msg_warn "API 响应: HTTP %s" "$code"
        return 1
    fi
}
configure_custom_api() {
    msg_title "自定义 API 配置"
    local cfg; cfg=$(get_active_config_path)
    if [[ -f "$cfg" ]] && ! json_is_valid; then
        msg_fail "配置损坏,请先修复"; wait_and_return 3; return 1
    fi
    local docker_mode=false
    is_docker_mode && docker_mode=true
    printf "${CYAN}${BOLD}=== 配置 + Agent 认证 + Gateway 启动 ===${NC}\n"
    if $docker_mode; then
        printf "${YELLOW}Docker 模式: 局域网 URL 将自动转换为 host.docker.internal${NC}\n"
    fi
    printf "\n${DIM}URL 示例:${NC}\n"
    printf "  ${DIM}- http://192.168.x.x:3000${NC}\n"
    printf "  ${DIM}- https://api.deepseek.com/v1${NC}\n"
    printf "  ${DIM}- http://127.0.0.1:11434 (Ollama)${NC}\n\n"
    printf "${CYAN}Provider 名称 (推荐: openai): ${NC}"
    local provider_name; read_input provider_name "openai"
    provider_name=$(printf "%s" "$provider_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    printf "\n${CYAN}API Base URL: ${NC}"
    local base_url; read_input base_url ""
    if [[ -z "$base_url" ]]; then
        msg_warn "URL 不能为空"; wait_and_return 2; return 1
    fi
    base_url="${base_url%/}"
    local final_url="$base_url"
    if $docker_mode && is_lan_url "$base_url"; then
        local converted; converted=$(convert_url_for_docker "$base_url")
        if [[ "$converted" != "$base_url" ]]; then
            printf "\n"; msg_warn "Docker 模式检测到局域网 URL"
            printf "  ${DIM}原始:${NC} %s\n" "$base_url"
            printf "  ${DIM}转换:${NC} ${GREEN}%s${NC}\n" "$converted"
            printf "\n"
            confirm "使用转换后的 URL?" && final_url="$converted"
        fi
    fi
    printf "\n${CYAN}API Key (本地服务输入 'local'): ${NC}"
    local api_key; read_input_silent api_key "local"
    test_api_connection "$base_url" "$api_key" || true
    printf "\n${CYAN}${BOLD}API 类型:${NC}\n"
    printf "  ${BOLD}1)${NC} openai-completions (OpenAI 兼容)\n"
    printf "  ${BOLD}2)${NC} openai-responses\n"
    printf "  ${BOLD}3)${NC} ollama\n"
    printf "  ${BOLD}4)${NC} anthropic-messages\n"
    printf "  ${BOLD}5)${NC} 自动检测\n\n"
    printf "${CYAN}选择 [1-5] (默认: 5): ${NC}"
    local api_choice; read_input api_choice "5"
    local api_type
    case "$api_choice" in
        1) api_type="openai-completions" ;;
        2) api_type="openai-responses" ;;
        3) api_type="ollama" ;;
        4) api_type="anthropic-messages" ;;
        *)
            msg_info "自动检测 API 类型..."
            api_type=$(auto_detect_api_type "$base_url" "$api_key")
            msg_ok "检测到: %s" "$api_type"
            ;;
    esac
    printf "\n"
    msg_info "探测可用模型..."
    local detected_models; detected_models=$(auto_detect_models "$base_url" "$api_key" "$api_type")
    if [[ -n "$detected_models" ]]; then
        msg_ok "发现模型: %s" "$detected_models"
        printf "\n${CYAN}使用探测到的模型? (Enter 确认 / 输入覆盖): ${NC}"
        local user_models; read_input user_models "$detected_models"
        detected_models="$user_models"
    else
        printf "${CYAN}模型 ID (多个用逗号分隔): ${NC}"
        read_input detected_models ""
        if [[ -z "$detected_models" ]]; then
            msg_warn "模型 ID 不能为空"; wait_and_return 2; return 1
        fi
    fi
    printf "\n"
    local default_model
    if [[ "$detected_models" == *","* ]]; then
        printf "${CYAN}多个模型,选择默认:${NC}\n"
        local i=1
        declare -a m_arr=()
        IFS=',' read -ra m_arr <<< "$detected_models"
        for m in "${m_arr[@]}"; do
            m=$(printf "%s" "$m" | xargs)
            printf "  ${BOLD}%d)${NC} %s\n" "$i" "$m"
            ((i++))
        done
        printf "\n${CYAN}选择 [1-$((i-1))] (默认: 1): ${NC}"
        local dc; read_input dc "1"
        [[ "$dc" =~ ^[0-9]+$ ]] && (( dc >= 1 && dc <= ${#m_arr[@]} )) || dc=1
        default_model=$(printf "%s" "${m_arr[$((dc-1))]}" | xargs)
    else
        default_model=$(printf "%s" "$detected_models" | xargs)
    fi
    local inject_openai_alias=false
    if [[ "$provider_name" != "openai" ]]; then
        printf "\n"
        confirm "同时以 openai 别名注入认证 (推荐)?" && inject_openai_alias=true
    fi
    G_API_URLS["$provider_name"]="$final_url"
    G_API_KEYS["$provider_name"]="$api_key"
    G_API_TYPES["$provider_name"]="$api_type"
    G_API_MODELS["$provider_name"]="$detected_models"
    G_DEFAULT_PROVIDER="$provider_name"
    printf "\n"; print_line
    printf "${GREEN}${BOLD}开始部署...${NC}\n"
    print_line; printf "\n"
    msg_step "[1/6] 写入配置..."
    _write_custom_provider_config "$provider_name" "$default_model"
    msg_step "[2/6] 同步认证到 main Agent..."
    sync_agent_auth "$provider_name" "$final_url" "$api_key" "$api_type" "main" || true
    if $inject_openai_alias; then
        msg_step "[3/6] 注入 openai 别名..."
        sync_agent_auth "openai" "$final_url" "$api_key" "$api_type" "main" || true
    else
        msg_step "[3/6] 跳过 openai 别名"
    fi
    msg_step "[4/6] Schema 兼容清理..."
    sanitize_config_for_schema | sed 's/^/  /'
    msg_step "[5/6] 固化默认模型..."
    persist_default_model "$provider_name" "$default_model" && msg_ok "默认模型: %s/%s" "$provider_name" "$default_model"
    msg_step "[6/6] 重启 Gateway..."
    is_openclaw_installed && openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
    service_restart
    wait_gateway_ready 30
    printf "\n${GREEN}${BOLD}=================================================${NC}\n"
    printf "${GREEN}${BOLD}  部署完成!${NC}\n"
    printf "${GREEN}${BOLD}=================================================${NC}\n\n"
    printf "  ${BOLD}Provider:${NC}  ${CYAN}%s${NC}\n" "$provider_name"
    printf "  ${BOLD}Base URL:${NC}  %s\n" "$final_url"
    printf "  ${BOLD}API Type:${NC}  ${CYAN}%s${NC}\n" "$api_type"
    printf "  ${BOLD}默认模型:${NC}  ${GREEN}%s/%s${NC}\n" "$provider_name" "$default_model"
    $inject_openai_alias && printf "  ${BOLD}openai 别名:${NC} ${GREEN}已注入${NC}\n"
    $docker_mode && [[ "$final_url" != "$base_url" ]] && printf "  ${BOLD}URL 转换:${NC}  ${GREEN}OK${NC}\n"
    printf "\n"
    _show_config_summary
    show_dashboard_info
    printf "\n${YELLOW}${BOLD}使用说明:${NC}\n"
    printf "  1. 打开 Dashboard URL\n"
    printf "  2. 硬刷新: ${BOLD}Ctrl+Shift+R${NC}\n"
    printf "  3. 模型选择器选: ${CYAN}%s/%s${NC}\n\n" "$provider_name" "$default_model"
    wait_and_return 5
    return 0
}
_write_custom_provider_config() {
    local provider_name="$1" default_model="$2"
    local cfg; cfg=$(get_active_config_path)
    mkdir -p "$(dirname "$cfg")"
    if has_cmd python3; then
        local base_url="${G_API_URLS[$provider_name]:-}"
        local api_key="${G_API_KEYS[$provider_name]:-local}"
        local api_type="${G_API_TYPES[$provider_name]:-openai-completions}"
        local models_str="${G_API_MODELS[$provider_name]:-}"
        python3 - "$cfg" "$provider_name" "$base_url" "$api_key" "$api_type" "$models_str" "$default_model" << 'PYEOF'
import json, sys, os
cfg_path = sys.argv[1]
provider_name = sys.argv[2]
base_url = sys.argv[3]
api_key = sys.argv[4]
api_type = sys.argv[5]
models_str = sys.argv[6]
default_model = sys.argv[7]
VALID_BIND = ["auto", "lan", "loopback", "custom", "tailnet"]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
try:
    with open(cfg_path, 'r') as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}
for bad in ["ui", "defaultProvider"]:
    config.pop(bad, None)
if "agents" in config and isinstance(config["agents"], dict):
    for bad_key in list(config["agents"].keys()):
        if bad_key not in ["defaults", "list"]:
            del config["agents"][bad_key]
config.setdefault("gateway", {})
config["gateway"].setdefault("mode", "local")
if config["gateway"].get("bind") not in VALID_BIND:
    config["gateway"]["bind"] = "loopback"
config.setdefault("models", {})
config["models"]["mode"] = "merge"
config["models"].setdefault("providers", {})
models_list = []
for model_id in models_str.split(","):
    model_id = model_id.strip()
    if model_id:
        models_list.append({
            "id": model_id, "name": model_id, "reasoning": False,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 128000, "maxTokens": 8192
        })
config["models"]["providers"][provider_name] = {
    "baseUrl": base_url, "apiKey": api_key, "api": api_type, "models": models_list
}
agents = config.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
defaults.setdefault("workspace", os.path.expanduser("~/.openclaw/workspace"))
model_cfg = defaults.setdefault("model", {})
model_cfg["primary"] = f"{provider_name}/{default_model}"
if "list" not in agents:
    agents["list"] = [{"id": "main", "default": True}]
tmp = cfg_path + ".tmp"
with open(tmp, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
with open(tmp, 'r') as f:
    json.load(f)
os.replace(tmp, cfg_path)
print("OK")
PYEOF
        chmod 600 "$cfg"
        fix_docker_ownership
        msg_ok "配置已写入"
    fi
}
_show_config_summary() {
    print_line
    printf "${BOLD}配置摘要${NC}\n"
    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        printf "  ${BOLD}%s${NC}  ${DIM}%s****${NC} -> ${CYAN}%s${NC}\n" "$p" "${G_API_KEYS[$p]:0:10}" "${G_API_MODELS[$p]:-}"
    done
    for p in "${!G_API_URLS[@]}"; do
        [[ -z "${G_API_URLS[$p]:-}" ]] && continue
        printf "  ${BOLD}%s${NC}  ${DIM}%s${NC}\n" "$p" "${G_API_URLS[$p]}"
    done
    print_line
}
configure_builtin_providers() {
    msg_title "内置 Provider API 密钥"
    if [[ -f "$(get_active_config_path)" ]] && ! json_is_valid; then
        msg_fail "配置损坏,请先修复"; wait_and_return 3; return 1
    fi
    load_config_from_file
    mkdir -p "$(dirname "$(get_active_config_path)")"
    if [[ ${#G_API_KEYS[@]} -gt 0 ]]; then
        printf "${CYAN}已有配置:${NC}\n"
        for p in anthropic openai google deepseek groq mistral; do
            [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
            local dt=""; [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && dt=" ${GREEN}[默认]${NC}"
            printf "  ${BOLD}%s${NC}: ${DIM}%s****${NC} -> %s%b\n" "$p" "${G_API_KEYS[$p]:0:8}" "${G_API_MODELS[$p]%%,*}" "$dt"
        done
        printf "\n"
    fi
    printf "  1) Anthropic   2) OpenAI   3) Google   4) DeepSeek\n"
    printf "  5) Groq        6) Mistral  0) 保存并退出\n\n"
    while true; do
        printf "${BOLD}编号 (0完成): ${NC}"
        local c; read_input c "0"
        case "$c" in
            0) break ;;
            1) _cfg_builtin_provider anthropic "sk-ant-..." "claude-sonnet-4-5" ;;
            2) _cfg_builtin_provider openai "sk-..." "gpt-4o" ;;
            3) _cfg_builtin_provider google "" "gemini-2.5-flash" ;;
            4) _cfg_builtin_provider deepseek "sk-..." "deepseek-chat" ;;
            5) _cfg_builtin_provider groq "gsk_..." "llama-3.3-70b-versatile" ;;
            6) _cfg_builtin_provider mistral "" "mistral-large-latest" ;;
            *) msg_warn "请输入 0-6" ;;
        esac
    done
    if [[ ${#G_API_KEYS[@]} -eq 0 && ${#G_API_URLS[@]} -eq 0 ]]; then
        msg_warn "未配置任何 Provider"; wait_and_return 2; return 0
    fi
    msg_step "保存配置..."
    ensure_config
    _write_builtin_providers_config
    _show_config_summary
    if is_openclaw_installed; then
        printf "\n"
        if confirm "同步认证到 main Agent?"; then
            for p in anthropic openai google deepseek groq mistral; do
                [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
                local built_url=""
                case "$p" in
                    anthropic) built_url="https://api.anthropic.com" ;;
                    openai)    built_url="https://api.openai.com/v1" ;;
                    google)    built_url="https://generativelanguage.googleapis.com" ;;
                    deepseek)  built_url="https://api.deepseek.com/v1" ;;
                    groq)      built_url="https://api.groq.com/openai/v1" ;;
                    mistral)   built_url="https://api.mistral.ai/v1" ;;
                esac
                sync_agent_auth "$p" "$built_url" "${G_API_KEYS[$p]}" "openai-completions" "main" || true
            done
            msg_step "重启 Gateway..."
            service_restart
            wait_gateway_ready 15
        fi
    fi
    printf "\n"; validate_config
    wait_and_return 3
    return 0
}
_cfg_builtin_provider() {
    local p="$1" hint="$2" rec="$3"
    printf "\n${CYAN}${BOLD}--- %s ---${NC}\n" "$p"
    local ek="${G_API_KEYS[$p]:-}"
    [[ -n "$ek" ]] && printf "  ${DIM}已有: %s****${NC}\n" "${ek:0:8}"
    printf "  Key${hint:+ (%s)}: " "$hint"
    local nk; read_input_silent nk ""
    if [[ -z "$nk" ]]; then
        if [[ -n "$ek" ]]; then msg_info "保留现有"
        else msg_warn "跳过"; fi
        return
    fi
    G_API_KEYS["$p"]="$nk"
    printf "  模型 (默认: %s): " "$rec"
    local sm; read_input sm "$rec"
    G_API_MODELS["$p"]="$sm"
    msg_ok "%s: %s" "$p" "$sm"
    [[ -z "$G_DEFAULT_PROVIDER" ]] && G_DEFAULT_PROVIDER="$p"
}
_write_builtin_providers_config() {
    local cfg; cfg=$(get_active_config_path)
    has_cmd python3 || return 1
    local env_args=()
    for p in anthropic openai google deepseek groq mistral; do
        [[ -n "${G_API_KEYS[$p]:-}" ]] && env_args+=("OC_KEY_${p}=${G_API_KEYS[$p]}")
        [[ -n "${G_API_MODELS[$p]:-}" ]] && env_args+=("OC_MODEL_${p}=${G_API_MODELS[$p]}")
    done
    env "${env_args[@]}" python3 - "$cfg" << 'PYEOF'
import json, os, sys
cfg_path = sys.argv[1]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
try:
    with open(cfg_path) as f:
        c = json.load(f)
except Exception:
    c = {}
c.setdefault("gateway", {"mode": "local", "bind": "loopback"})
if c["gateway"].get("bind") not in ["auto","lan","loopback","custom","tailnet"]:
    c["gateway"]["bind"] = "loopback"
for p in ["anthropic","openai","google","deepseek","groq","mistral"]:
    key = os.environ.get(f"OC_KEY_{p}", "")
    if key:
        c.setdefault(p, {})["apiKey"] = key
        models = os.environ.get(f"OC_MODEL_{p}", "")
        if models:
            first = models.split(",")[0].strip()
            c[p]["model"] = first
            c[p]["models"] = models
with open(cfg_path, "w") as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PYEOF
    chmod 600 "$cfg"
    fix_docker_ownership
    msg_ok "配置已保存"
}
configure_lan_access() {
    msg_title "局域网 UI 访问"
    if ! is_openclaw_installed; then
        msg_fail "OpenClaw 未安装"; wait_and_return 2; return 0
    fi
    if ! json_is_valid; then
        msg_fail "配置损坏,请先修复"; wait_and_return 3; return 0
    fi
    local cfg; cfg=$(get_active_config_path)
    printf "${CYAN}配置文件:${NC} ${DIM}%s${NC}\n\n" "$cfg"
    printf "${CYAN}当前 gateway 配置:${NC}\n"
    if [[ -f "$cfg" ]] && has_cmd python3; then
        python3 - "$cfg" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    gw = cfg.get("gateway", {})
    print(f"  bind       : {gw.get('bind', '未设置')}")
    print(f"  mode       : {gw.get('mode', '未设置')}")
    auth = gw.get("auth", {})
    print(f"  auth.mode  : {auth.get('mode', '未设置')}")
    print(f"  auth.token : {'已设置' if auth.get('token') else '未设置'}")
    ui = gw.get("controlUi", {})
    print(f"  controlUi  : {json.dumps(ui, ensure_ascii=False)}")
except Exception as e:
    print(f"  读取失败: {e}")
PYEOF
    fi
    printf "\n"; print_line
    printf "${BOLD}将执行的修改:${NC}\n"
    printf "  ${CYAN}gateway.bind${NC} -> ${GREEN}\"lan\"${NC}\n"
    printf "  ${CYAN}gateway.auth.token${NC} -> ${GREEN}自定义或自动生成${NC}\n"
    printf "  ${CYAN}gateway.controlUi.*${NC} -> ${GREEN}放宽认证${NC}\n\n"
    printf "${RED}[!] 安全警告:${NC}\n"
    printf "  - 勿将端口暴露到公网!\n"
    printf "  - 非 HTTPS 环境: 可能需要 ?token=xxx 访问\n\n"
    confirm "确认配置?" || { msg_info "已取消"; wait_and_return 2; return 0; }
    local existing_token; existing_token=$(get_gateway_token 2>/dev/null || printf "")
    printf "\n${CYAN}${BOLD}令牌设置${NC}\n"
    print_line
    if [[ -n "$existing_token" ]]; then
        printf "  ${BOLD}已有令牌:${NC} ${YELLOW}%s${NC}\n" "$existing_token"
        printf "  ${DIM}(输入 'keep' 保留现有令牌)${NC}\n"
    fi
    printf "  ${BOLD}选项:${NC}\n"
    printf "    - ${GREEN}直接回车${NC}: 自动生成安全随机令牌 ${DIM}(推荐)${NC}\n"
    printf "    - ${YELLOW}输入自定义令牌${NC}: 至少 16 字符\n"
    [[ -n "$existing_token" ]] && printf "    - ${CYAN}keep${NC}: 保留现有令牌\n"
    printf "\n${BOLD}请输入令牌 (回车自动生成): ${NC}"
    local user_token; read_input user_token ""
    local token_mode="auto" token_value=""
    if [[ "$user_token" == "keep" ]] && [[ -n "$existing_token" ]]; then
        token_mode="keep"
        token_value="$existing_token"
        msg_ok "保留现有令牌"
    elif [[ -z "$user_token" ]]; then
        token_mode="auto"
        msg_info "将自动生成安全随机令牌"
    else
        if [[ ${#user_token} -lt 16 ]]; then
            msg_warn "自定义令牌太短 (%d 字符, 需 >= 16), 改为自动生成" "${#user_token}"
            token_mode="auto"
        else
            token_mode="custom"
            token_value="$user_token"
            msg_ok "使用自定义令牌 (长度: %d)" "${#user_token}"
        fi
    fi
    local backup; backup=$(backup_config)
    [[ -n "$backup" ]] && msg_ok "已备份: %s" "$backup"
    mkdir -p "$(dirname "$cfg")"
    local gw_token=""
    if has_cmd python3; then
        local py_result
        py_result=$(OC_TOKEN_MODE="$token_mode" OC_TOKEN_VALUE="$token_value" python3 - "$cfg" << 'PYEOF'
import json, sys, os, secrets
cfg_path = sys.argv[1]
token_mode = os.environ.get("OC_TOKEN_MODE", "auto")
token_value = os.environ.get("OC_TOKEN_VALUE", "")
VALID_BIND = ["auto", "lan", "loopback", "custom", "tailnet"]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
for bad in ["ui", "defaultProvider"]:
    cfg.pop(bad, None)
if "agents" in cfg and isinstance(cfg["agents"], dict):
    for bad_key in list(cfg["agents"].keys()):
        if bad_key not in ["defaults", "list"]:
            del cfg["agents"][bad_key]
gw = cfg.setdefault("gateway", {})
gw["mode"] = "local"
gw["bind"] = "lan"
auth = gw.setdefault("auth", {})
if token_mode == "custom" and token_value:
    auth["token"] = token_value
elif token_mode == "keep" and token_value:
    auth["token"] = token_value
else:
    auth["token"] = secrets.token_hex(24)
auth["mode"] = "token"
gw.setdefault("controlUi", {}).update({
    "allowInsecureAuth": True,
    "dangerouslyAllowHostHeaderOriginFallback": True,
    "dangerouslyDisableDeviceAuth": True
})
tmp = cfg_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
with open(tmp) as f:
    json.load(f)
os.replace(tmp, cfg_path)
print(f"TOKEN={auth['token']}")
PYEOF
)
        if [[ $? -eq 0 ]]; then
            gw_token=$(printf "%s" "$py_result" | grep '^TOKEN=' | cut -d= -f2)
            fix_docker_ownership
            case "$token_mode" in
                custom) msg_ok "自定义令牌已写入" ;;
                keep)   msg_ok "现有令牌已保留" ;;
                auto)   msg_ok "自动生成的令牌已写入" ;;
            esac
        else
            msg_fail "写入失败"; wait_and_return 2; return 0
        fi
    fi
    printf "\n"; msg_step "运行 doctor --fix..."
    openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
    printf "\n"; msg_step "验证配置..."
    local vout; vout=$(openclaw_cmd config validate 2>&1)
    if printf "%s" "$vout" | grep -qiE "Invalid input"; then
        msg_warn "验证有警告,清理中..."
        sanitize_config_for_schema | sed 's/^/  /'
        openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
    else
        msg_ok "验证通过"
    fi
    printf "\n"; msg_step "重启 Gateway..."
    service_restart
    wait_gateway_ready 20
    local local_ip; local_ip=$(get_local_ip)
    local token_qs=""; [[ -n "$gw_token" ]] && token_qs="?token=${gw_token}"
    printf "\n${GREEN}${BOLD}局域网 UI 访问信息${NC}\n"
    print_line
    printf "  ${BOLD}本机:${NC}    ${CYAN}http://127.0.0.1:%s${NC}\n" "$OPENCLAW_PORT"
    printf "  ${BOLD}局域网:${NC}  ${CYAN}http://%s:%s%s${NC}\n" "$local_ip" "$OPENCLAW_PORT" "$token_qs"
    if [[ -n "$gw_token" ]]; then
        printf "\n  ${BOLD}WebSocket:${NC}  ${YELLOW}ws://%s:%s${NC}\n" "$local_ip" "$OPENCLAW_PORT"
        printf "  ${BOLD}网关令牌:${NC}   ${YELLOW}%s${NC}\n" "$gw_token"
        printf "  ${BOLD}令牌类型:${NC}   "
        case "$token_mode" in
            custom) printf "${YELLOW}自定义${NC}\n" ;;
            keep)   printf "${CYAN}保留原有${NC}\n" ;;
            auto)   printf "${GREEN}自动生成${NC}\n" ;;
        esac
    fi
    printf "\n  ${RED}警告: 勿暴露公网!${NC}\n"
    print_line
    wait_and_return 5
    return 0
}
install_plugins() {
    msg_title "安装插件"
    if ! is_openclaw_installed; then
        msg_fail "未安装"; wait_and_return 2; return 0
    fi
    printf "  ${BOLD}1)${NC} 微信\n"
    printf "  ${BOLD}2)${NC} 飞书\n"
    printf "  ${BOLD}3)${NC} 全部\n"
    printf "  ${BOLD}0)${NC} 返回\n\n"
    printf "${BOLD}选择: ${NC}"
    local choice; read_input choice "0"
    case "$choice" in
        1) _install_single_plugin "微信" "$WECHAT_PLUGIN_PKG" ;;
        2) _install_single_plugin "飞书" "$FEISHU_PLUGIN_PKG" ;;
        3)
            _install_single_plugin "微信" "$WECHAT_PLUGIN_PKG"
            _install_single_plugin "飞书" "$FEISHU_PLUGIN_PKG"
            ;;
        0) return 0 ;;
    esac
    wait_and_return 3
    return 0
}
_install_single_plugin() {
    local name="$1" pkg="$2"
    printf "\n"; msg_step "安装 %s..." "$name"
    if openclaw_cmd plugins install "${pkg}" --force 2>&1 | tee -a "$LOG_FILE"; then
        msg_ok "%s 成功" "$name"
    else
        msg_fail "%s 失败" "$name"
    fi
}
fetch_docker_tags() {
    local repo="$1"
    local url="https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=30&ordering=last_updated"
    local raw
    raw=$(curl -s --max-time 8 --connect-timeout 3 "$url" 2>/dev/null || printf "")
    [[ -z "$raw" ]] && return 1
    has_cmd python3 || return 1
    python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    seen=set(); tags=[]
    for t in d.get('results',[]):
        n=t['name']
        if n in ('latest','main','slim','main-slim','extended-stable','extended-stable-slim'): continue
        if 'beta' in n or 'browser' in n: continue
        if n.endswith(('-amd64','-arm64','-slim-amd64','-slim-arm64')): continue
        if n not in seen: seen.add(n); tags.append(n)
        if len(tags)>=5: break
    print('\\n'.join(tags))
except: pass
" <<< "$raw" 2>/dev/null
}
select_docker_image_source() {
    detect_region
    if is_china; then
        msg_info "国内网络,选择镜像源..."
        printf "\n"
        printf "  ${BOLD}1)${NC} dr34m/openclaw     ${GREEN}(每10分钟同步,推荐)${NC}\n"
        printf "  ${BOLD}2)${NC} 1panel/openclaw    ${DIM}(1Panel生态)${NC}\n"
        printf "  ${BOLD}3)${NC} alpine/openclaw    ${DIM}(社区镜像)${NC}\n"
        printf "  ${BOLD}4)${NC} openclaw/openclaw  ${DIM}(Docker Hub官方)${NC}\n"
        printf "  ${BOLD}5)${NC} ghcr.io 官方       ${DIM}(需科学上网)${NC}\n\n"
        printf "${BOLD}选择 [1-5] (默认: 1): ${NC}"
        local sc; read_input sc "1"
        case "$sc" in
            2) G_DOCKER_IMAGE="$DOCKER_IMAGES_1PANEL" ;;
            3) G_DOCKER_IMAGE="$DOCKER_IMAGES_ALPINE" ;;
            4) G_DOCKER_IMAGE="$DOCKER_IMAGES_OFFICIAL" ;;
            5) G_DOCKER_IMAGE="$DOCKER_IMAGES_GHCR" ;;
            *) G_DOCKER_IMAGE="$DOCKER_IMAGES_DR34M" ;;
        esac
    else
        printf "\n"
        printf "  ${BOLD}1)${NC} ghcr.io 官方       ${GREEN}(推荐)${NC}\n"
        printf "  ${BOLD}2)${NC} Docker Hub 官方\n"
        printf "  ${BOLD}3)${NC} dr34m/openclaw     ${DIM}(社区镜像)${NC}\n\n"
        printf "${BOLD}选择 [1-3] (默认: 1): ${NC}"
        local sc; read_input sc "1"
        case "$sc" in
            2) G_DOCKER_IMAGE="$DOCKER_IMAGES_OFFICIAL" ;;
            3) G_DOCKER_IMAGE="$DOCKER_IMAGES_DR34M" ;;
            *) G_DOCKER_IMAGE="$DOCKER_IMAGES_GHCR" ;;
        esac
    fi
    msg_ok "镜像源: %s" "$G_DOCKER_IMAGE"
}
select_docker_version() {
    local repo="$G_DOCKER_IMAGE"
    [[ "$repo" =~ ^ghcr\.io/ ]] && repo="$DOCKER_IMAGES_OFFICIAL"
    printf "\n${CYAN}${BOLD}版本选择:${NC}\n" >&2
    printf "  ${BOLD}1)${NC} latest ${GREEN}(推荐,最快)${NC}\n" >&2
    printf "  ${BOLD}2)${NC} 探测 Docker Hub 最近版本 ${YELLOW}(可能较慢)${NC}\n" >&2
    printf "  ${BOLD}3)${NC} 手动输入 tag\n" >&2
    printf "\n${BOLD}选择 [1-3] (默认: 1): ${NC}" >&2
    local vc; read_input vc "1"
    case "$vc" in
        2)
            msg_info_err "获取 Docker Hub 最近版本 (最多 8 秒)..."
            local tags_raw; tags_raw=$(fetch_docker_tags "$repo")
            if [[ -z "$tags_raw" ]]; then
                msg_warn_err "无法获取版本列表,使用 latest"
                printf "latest"
                return
            fi
            local -a tags_arr=()
            while IFS= read -r line; do
                [[ -n "$line" ]] && tags_arr+=("$line")
            done <<< "$tags_raw"
            if [[ ${#tags_arr[@]} -eq 0 ]]; then
                printf "latest"
                return
            fi
            printf "\n${CYAN}${BOLD}选择具体版本:${NC}\n" >&2
            printf "  ${BOLD}0)${NC} latest ${GREEN}(最新稳定)${NC}\n" >&2
            local i=1
            for t in "${tags_arr[@]}"; do
                local label=""
                [[ $i -eq 1 ]] && label=" ${GREEN}[最新发布]${NC}"
                printf "  ${BOLD}%d)${NC} %s%b\n" "$i" "$t" "$label" >&2
                ((i++))
            done
            printf "\n${BOLD}选择 [0-%d] (默认: 0): ${NC}" "$((i-1))" >&2
            local sv; read_input sv "0"
            if [[ "$sv" == "0" ]]; then
                printf "latest"
            elif [[ "$sv" =~ ^[0-9]+$ ]] && (( sv >= 1 && sv <= ${#tags_arr[@]} )); then
                printf "%s" "${tags_arr[$((sv-1))]}"
            else
                printf "latest"
            fi
            ;;
        3)
            printf "${BOLD}输入 tag (默认: latest): ${NC}" >&2
            local mt; read_input mt "latest"
            printf "%s" "$mt"
            ;;
        *)
            printf "latest"
            ;;
    esac
}
deploy_docker() {
    msg_title "Docker 部署"
    detect_system
    detect_region
    if ! has_cmd docker; then
        msg_warn "Docker 未安装"
        confirm "安装 Docker?" || { wait_and_return 2; return 0; }
        _install_docker || { wait_and_return 3; return 0; }
    fi
    printf "${CYAN}Docker:${NC} %s\n\n" "$(docker --version 2>/dev/null || printf 'unknown')"
    if docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        local container_status
        container_status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || printf "unknown")
        printf "${CYAN}已有容器:${NC} ${BOLD}%s${NC}\n\n" "$container_status"
        printf "  ${BOLD}1)${NC} 启动  ${BOLD}2)${NC} 停止  ${BOLD}3)${NC} 重启\n"
        printf "  ${BOLD}4)${NC} 删除重部署  ${BOLD}5)${NC} 日志  ${BOLD}6)${NC} Shell\n"
        printf "  ${BOLD}0)${NC} 返回\n\n"
        printf "${BOLD}选择: ${NC}"
        local dc; read_input dc "0"
        case "$dc" in
            1) docker start "$DOCKER_CONTAINER" && msg_ok "已启动" ;;
            2) docker stop  "$DOCKER_CONTAINER" && msg_ok "已停止" ;;
            3) docker restart "$DOCKER_CONTAINER" && msg_ok "已重启" ;;
            4) confirm "确认删除容器?" && { docker rm -f "$DOCKER_CONTAINER"; _docker_run; } ;;
            5) trap 'printf "\n"; msg_info "退出"' INT; docker logs -f "$DOCKER_CONTAINER" 2>&1 || true; trap - INT ;;
            6) docker exec -it "$DOCKER_CONTAINER" /bin/sh 2>/dev/null || docker exec -it "$DOCKER_CONTAINER" /bin/bash 2>/dev/null ;;
            0) return 0 ;;
        esac
    else
        _docker_run
    fi
    wait_and_return 3
    return 0
}
_docker_run() {
    select_docker_image_source
    local tag; tag=$(select_docker_version)
    local image="${G_DOCKER_IMAGE}:${tag}"
    msg_ok "版本: %s" "$tag"
    printf "\n"
    printf "  端口 (默认: %s): " "$OPENCLAW_PORT"
    local port; read_input port "$OPENCLAW_PORT"
    printf "  数据目录 (默认: %s): " "$DOCKER_DATA_DIR"
    local data_dir; read_input data_dir "$DOCKER_DATA_DIR"
    printf "\n${CYAN}${BOLD}网络模式:${NC}\n"
    printf "  ${BOLD}1)${NC} bridge + host.docker.internal ${DIM}(默认)${NC}\n"
    printf "  ${BOLD}2)${NC} host                          ${DIM}(容器共享宿主机网络)${NC}\n\n"
    printf "${CYAN}选择 [1-2] (默认: 1): ${NC}"
    local nm; read_input nm "1"
    local network_mode="bridge"
    [[ "$nm" == "2" ]] && network_mode="host"
    local extra_opts=""
    confirm "启用局域网 UI 访问?" && extra_opts="--lan"
    mkdir -p "$data_dir"
    _docker_deploy_internal "$port" "$data_dir" "$extra_opts" "$network_mode" "$image"
}
_docker_deploy_internal() {
    local port="$1" data_dir="$2" extra="$3" network_mode="$4" image="$5"
    local gw_token
    gw_token=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | xxd -p | tr -d '\n' || printf "%s" "$(date +%s%N)")
    mkdir -p "${data_dir}/.openclaw" "${data_dir}/workspace"
    chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}" 2>/dev/null \
        || $SUDO chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}" 2>/dev/null || true
    msg_step "拉取镜像 %s..." "$image"
    if docker pull "${image}" 2>&1 | tail -3; then
        msg_ok "拉取成功"
    else
        msg_warn "拉取失败,尝试备用镜像..."
        local fallbacks=("$DOCKER_IMAGES_DR34M:latest" "$DOCKER_IMAGES_1PANEL:latest" "$DOCKER_IMAGES_ALPINE:latest" "$DOCKER_IMAGES_OFFICIAL:latest")
        local pulled=false
        for fb in "${fallbacks[@]}"; do
            [[ "$fb" == "$image" ]] && continue
            if docker pull "$fb" 2>&1 | tail -2; then
                image="$fb"; pulled=true; break
            fi
        done
        $pulled || { msg_fail "所有镜像拉取失败"; return 1; }
    fi
    local container_config="${data_dir}/.openclaw/openclaw.json"
    local bind_v="loopback"
    [[ "$extra" == "--lan" ]] && bind_v="lan"
    msg_info "准备配置 (bind: %s)..." "$bind_v"
    local need_create=true
    if [[ -f "$container_config" ]] && has_cmd python3; then
        if python3 - "$container_config" << 'PYEOF' 2>/dev/null
import json, sys
c=json.load(open(sys.argv[1]))
assert c.get('gateway',{}).get('bind') in ['auto','lan','loopback','custom','tailnet']
assert c.get('gateway',{}).get('mode') == 'local'
PYEOF
        then
            msg_info "现有配置有效,保留"
            need_create=false
            if [[ "$extra" == "--lan" ]]; then
                python3 - "$container_config" << 'PYEOF'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["gateway"]["bind"] = "lan"
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False)
PYEOF
            fi
        else
            msg_warn "现有配置无效,备份并覆盖"
            cp "$container_config" "${container_config}.bak.$(date +%s)" 2>/dev/null || true
        fi
    fi
    if $need_create; then
        local content
        content=$(cat << EOF
{
  "gateway": {"mode": "local", "bind": "${bind_v}"},
  "models": {"mode": "merge", "providers": {}},
  "agents": {
    "defaults": {"workspace": "~/.openclaw/workspace"},
    "list": [{"id": "main", "default": true}]
  }
}
EOF
)
        atomic_write_json "$container_config" "$content"
    fi
    chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}/.openclaw" 2>/dev/null \
        || $SUDO chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}/.openclaw" 2>/dev/null || true
    msg_step "启动容器 (网络: %s)..." "$network_mode"
    local run_cmd=(
        docker run -d
        --name "$DOCKER_CONTAINER"
        --restart unless-stopped
        -v "${data_dir}/.openclaw:/home/node/.openclaw"
        -v "${data_dir}/workspace:/home/node/workspace"
        -e "OPENCLAW_GATEWAY_TOKEN=${gw_token}"
    )
    if [[ "$network_mode" == "host" ]]; then
        run_cmd+=(--network host)
    else
        run_cmd+=(-p "${port}:18789" --add-host=host.docker.internal:host-gateway)
    fi
    run_cmd+=("${image}")
    if "${run_cmd[@]}" 2>&1 | tail -2; then
        sleep 3
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || printf "unknown")
        if [[ "$status" != "running" ]]; then
            msg_fail "容器启动后退出 (状态: %s)" "$status"
            printf "\n${YELLOW}${BOLD}容器日志:${NC}\n"
            print_line
            docker logs --tail 30 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
            print_line
            return 1
        fi
        msg_ok "容器已启动"
        wait_gateway_ready 25
        if [[ "$extra" == "--lan" ]]; then
            msg_step "配置局域网 controlUi..."
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.bind lan >/dev/null 2>&1 || true
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.controlUi.allowInsecureAuth true >/dev/null 2>&1 || true
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true >/dev/null 2>&1 || true
            docker restart "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
            sleep 3
            msg_ok "局域网模式已启用"
        fi
        local local_ip; local_ip=$(get_local_ip)
        printf "\n${GREEN}${BOLD}Docker 部署完成!${NC}\n"
        printf "  ${BOLD}镜像:${NC}   %s\n" "$image"
        printf "  ${BOLD}本机:${NC}   ${CYAN}http://127.0.0.1:%s${NC}\n" "$port"
        printf "  ${BOLD}局域网:${NC} ${CYAN}http://%s:%s${NC}\n" "$local_ip" "$port"
        printf "  ${BOLD}网络:${NC}   %s\n" "$network_mode"
        printf "\n${CYAN}提示:${NC}\n"
        printf "  - 访问宿主机服务用: host.docker.internal:端口\n"
        printf "  - 菜单 [2] 配置 API\n"
        log "Docker deployed (network: $network_mode)"
    else
        msg_fail "启动失败"
    fi
}
_install_docker() {
    detect_system
    msg_step "安装 Docker..."
    case "$OS" in
        debian)
            safe_run "apt update"   $SUDO apt-get update -qq
            safe_run "依赖"         $SUDO apt-get install -y ca-certificates curl gnupg lsb-release
            safe_run "Docker"       bash -c "curl -fsSL https://get.docker.com | $SUDO sh" ;;
        rhel|fedora)
            safe_run "Docker"       bash -c "curl -fsSL https://get.docker.com | $SUDO sh" ;;
        arch)
            safe_run "Docker"       $SUDO pacman -S --noconfirm docker ;;
        alpine)
            safe_run "Docker"       $SUDO apk add docker ;;
        macos)
            msg_info "请手动安装 Docker Desktop"
            return 1 ;;
        *)
            safe_run "Docker"       bash -c "curl -fsSL https://get.docker.com | $SUDO sh" ;;
    esac
    case "$SERVICE_MANAGER" in
        systemd) $SUDO systemctl enable --now docker 2>/dev/null || true; $SUDO usermod -aG docker "$USER" 2>/dev/null || true ;;
        openrc)  $SUDO rc-update add docker 2>/dev/null || true; $SUDO service docker start 2>/dev/null || true ;;
    esac
    has_cmd docker && msg_ok "Docker 安装成功" || { msg_fail "安装失败"; return 1; }
}
_try_systemd() {
    local svc
    for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
        $SUDO systemctl "$@" "$svc" 2>/dev/null && return 0
        systemctl --user "$@" "$svc" 2>/dev/null && return 0
    done
    return 1
}
_try_openrc() {
    local action="$1"
    local svc
    for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
        $SUDO rc-service "$svc" "$action" 2>/dev/null && return 0
    done
    return 1
}
_try_launchd() {
    local action="$1" plist
    for plist in "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist" \
                 "$HOME/Library/LaunchAgents/com.openclaw.gateway.plist"; do
        [[ ! -f "$plist" ]] && continue
        case "$action" in
            start)   launchctl load   "$plist" 2>/dev/null && return 0 ;;
            stop)    launchctl unload "$plist" 2>/dev/null && return 0 ;;
            restart) launchctl unload "$plist" 2>/dev/null; launchctl load "$plist" 2>/dev/null && return 0 ;;
            status)  launchctl list 2>/dev/null | grep -i openclaw && return 0 ;;
        esac
    done
    return 1
}
service_start() {
    detect_system
    if is_docker_mode; then
        docker start "$DOCKER_CONTAINER" 2>/dev/null || true
        return 0
    fi
    has_cmd openclaw || return 1
    ensure_config
    pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
    rm -f "$OPENCLAW_CONFIG_DIR/gateway.lock" "$OPENCLAW_CONFIG_DIR"/*.pid 2>/dev/null || true
    sleep 1
    local port_pid=""
    if has_cmd lsof; then
        port_pid=$(lsof -ti :$OPENCLAW_PORT 2>/dev/null | head -1)
    elif has_cmd ss; then
        port_pid=$(ss -lntp 2>/dev/null | grep ":$OPENCLAW_PORT" | grep -oP 'pid=\K[0-9]+' | head -1)
    fi
    [[ -n "$port_pid" ]] && { kill -9 "$port_pid" 2>/dev/null || $SUDO kill -9 "$port_pid" 2>/dev/null || true; sleep 2; }
    case "$SERVICE_MANAGER" in
        systemd) _try_systemd start && return 0 ;;
        launchd) _try_launchd start && return 0 ;;
        openrc)  _try_openrc start && return 0 ;;
    esac
    mkdir -p "$OPENCLAW_LOG_DIR"
    local out_log="$OPENCLAW_LOG_DIR/gateway.out"
    : > "$out_log"
    local openclaw_bin; openclaw_bin=$(command -v openclaw)
    [[ -z "$openclaw_bin" ]] && return 1
    nohup "$openclaw_bin" gateway run > "$out_log" 2>&1 &
}
service_stop() {
    detect_system
    if is_docker_mode; then
        docker stop "$DOCKER_CONTAINER" 2>/dev/null || true
        return 0
    fi
    case "$SERVICE_MANAGER" in
        systemd) _try_systemd stop 2>/dev/null ;;
        launchd) _try_launchd stop 2>/dev/null ;;
        openrc)  _try_openrc stop 2>/dev/null ;;
    esac
    has_cmd openclaw && openclaw gateway stop 2>/dev/null || true
    pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
}
service_restart() { service_stop; sleep 2; service_start; }
service_status() {
    detect_system
    if is_docker_mode; then
        docker inspect --format='Status: {{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null
        printf "\n"
        docker logs --tail 15 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
        return 0
    fi
    case "$SERVICE_MANAGER" in
        systemd) _try_systemd status --no-pager ;;
        launchd) _try_launchd status ;;
        openrc)  _try_openrc status ;;
    esac
}
manage_service() {
    local action="$1"
    detect_system
    local docker_mode=false
    is_docker_mode && docker_mode=true
    case "$action" in
        start)
            msg_step "启动 Gateway..."
            if $docker_mode; then
                msg_info "Docker 模式启动..."
                docker start "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
                sleep 5
                local status; status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || printf "unknown")
                if [[ "$status" == "running" ]]; then
                    wait_gateway_ready 20
                    show_dashboard_info
                else
                    msg_fail "容器状态: %s" "$status"
                    docker logs --tail 25 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
                fi
                wait_and_return 5; return 0
            fi
            if ! json_is_valid; then
                msg_fail "配置损坏,请先修复"; wait_and_return 3; return 0
            fi
            msg_step "运行 doctor --fix..."
            openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
            msg_step "验证配置..."
            local validate_out; validate_out=$(openclaw_cmd config validate 2>&1)
            if printf "%s" "$validate_out" | grep -qiE "Invalid input|invalid config"; then
                msg_warn "验证失败:"
                printf "%s\n" "$validate_out" | grep -iE "×|invalid|allowed" | head -8 | sed 's/^/  /'
                printf "\n"; msg_step "自动清理..."
                sanitize_config_for_schema | sed 's/^/  /'
                openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
                sleep 1
            else
                msg_ok "配置有效"
            fi
            service_start
            wait_gateway_ready 30
            if gateway_health_check; then
                show_dashboard_info
            else
                msg_fail "Gateway 启动失败"
                printf "\n${YELLOW}${BOLD}错误日志:${NC}\n"
                print_line
                tail -25 "$OPENCLAW_LOG_DIR/gateway.out" 2>/dev/null | sed 's/^/  /' || printf "  (无日志)\n"
                print_line
                printf "\n${CYAN}修复建议:${NC}\n"
                printf "  1) 菜单 [8] 修复配置\n"
                printf "  2) 运行: ${YELLOW}openclaw doctor --fix${NC}\n"
            fi
            ;;
        stop)
            confirm "确认停止?" && { service_stop; msg_ok "已停止"; } || msg_info "已取消"
            ;;
        restart)
            msg_step "重启..."
            if $docker_mode; then
                docker restart "$DOCKER_CONTAINER" >/dev/null 2>&1
                sleep 5
                local st; st=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || printf "unknown")
                if [[ "$st" == "running" ]]; then
                    wait_gateway_ready 20
                    show_dashboard_info
                else
                    msg_fail "重启失败,状态: %s" "$st"
                    docker logs --tail 20 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
                fi
            else
                service_stop
                sleep 2
                service_start
                wait_gateway_ready 25
                show_dashboard_info
            fi
            ;;
        status)
            msg_step "状态:"
            printf "\n"
            service_status
            printf "\n${CYAN}端口 (%s):${NC}\n" "$OPENCLAW_PORT"
            ss -lntp 2>/dev/null | grep ":$OPENCLAW_PORT" | sed 's/^/  /' || printf "  未监听\n"
            load_config_from_file
            show_dashboard_info
            ;;
    esac
    wait_and_return 5
    return 0
}
show_dashboard_info() {
    local local_ip; local_ip=$(get_local_ip)
    local public_ip
    public_ip=$(curl -s --max-time 3 --connect-timeout 2 https://api.ipify.org 2>/dev/null \
             || curl -s --max-time 3 --connect-timeout 2 https://ifconfig.me 2>/dev/null || printf "无法获取")
    [[ -z "$G_DEFAULT_PROVIDER" ]] && load_config_from_file
    local bind_mode="loopback" token=""
    local cfg; cfg=$(get_active_config_path)
    if [[ -f "$cfg" ]] && json_is_valid && has_cmd python3; then
        bind_mode=$(python3 - "$cfg" << 'PYEOF' 2>/dev/null
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    print(c.get('gateway', {}).get('bind', 'loopback'))
except:
    print('loopback')
PYEOF
)
        token=$(get_gateway_token)
    fi
    local token_qs=""
    [[ -n "$token" ]] && token_qs="?token=${token}"
    printf "\n${GREEN}${BOLD}=================================================${NC}\n"
    printf "${GREEN}${BOLD}  OpenClaw 访问信息${NC}\n"
    printf "${GREEN}${BOLD}=================================================${NC}\n"
    printf "  ${BOLD}本机:${NC}    ${CYAN}http://127.0.0.1:%s%s${NC}\n" "$OPENCLAW_PORT" "$token_qs"
    if [[ "$bind_mode" == "lan" ]]; then
        printf "  ${BOLD}局域网:${NC}  ${CYAN}http://%s:%s%s${NC} ${GREEN}(已启用)${NC}\n" "$local_ip" "$OPENCLAW_PORT" "$token_qs"
    else
        printf "  ${BOLD}局域网:${NC}  ${DIM}未启用 (菜单[4]启用)${NC}\n"
    fi
    printf "  ${BOLD}SSH隧道:${NC} ${YELLOW}ssh -L %s:localhost:%s user@%s${NC}\n" "$OPENCLAW_PORT" "$OPENCLAW_PORT" "$public_ip"
    printf "  ${BOLD}bind:${NC}    %s\n" "$bind_mode"
    if [[ -n "$token" ]]; then
        printf "  ${BOLD}Token:${NC}   ${YELLOW}%s${NC}\n" "$token"
    fi
    if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
        local dm="${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
        dm="${dm%%,*}"
        printf "  ${BOLD}默认AI:${NC}  ${CYAN}%s${NC} -> %s\n" "$G_DEFAULT_PROVIDER" "$dm"
    fi
    printf "  ${RED}警告: 勿暴露公网!${NC}\n"
    printf "${GREEN}${BOLD}=================================================${NC}\n\n"
    if [[ -n "$token" ]] && [[ "$bind_mode" == "lan" ]]; then
        printf "${CYAN}${BOLD}浏览器 UI 登录信息:${NC}\n"
        printf "  ${BOLD}WebSocket:${NC} ${YELLOW}ws://%s:%s${NC}\n" "$local_ip" "$OPENCLAW_PORT"
        printf "  ${BOLD}令牌:${NC}      ${YELLOW}%s${NC}\n\n" "$token"
    fi
}
show_version() {
    msg_title "版本信息"
    is_openclaw_installed || { msg_fail "未安装"; wait_and_return 2; return 0; }
    print_line
    printf "  ${BOLD}OpenClaw${NC}    : %s\n" "$(openclaw_cmd --version 2>/dev/null || printf '未知')"
    printf "  ${BOLD}Node.js${NC}     : %s\n" "$(node -v 2>/dev/null || printf '未安装')"
    printf "  ${BOLD}npm${NC}         : v%s\n" "$(npm -v 2>/dev/null || printf '未安装')"
    printf "  ${BOLD}Docker${NC}      : %s\n" "$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || printf '未安装')"
    printf "  ${BOLD}部署方式${NC}    : %s\n" "$(_detect_deploy_mode)"
    printf "  ${BOLD}脚本版本${NC}    : %s\n" "$SCRIPT_VERSION"
    print_line
    printf "\n"
    msg_info "检查最新版本..."
    local latest current
    latest=$(get_openclaw_latest_version)
    current=$(openclaw_cmd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || printf "0.0.0")
    printf "  当前: %s  最新: %s\n" "$current" "${latest:-无法获取}"
    if [[ -n "$latest" && "$latest" != "$current" ]]; then
        confirm "升级到 %s?" "$latest" && {
            if is_docker_mode; then
                docker pull "${DOCKER_IMAGES_GHCR}:latest" && docker rm -f "$DOCKER_CONTAINER" && _docker_run
            else
                local npm_args=""
                is_china && npm_args="--registry=${NPM_MIRROR_CN}"
                npm install -g openclaw@latest $npm_args 2>&1 | tail -5 && msg_ok "已升级" || msg_fail "升级失败"
            fi
        }
    else
        msg_ok "已是最新版本"
    fi
    wait_and_return 3
    return 0
}
diagnose_and_fix() {
    msg_title "诊断与修复"
    detect_system
    local issues=0 fixed=0
    local cfg; cfg=$(get_active_config_path)
    printf "${CYAN}${BOLD}检测中...${NC}\n"
    printf "${DIM}模式: %s  配置: %s${NC}\n\n" "$(_detect_deploy_mode)" "$cfg"
    printf "  [1/10] OpenClaw... "
    if is_openclaw_installed; then
        printf "${GREEN}[OK] %s${NC}\n" "$(openclaw_cmd --version 2>/dev/null)"
    else
        printf "${RED}[FAIL] 未安装${NC}\n"; ((issues++))
    fi
    printf "  [2/10] 配置存在... "
    if [[ -f "$cfg" ]]; then
        printf "${GREEN}[OK]${NC}\n"
    else
        printf "${RED}[FAIL] 不存在${NC}\n"; ((issues++))
        confirm "  创建?" && { create_minimal_config; ((fixed++)); }
    fi
    printf "  [3/10] JSON 有效... "
    if [[ -f "$cfg" ]]; then
        if json_is_valid; then
            printf "${GREEN}[OK]${NC}\n"
        else
            printf "${RED}[FAIL] 损坏${NC}\n"; ((issues++))
            confirm "  修复?" && { backup_config; create_minimal_config; ((fixed++)); }
        fi
    else
        printf "${DIM}跳过${NC}\n"
    fi
    printf "  [4/10] gateway.bind... "
    if [[ -f "$cfg" ]] && json_is_valid && has_cmd python3; then
        local bind_v
        bind_v=$(python3 - "$cfg" << 'PYEOF' 2>/dev/null
import json, sys
try:
    c=json.load(open(sys.argv[1]))
    print(c.get('gateway',{}).get('bind',''))
except: print('')
PYEOF
)
        if [[ "$bind_v" =~ ^(auto|lan|loopback|custom|tailnet)$ ]]; then
            printf "${GREEN}[OK] bind=%s${NC}\n" "$bind_v"
        else
            printf "${RED}[FAIL] bind='%s' 无效${NC}\n" "$bind_v"; ((issues++))
            confirm "  修复?" && { sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        fi
    else
        printf "${DIM}跳过${NC}\n"
    fi
    printf "  [5/10] agents 结构... "
    if [[ -f "$cfg" ]] && json_is_valid && has_cmd python3; then
        local agents_ok
        agents_ok=$(python3 - "$cfg" << 'PYEOF' 2>/dev/null
import json, sys
try:
    c=json.load(open(sys.argv[1]))
    agents = c.get('agents', {})
    if not agents: print('MISSING')
    elif not isinstance(agents, dict): print('BAD_TYPE')
    elif set(agents.keys()) - {'defaults', 'list'}:
        print('BAD_KEYS:' + ','.join(set(agents.keys()) - {'defaults', 'list'}))
    else:
        print('OK')
except Exception as e:
    print('ERROR:' + str(e))
PYEOF
)
        if [[ "$agents_ok" == "OK" ]]; then
            printf "${GREEN}[OK]${NC}\n"
        elif [[ "$agents_ok" == "MISSING" ]]; then
            printf "${RED}[FAIL] 缺失${NC}\n"; ((issues++))
            confirm "  修复?" && { sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        else
            printf "${RED}[FAIL] %s${NC}\n" "$agents_ok"; ((issues++))
            confirm "  修复?" && { sanitize_config_for_schema | sed 's/^/    /'; openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true; ((fixed++)); }
        fi
    else
        printf "${DIM}跳过${NC}\n"
    fi
    printf "  [6/10] openclaw schema... "
    if is_openclaw_installed && json_is_valid; then
        local schema_out
        schema_out=$(openclaw_cmd config validate 2>&1)
        if printf "%s" "$schema_out" | grep -qiE "Invalid input"; then
            printf "${RED}[FAIL]${NC}\n"; ((issues++))
            printf "%s\n" "$schema_out" | grep -iE "×|invalid|allowed" | head -5 | sed 's/^/    /'
            confirm "  自动修复?" && { openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true; sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        else
            printf "${GREEN}[OK]${NC}\n"
        fi
    else
        printf "${DIM}跳过${NC}\n"
    fi
    printf "  [7/10] Docker URL 兼容... "
    if is_docker_mode && [[ -f "$cfg" ]] && json_is_valid && has_cmd python3; then
        local lan_urls
        lan_urls=$(python3 - "$cfg" << 'PYEOF' 2>/dev/null
import json, re, sys
try:
    c = json.load(open(sys.argv[1]))
    p = re.compile(r'^https?://(127\.|localhost|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)')
    bad = []
    for name, pcfg in c.get('models', {}).get('providers', {}).items():
        url = pcfg.get('baseUrl', '') if isinstance(pcfg, dict) else ''
        if p.match(url):
            bad.append(name)
    print(','.join(bad))
except: print('')
PYEOF
)
        if [[ -z "$lan_urls" ]]; then
            printf "${GREEN}[OK]${NC}\n"
        else
            printf "${RED}[FAIL] LAN URL: %s${NC}\n" "$lan_urls"; ((issues++))
            confirm "  转换为 host.docker.internal?" && { convert_urls_for_docker_mode | sed 's/^/    /'; ((fixed++)); }
        fi
    else
        printf "${DIM}跳过${NC}\n"
    fi
    printf "  [8/10] Agent 认证... "
    if is_openclaw_installed; then
        local agent_base
        if is_docker_mode; then
            agent_base="${DOCKER_DATA_DIR}/.openclaw/agents"
        else
            agent_base="$OPENCLAW_AGENTS_DIR"
        fi
        local auth_file="$agent_base/main/agent/auth-profiles.json"
        local sqlite_file="$agent_base/main/agent/openclaw-agent.sqlite"
        if [[ -f "$auth_file" ]] || [[ -f "$sqlite_file" ]]; then
            printf "${GREEN}[OK]${NC}\n"
        else
            printf "${RED}[FAIL] 缺失${NC}\n"; ((issues++))
        fi
    else
        printf "${DIM}跳过${NC}\n"
    fi
    printf "  [9/10] Gateway 端口... "
    if gateway_health_check; then
        printf "${GREEN}[OK] 响应${NC}\n"
    else
        printf "${YELLOW}[WARN] 无响应${NC}\n"; ((issues++))
        confirm "  启动?" && { service_start; wait_gateway_ready 15 && ((fixed++)); }
    fi
    printf "  [10/10] 磁盘空间... "
    local da; da=$(df "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || printf "9999999")
    if [[ "$da" -gt 1048576 ]]; then
        printf "${GREEN}[OK] %s${NC}\n" "$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
    else
        printf "${RED}[FAIL] 空间不足${NC}\n"; ((issues++))
    fi
    if is_openclaw_installed; then
        printf "\n"; msg_step "运行 openclaw doctor --fix..."
        openclaw_cmd doctor --fix 2>&1 | tail -15 | sed 's/^/    /' || true
    fi
    printf "\n"; print_line
    printf "${BOLD}结果:${NC}  问题 ${RED}%d${NC}  修复 ${GREEN}%d${NC}\n" "$issues" "$fixed"
    print_line
    wait_and_return 3
    return 0
}
view_logs() {
    msg_title "日志查看"
    printf "  ${BOLD}1)${NC} 实时 Gateway 日志\n"
    printf "  ${BOLD}2)${NC} systemd 日志\n"
    printf "  ${BOLD}3)${NC} 日志文件列表\n"
    printf "  ${BOLD}4)${NC} Docker 容器日志\n"
    printf "  ${BOLD}5)${NC} 脚本安装日志\n"
    printf "  ${BOLD}6)${NC} gateway.out\n"
    printf "  ${BOLD}0)${NC} 返回\n\n"
    printf "${BOLD}选择: ${NC}"
    local lc; read_input lc "0"
    case "$lc" in
        1)
            trap 'printf "\n"; msg_info "退出"' INT
            if is_docker_mode; then
                docker logs -f "$DOCKER_CONTAINER" 2>&1 || true
            else
                openclaw_cmd gateway logs --follow 2>/dev/null \
                    || openclaw_cmd logs 2>/dev/null \
                    || tail -f "${OPENCLAW_LOG_DIR}/gateway.log" 2>/dev/null \
                    || msg_fail "无法获取日志"
            fi
            trap - INT
            ;;
        2)
            detect_system
            if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
                local svc
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    $SUDO journalctl -u "$svc" -n 100 --no-pager 2>/dev/null && break
                done
            else
                msg_warn "非 systemd 系统"
            fi
            ;;
        3)
            local log_dir="$OPENCLAW_LOG_DIR"
            is_docker_mode && log_dir="${DOCKER_DATA_DIR}/.openclaw/logs"
            if [[ -d "$log_dir" ]]; then
                ls -lh "$log_dir" 2>/dev/null
                printf "\n${BOLD}文件名 (Enter查看最新): ${NC}"
                local lf; read_input lf ""
                if [[ -n "$lf" ]]; then
                    less "${log_dir}/${lf}" 2>/dev/null
                else
                    local ll; ll=$(ls -t "${log_dir}"/*.log 2>/dev/null | head -1 || printf "")
                    [[ -n "$ll" ]] && less "$ll" || msg_warn "无日志文件"
                fi
            else
                msg_warn "日志目录不存在"
            fi
            ;;
        4)
            if docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
                trap 'printf "\n"; msg_info "退出"' INT
                docker logs -f "$DOCKER_CONTAINER" 2>&1 || true
                trap - INT
            else
                msg_warn "容器未运行"
            fi
            ;;
        5)  [[ -f "$LOG_FILE" ]] && less "$LOG_FILE" || msg_warn "脚本日志不存在" ;;
        6)  [[ -f "$OPENCLAW_LOG_DIR/gateway.out" ]] && less "$OPENCLAW_LOG_DIR/gateway.out" || msg_warn "gateway.out 不存在" ;;
        0)  return 0 ;;
    esac
    wait_and_return 2
    return 0
}
uninstall_openclaw() {
    msg_title "卸载 OpenClaw"
    printf "${RED}${BOLD}警告: 此操作将卸载 OpenClaw${NC}\n\n"
    confirm "确认卸载?" || { wait_and_return 2; return 0; }
    detect_system
    if docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        docker stop "$DOCKER_CONTAINER" 2>/dev/null || true
        confirm "删除 Docker 容器?" && docker rm -f "$DOCKER_CONTAINER" 2>/dev/null
        confirm "删除 Docker 镜像?" && {
            docker rmi "${DOCKER_IMAGES_GHCR}:latest" 2>/dev/null || true
            docker rmi "${DOCKER_IMAGES_OFFICIAL}:latest" 2>/dev/null || true
        }
        confirm "删除数据目录 (%s)?" "$DOCKER_DATA_DIR" && rm -rf "$DOCKER_DATA_DIR"
    fi
    if has_cmd openclaw; then
        pkill -9 -f openclaw 2>/dev/null || true
        service_stop 2>/dev/null || true
        case "$SERVICE_MANAGER" in
            systemd)
                local svc
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    $SUDO systemctl disable "$svc" 2>/dev/null || true
                    systemctl --user disable "$svc" 2>/dev/null || true
                    $SUDO rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
                done
                $SUDO systemctl daemon-reload 2>/dev/null || true
                ;;
            launchd)
                _try_launchd stop 2>/dev/null || true
                rm -f "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist" 2>/dev/null || true
                ;;
            openrc)
                local svc
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    $SUDO rc-update del "$svc" 2>/dev/null || true
                done
                ;;
        esac
        npm uninstall -g openclaw >> "$LOG_FILE" 2>&1 || {
            local np; np=$(npm prefix -g 2>/dev/null || printf "/usr/local")
            $SUDO rm -f "${np}/bin/openclaw" 2>/dev/null || true
            $SUDO rm -rf "${np}/lib/node_modules/openclaw" 2>/dev/null || true
        }
    fi
    confirm "删除配置目录 (%s)?" "$OPENCLAW_CONFIG_DIR" && {
        rm -rf "$OPENCLAW_CONFIG_DIR"
        G_API_KEYS=(); G_API_MODELS=(); G_API_TYPES=(); G_API_URLS=()
        G_DEFAULT_PROVIDER=""
    }
    msg_ok "已卸载"
    wait_and_return 3
    return 0
}
show_command_reference() {
    msg_title "命令速查"
    local use_docker=false
    is_docker_mode && use_docker=true
    local prefix=""
    $use_docker && prefix="docker exec ${DOCKER_CONTAINER} "
    printf "${CYAN}${BOLD}服务管理${NC}\n"
    print_line
    _cmd_row "${prefix}openclaw setup"               "初始化"
    _cmd_row "${prefix}openclaw gateway run"         "前台调试"
    _cmd_row "${prefix}openclaw gateway restart"     "重启"
    _cmd_row "${prefix}openclaw gateway status"      "状态"
    _cmd_row "${prefix}openclaw dashboard --no-open" "获取 URL"
    _cmd_row "${prefix}openclaw doctor --fix"        "自动修复配置"
    printf "\n"
    if $use_docker; then
        printf "${CYAN}${BOLD}Docker 专属${NC}\n"
        print_line
        _cmd_row "docker logs -f ${DOCKER_CONTAINER}"       "实时日志"
        _cmd_row "docker restart ${DOCKER_CONTAINER}"       "重启容器"
        _cmd_row "docker exec -it ${DOCKER_CONTAINER} sh"   "进入容器"
        _cmd_row "cat ${DOCKER_DATA_DIR}/.openclaw/openclaw.json" "查看配置"
        printf "\n"
    fi
    printf "${CYAN}${BOLD}Agent 管理${NC}\n"
    print_line
    _cmd_row "${prefix}openclaw agents list"              "列出 Agent"
    _cmd_row "${prefix}openclaw agents auth list main"    "认证列表"
    _cmd_row "${prefix}openclaw agents login main"        "交互登录"
    printf "\n"
    printf "${RED}${BOLD}Schema 规范${NC}\n"
    print_line
    _cmd_row "gateway.bind 允许值"                             "auto/lan/loopback/custom/tailnet"
    _cmd_row "agents 必须包含"                                 "defaults + list"
    _cmd_row "${prefix}openclaw config set gateway.bind lan"   "启用局域网"
    printf "\n"
    wait_and_return 3
    return 0
}
_cmd_row() {
    printf "  ${CYAN}%-52s${NC} ${DIM}%s${NC}\n" "$1" "$2"
}
run_setup_wizard() {
    msg_title "setup 向导"
    if ! is_openclaw_installed; then
        msg_fail "未安装"; wait_and_return 2; return 0
    fi
    if ! json_is_valid; then
        msg_fail "配置损坏,请先修复"; wait_and_return 3; return 0
    fi
    ensure_config
    confirm "运行 openclaw setup?" || { wait_and_return 2; return 0; }
    openclaw_cmd setup </dev/tty && msg_ok "完成" || msg_warn "退出"
    confirm "重启 Gateway?" && { service_restart; wait_gateway_ready 15; }
    wait_and_return 3
    return 0
}
quick_commands() {
    msg_title "快捷命令"
    if ! is_openclaw_installed; then
        msg_fail "未安装"; wait_and_return 2; return 0
    fi
    printf "  ${BOLD}1)${NC}  openclaw setup\n"
    printf "  ${BOLD}2)${NC}  openclaw status\n"
    printf "  ${BOLD}3)${NC}  openclaw health\n"
    printf "  ${BOLD}4)${NC}  openclaw doctor --fix\n"
    printf "  ${BOLD}5)${NC}  openclaw logs\n"
    printf "  ${BOLD}6)${NC}  openclaw models status\n"
    printf "  ${BOLD}7)${NC}  openclaw models list\n"
    printf "  ${BOLD}8)${NC}  openclaw config validate\n"
    printf "  ${BOLD}9)${NC}  openclaw dashboard --no-open\n"
    printf "  ${BOLD}10)${NC} openclaw agents list\n"
    printf "  ${BOLD}11)${NC} openclaw gateway run (前台)\n"
    printf "  ${BOLD}12)${NC} 验证配置\n"
    printf "  ${BOLD}13)${NC} 配置自定义 API\n"
    printf "  ${BOLD}0)${NC}  返回\n\n"
    printf "${BOLD}选择: ${NC}"
    local qc; read_input qc "0"
    printf "\n"
    case "$qc" in
        1)  openclaw_cmd setup </dev/tty 2>&1 ;;
        2)  openclaw_cmd status ;;
        3)  openclaw_cmd health ;;
        4)  openclaw_cmd doctor --fix ;;
        5)  trap 'printf "\n"; msg_info "退出"' INT; openclaw_cmd logs 2>&1 || true; trap - INT ;;
        6)  openclaw_cmd models status ;;
        7)  openclaw_cmd models list ;;
        8)  openclaw_cmd config validate ;;
        9)  openclaw_cmd dashboard --no-open ;;
        10) openclaw_cmd agents list ;;
        11) msg_info "Ctrl+C 退出"; trap 'printf "\n"; msg_info "退出"' INT; openclaw_cmd gateway run 2>&1; trap - INT ;;
        12) validate_config ;;
        13) configure_custom_api ;;
        0)  return 0 ;;
        *)  msg_warn "无效选择" ;;
    esac
    wait_and_return 2
    return 0
}
detect_state() {
    local state="unknown"
    if ! is_openclaw_installed; then
        state="not_installed"
    else
        local cfg; cfg=$(get_active_config_path)
        if [[ ! -f "$cfg" ]] || ! json_is_valid; then
            state="broken_config"
        else
            load_config_from_file
            if [[ ${#G_API_KEYS[@]} -eq 0 && ${#G_API_URLS[@]} -eq 0 ]]; then
                state="no_provider"
            elif gateway_health_check; then
                state="running"
            else
                state="stopped"
            fi
        fi
    fi
    printf "%s" "$state"
}
smart_quick_start() {
    msg_title "智能快速开始"
    detect_system
    detect_region
    local state; state=$(detect_state)
    printf "  ${BOLD}当前状态:${NC} "
    case "$state" in
        not_installed)   printf "${RED}未安装${NC}\n" ;;
        broken_config)   printf "${RED}配置损坏${NC}\n" ;;
        no_provider)     printf "${YELLOW}未配置 AI Provider${NC}\n" ;;
        stopped)         printf "${YELLOW}已安装/已配置/未运行${NC}\n" ;;
        running)         printf "${GREEN}运行中${NC}\n" ;;
    esac
    is_china && printf "  ${BOLD}网络环境:${NC} ${CYAN}中国大陆 (自动镜像加速)${NC}\n"
    printf "\n"
    case "$state" in
        not_installed)
            msg_step "检测到未安装,开始部署..."
            printf "  ${BOLD}1)${NC} npm 本地安装 ${GREEN}(推荐)${NC}\n"
            printf "  ${BOLD}2)${NC} Docker 容器部署\n"
            printf "  ${BOLD}0)${NC} 返回\n\n"
            printf "${BOLD}选择: ${NC}"
            local ch; read_input ch "1"
            case "$ch" in
                1) install_openclaw ;;
                2) deploy_docker ;;
                0) return 0 ;;
            esac
            ;;
        broken_config)
            msg_step "配置损坏,自动修复..."
            repair_broken_config
            ;;
        no_provider)
            msg_step "未配置 AI Provider,开始配置..."
            printf "  ${BOLD}1)${NC} 自定义 API ${GREEN}(推荐)${NC}\n"
            printf "  ${BOLD}2)${NC} 内置 Provider\n"
            printf "  ${BOLD}0)${NC} 返回\n\n"
            printf "${BOLD}选择: ${NC}"
            local ch; read_input ch "1"
            case "$ch" in
                1) configure_custom_api ;;
                2) configure_builtin_providers ;;
                0) return 0 ;;
            esac
            ;;
        stopped)
            msg_step "启动 Gateway..."
            openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
            service_start
            wait_gateway_ready 20
            load_config_from_file
            show_dashboard_info
            wait_and_return 3
            ;;
        running)
            msg_ok "一切正常!"
            load_config_from_file
            show_dashboard_info
            wait_and_return 3
            ;;
    esac
}
show_banner() {
    clear
    printf "${CYAN}${BOLD}"
    cat << 'BANNER'
   ___                    ____ _
  / _ \ _ __   ___ _ __  / ___| | __ ___      __
 | | | | '_ \ / _ \ '_ \| |   | |/ _` \ \ /\ / /
 | |_| | |_) |  __/ | | | |___| | (_| |\ V  V /
  \___/| .__/ \___|_| |_|\____|_|\__,_| \_/\_/
       |_|
BANNER
    printf "${NC}\n"
    printf "        ${DIM}%s | 智能部署 | 国内镜像加速${NC}\n\n" "$SCRIPT_VERSION"
    detect_system
    detect_region
    load_config_from_file 2>/dev/null || true
    local st="未安装" sc="$RED"
    if is_openclaw_installed; then
        if gateway_health_check; then
            sc="$GREEN"; st="运行中"
        else
            sc="$YELLOW"; st="已停止"
        fi
    fi
    local cs_txt="未创建" cs_color="$DIM"
    local cfg; cfg=$(get_active_config_path)
    if [[ -f "$cfg" ]]; then
        if json_is_valid; then
            cs_color="$GREEN"; cs_txt="有效"
        else
            cs_color="$RED"; cs_txt="损坏"
        fi
    fi
    local ml_txt="npm" ml_color="$NC"
    if is_docker_mode; then
        ml_color="$CYAN"; ml_txt="Docker"
    fi
    local rg_txt="$G_REGION" rg_color="$DIM"
    if is_china; then
        rg_color="$YELLOW"; rg_txt="国内"
    fi
    printf "  GW: %s%s%s  模式: %s%s%s  配置: %s%s%s  网络: %s%s%s" \
        "$sc" "$st" "$NC" \
        "$ml_color" "$ml_txt" "$NC" \
        "$cs_color" "$cs_txt" "$NC" \
        "$rg_color" "$rg_txt" "$NC"
    if [[ -n "${G_DEFAULT_PROVIDER:-}" ]]; then
        printf "  AI: %s%s%s" "$CYAN" "$G_DEFAULT_PROVIDER" "$NC"
    fi
    printf "\n"
    print_line
}
main_menu() {
    while true; do
        show_banner
        printf "${WHITE}${BOLD}  主菜单${NC}\n\n"
        printf "  ${BOLD}[1]${NC}  快速开始 (智能检测/安装/配置/启动)\n"
        printf "  ${BOLD}[2]${NC}  配置自定义 API\n"
        printf "  ${BOLD}[3]${NC}  配置内置 Provider\n"
        printf "  ${BOLD}[4]${NC}  局域网 UI 访问\n"
        printf "  ${BOLD}[5]${NC}  Docker 部署\n"
        printf "  ${BOLD}[6]${NC}  启动 Gateway\n"
        printf "  ${BOLD}[7]${NC}  停止 Gateway\n"
        printf "  ${BOLD}[8]${NC}  重启 Gateway\n"
        printf "  ${BOLD}[9]${NC}  状态/Dashboard\n"
        printf "  ${BOLD}[10]${NC} 诊断修复\n"
        printf "  ${BOLD}[11]${NC} 日志查看\n"
        printf "  ${BOLD}[12]${NC} 令牌管理\n"
        printf "  ${BOLD}[13]${NC} 修复配置\n"
        printf "  ${BOLD}[14]${NC} 验证配置\n"
        printf "  ${BOLD}[15]${NC} Agent 认证修复\n"
        printf "  ${BOLD}[16]${NC} 安装插件\n"
        printf "  ${BOLD}[17]${NC} 版本/升级\n"
        printf "  ${BOLD}[18]${NC} 系统信息\n"
        printf "  ${BOLD}[19]${NC} 命令速查\n"
        printf "  ${BOLD}[20]${NC} 快捷命令\n"
        printf "  ${BOLD}[21]${NC} setup 向导\n"
        printf "  ${BOLD}[22]${NC} 卸载\n"
        printf "  ${BOLD}[0]${NC}  退出\n\n"
        print_line
        printf "  ${BOLD}选择: ${NC}"
        local choice; read_input choice ""
        case "$choice" in
            1)  smart_quick_start ;;
            2)  configure_custom_api ;;
            3)  configure_builtin_providers ;;
            4)  configure_lan_access ;;
            5)  deploy_docker ;;
            6)  manage_service start ;;
            7)  manage_service stop ;;
            8)  manage_service restart ;;
            9)  manage_service status ;;
            10) diagnose_and_fix ;;
            11) view_logs ;;
            12) show_token_manager ;;
            13) repair_broken_config ;;
            14) validate_config; wait_and_return 3 ;;
            15) fix_agent_auth_menu ;;
            16) install_plugins ;;
            17) show_version ;;
            18) print_sysinfo; wait_and_return 3 ;;
            19) show_command_reference ;;
            20) quick_commands ;;
            21) run_setup_wizard ;;
            22) uninstall_openclaw ;;
            0)  printf "\n${GREEN}${BOLD}再见!${NC}\n\n"; exit 0 ;;
            *)  msg_warn "无效: %s" "$choice"; sleep 1 ;;
        esac
    done
}
init_privilege
case "${1:-}" in
    install)      detect_system; detect_region; install_openclaw ;;
    docker)       detect_system; detect_region; deploy_docker ;;
    lan)          detect_system; detect_region; configure_lan_access ;;
    plugins)      install_plugins ;;
    setup)        detect_system; run_setup_wizard ;;
    start)        detect_system; manage_service start ;;
    stop)         detect_system; manage_service stop ;;
    restart)      detect_system; manage_service restart ;;
    status)       detect_system; manage_service status ;;
    version)      detect_system; show_version ;;
    diagnose)     detect_system; detect_region; diagnose_and_fix ;;
    uninstall)    detect_system; uninstall_openclaw ;;
    url)          detect_system; load_config_from_file; show_dashboard_info; wait_and_return 3 ;;
    config)       detect_system; detect_region; configure_builtin_providers ;;
    custom)       detect_system; detect_region; configure_custom_api ;;
    validate)     detect_system; validate_config; wait_and_return 3 ;;
    repair)       detect_system; repair_broken_config ;;
    token)        detect_system; show_token_manager ;;
    sanitize)     detect_system; sanitize_config_for_schema ;;
    convert-urls) detect_system; convert_urls_for_docker_mode ;;
    fix-agent)    detect_system; detect_region; fix_agent_auth_menu ;;
    agent-auth)   detect_system; detect_region; fix_agent_auth_menu ;;
    ref|help)     show_command_reference ;;
    cmds)         detect_system; quick_commands ;;
    sysinfo)      detect_system; detect_region; print_sysinfo; wait_and_return 3 ;;
    --china)      OPENCLAW_REGION="china"; shift; main_menu ;;
    --overseas)   OPENCLAW_REGION="overseas"; shift; main_menu ;;
    *)            main_menu ;;
esac
