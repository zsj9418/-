#!/usr/bin/env bash
set -uo pipefail
SCRIPT_VERSION="v1.2.1"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
OK="✅"; FAIL="❌"; WARN="⚠️ "; INFO="ℹ️ "
ARROW="➜"; ROCKET="🚀"; TRASH="🗑️ "; DOCTOR="🩺"
POWER="⚡"; GEAR="⚙️"; LOBSTER="🦞"; DOCKER_ICO="🐳"
PLUGIN="🔌"; KEY="🔐"; LINK="🔗"
OPENCLAW_PORT=18789
OPENCLAW_SERVICE_CANDIDATES=("openclaw" "openclaw-gateway")
OPENCLAW_CONFIG_DIR="$HOME/.openclaw"
OPENCLAW_JSON="$OPENCLAW_CONFIG_DIR/openclaw.json"
OPENCLAW_LOG_DIR="$OPENCLAW_CONFIG_DIR/logs"
OPENCLAW_AGENTS_DIR="$OPENCLAW_CONFIG_DIR/agents"
NODE_MIN_VERSION=22
NODE_RECOMMENDED_VERSION=24
LOG_FILE="/tmp/openclaw_install_$(date +%Y%m%d_%H%M%S).log"
GITHUB_REPO="https://github.com/openclaw/openclaw"
OPENCLAW_INSTALL_URL="https://openclaw.ai/install.sh"
DOCKER_IMAGE="ghcr.io/openclaw/openclaw"
DOCKER_IMAGE_MIRROR="openclaw/openclaw"
DOCKER_IMAGE_DR34M="dr34m/openclaw"
DOCKER_IMAGE_1PANEL="1panel/openclaw"
DOCKER_IMAGE_ALPINE="alpine/openclaw"
DOCKER_IMAGE_ZH_HUB="1186258278/openclaw-zh"
DOCKER_IMAGE_ZH_GHCR="ghcr.io/1186258278/openclaw-zh"
DOCKER_CONTAINER="openclaw-core"
DOCKER_CONTAINER_ZH="openclaw"
DOCKER_VOL_OFFICIAL="openclaw-core-data"
DOCKER_VOL_ZH="openclaw-data"
DOCKER_DATA_DIR="$HOME/openclaw"
NPM_MIRROR_CN="https://registry.npmmirror.com"
NODE_MIRROR_CN="https://npmmirror.com/mirrors/node"
NODE_MIRROR_OFFICIAL="https://nodejs.org/dist"
WECHAT_PLUGIN_PKG="@tencent-weixin/openclaw-weixin"
FEISHU_PLUGIN_PKG="@m1heng-clawd/feishu"
DEPS_STAMP="$OPENCLAW_CONFIG_DIR/.deps_installed"
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
print_line() { echo -e "${DIM}$(printf '─%.0s' {1..60})${NC}"; }
msg_ok()   { echo -e "${GREEN}${OK}  $*${NC}"; }
msg_fail() { echo -e "${RED}${FAIL}  $*${NC}"; }
msg_warn() { echo -e "${YELLOW}${WARN} $*${NC}"; }
msg_info() { echo -e "${CYAN}${INFO} $*${NC}"; }
msg_step() { echo -e "\n${BLUE}${BOLD}${ARROW} $*${NC}"; }
msg_title() {
    echo ""
    local title="$1"
    local width=58
    local tlen=${#title}
    local lpad=$(( (width - tlen) / 2 ))
    local rpad=$(( width - tlen - lpad ))
    echo -e "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    printf "${MAGENTA}${BOLD}║%${lpad}s%s%${rpad}s║${NC}\n" "" "$title" ""
    echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}
wait_and_return() {
    local t="${1:-3}"
    echo -ne "\n${DIM}${t} 秒后返回...${NC}"
    sleep "$t"; echo ""
}
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
has_cmd() { command -v "$1" &>/dev/null; }
read_input() {
    local varname="$1"
    local default_val="${2:-}"
    local input=""
    read -r input </dev/tty 2>/dev/null || input=""
    input="${input:-$default_val}"
    eval "$varname=\"\$input\""
}
read_input_silent() {
    local varname="$1"
    local default_val="${2:-}"
    local input=""
    read -rs input </dev/tty 2>/dev/null || input=""
    echo ""
    input="${input:-$default_val}"
    eval "$varname=\"\$input\""
}
confirm() {
    local prompt="${1:-确认操作}"
    local answer=""
    echo -ne "${YELLOW}${WARN} ${prompt} [y/N]: ${NC}"
    read -r answer </dev/tty 2>/dev/null || answer="n"
    [[ "$answer" =~ ^[Yy]$ ]]
}
safe_run() {
    local desc="$1"; shift
    if "$@" >> "$LOG_FILE" 2>&1; then
        msg_ok "$desc"; return 0
    else
        msg_warn "$desc 失败 (详见 $LOG_FILE)"; return 1
    fi
}
get_local_ip() {
    local ip=""
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip=$(ipconfig getifaddr en0 2>/dev/null || true)
    [[ -z "$ip" ]] && ip=$(ipconfig getifaddr en1 2>/dev/null || true)
    [[ -z "$ip" ]] && ip="127.0.0.1"
    echo "$ip"
}
is_lan_url() {
    local url="$1"
    [[ "$url" =~ ^https?://(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.|localhost) ]]
}
convert_url_for_docker() {
    local url="$1"
    if [[ "$url" =~ ^(https?://)(127\.0\.0\.1|localhost)(:[0-9]+)?(.*)$ ]]; then
        echo "${BASH_REMATCH[1]}host.docker.internal${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
    elif [[ "$url" =~ ^(https?://)(192\.168\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+)(:[0-9]+)?(.*)$ ]]; then
        echo "${BASH_REMATCH[1]}host.docker.internal${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
    else
        echo "$url"
    fi
}
init_privilege() {
    if [[ $EUID -eq 0 ]]; then
        SUDO=""; IS_ROOT=true
    elif has_cmd sudo; then
        SUDO="sudo"; IS_ROOT=false
        sudo -n true 2>/dev/null || echo -e "${YELLOW}[WARN]${NC} sudo 可能需要密码" >&2
    elif has_cmd doas; then
        SUDO="doas"; IS_ROOT=false
    else
        echo -e "${RED}[FAIL]${NC} 无 root 权限且未找到 sudo/doas" >&2
        exit 1
    fi
    export SUDO IS_ROOT
}
detect_region() {
    [[ -n "${G_REGION:-}" ]] && return
    case "${OPENCLAW_REGION:-}" in
        cn|china) G_REGION="china"; return ;;
        overseas|global) G_REGION="overseas"; return ;;
    esac
    if curl -s --max-time 3 --connect-timeout 2 https://www.google.com &>/dev/null; then
        G_REGION="overseas"
    elif curl -s --max-time 3 --connect-timeout 2 https://www.baidu.com &>/dev/null; then
        G_REGION="china"
    else
        G_REGION="unknown"
    fi
    log "Region: $G_REGION"
}
is_china() { [[ "${G_REGION:-}" == "china" ]]; }
detect_system() {
    [[ -n "${OS:-}" ]] && return
    init_privilege
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"; SERVICE_MANAGER="launchd"
        PRETTY_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
        if has_cmd brew; then
            PKG_MANAGER="brew"; INSTALL_CMD="brew install"; UPDATE_CMD="brew update"
        else
            PKG_MANAGER="none"; INSTALL_CMD=""; UPDATE_CMD=""
        fi
    elif [[ -f /etc/os-release ]]; then
        source /etc/os-release
        PRETTY_NAME="${PRETTY_NAME:-${ID:-unknown}}"
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
            *) OS="unknown"; PKG_MANAGER="unknown"; INSTALL_CMD=""; UPDATE_CMD="" ;;
        esac
        SERVICE_MANAGER="systemd"
        [[ "$OS" == "alpine" ]] && SERVICE_MANAGER="openrc"
    else
        OS="unknown"; SERVICE_MANAGER="unknown"; PKG_MANAGER="unknown"
    fi
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)  ARCH_LABEL="x86_64 (64位)" ;;
        aarch64|arm64) ARCH_LABEL="ARM64 (64位)" ;;
        armv7l|armv6l) ARCH_LABEL="ARMv7 (32位)" ;;
        i386|i686)     ARCH_LABEL="x86 (32位)" ;;
        *)             ARCH_LABEL="$ARCH" ;;
    esac
}
_container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"
}
_container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"
}
_detect_deploy_mode() {
    if _container_exists "$DOCKER_CONTAINER_ZH"; then
        echo "Docker(中文版)"
    elif _container_exists "$DOCKER_CONTAINER"; then
        echo "Docker(官方版)"
    elif has_cmd openclaw; then
        echo "本地安装(npm)"
    else
        echo "未部署"
    fi
}
is_docker_mode() {
    ! has_cmd openclaw && { _container_exists "$DOCKER_CONTAINER_ZH" || _container_exists "$DOCKER_CONTAINER"; }
}
is_openclaw_installed() {
    has_cmd openclaw || _container_exists "$DOCKER_CONTAINER_ZH" || _container_exists "$DOCKER_CONTAINER"
}
get_active_config_path() {
    if is_docker_mode; then
        echo "${DOCKER_DATA_DIR}/.openclaw/openclaw.json"
    else
        echo "$OPENCLAW_JSON"
    fi
}
_get_active_container() {
    if _container_running "$DOCKER_CONTAINER_ZH"; then
        echo "$DOCKER_CONTAINER_ZH"
    elif _container_running "$DOCKER_CONTAINER"; then
        echo "$DOCKER_CONTAINER"
    else
        echo ""
    fi
}
openclaw_cmd() {
    if has_cmd openclaw; then
        openclaw "$@"
    else
        local cname=""
        cname=$(_get_active_container)
        if [[ -n "$cname" ]]; then
            docker exec "$cname" openclaw "$@"
        else
            echo "openclaw 未运行" >&2; return 1
        fi
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
    cp "$cfg" "$bk" 2>/dev/null && echo "$bk"
}
atomic_write_json() {
    local cfg="$1"
    local content="$2"
    local tmp="${1}.tmp.$$"
    mkdir -p "$(dirname "$cfg")"
    printf '%s' "$content" > "$tmp"
    if has_cmd python3; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp" 2>/dev/null \
            || { rm -f "$tmp"; return 1; }
    fi
    mv "$tmp" "$cfg"; chmod 600 "$cfg"
}
sanitize_config_for_schema() {
    local cfg="${1:-$(get_active_config_path)}"
    [[ ! -f "$cfg" ]] && return 1
    has_cmd python3 || return 1
    json_is_valid "$cfg" || return 1
    python3 - "$cfg" << 'PYEOF'
import json, sys, os
cfg_path = sys.argv[1]
VALID_BIND = ["auto","lan","loopback","custom","tailnet"]
BAD_ROOT = ["ui","defaultProvider"]
try:
    with open(cfg_path) as f: c = json.load(f)
except: sys.exit(1)
changed = []
gw = c.setdefault("gateway", {})
if gw.get("bind") == "localhost":
    gw["bind"] = "loopback"; changed.append("gateway.bind: localhost -> loopback")
elif gw.get("bind") not in VALID_BIND:
    gw["bind"] = "loopback"; changed.append("gateway.bind -> loopback")
if not gw.get("mode"):
    gw["mode"] = "local"; changed.append("gateway.mode -> local")
for k in BAD_ROOT:
    if k in c: del c[k]; changed.append(f"removed {k}")
if "agents" in c and isinstance(c["agents"], dict):
    agents = c["agents"]
    for k in list(agents.keys()):
        if k not in ("defaults","list"):
            del agents[k]; changed.append(f"removed agents.{k}")
    if "defaults" in agents and isinstance(agents["defaults"], dict):
        m = agents["defaults"].get("model")
        if isinstance(m, str):
            agents["defaults"]["model"] = {"primary": m}; changed.append("model str->obj")
        elif m is not None and not isinstance(m, dict):
            del agents["defaults"]["model"]; changed.append("model removed")
        if not agents["defaults"]:
            del agents["defaults"]; changed.append("removed empty defaults")
    if not agents: del c["agents"]; changed.append("removed empty agents")
providers = c.get("models",{}).get("providers",{})
if isinstance(providers, dict):
    for name, p in providers.items():
        if isinstance(p, dict) and not p.get("api"):
            p["api"] = "openai-completions"; changed.append(f"{name}.api -> openai-completions")
if changed:
    tmp = cfg_path + ".tmp"
    with open(tmp,"w") as f: json.dump(c,f,indent=2,ensure_ascii=False)
    os.replace(tmp, cfg_path)
    for ch in changed: print(ch)
else: print("NOCHANGE")
PYEOF
    chmod 600 "$cfg" 2>/dev/null
}
convert_urls_for_docker_mode() {
    local cfg="${1:-$(get_active_config_path)}"
    [[ ! -f "$cfg" ]] && return 1
    has_cmd python3 && json_is_valid "$cfg" || return 1
    python3 - "$cfg" << 'PYEOF'
import json, sys, os, re
cfg_path = sys.argv[1]
PAT = re.compile(r'^(https?://)(127\.0\.0\.1|localhost|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(1[6-9]|2[0-9]|3[0-1])\.\d+\.\d+)')
try:
    with open(cfg_path) as f: c = json.load(f)
except: sys.exit(1)
changed = []
for name, p in c.get("models",{}).get("providers",{}).items():
    if not isinstance(p, dict): continue
    url = p.get("baseUrl","")
    if PAT.match(url):
        new = PAT.sub(r'\1host.docker.internal', url)
        if new != url: p["baseUrl"] = new; changed.append(f"{name}: LAN -> host.docker.internal")
if changed:
    tmp = cfg_path + ".tmp"
    with open(tmp,"w") as f: json.dump(c,f,indent=2,ensure_ascii=False)
    os.replace(tmp, cfg_path)
    for ch in changed: print(ch)
else: print("NOCHANGE")
PYEOF
    chmod 600 "$cfg" 2>/dev/null
}
load_config_from_file() {
    local cfg=""
    cfg=$(get_active_config_path)
    [[ ! -f "$cfg" ]] && return 0
    json_is_valid "$cfg" || return 0
    has_cmd python3 || return 0
    local result=""
    result=$(python3 - "$cfg" << 'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f: c = json.load(f)
except: sys.exit(0)
first_builtin = ""
for p in ["anthropic","openai","google","deepseek","groq","mistral"]:
    pc = c.get(p, {})
    if not isinstance(pc, dict): continue
    key = pc.get("apiKey","")
    if key:
        print(f'G_API_KEYS[{p}]="{key}"')
        if not first_builtin: first_builtin = p
    ms = pc.get("models") or pc.get("model","")
    if ms: print(f'G_API_MODELS[{p}]="{ms}"')
first_custom = ""
for name, pc in c.get("models",{}).get("providers",{}).items():
    if not isinstance(pc, dict): continue
    bu = pc.get("baseUrl",""); ak = pc.get("apiKey","")
    at = pc.get("api","")
    ml = pc.get("models",[])
    ids = ",".join(m.get("id","") for m in ml if isinstance(m,dict) and m.get("id")) if isinstance(ml,list) else ""
    if bu: print(f'G_API_URLS[{name}]="{bu}"')
    if ak: print(f'G_API_KEYS[{name}]="{ak}"')
    if at: print(f'G_API_TYPES[{name}]="{at}"')
    if ids: print(f'G_API_MODELS[{name}]="{ids}"')
    if not first_custom: first_custom = name
if first_custom: print(f'G_DEFAULT_PROVIDER="{first_custom}"')
elif first_builtin: print(f'G_DEFAULT_PROVIDER="{first_builtin}"')
PYEOF
)
    [[ -n "${result:-}" ]] && eval "$result" 2>/dev/null || true
}
get_gateway_token() {
    local cfg=""
    cfg=$(get_active_config_path)
    [[ ! -f "$cfg" ]] && return 1
    has_cmd python3 || return 1
    python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('gateway',{}).get('auth',{}).get('token',''))
except: pass
" "$cfg" 2>/dev/null
}
_create_minimal_config() {
    local cfg=""
    cfg=$(get_active_config_path)
    local content='{
  "gateway": {"mode": "local", "bind": "loopback"},
  "models": {"mode": "merge", "providers": {}},
  "agents": {
    "defaults": {"workspace": "~/.openclaw/workspace"},
    "list": [{"id": "main", "default": true}]
  }
}'
    atomic_write_json "$cfg" "$content" && msg_ok "最小配置已创建" || msg_fail "配置创建失败"
}
ensure_minimal_config() {
    local cfg=""
    cfg=$(get_active_config_path)
    mkdir -p "$(dirname "$cfg")"
    if [[ ! -f "$cfg" ]]; then _create_minimal_config; return; fi
    if ! json_is_valid "$cfg"; then
        msg_warn "配置损坏,备份并重建"; backup_config; _create_minimal_config; return
    fi
    sanitize_config_for_schema >/dev/null 2>&1 || true
}
prompt_gateway_token() {
    local varname="$1"
    local existing="${2:-}"
    echo -e "\n${CYAN}${BOLD}── 网关令牌 ──${NC}"
    [[ -n "$existing" ]] && echo -e "  已有令牌: ${YELLOW}${existing}${NC}"
    echo -e "  ${DIM}直接回车 → 自动生成随机令牌（推荐）${NC}"
    echo -e "  ${DIM}输入自定义令牌（至少 16 字符）${NC}"
    [[ -n "$existing" ]] && echo -e "  ${DIM}输入 keep → 保留现有${NC}"
    echo -ne "${BOLD}令牌 (回车自动生成): ${NC}"
    local user_tok=""
    read_input user_tok ""
    _gen_token() {
        openssl rand -hex 24 2>/dev/null \
            || (head -c 24 /dev/urandom | xxd -p | tr -d '\n') 2>/dev/null \
            || echo "$(date +%s%N)abc123"
    }
    if [[ "$user_tok" == "keep" && -n "$existing" ]]; then
        eval "$varname=\"\$existing\""; msg_ok "保留现有令牌"
    elif [[ -z "$user_tok" ]]; then
        eval "$varname=\"\$(_gen_token)\""; msg_ok "已自动生成令牌"
    elif [[ ${#user_tok} -lt 16 ]]; then
        msg_warn "令牌过短(${#user_tok}字符),已自动生成"
        eval "$varname=\"\$(_gen_token)\""
    else
        eval "$varname=\"\$user_tok\""; msg_ok "使用自定义令牌(长度:${#user_tok})"
    fi
}
print_sysinfo() {
    detect_system; detect_region
    local cfg_path=""
    cfg_path=$(get_active_config_path)
    local cfg_status="未创建"
    if [[ -f "$cfg_path" ]]; then
        json_is_valid "$cfg_path" && cfg_status="${GREEN}有效${NC}" || cfg_status="${RED}损坏${NC}"
    fi
    echo -e "${CYAN}${BOLD}系统信息${NC}"; print_line
    echo -e "  ${BOLD}操作系统${NC}    : $(echo "$OS" | tr '[:lower:]' '[:upper:]') ($PRETTY_NAME)"
    echo -e "  ${BOLD}架构${NC}        : $ARCH_LABEL"
    echo -e "  ${BOLD}用户${NC}        : $(whoami) (UID:$EUID)"
    echo -e "  ${BOLD}包管理器${NC}    : $PKG_MANAGER"
    echo -e "  ${BOLD}服务管理${NC}    : $SERVICE_MANAGER"
    echo -e "  ${BOLD}主机名${NC}      : $(hostname)"
    echo -e "  ${BOLD}内存${NC}        : $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || sysctl hw.memsize 2>/dev/null | awk '{printf "%.1fGB",$2/1073741824}' || echo '?')"
    echo -e "  ${BOLD}CPU${NC}         : $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?') 核"
    echo -e "  ${BOLD}磁盘可用${NC}    : $(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo '?')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}npm${NC}         : $(npm -v 2>/dev/null | sed 's/^/v/' || echo '未安装')"
    echo -e "  ${BOLD}Docker${NC}      : $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo '未安装')"
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw_cmd --version 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}部署方式${NC}    : $(_detect_deploy_mode)"
    echo -e "  ${BOLD}网络环境${NC}    : ${G_REGION:-unknown}"
    echo -e "  ${BOLD}配置路径${NC}    : $cfg_path"
    echo -e "  ${BOLD}配置状态${NC}    : $cfg_status"
    [[ -n "${G_DEFAULT_PROVIDER:-}" ]] && echo -e "  ${BOLD}默认AI${NC}      : ${GREEN}${G_DEFAULT_PROVIDER}${NC}"
    print_line
}
install_system_deps() {
    if [[ -f "$DEPS_STAMP" ]]; then
        msg_info "依赖已安装(跳过)"; return 0
    fi
    detect_system
    msg_step "安装系统依赖..."
    case "$OS" in
        debian)
            safe_run "apt update" ${SUDO:-} apt-get update -qq
            safe_run "基础依赖" ${SUDO:-} apt-get install -y curl wget git build-essential ca-certificates gnupg python3 jq lsb-release ;;
        rhel)
            safe_run "yum update" ${SUDO:-} yum update -y
            safe_run "基础依赖" ${SUDO:-} yum install -y curl wget git gcc gcc-c++ make python3 jq ;;
        fedora)
            safe_run "dnf update" ${SUDO:-} dnf update -y
            safe_run "基础依赖" ${SUDO:-} dnf install -y curl wget git gcc gcc-c++ make python3 jq ;;
        arch)
            safe_run "pacman" ${SUDO:-} pacman -Sy --noconfirm
            safe_run "基础依赖" ${SUDO:-} pacman -S --noconfirm curl wget git base-devel python jq ;;
        alpine)
            safe_run "apk update" ${SUDO:-} apk update
            safe_run "基础依赖" ${SUDO:-} apk add curl wget git build-base python3 jq bash ;;
        macos)
            if ! has_cmd brew; then
                safe_run "Homebrew" bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            fi
            safe_run "brew工具" brew install curl wget git jq python3 ;;
        *) msg_warn "未知系统($OS),跳过依赖安装" ;;
    esac
    mkdir -p "$(dirname "$DEPS_STAMP")"
    date '+%Y-%m-%d %H:%M:%S' > "$DEPS_STAMP"
    msg_ok "依赖安装完成"
}
_refresh_node_path() {
    local nd=""
    [[ -d "$HOME/.nvm/versions/node" ]] && nd=$(ls -d "$HOME/.nvm/versions/node/"v* 2>/dev/null | sort -V | tail -1 || true)
    for p in "${nd:+${nd}/bin}" "$HOME/.local/bin" "/usr/local/bin"; do
        [[ -n "$p" && -d "$p" ]] && export PATH="$p:$PATH"
    done
    export NVM_DIR="$HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
    hash -r 2>/dev/null || true
}
_install_node_nodesource() {
    local ver="$1"
    case "$OS" in
        debian)
            safe_run "NodeSource" bash -c "curl -fsSL https://deb.nodesource.com/setup_${ver}.x | ${SUDO:-} -E bash -"
            safe_run "nodejs" ${SUDO:-} apt-get install -y nodejs ;;
        rhel|fedora)
            safe_run "NodeSource" bash -c "curl -fsSL https://rpm.nodesource.com/setup_${ver}.x | ${SUDO:-} bash -"
            safe_run "nodejs" ${SUDO:-} "$PKG_MANAGER" install -y nodejs ;;
        arch) safe_run "nodejs" ${SUDO:-} pacman -S --noconfirm nodejs npm ;;
        alpine) safe_run "nodejs" ${SUDO:-} apk add nodejs npm ;;
        macos)
            has_cmd brew || { msg_fail "需要Homebrew"; return 1; }
            safe_run "node@${ver}" brew install "node@${ver}"
            brew link --force --overwrite "node@${ver}" 2>/dev/null || true ;;
    esac
}
_install_node_nvm() {
    local ver="$1"
    local nvm_ver="v0.40.1"
    safe_run "nvm" bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_ver}/install.sh | bash"
    export NVM_DIR="$HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" || return 1
    safe_run "node v${ver}" nvm install "$ver"
    nvm use "$ver" >> "$LOG_FILE" 2>&1 || true
    nvm alias default "$ver" >> "$LOG_FILE" 2>&1 || true
}
_install_node_native() {
    case "$OS" in
        debian) safe_run "apt" ${SUDO:-} apt-get update -qq; safe_run "nodejs" ${SUDO:-} apt-get install -y nodejs npm ;;
        rhel) safe_run "nodejs" ${SUDO:-} yum install -y nodejs npm ;;
        fedora) safe_run "nodejs" ${SUDO:-} dnf install -y nodejs npm ;;
        arch) safe_run "nodejs" ${SUDO:-} pacman -S --noconfirm nodejs npm ;;
        alpine) safe_run "nodejs" ${SUDO:-} apk add nodejs npm ;;
        macos) has_cmd brew && safe_run "node" brew install node || return 1 ;;
    esac
}
_install_node_binary() {
    local ver="${1:-$NODE_RECOMMENDED_VERSION}"
    detect_region
    msg_step "二进制安装 Node.js v${ver}..."
    local arch_suffix=""
    case "$ARCH" in
        x86_64|amd64)  arch_suffix="linux-x64" ;;
        aarch64|arm64) arch_suffix="linux-arm64" ;;
        armv7l)        arch_suffix="linux-armv7l" ;;
        *) msg_fail "不支持的架构: $ARCH"; return 1 ;;
    esac
    local mirror=""
    is_china && mirror="$NODE_MIRROR_CN" || mirror="$NODE_MIRROR_OFFICIAL"
    local latest=""
    latest=$(curl -s --max-time 10 "${mirror}/latest-v${ver}.x/" 2>/dev/null \
        | grep -oE "node-v${ver}\.[0-9]+\.[0-9]+-${arch_suffix}\.tar\.[gx]z" | head -1 || true)
    if [[ -z "$latest" ]]; then
        latest=$(curl -s --max-time 10 "${mirror}/latest/" 2>/dev/null \
            | grep -oE "node-v[0-9]+\.[0-9]+\.[0-9]+-${arch_suffix}\.tar\.[gx]z" | head -1 || true)
        [[ -z "$latest" ]] && { msg_fail "获取失败"; return 1; }
    fi
    local is_xz=false
    [[ "$latest" == *.tar.xz ]] && is_xz=true
    local base_url="${mirror}/latest-v${ver}.x"
    [[ ! "$latest" =~ ^node-v${ver} ]] && base_url="${mirror}/latest"
    local url="${base_url}/${latest}"
    local tmpd="/tmp/node_bin_$$"
    mkdir -p "$tmpd"
    msg_info "下载: $url"
    curl -fL --max-time 120 --progress-bar -o "${tmpd}/node.pkg" "$url" \
        || { msg_fail "下载失败"; rm -rf "$tmpd"; return 1; }
    if $is_xz; then
        tar -xJf "${tmpd}/node.pkg" -C "$tmpd" 2>/dev/null || { msg_fail "解压失败"; rm -rf "$tmpd"; return 1; }
    else
        tar -xzf "${tmpd}/node.pkg" -C "$tmpd" 2>/dev/null || { msg_fail "解压失败"; rm -rf "$tmpd"; return 1; }
    fi
    local ndir=""
    ndir=$(find "$tmpd" -maxdepth 1 -type d -name "node-v*" | head -1)
    [[ -z "$ndir" ]] && { msg_fail "解压产物未找到"; rm -rf "$tmpd"; return 1; }
    for sub in bin include lib share; do
        [[ -d "${ndir}/${sub}" ]] && {
            ${SUDO:-} cp -rf "${ndir}/${sub}/"* "/usr/local/${sub}/" 2>/dev/null || true
        }
    done
    rm -rf "$tmpd"; hash -r 2>/dev/null || true
    has_cmd node && { msg_ok "Node.js $(node -v) 安装成功(二进制)"; return 0; }
    msg_fail "二进制安装失败"; return 1
}
install_nodejs() {
    msg_step "检测 Node.js..."
    if has_cmd node; then
        local ver=""
        ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$ver" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v) 满足要求(>=v${NODE_MIN_VERSION})"; return 0
        else
            msg_warn "Node.js $(node -v) 版本过低,需>=v${NODE_MIN_VERSION}"
        fi
    else
        msg_info "Node.js 未安装"
    fi
    local tv="$NODE_RECOMMENDED_VERSION"
    echo -e "\n  ${BOLD}1)${NC} NodeSource 官方仓库 ${GREEN}(推荐)${NC}"
    echo -e "  ${BOLD}2)${NC} nvm 版本管理"
    echo -e "  ${BOLD}3)${NC} 系统包管理器"
    echo -e "  ${BOLD}4)${NC} 官方二进制包 ${YELLOW}(网络问题时用)${NC}"
    echo -e "  ${BOLD}5)${NC} 跳过"
    echo -ne "\n${BOLD}选择[1-5](默认:1): ${NC}"
    local nc=""
    read_input nc "1"
    if [[ "$nc" =~ ^[1-4]$ ]]; then
        echo -ne "${BOLD}Node.js 主版本号(默认:${tv}): ${NC}"
        local cv=""
        read_input cv "$tv"
        cv=$(echo "$cv" | tr -d 'vV ')
        [[ "$cv" =~ ^[0-9]+$ ]] && tv="$cv"
    fi
    msg_info "安装 Node.js v${tv}..."
    case "$nc" in
        1) _install_node_nodesource "$tv" || { msg_warn "NodeSource失败,回退二进制"; _install_node_binary "$tv"; } ;;
        2) _install_node_nvm "$tv" ;;
        3) _install_node_native ;;
        4) _install_node_binary "$tv" ;;
        5) return 1 ;;
        *) _install_node_nodesource "$tv" || _install_node_binary "$tv" ;;
    esac
    _refresh_node_path
    if has_cmd node; then
        local iv=""
        iv=$(node -v | sed 's/v//' | cut -d. -f1)
        [[ "$iv" -ge "$NODE_MIN_VERSION" ]] && { msg_ok "Node.js $(node -v) 安装成功"; return 0; }
    fi
    msg_fail "Node.js 安装失败"; return 1
}
_install_docker() {
    detect_system
    msg_step "安装 Docker..."
    case "$OS" in
        debian|rhel|fedora|unknown)
            safe_run "Docker" bash -c "curl -fsSL https://get.docker.com | ${SUDO:-} sh" ;;
        arch) safe_run "Docker" ${SUDO:-} pacman -S --noconfirm docker ;;
        alpine) safe_run "Docker" ${SUDO:-} apk add docker ;;
        macos) msg_info "请手动安装Docker Desktop: https://docker.com/products/docker-desktop"; return 1 ;;
    esac
    case "$SERVICE_MANAGER" in
        systemd) ${SUDO:-} systemctl enable --now docker 2>/dev/null || true; ${SUDO:-} usermod -aG docker "$USER" 2>/dev/null || true ;;
        openrc) ${SUDO:-} rc-update add docker 2>/dev/null || true; ${SUDO:-} service docker start 2>/dev/null || true ;;
    esac
    has_cmd docker && msg_ok "Docker安装成功" || { msg_fail "Docker安装失败"; return 1; }
}
_fetch_docker_tags() {
    local repo="$1"
    local url="https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=30&ordering=last_updated"
    local raw=""
    raw=$(curl -s --max-time 8 --connect-timeout 3 "$url" 2>/dev/null || true)
    [[ -z "$raw" ]] && return 1
    has_cmd python3 || return 1
    python3 -c "
import json,sys
SKIP={'latest','main','slim','main-slim','extended-stable','extended-stable-slim','nightly'}
SKIP_SUF=('-amd64','-arm64','-slim-amd64','-slim-arm64')
try:
    d=json.loads(sys.stdin.read())
    seen,tags=set(),[]
    for t in d.get('results',[]):
        n=t['name']
        if n in SKIP: continue
        if any(n.endswith(s) for s in SKIP_SUF): continue
        if any(x in n for x in ('beta','browser','rc','alpha')): continue
        if n not in seen: seen.add(n); tags.append(n)
        if len(tags)>=5: break
    print('\n'.join(tags))
except: pass
" <<< "$raw" 2>/dev/null
}
select_docker_version() {
    local repo="${1:-openclaw/openclaw}"
    echo -e "\n${CYAN}${BOLD}── 版本选择 ──${NC}" >&2
    echo -e "  ${BOLD}1)${NC} latest ${GREEN}(推荐)${NC}" >&2
    echo -e "  ${BOLD}2)${NC} 查看最近5个版本" >&2
    echo -e "  ${BOLD}3)${NC} 手动输入tag" >&2
    echo -ne "\n${BOLD}选择[1-3](默认:1): ${NC}" >&2
    local vc=""
    read_input vc "1"
    case "$vc" in
        2)
            msg_info "获取版本列表..." >&2
            local tags_raw=""
            tags_raw=$(_fetch_docker_tags "$repo")
            if [[ -z "$tags_raw" ]]; then msg_warn "无法获取,使用latest" >&2; echo "latest"; return; fi
            local -a tags_arr=()
            while IFS= read -r line; do [[ -n "$line" ]] && tags_arr+=("$line"); done <<< "$tags_raw"
            [[ ${#tags_arr[@]} -eq 0 ]] && { echo "latest"; return; }
            echo -e "\n${CYAN}最近${#tags_arr[@]}个版本:${NC}" >&2
            echo -e "  ${BOLD}0)${NC} latest ${GREEN}[最新稳定]${NC}" >&2
            local i=1
            for t in "${tags_arr[@]}"; do
                local lbl=""
                [[ $i -eq 1 ]] && lbl=" ${GREEN}[最新发布]${NC}"
                echo -e "  ${BOLD}${i})${NC} ${t}${lbl}" >&2
                ((i++))
            done
            echo -ne "\n${BOLD}选择[0-$((i-1))](默认:0): ${NC}" >&2
            local sv=""
            read_input sv "0"
            if [[ "$sv" == "0" ]]; then echo "latest"
            elif [[ "$sv" =~ ^[0-9]+$ ]] && (( sv >= 1 && sv <= ${#tags_arr[@]} )); then
                echo "${tags_arr[$((sv-1))]}"
            else echo "latest"; fi ;;
        3)
            echo -ne "${BOLD}输入tag(默认:latest): ${NC}" >&2
            local mt=""
            read_input mt "latest"
            echo "$mt" ;;
        *) echo "latest" ;;
    esac
}
gateway_health_check() {
    local urls=(
        "http://127.0.0.1:${OPENCLAW_PORT}"
        "http://127.0.0.1:${OPENCLAW_PORT}/health"
        "http://127.0.0.1:${OPENCLAW_PORT}/healthz"
        "http://localhost:${OPENCLAW_PORT}"
    )
    for url in "${urls[@]}"; do
        local code=""
        code=$(curl -s -o /dev/null --max-time 2 --connect-timeout 2 -w "%{http_code}" "$url" 2>/dev/null || echo "000")
        [[ "$code" =~ ^(200|401|403|404)$ ]] && return 0
    done
    local cname=""
    cname=$(_get_active_container)
    if [[ -n "$cname" ]]; then
        docker logs --tail 50 "$cname" 2>&1 | grep -qE "\[gateway\] ready|http server listening|Gateway running" && return 0
    fi
    has_cmd ss && ss -lntp 2>/dev/null | grep -q ":${OPENCLAW_PORT}\b" && return 0
    has_cmd nc && nc -z -w 2 127.0.0.1 "$OPENCLAW_PORT" 2>/dev/null && return 0
    return 1
}
wait_gateway_ready() {
    local timeout="${1:-30}"
    local i=0
    echo -ne "  等待就绪"
    while (( i < timeout )); do
        sleep 1; echo -ne "."
        if gateway_health_check; then echo ""; msg_ok "Gateway 已就绪"; return 0; fi
        ((i++))
    done
    echo ""; msg_warn "Gateway 未响应(超时${timeout}s)"; return 1
}
_select_official_image() {
    detect_region
    echo -e "\n${CYAN}${BOLD}── 官方版镜像源 ──${NC}"
    if is_china; then
        echo -e "  ${BOLD}1)${NC} dr34m/openclaw ${GREEN}(国内推荐)${NC}"
        echo -e "  ${BOLD}2)${NC} 1panel/openclaw"
        echo -e "  ${BOLD}3)${NC} alpine/openclaw"
        echo -e "  ${BOLD}4)${NC} openclaw/openclaw"
        echo -e "  ${BOLD}5)${NC} ghcr.io ${DIM}(需科学上网)${NC}"
        echo -ne "\n${BOLD}选择[1-5](默认:1): ${NC}"
        local sc=""
        read_input sc "1"
        case "$sc" in
            2) G_DOCKER_IMAGE="$DOCKER_IMAGE_1PANEL" ;;
            3) G_DOCKER_IMAGE="$DOCKER_IMAGE_ALPINE" ;;
            4) G_DOCKER_IMAGE="$DOCKER_IMAGE_MIRROR" ;;
            5) G_DOCKER_IMAGE="$DOCKER_IMAGE" ;;
            *) G_DOCKER_IMAGE="$DOCKER_IMAGE_DR34M" ;;
        esac
    else
        echo -e "  ${BOLD}1)${NC} ghcr.io ${GREEN}(推荐)${NC}"
        echo -e "  ${BOLD}2)${NC} Docker Hub"
        echo -e "  ${BOLD}3)${NC} dr34m/openclaw"
        echo -ne "\n${BOLD}选择[1-3](默认:1): ${NC}"
        local sc=""
        read_input sc "1"
        case "$sc" in
            2) G_DOCKER_IMAGE="$DOCKER_IMAGE_MIRROR" ;;
            3) G_DOCKER_IMAGE="$DOCKER_IMAGE_DR34M" ;;
            *) G_DOCKER_IMAGE="$DOCKER_IMAGE" ;;
        esac
    fi
    msg_ok "镜像源: $G_DOCKER_IMAGE"
}
_select_zh_image() {
    detect_region
    echo -e "\n${CYAN}${BOLD}── 中文版镜像源 ──${NC}"
    if is_china; then
        echo -e "  ${BOLD}1)${NC} Docker Hub ${GREEN}(国内推荐)${NC}"
        echo -e "  ${BOLD}2)${NC} GHCR ${DIM}(海外)${NC}"
    else
        echo -e "  ${BOLD}1)${NC} GHCR ${GREEN}(海外推荐)${NC}"
        echo -e "  ${BOLD}2)${NC} Docker Hub"
    fi
    echo -ne "\n${BOLD}选择[1-2](默认:1): ${NC}"
    local sc=""
    read_input sc "1"
    if is_china; then
        [[ "$sc" == "2" ]] && G_DOCKER_IMAGE="$DOCKER_IMAGE_ZH_GHCR" || G_DOCKER_IMAGE="$DOCKER_IMAGE_ZH_HUB"
    else
        [[ "$sc" == "2" ]] && G_DOCKER_IMAGE="$DOCKER_IMAGE_ZH_HUB" || G_DOCKER_IMAGE="$DOCKER_IMAGE_ZH_GHCR"
    fi
    msg_ok "镜像源: $G_DOCKER_IMAGE"
}
_ask_network_mode() {
    echo -e "\n${CYAN}${BOLD}── 网络模式 ──${NC}"
    echo -e "  ${BOLD}1)${NC} bridge ${GREEN}(默认推荐)${NC}"
    echo -e "  ${BOLD}2)${NC} host ${DIM}(共享宿主机网络)${NC}"
    echo -ne "\n${BOLD}选择[1-2](默认:1): ${NC}"
    local nm=""
    read_input nm "1"
    [[ "$nm" == "2" ]] && echo "host" || echo "bridge"
}
_docker_show_result() {
    local cname="$1"
    local port="$2"
    local gw_token="$3"
    local network_mode="$4"
    local edition="$5"
    local local_ip=""
    local_ip=$(get_local_ip)
    local display_port="$port"
    [[ "$network_mode" == "host" ]] && display_port="$OPENCLAW_PORT"
    echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║     OpenClaw ${edition} 部署完成!${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${BOLD}容器名:${NC}   ${cname}"
    echo -e "  ${BOLD}令牌:${NC}     ${YELLOW}${gw_token}${NC}"
    echo -e "  ${BOLD}本机:${NC}     ${CYAN}http://127.0.0.1:${display_port}${NC}"
    echo -e "  ${BOLD}局域网:${NC}   ${CYAN}http://${local_ip}:${display_port}${NC}"
    echo -e "\n${YELLOW}浏览器打开局域网地址,在连接框中填入令牌即可登录${NC}"
    echo -e "${CYAN}部署完成后通过主菜单 [3] 配置API密钥${NC}"
    echo -e "${RED}勿将端口暴露公网!${NC}\n"
}
_docker_manage_menu() {
    local cname="$1"
    local label="$2"
    local redeploy_func="$3"
    local cstatus=""
    cstatus=$(docker inspect --format='{{.State.Status}}' "$cname" 2>/dev/null || echo "unknown")
    echo -e "${CYAN}已有${label}容器:${NC} ${BOLD}${cstatus}${NC}\n"
    echo -e "  ${BOLD}1)${NC} 启动  ${BOLD}2)${NC} 停止  ${BOLD}3)${NC} 重启"
    echo -e "  ${BOLD}4)${NC} 删除重部署  ${BOLD}5)${NC} 日志  ${BOLD}6)${NC} Shell"
    [[ "$label" == "中文版" ]] && echo -e "  ${BOLD}7)${NC} 升级镜像"
    echo -e "  ${BOLD}0)${NC} 返回"
    echo -ne "\n${BOLD}选择: ${NC}"
    local dc=""
    read_input dc "0"
    case "$dc" in
        1) docker start "$cname" && msg_ok "已启动" && wait_gateway_ready 20 && show_dashboard_info ;;
        2) docker stop "$cname" && msg_ok "已停止" ;;
        3) docker restart "$cname" && msg_ok "已重启" && wait_gateway_ready 20 && show_dashboard_info ;;
        4) confirm "确认删除容器?" && { docker rm -f "$cname" 2>/dev/null; $redeploy_func; } ;;
        5) trap 'echo ""; msg_info "退出"' INT; docker logs -f "$cname" 2>&1 || true; trap - INT ;;
        6) docker exec -it "$cname" /bin/sh 2>/dev/null || docker exec -it "$cname" /bin/bash 2>/dev/null || true ;;
        7) [[ "$label" == "中文版" ]] && _zh_upgrade ;;
        0) return 0 ;;
    esac
}
_zh_upgrade() {
    msg_step "升级中文版镜像..."
    _select_zh_image
    local image="${G_DOCKER_IMAGE}:latest"
    if docker pull "$image" 2>&1 | tail -3; then
        msg_ok "镜像已更新"
        confirm "重启容器应用新镜像?" && {
            docker stop "$DOCKER_CONTAINER_ZH" 2>/dev/null || true
            docker rm "$DOCKER_CONTAINER_ZH" 2>/dev/null || true
            msg_info "容器已删除,请重新选择Docker部署"
        }
    else
        msg_fail "镜像升级失败"
    fi
}
deploy_docker() {
    msg_title "${DOCKER_ICO} Docker 部署"
    detect_system; detect_region
    if ! has_cmd docker; then
        msg_warn "Docker未安装"
        confirm "安装Docker?" || { wait_and_return 2; return 0; }
        _install_docker || { wait_and_return 3; return 0; }
    fi
    echo -e "${CYAN}${BOLD}选择版本:${NC}"
    echo -e "  ${BOLD}1)${NC} 官方版"
    echo -e "  ${BOLD}2)${NC} 中文汉化版 ${CYAN}(推荐)${NC}"
    echo -e "  ${BOLD}0)${NC} 返回"
    echo -ne "\n${BOLD}选择[0-2](默认:2): ${NC}"
    local dv=""
    read_input dv "2"
    case "$dv" in
        1) _deploy_docker_official ;;
        2) _deploy_docker_zh ;;
        0) return 0 ;;
        *) msg_warn "无效"; sleep 1; deploy_docker ;;
    esac
    wait_and_return 3
}
_deploy_docker_official() {
    if _container_exists "$DOCKER_CONTAINER"; then
        _docker_manage_menu "$DOCKER_CONTAINER" "官方版" _deploy_docker_official_new
        return 0
    fi
    _deploy_docker_official_new
}
_deploy_docker_official_new() {
    _select_official_image
    local tag=""
    tag=$(select_docker_version "${G_DOCKER_IMAGE}")
    local image="${G_DOCKER_IMAGE}:${tag}"
    echo -ne "\n  端口(默认:${OPENCLAW_PORT}): "
    local port=""
    read_input port "$OPENCLAW_PORT"
    echo -ne "  数据目录(默认:${DOCKER_DATA_DIR}): "
    local data_dir=""
    read_input data_dir "$DOCKER_DATA_DIR"
    local network_mode=""
    network_mode=$(_ask_network_mode)
    local gw_token=""
    prompt_gateway_token gw_token ""
    local vol="$DOCKER_VOL_OFFICIAL"
    docker volume create "$vol" >/dev/null 2>&1 || true
    mkdir -p "${data_dir}/workspace"
    msg_step "拉取镜像 ${image}..."
    if ! docker pull "${image}" 2>&1 | tail -3; then
        msg_warn "主镜像失败,尝试备用..."
        local pulled=false
        for fb in "$DOCKER_IMAGE_DR34M:latest" "$DOCKER_IMAGE_1PANEL:latest" "$DOCKER_IMAGE_ALPINE:latest" "$DOCKER_IMAGE_MIRROR:latest"; do
            [[ "$fb" == "${image}" ]] && continue
            docker pull "$fb" 2>&1 | tail -2 && { image="$fb"; pulled=true; break; }
        done
        $pulled || { msg_fail "镜像拉取失败"; return 1; }
    fi
    msg_ok "镜像就绪: ${image}"
    msg_step "初始化配置..."
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.mode local >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.bind lan >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.auth.mode token >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.auth.token "$gw_token" >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.controlUi.allowInsecureAuth true >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true
    msg_ok "配置写入完成"
    msg_step "启动容器 ${DOCKER_CONTAINER}..."
    local run_cmd=(
        docker run -d
        --name "$DOCKER_CONTAINER"
        --restart unless-stopped
        -v "${vol}:/root/.openclaw"
        -v "${data_dir}/workspace:/root/workspace"
        -e "OPENCLAW_GATEWAY_TOKEN=${gw_token}"
    )
    if [[ "$network_mode" == "host" ]]; then
        run_cmd+=(--network host)
    else
        run_cmd+=(-p "${port}:18789" --add-host=host.docker.internal:host-gateway)
    fi
    run_cmd+=("${image}" openclaw gateway run)
    if "${run_cmd[@]}" 2>&1 | tail -2; then
        sleep 4
        local status=""
        status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")
        if [[ "$status" != "running" ]]; then
            msg_fail "容器启动后退出(状态:$status)"
            echo -e "\n${YELLOW}容器日志:${NC}"; print_line
            docker logs --tail 30 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'; print_line
            return 1
        fi
        msg_ok "容器已启动"
        wait_gateway_ready 30
        _docker_show_result "$DOCKER_CONTAINER" "$port" "$gw_token" "$network_mode" "官方版"
        log "Docker official deployed"
    else
        msg_fail "容器启动失败"
        docker logs --tail 20 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /' || true
        return 1
    fi
}
_deploy_docker_zh() {
    if _container_exists "$DOCKER_CONTAINER_ZH"; then
        _docker_manage_menu "$DOCKER_CONTAINER_ZH" "中文版" _deploy_docker_zh_new
        return 0
    fi
    _deploy_docker_zh_new
}
_deploy_docker_zh_new() {
    _select_zh_image
    echo -e "\n${CYAN}${BOLD}── 中文版 Tag ──${NC}"
    echo -e "  ${BOLD}1)${NC} latest ${GREEN}(稳定推荐)${NC}"
    echo -e "  ${BOLD}2)${NC} nightly ${DIM}(每小时同步上游)${NC}"
    echo -ne "\n${BOLD}选择[1-2](默认:1): ${NC}"
    local tc=""
    read_input tc "1"
    local zh_tag="latest"
    [[ "$tc" == "2" ]] && zh_tag="nightly"
    local image="${G_DOCKER_IMAGE}:${zh_tag}"
    echo -ne "\n  端口(默认:${OPENCLAW_PORT}): "
    local port=""
    read_input port "$OPENCLAW_PORT"
    echo -ne "  数据目录(默认:${DOCKER_DATA_DIR}): "
    local data_dir=""
    read_input data_dir "$DOCKER_DATA_DIR"
    local network_mode=""
    network_mode=$(_ask_network_mode)
    local gw_token=""
    prompt_gateway_token gw_token ""
    local vol="$DOCKER_VOL_ZH"
    msg_step "拉取镜像 ${image}..."
    if ! docker pull "${image}" 2>&1 | tail -3; then
        msg_warn "主镜像失败,尝试备用..."
        local fb=""
        [[ "$G_DOCKER_IMAGE" == "$DOCKER_IMAGE_ZH_HUB" ]] && fb="${DOCKER_IMAGE_ZH_GHCR}:${zh_tag}" || fb="${DOCKER_IMAGE_ZH_HUB}:${zh_tag}"
        docker pull "${fb}" 2>&1 | tail -2 && image="${fb}" || { msg_fail "镜像拉取失败"; return 1; }
    fi
    msg_ok "镜像就绪: ${image}"
    docker volume create "$vol" >/dev/null 2>&1 || true
    mkdir -p "${data_dir}/workspace"
    msg_step "初始化配置(按官方文档流程)..."
    echo -e "\n${YELLOW}${BOLD}即将运行 openclaw onboard 初始化向导${NC}"
    echo -e "${DIM}向导说明:${NC}"
    echo -e "  • 遇到 AI Provider 选择 → 可直接跳过(稍后菜单[3]配置)"
    echo -e "  • 遇到 Gateway mode → 选 local"
    echo -e "  • 遇到 Bind → 选 lan"
    echo -e "  • 遇到 Token → 填入: ${YELLOW}${gw_token}${NC}"
    echo -e "  • 遇到 Telegram/WhatsApp 等通道 → 跳过"
    echo -e "\n${CYAN}按回车开始向导...${NC}"
    read -r </dev/tty 2>/dev/null || true
    docker run --rm -it \
        -v "${vol}:/root/.openclaw" \
        "${image}" openclaw onboard </dev/tty || true
    msg_step "补充关键配置参数..."
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.mode local >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.bind lan >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.auth.mode token >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.auth.token "$gw_token" >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.controlUi.allowInsecureAuth true >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true >/dev/null 2>&1 || true
    docker run --rm -v "${vol}:/root/.openclaw" "${image}" openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true
    msg_ok "配置补充完成"
    msg_step "启动容器 ${DOCKER_CONTAINER_ZH}..."
    local run_cmd=(
        docker run -d
        --name "$DOCKER_CONTAINER_ZH"
        --restart unless-stopped
        -v "${vol}:/root/.openclaw"
        -v "${data_dir}/workspace:/root/workspace"
        -e "OPENCLAW_GATEWAY_TOKEN=${gw_token}"
    )
    if [[ "$network_mode" == "host" ]]; then
        run_cmd+=(--network host)
    else
        run_cmd+=(-p "${port}:18789" --add-host=host.docker.internal:host-gateway)
    fi
    run_cmd+=("${image}" openclaw gateway run)
    if "${run_cmd[@]}" 2>&1 | tail -2; then
        sleep 4
        local status=""
        status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER_ZH" 2>/dev/null || echo "unknown")
        if [[ "$status" != "running" ]]; then
            msg_fail "容器启动后退出(状态:$status)"
            echo -e "\n${YELLOW}容器日志:${NC}"; print_line
            docker logs --tail 30 "$DOCKER_CONTAINER_ZH" 2>&1 | sed 's/^/  /'; print_line
            return 1
        fi
        msg_ok "容器已启动"
        wait_gateway_ready 30
        _docker_show_result "$DOCKER_CONTAINER_ZH" "$port" "$gw_token" "$network_mode" "中文汉化版"
        log "Docker ZH deployed: image=$image net=$network_mode"
    else
        msg_fail "容器启动失败"
        docker logs --tail 20 "$DOCKER_CONTAINER_ZH" 2>&1 | sed 's/^/  /' || true
        return 1
    fi
}
install_openclaw_npm() {
    msg_title "${ROCKET} npm 安装 OpenClaw"
    detect_system; detect_region
    install_system_deps
    if has_cmd openclaw; then
        local iv=""
        iv=$(openclaw --version 2>/dev/null || echo "未知")
        msg_warn "已安装($iv)"
        confirm "重新安装?" || { wait_and_return 2; return 0; }
    fi
    msg_step "步骤1/4: Node.js"
    install_nodejs || { msg_fail "Node.js安装失败"; wait_and_return 3; return 1; }
    msg_step "步骤2/4: 安装OpenClaw"
    echo -e "  ${BOLD}1)${NC} 官方脚本 ${GREEN}(推荐)${NC}"
    echo -e "  ${BOLD}2)${NC} npm直装"
    echo -e "  ${BOLD}3)${NC} GitHub源码编译"
    echo -ne "\n${BOLD}选择[1-3](默认:1): ${NC}"
    local ic=""
    read_input ic "1"
    local npm_args=""
    is_china && npm_args="--registry=${NPM_MIRROR_CN}"
    case "$ic" in
        2)
            msg_info "npm install -g openclaw@latest"
            npm install -g openclaw@latest ${npm_args:+"$npm_args"} >> "$LOG_FILE" 2>&1 \
                && msg_ok "npm安装成功" || { msg_fail "npm安装失败"; tail -10 "$LOG_FILE" | sed 's/^/  /'; } ;;
        3)
            echo -ne "${BOLD}仓库(默认:${GITHUB_REPO}): ${NC}"
            local repo=""
            read_input repo "$GITHUB_REPO"
            local tmpd="/tmp/oc_src_$$"
            git clone "$repo" "$tmpd" >> "$LOG_FILE" 2>&1 || { msg_fail "clone失败"; return 1; }
            pushd "$tmpd" > /dev/null
            has_cmd pnpm || npm install -g pnpm ${npm_args:+"$npm_args"} >> "$LOG_FILE" 2>&1 || true
            pnpm install >> "$LOG_FILE" 2>&1 || true
            pnpm run build >> "$LOG_FILE" 2>&1 || true
            pnpm install -g . >> "$LOG_FILE" 2>&1 || true
            popd > /dev/null; rm -rf "$tmpd" ;;
        *)
            msg_info "下载官方脚本..."
            if curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 --connect-timeout 10 "$OPENCLAW_INSTALL_URL" 2>/dev/null | bash >> "$LOG_FILE" 2>&1; then
                msg_ok "官方脚本成功"
            else
                msg_warn "官方脚本失败,回退npm..."
                npm install -g openclaw@latest ${npm_args:+"$npm_args"} >> "$LOG_FILE" 2>&1 || true
            fi ;;
    esac
    _refresh_node_path
    has_cmd openclaw || { msg_fail "安装失败"; tail -10 "$LOG_FILE" | sed 's/^/  /'; wait_and_return 5; return 1; }
    msg_ok "OpenClaw $(openclaw --version 2>/dev/null) 安装成功"
    msg_step "步骤3/4: 初始化配置"
    ensure_minimal_config
    msg_step "步骤4/4: 配置AI并启动"
    echo -e "\n  ${BOLD}1)${NC} 配置自定义API ${GREEN}(推荐)${NC}"
    echo -e "  ${BOLD}2)${NC} 配置内置Provider"
    echo -e "  ${BOLD}3)${NC} 跳过,直接启动"
    echo -ne "\n${BOLD}选择: ${NC}"
    local next=""
    read_input next "3"
    case "$next" in
        1) configure_custom_api ;;
        2) configure_builtin_providers ;;
        *) openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true; service_start; wait_gateway_ready 30 ;;
    esac
    confirm "配置局域网访问?" && configure_lan_access || show_dashboard_info
    log "npm install completed"
    wait_and_return 3
}
_try_systemd() {
    local svc=""
    for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
        ${SUDO:-} systemctl "$@" "$svc" 2>/dev/null && return 0
        systemctl --user "$@" "$svc" 2>/dev/null && return 0
    done; return 1
}
_try_openrc() {
    local action="$1"
    local svc=""
    for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
        ${SUDO:-} rc-service "$svc" "$action" 2>/dev/null && return 0
    done; return 1
}
_try_launchd() {
    local action="$1"
    local plist=""
    for plist in "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist" \
                 "$HOME/Library/LaunchAgents/com.openclaw.gateway.plist"; do
        [[ ! -f "$plist" ]] && continue
        case "$action" in
            start) launchctl load "$plist" 2>/dev/null && return 0 ;;
            stop) launchctl unload "$plist" 2>/dev/null && return 0 ;;
            restart) launchctl unload "$plist" 2>/dev/null; launchctl load "$plist" 2>/dev/null && return 0 ;;
            status) launchctl list 2>/dev/null | grep -i openclaw && return 0 ;;
        esac
    done; return 1
}
service_start() {
    detect_system
    if is_docker_mode; then
        for cn in "$DOCKER_CONTAINER_ZH" "$DOCKER_CONTAINER"; do
            _container_exists "$cn" && docker start "$cn" >/dev/null 2>&1 || true
        done; return 0
    fi
    has_cmd openclaw || return 1
    ensure_minimal_config
    pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
    rm -f "$OPENCLAW_CONFIG_DIR/gateway.lock" "$OPENCLAW_CONFIG_DIR"/*.pid 2>/dev/null || true
    sleep 1
    local port_pid=""
    has_cmd lsof && port_pid=$(lsof -ti :"$OPENCLAW_PORT" 2>/dev/null | head -1 || true)
    has_cmd ss && [[ -z "$port_pid" ]] && port_pid=$(ss -lntp 2>/dev/null | grep ":$OPENCLAW_PORT" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    [[ -n "$port_pid" ]] && { kill -9 "$port_pid" 2>/dev/null || true; sleep 2; }
    case "$SERVICE_MANAGER" in
        systemd) _try_systemd start && return 0 ;;
        launchd) _try_launchd start && return 0 ;;
        openrc) _try_openrc start && return 0 ;;
    esac
    mkdir -p "$OPENCLAW_LOG_DIR"
    local out_log="$OPENCLAW_LOG_DIR/gateway.out"
    : > "$out_log"
    local bin=""
    bin=$(command -v openclaw); [[ -z "$bin" ]] && return 1
    nohup "$bin" gateway run > "$out_log" 2>&1 &
}
service_stop() {
    detect_system
    if is_docker_mode; then
        for cn in "$DOCKER_CONTAINER_ZH" "$DOCKER_CONTAINER"; do
            _container_running "$cn" && docker stop "$cn" >/dev/null 2>&1 || true
        done; return 0
    fi
    case "$SERVICE_MANAGER" in
        systemd) _try_systemd stop 2>/dev/null ;;
        launchd) _try_launchd stop 2>/dev/null ;;
        openrc) _try_openrc stop 2>/dev/null ;;
    esac
    has_cmd openclaw && openclaw gateway stop 2>/dev/null || true
    pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
}
service_restart() { service_stop; sleep 2; service_start; }
service_status() {
    detect_system
    if is_docker_mode; then
        for cn in "$DOCKER_CONTAINER_ZH" "$DOCKER_CONTAINER"; do
            _container_exists "$cn" || continue
            echo -e "${BOLD}容器[$cn]:${NC}"
            docker inspect --format='  状态: {{.State.Status}}' "$cn" 2>/dev/null || true
            echo ""; docker logs --tail 10 "$cn" 2>&1 | sed 's/^/  /' || true; echo ""
        done; return 0
    fi
    case "$SERVICE_MANAGER" in
        systemd) _try_systemd status --no-pager ;;
        launchd) _try_launchd status ;;
        openrc) _try_openrc status ;;
    esac
}
manage_service() {
    local action="$1"
    detect_system
    local docker_mode=false
    is_docker_mode && docker_mode=true
    case "$action" in
        start)
            msg_step "启动Gateway..."
            if $docker_mode; then
                service_start; sleep 5; wait_gateway_ready 20; show_dashboard_info
                wait_and_return 5; return 0
            fi
            if ! json_is_valid "$(get_active_config_path)"; then
                msg_fail "配置损坏,请先修复"; wait_and_return 3; return 0
            fi
            openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
            service_start; wait_gateway_ready 30
            gateway_health_check && show_dashboard_info || {
                msg_fail "Gateway启动失败"
                tail -25 "$OPENCLAW_LOG_DIR/gateway.out" 2>/dev/null | sed 's/^/  /' || true
            } ;;
        stop)
            confirm "确认停止?" && { service_stop; msg_ok "已停止"; } || msg_info "已取消" ;;
        restart)
            msg_step "重启..."
            if $docker_mode; then
                for cn in "$DOCKER_CONTAINER_ZH" "$DOCKER_CONTAINER"; do
                    _container_exists "$cn" && docker restart "$cn" >/dev/null 2>&1 || true
                done
                sleep 5; wait_gateway_ready 20
            else service_stop; sleep 2; service_start; wait_gateway_ready 25; fi
            show_dashboard_info ;;
        status)
            msg_step "状态:"
            echo ""; service_status
            echo -e "\n${CYAN}端口(${OPENCLAW_PORT}):${NC}"
            ss -lntp 2>/dev/null | grep ":$OPENCLAW_PORT" | sed 's/^/  /' || echo "  未监听"
            load_config_from_file; show_dashboard_info ;;
    esac
    wait_and_return 5
}
show_dashboard_info() {
    local local_ip=""
    local_ip=$(get_local_ip)
    [[ -z "${G_DEFAULT_PROVIDER:-}" ]] && load_config_from_file
    local bind_mode="loopback"
    local token=""
    local cfg=""
    cfg=$(get_active_config_path)
    if [[ -f "$cfg" ]] && json_is_valid "$cfg" && has_cmd python3; then
        bind_mode=$(python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('gateway',{}).get('bind','loopback'))
except: print('loopback')
" "$cfg" 2>/dev/null || echo "loopback")
        token=$(get_gateway_token || true)
    fi
    if is_docker_mode && [[ -z "$token" ]]; then
        local cname=""
        cname=$(_get_active_container)
        [[ -n "$cname" ]] && token=$(docker exec "$cname" openclaw config get gateway.auth.token 2>/dev/null | tr -d '[:space:]' || echo "")
    fi
    echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║            OpenClaw 访问信息                              ║${NC}"
    echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}本机:${NC}    ${CYAN}http://127.0.0.1:${OPENCLAW_PORT}${NC}"
    if [[ "$bind_mode" == "lan" ]] || is_docker_mode; then
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}局域网:${NC}  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${NC} ${GREEN}(已启用)${NC}"
    else
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}局域网:${NC}  ${DIM}未启用(菜单[5]启用)${NC}"
    fi
    [[ -n "$token" ]] && echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}令牌:${NC}    ${YELLOW}${token}${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}部署:${NC}    $(_detect_deploy_mode)"
    if [[ -n "${G_DEFAULT_PROVIDER:-}" ]]; then
        local dm="${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
        dm="${dm%%,*}"
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}默认AI:${NC}  ${CYAN}${G_DEFAULT_PROVIDER}${NC} → ${dm}"
    fi
    echo -e "${GREEN}${BOLD}║${NC}  ${RED}勿暴露公网!${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    if [[ -n "$token" ]]; then
        echo -e "\n${CYAN}浏览器访问局域网地址,连接时填入令牌: ${YELLOW}${token}${NC}\n"
    fi
}
auto_detect_api_type() {
    local url="$1"
    local key="$2"
    [[ "$url" =~ :11434 ]] && { echo "ollama"; return; }
    [[ "$url" =~ api\.anthropic\.com ]] && { echo "anthropic-messages"; return; }
    local resp=""
    if [[ "$key" != "local" && -n "$key" ]]; then
        resp=$(curl -s --max-time 5 -H "Authorization: Bearer ${key}" "${url}/v1/models" 2>/dev/null || true)
    else
        resp=$(curl -s --max-time 5 "${url}/v1/models" 2>/dev/null || true)
    fi
    echo "$resp" | grep -q '"data"' 2>/dev/null && { echo "openai-completions"; return; }
    resp=$(curl -s --max-time 5 "${url}/api/tags" 2>/dev/null || true)
    echo "$resp" | grep -q '"models"' 2>/dev/null && { echo "ollama"; return; }
    echo "openai-completions"
}
auto_detect_models() {
    local url="$1"
    local key="$2"
    local api_type="$3"
    if [[ "$api_type" == "ollama" ]]; then
        local resp=""
        resp=$(curl -s --max-time 5 "${url}/api/tags" 2>/dev/null || true)
        if has_cmd python3 && echo "$resp" | grep -q '"models"'; then
            python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(','.join(m['name'] for m in d.get('models',[])[:10]))" <<< "$resp" 2>/dev/null
            return
        fi
    fi
    local resp=""
    if [[ "$key" != "local" && -n "$key" ]]; then
        resp=$(curl -s --max-time 5 -H "Authorization: Bearer ${key}" "${url}/v1/models" 2>/dev/null || true)
    else
        resp=$(curl -s --max-time 5 "${url}/v1/models" 2>/dev/null || true)
    fi
    if has_cmd python3 && echo "$resp" | grep -q '"data"'; then
        python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(','.join(m['id'] for m in d.get('data',[])[:10]))" <<< "$resp" 2>/dev/null
    fi
}
test_api_connection() {
    local url="$1"
    local key="$2"
    msg_info "测试API连接..."
    local code=""
    if [[ "$key" != "local" && -n "$key" ]]; then
        code=$(curl -s -o /dev/null --max-time 10 --connect-timeout 5 -w "%{http_code}" -H "Authorization: Bearer ${key}" "${url}/v1/models" 2>/dev/null || echo "000")
    else
        code=$(curl -s -o /dev/null --max-time 10 --connect-timeout 5 -w "%{http_code}" "${url}/v1/models" 2>/dev/null || echo "000")
    fi
    [[ "$code" =~ ^(200|401|403)$ ]] && { msg_ok "API可达(HTTP $code)"; return 0; } || { msg_warn "API响应:HTTP $code"; return 1; }
}
configure_custom_api() {
    msg_title "配置自定义 API"
    local cfg=""
    cfg=$(get_active_config_path)
    local docker_mode=false
    is_docker_mode && docker_mode=true
    echo -e "${DIM}URL示例: https://api.deepseek.com/v1 / http://192.168.x.x:3000 / http://127.0.0.1:11434${NC}"
    $docker_mode && echo -e "${YELLOW}Docker模式:局域网URL将自动转换为host.docker.internal${NC}"
    echo -ne "\n${CYAN}Provider名称(推荐:openai): ${NC}"
    local pname=""
    read_input pname "openai"
    pname=$(echo "$pname" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    echo -ne "${CYAN}API Base URL: ${NC}"
    local base_url=""
    read_input base_url ""
    [[ -z "$base_url" ]] && { msg_warn "URL不能为空"; wait_and_return 2; return 1; }
    base_url="${base_url%/}"
    local final_url="$base_url"
    if $docker_mode && is_lan_url "$base_url"; then
        local conv=""
        conv=$(convert_url_for_docker "$base_url")
        if [[ "$conv" != "$base_url" ]]; then
            msg_warn "检测到局域网URL,建议转换:"
            echo -e "  原始: $base_url\n  转换: ${GREEN}$conv${NC}"
            confirm "使用转换后URL?" && final_url="$conv"
        fi
    fi
    echo -ne "\n${CYAN}API Key(本地服务输入'local'): ${NC}"
    local api_key=""
    read_input_silent api_key "local"
    test_api_connection "$base_url" "$api_key" || true
    echo -e "\n${CYAN}API类型:${NC}"
    echo -e "  1) openai-completions  2) openai-responses  3) ollama  4) anthropic-messages  5) 自动检测"
    echo -ne "${CYAN}选择[1-5](默认:5): ${NC}"
    local ac=""
    read_input ac "5"
    local api_type=""
    case "$ac" in
        1) api_type="openai-completions" ;;
        2) api_type="openai-responses" ;;
        3) api_type="ollama" ;;
        4) api_type="anthropic-messages" ;;
        *) msg_info "自动检测..."; api_type=$(auto_detect_api_type "$base_url" "$api_key"); msg_ok "检测到:$api_type" ;;
    esac
    msg_info "探测可用模型..."
    local detected_models=""
    detected_models=$(auto_detect_models "$base_url" "$api_key" "$api_type")
    if [[ -n "$detected_models" ]]; then
        msg_ok "发现模型: $detected_models"
        echo -ne "${CYAN}确认或覆盖(回车使用): ${NC}"
        local um=""
        read_input um "$detected_models"
        detected_models="$um"
    else
        echo -ne "${CYAN}模型ID(多个逗号分隔): ${NC}"
        read_input detected_models ""
        [[ -z "$detected_models" ]] && { msg_warn "模型不能为空"; wait_and_return 2; return 1; }
    fi
    local default_model=""
    if [[ "$detected_models" == *","* ]]; then
        echo -e "\n${CYAN}选择默认模型:${NC}"
        local i=1
        local -a m_arr=()
        IFS=',' read -ra m_arr <<< "$detected_models"
        for m in "${m_arr[@]}"; do m=$(echo "$m" | xargs); echo "  ${i}) $m"; ((i++)); done
        echo -ne "${CYAN}选择[1-$((i-1))]: ${NC}"
        local dc=""
        read_input dc "1"
        [[ "$dc" =~ ^[0-9]+$ ]] && (( dc >= 1 && dc <= ${#m_arr[@]} )) || dc=1
        default_model=$(echo "${m_arr[$((dc-1))]}" | xargs)
    else
        default_model=$(echo "$detected_models" | xargs)
    fi
    local inject_openai=false
    [[ "$pname" != "openai" ]] && confirm "同时以openai别名注入认证(推荐)?" && inject_openai=true
    G_API_URLS["$pname"]="$final_url"; G_API_KEYS["$pname"]="$api_key"
    G_API_TYPES["$pname"]="$api_type"; G_API_MODELS["$pname"]="$detected_models"
    G_DEFAULT_PROVIDER="$pname"
    echo ""; print_line; echo -e "${GREEN}开始部署...${NC}"; print_line
    msg_step "[1/6] 写入配置"
    _write_custom_provider_config "$pname" "$default_model"
    msg_step "[2/6] 同步Agent认证"
    sync_agent_auth "$pname" "$final_url" "$api_key" "$api_type" "main" || true
    if $inject_openai; then
        msg_step "[3/6] 注入openai别名"
        sync_agent_auth "openai" "$final_url" "$api_key" "$api_type" "main" || true
    else msg_step "[3/6] 跳过openai别名"; fi
    msg_step "[4/6] Schema清理"
    sanitize_config_for_schema | sed 's/^/  /'
    msg_step "[5/6] 固化默认模型"
    _persist_default_model "$pname" "$default_model" && msg_ok "默认模型:${pname}/${default_model}"
    msg_step "[6/6] 重启Gateway"
    is_openclaw_installed && openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
    service_restart; wait_gateway_ready 30
    echo -e "\n${GREEN}配置完成! Provider:${CYAN}${pname}${NC} 模型:${GREEN}${pname}/${default_model}${NC}"
    $inject_openai && echo -e "openai别名: ${GREEN}已注入${NC}"
    echo ""; show_dashboard_info
    wait_and_return 5
}
_write_custom_provider_config() {
    local pname="$1"
    local default_model="$2"
    local cfg=""
    cfg=$(get_active_config_path); mkdir -p "$(dirname "$cfg")"
    has_cmd python3 || return 1
    local base_url="${G_API_URLS[$pname]:-}"
    local api_key="${G_API_KEYS[$pname]:-local}"
    local api_type="${G_API_TYPES[$pname]:-openai-completions}"
    local models_str="${G_API_MODELS[$pname]:-}"
    python3 - "$cfg" "$pname" "$base_url" "$api_key" "$api_type" "$models_str" "$default_model" << 'PYEOF'
import json,sys,os
cfg_path,pname,base_url,api_key,api_type,models_str,default_model = sys.argv[1:8]
VALID_BIND=["auto","lan","loopback","custom","tailnet"]
os.makedirs(os.path.dirname(cfg_path),exist_ok=True)
try:
    with open(cfg_path) as f: c=json.load(f)
except: c={}
for bad in ["ui","defaultProvider"]: c.pop(bad,None)
if "agents" in c and isinstance(c["agents"],dict):
    for k in list(c["agents"].keys()):
        if k not in ("defaults","list"): del c["agents"][k]
gw=c.setdefault("gateway",{}); gw.setdefault("mode","local")
if gw.get("bind") not in VALID_BIND: gw["bind"]="loopback"
c.setdefault("models",{}); c["models"]["mode"]="merge"; c["models"].setdefault("providers",{})
ml=[{"id":m.strip(),"name":m.strip(),"reasoning":False,"input":["text"],
     "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},
     "contextWindow":128000,"maxTokens":8192} for m in models_str.split(",") if m.strip()]
c["models"]["providers"][pname]={"baseUrl":base_url,"apiKey":api_key,"api":api_type,"models":ml}
agents=c.setdefault("agents",{}); defaults=agents.setdefault("defaults",{})
defaults.setdefault("workspace",os.path.expanduser("~/.openclaw/workspace"))
mc=defaults.setdefault("model",{})
if not isinstance(mc,dict): mc={}; defaults["model"]=mc
mc["primary"]=f"{pname}/{default_model}"
if "list" not in agents: agents["list"]=[{"id":"main","default":True}]
tmp=cfg_path+".tmp"
with open(tmp,"w") as f: json.dump(c,f,indent=2,ensure_ascii=False)
with open(tmp) as f: json.load(f)
os.replace(tmp,cfg_path); print("OK")
PYEOF
    chmod 600 "$cfg"; msg_ok "配置已写入"
}
_persist_default_model() {
    local provider="$1"
    local model="$2"
    is_openclaw_installed || return 1
    local full="${provider}/${model}"
    openclaw_cmd config set agents.defaults.model.primary "$full" >/dev/null 2>&1 && return 0
    has_cmd python3 || return 1
    local cfg=""
    cfg=$(get_active_config_path)
    [[ -f "$cfg" ]] && json_is_valid "$cfg" || return 1
    python3 - "$cfg" "$full" << 'PYEOF'
import json,sys,os
p,fm=sys.argv[1],sys.argv[2]
try:
    with open(p) as f: c=json.load(f)
except: sys.exit(1)
a=c.setdefault("agents",{}); d=a.setdefault("defaults",{})
mc=d.setdefault("model",{})
if not isinstance(mc,dict): mc={}; d["model"]=mc
mc["primary"]=fm
if "list" not in a: a["list"]=[{"id":"main","default":True}]
tmp=p+".tmp"
with open(tmp,"w") as f: json.dump(c,f,indent=2,ensure_ascii=False)
os.replace(tmp,p); print("OK")
PYEOF
    chmod 600 "$cfg"
}
sync_agent_auth() {
    local pname="$1"
    local base_url="$2"
    local api_key="$3"
    local api_type="$4"
    local agent_name="${5:-main}"
    is_openclaw_installed || return 1
    _write_agent_auth_file "$agent_name" "$pname" "$base_url" "$api_key" "$api_type" \
        && msg_ok "Agent[$agent_name] ← $pname" || { msg_warn "Agent认证写入失败($pname)"; return 1; }
}
_write_agent_auth_file() {
    local agent_name="$1"
    local provider="$2"
    local base_url="$3"
    local api_key="$4"
    local api_type="$5"
    local base_dir=""
    is_docker_mode && base_dir="${DOCKER_DATA_DIR}/.openclaw/agents" || base_dir="$OPENCLAW_AGENTS_DIR"
    local agent_dir="${base_dir}/${agent_name}/agent"
    local auth_json="${agent_dir}/auth-profiles.json"
    mkdir -p "$agent_dir"; has_cmd python3 || return 1
    python3 - "$auth_json" "$provider" "$base_url" "$api_key" "$api_type" << 'PYEOF'
import json,sys,os
path,provider,base_url,api_key,api_type=sys.argv[1:6]
try:
    with open(path) as f: data=json.load(f)
    if not isinstance(data,dict): data={}
except: data={}
entry={"provider":provider,"apiKey":api_key,"baseUrl":base_url,"api":api_type,"kind":"static","portable":True}
if "profiles" in data and isinstance(data["profiles"],dict): data["profiles"][provider]=entry
elif "providers" in data and isinstance(data["providers"],dict): data["providers"][provider]=entry
else: data[provider]=entry
tmp=path+".tmp"
with open(tmp,"w") as f: json.dump(data,f,indent=2,ensure_ascii=False)
with open(tmp) as f: json.load(f)
os.replace(tmp,path); print("OK")
PYEOF
    chmod 600 "$auth_json" 2>/dev/null
}
configure_builtin_providers() {
    msg_title "内置 Provider 密钥"
    local cfg=""
    cfg=$(get_active_config_path)
    if [[ -f "$cfg" ]] && ! json_is_valid "$cfg"; then msg_fail "配置损坏,请先修复"; wait_and_return 3; return 1; fi
    load_config_from_file; mkdir -p "$(dirname "$cfg")"
    if [[ ${#G_API_KEYS[@]} -gt 0 ]]; then
        echo -e "${CYAN}已有配置:${NC}"
        for p in anthropic openai google deepseek groq mistral; do
            [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
            local dt=""
            [[ "${G_DEFAULT_PROVIDER:-}" == "$p" ]] && dt=" ${GREEN}[默认]${NC}"
            echo -e "  ${BOLD}${p}${NC}: ${DIM}${G_API_KEYS[$p]:0:8}****${NC} → ${G_API_MODELS[$p]%%,*}${dt}"
        done; echo ""
    fi
    echo "  1) Anthropic  2) OpenAI  3) Google  4) DeepSeek  5) Groq  6) Mistral  0) 保存"
    while true; do
        echo -ne "\n${BOLD}编号(0完成): ${NC}"
        local c=""
        read_input c "0"
        case "$c" in
            0) break ;;
            1) _cfg_builtin anthropic "sk-ant-..." "claude-sonnet-4-5" ;;
            2) _cfg_builtin openai "sk-..." "gpt-4o" ;;
            3) _cfg_builtin google "" "gemini-2.5-flash" ;;
            4) _cfg_builtin deepseek "sk-..." "deepseek-chat" ;;
            5) _cfg_builtin groq "gsk_..." "llama-3.3-70b-versatile" ;;
            6) _cfg_builtin mistral "" "mistral-large-latest" ;;
            *) msg_warn "请输入0-6" ;;
        esac
    done
    if [[ ${#G_API_KEYS[@]} -eq 0 && ${#G_API_URLS[@]} -eq 0 ]]; then msg_warn "未配置"; wait_and_return 2; return 0; fi
    msg_step "保存..."; ensure_minimal_config; _write_builtin_providers_config
    if is_openclaw_installed && confirm "同步认证到main Agent?"; then
        for p in anthropic openai google deepseek groq mistral; do
            [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
            local built_url=""
            case "$p" in
                anthropic) built_url="https://api.anthropic.com" ;;
                openai) built_url="https://api.openai.com/v1" ;;
                google) built_url="https://generativelanguage.googleapis.com" ;;
                deepseek) built_url="https://api.deepseek.com/v1" ;;
                groq) built_url="https://api.groq.com/openai/v1" ;;
                mistral) built_url="https://api.mistral.ai/v1" ;;
            esac
            sync_agent_auth "$p" "$built_url" "${G_API_KEYS[$p]}" "openai-completions" "main" || true
        done
        msg_step "重启..."; service_restart; wait_gateway_ready 15
    fi
    echo ""; validate_config; wait_and_return 3
}
_cfg_builtin() {
    local p="$1"
    local hint="$2"
    local rec="$3"
    echo -e "\n${CYAN}── ${p} ──${NC}"
    local ek="${G_API_KEYS[$p]:-}"
    [[ -n "$ek" ]] && echo -e "  已有: ${DIM}${ek:0:8}****${NC}"
    echo -ne "  Key${hint:+ ($hint)}: "
    local nk=""
    read_input_silent nk ""
    if [[ -z "$nk" ]]; then [[ -n "$ek" ]] && msg_info "保留" || msg_warn "跳过"; return; fi
    G_API_KEYS["$p"]="$nk"
    echo -ne "  模型(默认:${rec}): "
    local sm=""
    read_input sm "$rec"
    G_API_MODELS["$p"]="$sm"
    msg_ok "${p}:${sm}"
    [[ -z "${G_DEFAULT_PROVIDER:-}" ]] && G_DEFAULT_PROVIDER="$p"
}
_write_builtin_providers_config() {
    local cfg=""
    cfg=$(get_active_config_path); has_cmd python3 || return 1
    local env_args=()
    for p in anthropic openai google deepseek groq mistral; do
        [[ -n "${G_API_KEYS[$p]:-}" ]] && env_args+=("OC_KEY_${p}=${G_API_KEYS[$p]}")
        [[ -n "${G_API_MODELS[$p]:-}" ]] && env_args+=("OC_MODEL_${p}=${G_API_MODELS[$p]}")
    done
    env "${env_args[@]}" python3 - "$cfg" << 'PYEOF'
import json,os,sys
p=sys.argv[1]
os.makedirs(os.path.dirname(p),exist_ok=True)
try:
    with open(p) as f: c=json.load(f)
except: c={}
c.setdefault("gateway",{"mode":"local","bind":"loopback"})
if c["gateway"].get("bind") not in ["auto","lan","loopback","custom","tailnet"]: c["gateway"]["bind"]="loopback"
for pr in ["anthropic","openai","google","deepseek","groq","mistral"]:
    key=os.environ.get(f"OC_KEY_{pr}","")
    if not key: continue
    c.setdefault(pr,{})["apiKey"]=key
    models=os.environ.get(f"OC_MODEL_{pr}","")
    if models: c[pr]["model"]=models.split(",")[0].strip(); c[pr]["models"]=models
tmp=p+".tmp"
with open(tmp,"w") as f: json.dump(c,f,indent=2,ensure_ascii=False)
with open(tmp) as f: json.load(f)
os.replace(tmp,p)
PYEOF
    chmod 600 "$cfg"; msg_ok "配置已保存"
}
configure_lan_access() {
    msg_title "局域网访问配置"
    if ! is_openclaw_installed; then msg_fail "OpenClaw未安装"; wait_and_return 2; return 0; fi
    if is_docker_mode; then
        local cname=""
        cname=$(_get_active_container)
        if [[ -z "$cname" ]]; then msg_fail "容器未运行"; wait_and_return 2; return 0; fi
        local existing_token=""
        existing_token=$(docker exec "$cname" openclaw config get gateway.auth.token 2>/dev/null | tr -d '[:space:]' || echo "")
        local gw_token=""
        prompt_gateway_token gw_token "$existing_token"
        docker exec "$cname" openclaw config set gateway.bind lan >/dev/null 2>&1 || true
        docker exec "$cname" openclaw config set gateway.auth.mode token >/dev/null 2>&1 || true
        docker exec "$cname" openclaw config set gateway.auth.token "$gw_token" >/dev/null 2>&1 || true
        docker exec "$cname" openclaw config set gateway.controlUi.allowInsecureAuth true >/dev/null 2>&1 || true
        docker exec "$cname" openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true >/dev/null 2>&1 || true
        docker exec "$cname" openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true
        msg_ok "配置已更新,重启容器..."
        docker restart "$cname" >/dev/null 2>&1
        sleep 3; wait_gateway_ready 20
        local local_ip=""
        local_ip=$(get_local_ip)
        echo -e "\n${GREEN}局域网访问信息${NC}"; print_line
        echo -e "  ${BOLD}地址:${NC}  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${NC}"
        echo -e "  ${BOLD}令牌:${NC}  ${YELLOW}${gw_token}${NC}"; print_line
        wait_and_return 5; return 0
    fi
    local cfg=""
    cfg=$(get_active_config_path)
    if ! json_is_valid "$cfg"; then msg_fail "配置损坏,请先修复"; wait_and_return 3; return 0; fi
    confirm "确认配置局域网访问?" || { msg_info "已取消"; wait_and_return 2; return 0; }
    local existing_token=""
    existing_token=$(get_gateway_token 2>/dev/null || echo "")
    local gw_token=""
    prompt_gateway_token gw_token "$existing_token"
    local backup=""
    backup=$(backup_config); [[ -n "$backup" ]] && msg_ok "已备份:$backup"
    OC_TOKEN="$gw_token" python3 - "$cfg" << 'PYEOF'
import json,sys,os
p=sys.argv[1]; token=os.environ.get("OC_TOKEN","")
os.makedirs(os.path.dirname(p),exist_ok=True)
try:
    with open(p) as f: c=json.load(f)
except: c={}
for bad in ["ui","defaultProvider"]: c.pop(bad,None)
if "agents" in c and isinstance(c["agents"],dict):
    for k in list(c["agents"].keys()):
        if k not in ("defaults","list"): del c["agents"][k]
gw=c.setdefault("gateway",{}); gw["mode"]="local"; gw["bind"]="lan"
auth=gw.setdefault("auth",{}); auth["token"]=token; auth["mode"]="token"
gw.setdefault("controlUi",{}).update({
    "allowInsecureAuth":True,
    "dangerouslyDisableDeviceAuth":True,
    "dangerouslyAllowHostHeaderOriginFallback":True
})
tmp=p+".tmp"
with open(tmp,"w") as f: json.dump(c,f,indent=2,ensure_ascii=False)
with open(tmp) as f: json.load(f)
os.replace(tmp,p)
PYEOF
    chmod 600 "$cfg"; msg_ok "配置写入成功"
    msg_step "重启Gateway..."
    service_restart; wait_gateway_ready 20
    local local_ip=""
    local_ip=$(get_local_ip)
    echo -e "\n${GREEN}局域网访问信息${NC}"; print_line
    echo -e "  ${BOLD}地址:${NC}  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${NC}"
    echo -e "  ${BOLD}令牌:${NC}  ${YELLOW}${gw_token}${NC}"; print_line
    wait_and_return 5
}
show_token_manager() {
    msg_title "网关令牌管理"
    if ! json_is_valid "$(get_active_config_path)"; then msg_fail "配置无效"; wait_and_return 3; return 0; fi
    local token=""
    local local_ip=""
    token=$(get_gateway_token)
    if is_docker_mode && [[ -z "$token" ]]; then
        local cname=""
        cname=$(_get_active_container)
        [[ -n "$cname" ]] && token=$(docker exec "$cname" openclaw config get gateway.auth.token 2>/dev/null | tr -d '[:space:]' || echo "")
    fi
    local_ip=$(get_local_ip)
    echo -e "${CYAN}令牌状态${NC}"; print_line
    if [[ -n "$token" ]]; then
        echo -e "  ${BOLD}状态:${NC} ${GREEN}已设置${NC}"
        echo -e "  ${BOLD}Token:${NC} ${YELLOW}${token}${NC}"
        echo -e "\n  访问: ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${NC}  (连接时填入令牌)"
    else
        echo -e "  ${BOLD}状态:${NC} ${DIM}未设置${NC}"
    fi
    print_line
    echo -e "\n  1) 查看  2) 生成/更换  3) 手动设置  4) 删除  0) 返回"
    echo -ne "\n${BOLD}选择: ${NC}"
    local tc=""
    read_input tc "0"
    case "$tc" in
        1) [[ -n "$token" ]] && echo -e "\n${YELLOW}${token}${NC}" || msg_warn "未设置" ;;
        2) local nt=""; prompt_gateway_token nt ""; _set_gateway_token "$nt" ;;
        3)
            echo -ne "\n${BOLD}令牌(至少16字符): ${NC}"
            local ct=""
            read_input ct ""
            [[ ${#ct} -lt 16 ]] && msg_fail "太短" || _set_gateway_token "$ct" ;;
        4) confirm "确认删除?" && _remove_gateway_token ;;
        0) return 0 ;;
    esac
    wait_and_return 3
}
_set_gateway_token() {
    local new_token="$1"
    if is_docker_mode; then
        local cname=""
        cname=$(_get_active_container)
        if [[ -n "$cname" ]]; then
            docker exec "$cname" openclaw config set gateway.auth.token "$new_token" >/dev/null 2>&1
            docker exec "$cname" openclaw config set gateway.auth.mode token >/dev/null 2>&1
            msg_ok "令牌已更新: ${YELLOW}${new_token}${NC}"
            confirm "重启容器?" && { docker restart "$cname" >/dev/null 2>&1; wait_gateway_ready 15; }
            return
        fi
    fi
    local cfg=""
    cfg=$(get_active_config_path); has_cmd python3 || return 1
    python3 - "$cfg" "$new_token" << 'PYEOF'
import json,sys,os
p,token=sys.argv[1],sys.argv[2]
os.makedirs(os.path.dirname(p),exist_ok=True)
try:
    with open(p) as f: c=json.load(f)
except: c={}
gw=c.setdefault("gateway",{}); gw.setdefault("mode","local")
if gw.get("bind") not in ["auto","lan","loopback","custom","tailnet"]: gw["bind"]="loopback"
auth=gw.setdefault("auth",{}); auth["mode"]="token"; auth["token"]=token
tmp=p+".tmp"
with open(tmp,"w") as f: json.dump(c,f,indent=2,ensure_ascii=False)
os.replace(tmp,p); print("OK")
PYEOF
    chmod 600 "$cfg"
    msg_ok "令牌已更新: ${YELLOW}${new_token}${NC}"
    confirm "重启Gateway?" && { service_restart; wait_gateway_ready 15; }
}
_remove_gateway_token() {
    local cfg=""
    cfg=$(get_active_config_path); has_cmd python3 || return 1
    python3 - "$cfg" << 'PYEOF'
import json,sys,os
p=sys.argv[1]
try:
    with open(p) as f: c=json.load(f)
except: sys.exit(0)
auth=c.get("gateway",{}).get("auth",{})
auth.pop("token",None)
if auth.get("mode")=="token": auth.pop("mode",None)
if not auth: c.get("gateway",{}).pop("auth",None)
tmp=p+".tmp"
with open(tmp,"w") as f: json.dump(c,f,indent=2,ensure_ascii=False)
os.replace(tmp,p)
PYEOF
    chmod 600 "$cfg"; msg_ok "令牌已删除"
}
fix_agent_auth_menu() {
    msg_title "修复 Agent 认证"
    if ! is_openclaw_installed; then msg_fail "未安装"; wait_and_return 2; return 0; fi
    if ! json_is_valid "$(get_active_config_path)"; then msg_fail "配置损坏"; wait_and_return 3; return 0; fi
    load_config_from_file
    if [[ ${#G_API_URLS[@]} -eq 0 && ${#G_API_KEYS[@]} -eq 0 ]]; then msg_fail "无Provider配置"; wait_and_return 3; return 0; fi
    echo -ne "\n${BOLD}Agent名(默认:main): ${NC}"
    local agent_name=""
    read_input agent_name "main"
    local inject_openai=false
    [[ ${#G_API_URLS[@]} -gt 0 && -z "${G_API_KEYS[openai]:-}" ]] && confirm "以openai别名注入?" && inject_openai=true
    confirm "确认同步?" || { wait_and_return 2; return 0; }
    local ok=0
    local fail=0
    local first_custom=""
    for p in "${!G_API_URLS[@]}"; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        [[ -z "$first_custom" ]] && first_custom="$p"
        local url="${G_API_URLS[$p]}"
        is_docker_mode && is_lan_url "$url" && url=$(convert_url_for_docker "$url")
        sync_agent_auth "$p" "$url" "${G_API_KEYS[$p]}" "${G_API_TYPES[$p]:-openai-completions}" "$agent_name" && ((ok++)) || ((fail++))
    done
    if $inject_openai && [[ -n "$first_custom" ]]; then
        local url="${G_API_URLS[$first_custom]}"
        is_docker_mode && is_lan_url "$url" && url=$(convert_url_for_docker "$url")
        sync_agent_auth "openai" "$url" "${G_API_KEYS[$first_custom]}" "${G_API_TYPES[$first_custom]:-openai-completions}" "$agent_name" && ((ok++)) || ((fail++))
    fi
    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        [[ "$p" == "openai" && "$inject_openai" == "true" ]] && continue
        local built_url=""
        case "$p" in
            anthropic) built_url="https://api.anthropic.com" ;;
            openai) built_url="https://api.openai.com/v1" ;;
            google) built_url="https://generativelanguage.googleapis.com" ;;
            deepseek) built_url="https://api.deepseek.com/v1" ;;
            groq) built_url="https://api.groq.com/openai/v1" ;;
            mistral) built_url="https://api.mistral.ai/v1" ;;
        esac
        sync_agent_auth "$p" "$built_url" "${G_API_KEYS[$p]}" "openai-completions" "$agent_name" && ((ok++)) || ((fail++))
    done
    msg_step "重启Gateway..."; service_restart; wait_gateway_ready 15
    echo ""; print_line
    echo -e "成功${GREEN}${ok}${NC} 失败${RED}${fail}${NC}"; print_line
    wait_and_return 5
}
validate_config() {
    local cfg=""
    cfg=$(get_active_config_path)
    msg_step "验证配置..."
    [[ ! -f "$cfg" ]] && { msg_fail "配置不存在"; return 1; }
    ! json_is_valid "$cfg" && { msg_fail "JSON格式无效"; return 1; }
    if is_openclaw_installed; then
        local out=""
        out=$(openclaw_cmd config validate 2>&1)
        if echo "$out" | grep -qiE "Invalid input|invalid config"; then
            msg_fail "Schema验证失败:"
            echo "$out" | grep -iE "×|invalid|allowed" | head -10 | sed 's/^/  /'
            if confirm "自动清理?"; then
                sanitize_config_for_schema | sed 's/^/  /'
                openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true
                out=$(openclaw_cmd config validate 2>&1)
                echo "$out" | grep -qiE "Invalid input" && { msg_fail "仍失败"; return 1; } || { msg_ok "通过"; return 0; }
            fi
            return 1
        else
            msg_ok "验证通过"; return 0
        fi
    fi
    msg_ok "JSON格式正确"
    return 0
}
repair_broken_config() {
    msg_title "修复配置文件"
    local cfg=""
    cfg=$(get_active_config_path)
    if [[ ! -f "$cfg" ]]; then
        msg_info "配置不存在,创建最小配置"
        _create_minimal_config; wait_and_return 2; return 0
    fi
    if json_is_valid "$cfg"; then
        msg_ok "JSON格式有效"
        local result=""
        result=$(sanitize_config_for_schema 2>&1)
        [[ "$result" == "NOCHANGE" ]] && msg_ok "无需修改" || { echo "$result" | sed 's/^/  /'; msg_ok "已清理"; }
        wait_and_return 3; return 0
    fi
    msg_fail "JSON格式损坏"
    if has_cmd python3; then
        local err=""
        err=$(python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$cfg" 2>&1 | tail -1)
        echo -e "  错误: $err"
    fi
    echo -e "\n  ${BOLD}1)${NC} 备份并重建  ${BOLD}2)${NC} 手动编辑  ${BOLD}3)${NC} 智能修剪  ${BOLD}0)${NC} 取消"
    echo -ne "\n${BOLD}选择: ${NC}"
    local rc=""
    read_input rc "0"
    case "$rc" in
        1)
            local bk=""
            bk=$(backup_config); [[ -n "$bk" ]] && msg_ok "已备份:$bk"
            _create_minimal_config; msg_ok "已重建" ;;
        2)
            local bk=""
            bk=$(backup_config); [[ -n "$bk" ]] && msg_ok "已备份:$bk"
            local editor="${EDITOR:-nano}"; has_cmd "$editor" || editor="vi"
            "$editor" "$cfg" </dev/tty
            json_is_valid "$cfg" && { msg_ok "修复成功"; sanitize_config_for_schema; } || msg_fail "仍无效" ;;
        3)
            local bk=""
            bk=$(backup_config); [[ -n "$bk" ]] && msg_ok "已备份:$bk"
            python3 - "$cfg" << 'PYEOF'
import json,re,sys,os
path=sys.argv[1]
MINIMAL={"gateway":{"mode":"local","bind":"loopback"},"models":{"mode":"merge","providers":{}},"agents":{"defaults":{"workspace":"~/.openclaw/workspace"},"list":[{"id":"main","default":True}]}}
try:
    with open(path) as f: content=f.read()
    lines,cleaned=content.split('\n'),[]
    for line in lines:
        s=line.strip()
        if re.search(r':\s*(fa|tr|nu|un)\s*$',s): continue
        if re.search(r':\s*[a-z]+\s*$',s) and not re.search(r':\s*(true|false|null)\s*[,}\]]?\s*$',s): continue
        cleaned.append(line)
    cfg=json.loads('\n'.join(cleaned)); result="SMART_OK"
except json.JSONDecodeError:
    cfg=MINIMAL; result="FALLBACK"
tmp=path+".tmp"
with open(tmp,"w") as f: json.dump(cfg,f,indent=2,ensure_ascii=False)
os.replace(tmp,path); print(result)
PYEOF
            json_is_valid "$cfg" && { sanitize_config_for_schema | sed 's/^/  /'; msg_ok "修复完成"; } || msg_fail "修复失败" ;;
        0) msg_info "已取消" ;;
    esac
    wait_and_return 3
}
diagnose_and_fix() {
    msg_title "诊断与修复"
    detect_system
    local issues=0
    local fixed=0
    local cfg=""
    cfg=$(get_active_config_path)
    echo -e "${CYAN}开始检测... 模式:$(_detect_deploy_mode)${NC}\n"
    echo -ne "  [1/9] OpenClaw安装... "
    is_openclaw_installed && echo -e "${GREEN}${OK}${NC}" || { echo -e "${RED}${FAIL} 未安装${NC}"; ((issues++)); }
    echo -ne "  [2/9] 配置存在... "
    if [[ -f "$cfg" ]]; then echo -e "${GREEN}${OK}${NC}"
    else
        echo -e "${RED}${FAIL} 不存在${NC}"; ((issues++))
        confirm "  → 创建?" && { _create_minimal_config; ((fixed++)); }
    fi
    echo -ne "  [3/9] JSON有效... "
    if [[ ! -f "$cfg" ]]; then echo -e "${DIM}跳过${NC}"
    elif json_is_valid "$cfg"; then echo -e "${GREEN}${OK}${NC}"
    else
        echo -e "${RED}${FAIL} 损坏${NC}"; ((issues++))
        confirm "  → 修复?" && { backup_config; _create_minimal_config; ((fixed++)); }
    fi
    echo -ne "  [4/9] gateway.bind... "
    if [[ -f "$cfg" ]] && json_is_valid "$cfg" && has_cmd python3; then
        local bv=""
        bv=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('gateway',{}).get('bind',''))" "$cfg" 2>/dev/null || echo "")
        if [[ "$bv" =~ ^(auto|lan|loopback|custom|tailnet)$ ]]; then echo -e "${GREEN}${OK} bind=$bv${NC}"
        else
            echo -e "${RED}${FAIL} bind='$bv'无效${NC}"; ((issues++))
            confirm "  → 修复?" && { sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        fi
    else echo -e "${DIM}跳过${NC}"; fi
    echo -ne "  [5/9] Schema验证... "
    if is_openclaw_installed && [[ -f "$cfg" ]] && json_is_valid "$cfg"; then
        local so=""
        so=$(openclaw_cmd config validate 2>&1)
        if echo "$so" | grep -qiE "Invalid input"; then
            echo -e "${RED}${FAIL}${NC}"; ((issues++))
            confirm "  → 自动修复?" && { openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true; sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        else echo -e "${GREEN}${OK}${NC}"; fi
    else echo -e "${DIM}跳过${NC}"; fi
    echo -ne "  [6/9] DockerURL兼容... "
    if is_docker_mode && [[ -f "$cfg" ]] && json_is_valid "$cfg" && has_cmd python3; then
        local lu=""
        lu=$(python3 -c "
import json,re,sys
PAT=re.compile(r'^https?://(127\.|localhost|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)')
try:
    c=json.load(open(sys.argv[1]))
    bad=[n for n,p in c.get('models',{}).get('providers',{}).items() if isinstance(p,dict) and PAT.match(p.get('baseUrl',''))]
    print(','.join(bad))
except: print('')
" "$cfg" 2>/dev/null || echo "")
        if [[ -z "$lu" ]]; then echo -e "${GREEN}${OK}${NC}"
        else
            echo -e "${RED}${FAIL} LAN URL:$lu${NC}"; ((issues++))
            confirm "  → 转换?" && { convert_urls_for_docker_mode | sed 's/^/    /'; ((fixed++)); }
        fi
    else echo -e "${DIM}跳过${NC}"; fi
    echo -ne "  [7/9] Agent认证... "
    if is_openclaw_installed; then
        local ab=""
        is_docker_mode && ab="${DOCKER_DATA_DIR}/.openclaw/agents" || ab="$OPENCLAW_AGENTS_DIR"
        if [[ -f "$ab/main/agent/auth-profiles.json" ]] || [[ -f "$ab/main/agent/openclaw-agent.sqlite" ]]; then
            echo -e "${GREEN}${OK}${NC}"
        else echo -e "${YELLOW}${WARN} 缺失${NC}"; ((issues++)); fi
    else echo -e "${DIM}跳过${NC}"; fi
    echo -ne "  [8/9] Gateway端口... "
    if gateway_health_check; then echo -e "${GREEN}${OK}${NC}"
    else
        echo -e "${YELLOW}${WARN} 无响应${NC}"; ((issues++))
        confirm "  → 启动?" && { service_start; wait_gateway_ready 15 && ((fixed++)) || true; }
    fi
    echo -ne "  [9/9] 磁盘空间... "
    local avail=""
    avail=$(df "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999999")
    if [[ "$avail" -gt 1048576 ]]; then
        echo -e "${GREEN}${OK} $(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')${NC}"
    else echo -e "${RED}${FAIL} 空间不足${NC}"; ((issues++)); fi
    if is_openclaw_installed; then
        echo ""; msg_step "openclaw doctor --fix..."
        openclaw_cmd doctor --fix 2>&1 | tail -10 | sed 's/^/  /' || true
    fi
    echo ""; print_line
    echo -e "发现问题${RED}${issues}${NC} 已修复${GREEN}${fixed}${NC}"
    print_line; wait_and_return 5
}
view_logs() {
    msg_title "日志查看"
    echo -e "  ${BOLD}1)${NC} 实时日志  ${BOLD}2)${NC} systemd  ${BOLD}3)${NC} 文件列表  ${BOLD}4)${NC} 官方版  ${BOLD}5)${NC} 中文版  ${BOLD}6)${NC} 脚本日志  ${BOLD}0)${NC} 返回"
    echo -ne "\n${BOLD}选择: ${NC}"
    local lc=""
    read_input lc "0"
    _follow() { trap 'echo ""; msg_info "已退出"' INT; eval "$1" || true; trap - INT; }
    case "$lc" in
        1)
            local cname=""
            cname=$(_get_active_container)
            if [[ -n "$cname" ]]; then _follow "docker logs -f '$cname' 2>&1"
            else _follow "openclaw_cmd gateway logs --follow 2>/dev/null || tail -f '${OPENCLAW_LOG_DIR}/gateway.log' 2>/dev/null"; fi ;;
        2)
            detect_system
            if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
                local svc=""
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    ${SUDO:-} journalctl -u "$svc" -n 100 --no-pager 2>/dev/null && break
                done
            else msg_warn "非systemd系统"; fi ;;
        3)
            local log_dir="$OPENCLAW_LOG_DIR"
            is_docker_mode && log_dir="${DOCKER_DATA_DIR}/.openclaw/logs"
            if [[ -d "$log_dir" ]]; then
                ls -lh "$log_dir" 2>/dev/null
                echo -ne "\n${BOLD}输入文件名(回车查看最新): ${NC}"
                local lf=""
                read_input lf ""
                if [[ -n "$lf" ]]; then less "${log_dir}/${lf}" 2>/dev/null
                else
                    local ll=""
                    ll=$(ls -t "${log_dir}"/*.log 2>/dev/null | head -1 || echo "")
                    [[ -n "$ll" ]] && less "$ll" || msg_warn "无日志"
                fi
            else msg_warn "日志目录不存在"; fi ;;
        4) _container_exists "$DOCKER_CONTAINER" && _follow "docker logs -f '$DOCKER_CONTAINER' 2>&1" || msg_warn "官方版容器不存在" ;;
        5) _container_exists "$DOCKER_CONTAINER_ZH" && _follow "docker logs -f '$DOCKER_CONTAINER_ZH' 2>&1" || msg_warn "中文版容器不存在" ;;
        6) [[ -f "$LOG_FILE" ]] && less "$LOG_FILE" || msg_warn "脚本日志不存在" ;;
        0) return 0 ;;
    esac
    wait_and_return 2
}
install_plugins() {
    msg_title "安装插件"
    if ! is_openclaw_installed; then msg_fail "OpenClaw未安装"; wait_and_return 2; return 0; fi
    echo -e "  ${BOLD}1)${NC} 微信  ${BOLD}2)${NC} 飞书  ${BOLD}3)${NC} 全部  ${BOLD}0)${NC} 返回"
    echo -ne "\n${BOLD}选择: ${NC}"
    local choice=""
    read_input choice "0"
    _install_plugin() {
        local name="$1"; local pkg="$2"
        msg_step "安装${name}..."
        openclaw_cmd plugins install "$pkg" --force 2>&1 | tee -a "$LOG_FILE" \
            && msg_ok "${name}成功" || msg_fail "${name}失败"
    }
    case "$choice" in
        1) _install_plugin "微信" "$WECHAT_PLUGIN_PKG" ;;
        2) _install_plugin "飞书" "$FEISHU_PLUGIN_PKG" ;;
        3) _install_plugin "微信" "$WECHAT_PLUGIN_PKG"; _install_plugin "飞书" "$FEISHU_PLUGIN_PKG" ;;
        0) return 0 ;;
    esac
    wait_and_return 3
}
get_openclaw_latest_version() {
    curl -s --max-time 5 --connect-timeout 3 "https://registry.npmjs.org/openclaw/latest" 2>/dev/null \
        | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || echo ""
}
show_version() {
    msg_title "版本信息与升级"
    if ! is_openclaw_installed; then msg_fail "未安装"; wait_and_return 2; return 0; fi
    print_line
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw_cmd --version 2>/dev/null || echo '未知')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}Docker${NC}      : $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo '未安装')"
    echo -e "  ${BOLD}部署方式${NC}    : $(_detect_deploy_mode)"
    echo -e "  ${BOLD}脚本版本${NC}    : $SCRIPT_VERSION"
    print_line
    echo ""; msg_info "检查最新版本..."
    local latest=""
    local current=""
    latest=$(get_openclaw_latest_version)
    current=$(openclaw_cmd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
    echo -e "  当前:${BOLD}${current}${NC}  最新:${BOLD}${latest:-无法获取}${NC}"
    if [[ -n "$latest" && "$latest" != "$current" ]]; then
        confirm "升级到$latest?" && {
            if _container_exists "$DOCKER_CONTAINER_ZH"; then
                msg_info "中文版请通过菜单[2]→升级镜像"
            elif is_docker_mode; then
                docker pull "${DOCKER_IMAGE}:latest" 2>&1 | tail -3 && {
                    docker rm -f "$DOCKER_CONTAINER" 2>/dev/null || true
                    _deploy_docker_official_new
                } || msg_fail "拉取失败"
            else
                local npm_args=""
                is_china && npm_args="--registry=${NPM_MIRROR_CN}"
                npm install -g openclaw@latest ${npm_args:+"$npm_args"} 2>&1 | tail -5 \
                    && msg_ok "已升级" || msg_fail "升级失败"
            fi
        }
    else msg_ok "已是最新版本"; fi
    wait_and_return 3
}
show_command_reference() {
    msg_title "命令速查"
    local use_docker=false
    is_docker_mode && use_docker=true
    local cname=""
    cname=$(_get_active_container)
    local prefix=""
    $use_docker && [[ -n "$cname" ]] && prefix="docker exec ${cname} "
    _row() { printf "  ${CYAN}%-50s${NC} ${DIM}%s${NC}\n" "$1" "$2"; }
    echo -e "${CYAN}服务管理${NC}"; print_line
    _row "${prefix}openclaw gateway run" "前台运行(调试)"
    _row "${prefix}openclaw gateway restart" "重启网关"
    _row "${prefix}openclaw dashboard --no-open" "获取访问URL"
    _row "${prefix}openclaw doctor --fix" "自动修复配置"
    _row "${prefix}openclaw config validate" "验证配置"
    if $use_docker && [[ -n "$cname" ]]; then
        echo -e "\n${CYAN}Docker${NC}"; print_line
        _row "docker logs -f ${cname}" "实时日志"
        _row "docker restart ${cname}" "重启容器"
        _row "docker exec -it ${cname} sh" "进入Shell"
        _row "docker volume ls" "查看数据卷"
    fi
    echo -e "\n${CYAN}Schema规范${NC}"; print_line
    _row "gateway.bind允许值" "auto/lan/loopback/custom/tailnet"
    _row "${prefix}openclaw config set gateway.bind lan" "启用局域网"
    _row "${prefix}openclaw config set gateway.auth.token TOKEN" "设置令牌"
    echo ""
    wait_and_return 3
}
quick_commands() {
    msg_title "快捷命令"
    if ! is_openclaw_installed; then msg_fail "未安装"; wait_and_return 2; return 0; fi
    echo -e "  ${BOLD}1)${NC} status  ${BOLD}2)${NC} health  ${BOLD}3)${NC} doctor --fix  ${BOLD}4)${NC} logs"
    echo -e "  ${BOLD}5)${NC} models list  ${BOLD}6)${NC} config validate  ${BOLD}7)${NC} agents list"
    echo -e "  ${BOLD}8)${NC} dashboard --no-open  ${BOLD}9)${NC} gateway run(前台)  ${BOLD}10)${NC} 配置自定义API  ${BOLD}0)${NC} 返回"
    echo -ne "\n${BOLD}选择: ${NC}"
    local qc=""
    read_input qc "0"; echo ""
    case "$qc" in
        1) openclaw_cmd status ;;
        2) openclaw_cmd health ;;
        3) openclaw_cmd doctor --fix ;;
        4) trap 'echo ""; msg_info "退出"' INT; openclaw_cmd logs 2>&1 || true; trap - INT ;;
        5) openclaw_cmd models list ;;
        6) openclaw_cmd config validate ;;
        7) openclaw_cmd agents list ;;
        8) openclaw_cmd dashboard --no-open ;;
        9) msg_info "Ctrl+C退出"; trap 'echo ""; msg_info "退出"' INT; openclaw_cmd gateway run 2>&1; trap - INT ;;
        10) configure_custom_api ;;
        0) return 0 ;;
        *) msg_warn "无效:$qc" ;;
    esac
    wait_and_return 2
}
run_setup_wizard() {
    msg_title "setup 向导"
    if ! is_openclaw_installed; then msg_fail "未安装"; wait_and_return 2; return 0; fi
    if ! json_is_valid "$(get_active_config_path)"; then msg_fail "配置损坏"; wait_and_return 3; return 0; fi
    ensure_minimal_config
    confirm "运行openclaw setup?" || { wait_and_return 2; return 0; }
    openclaw_cmd setup </dev/tty && msg_ok "完成" || msg_warn "退出"
    confirm "重启Gateway?" && { service_restart; wait_gateway_ready 15; }
    wait_and_return 3
}
uninstall_openclaw() {
    msg_title "卸载 OpenClaw"
    echo -e "${RED}此操作不可逆，将删除所有容器、数据卷、配置和程序文件!${NC}\n"
    confirm "确认卸载?" || { wait_and_return 2; return 0; }
    detect_system
    echo ""
    msg_step "第1步: 停止并清理 Docker 中文版..."
    if _container_exists "$DOCKER_CONTAINER_ZH"; then
        docker stop "$DOCKER_CONTAINER_ZH" 2>/dev/null || true
        docker rm -f "$DOCKER_CONTAINER_ZH" 2>/dev/null || true
        msg_ok "中文版容器已删除"
        if confirm "删除中文版镜像?"; then
            docker rmi "${DOCKER_IMAGE_ZH_HUB}:latest" 2>/dev/null && msg_ok "Docker Hub镜像已删除" || true
            docker rmi "${DOCKER_IMAGE_ZH_HUB}:nightly" 2>/dev/null || true
            docker rmi "${DOCKER_IMAGE_ZH_GHCR}:latest" 2>/dev/null && msg_ok "GHCR镜像已删除" || true
            docker rmi "${DOCKER_IMAGE_ZH_GHCR}:nightly" 2>/dev/null || true
        fi
        if confirm "删除中文版数据卷($DOCKER_VOL_ZH)?"; then
            docker volume rm "$DOCKER_VOL_ZH" 2>/dev/null && msg_ok "数据卷 $DOCKER_VOL_ZH 已删除" || msg_warn "数据卷删除失败或不存在"
        fi
    else
        msg_info "中文版容器不存在,跳过"
    fi
    msg_step "第2步: 停止并清理 Docker 官方版..."
    if _container_exists "$DOCKER_CONTAINER"; then
        docker stop "$DOCKER_CONTAINER" 2>/dev/null || true
        docker rm -f "$DOCKER_CONTAINER" 2>/dev/null || true
        msg_ok "官方版容器已删除"
        if confirm "删除官方版镜像?"; then
            docker rmi "${DOCKER_IMAGE}:latest" 2>/dev/null && msg_ok "GHCR镜像已删除" || true
            docker rmi "${DOCKER_IMAGE_MIRROR}:latest" 2>/dev/null || true
            docker rmi "${DOCKER_IMAGE_DR34M}:latest" 2>/dev/null || true
            docker rmi "${DOCKER_IMAGE_1PANEL}:latest" 2>/dev/null || true
            docker rmi "${DOCKER_IMAGE_ALPINE}:latest" 2>/dev/null || true
        fi
        if confirm "删除官方版数据卷($DOCKER_VOL_OFFICIAL)?"; then
            docker volume rm "$DOCKER_VOL_OFFICIAL" 2>/dev/null && msg_ok "数据卷 $DOCKER_VOL_OFFICIAL 已删除" || msg_warn "数据卷删除失败或不存在"
        fi
    else
        msg_info "官方版容器不存在,跳过"
    fi
    msg_step "第3步: 清理工作目录..."
    if [[ -d "$DOCKER_DATA_DIR" ]]; then
        if confirm "删除工作目录($DOCKER_DATA_DIR)?"; then
            rm -rf "$DOCKER_DATA_DIR" && msg_ok "工作目录已删除" || msg_warn "工作目录删除失败"
        fi
    else
        msg_info "工作目录不存在,跳过"
    fi
    msg_step "第4步: 卸载 npm 本地安装..."
    if has_cmd openclaw; then
        msg_info "停止 openclaw gateway 进程..."
        pkill -9 -f "openclaw gateway" 2>/dev/null || true
        pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
        sleep 1
        msg_info "清理服务文件..."
        case "$SERVICE_MANAGER" in
            systemd)
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    ${SUDO:-} systemctl stop "$svc" 2>/dev/null || true
                    ${SUDO:-} systemctl disable "$svc" 2>/dev/null || true
                    systemctl --user stop "$svc" 2>/dev/null || true
                    systemctl --user disable "$svc" 2>/dev/null || true
                    ${SUDO:-} rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
                    rm -f "$HOME/.config/systemd/user/${svc}.service" 2>/dev/null || true
                done
                ${SUDO:-} systemctl daemon-reload 2>/dev/null || true
                msg_ok "systemd 服务文件已清理" ;;
            launchd)
                for plist in "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist" \
                             "$HOME/Library/LaunchAgents/com.openclaw.gateway.plist"; do
                    [[ -f "$plist" ]] && launchctl unload "$plist" 2>/dev/null || true
                    rm -f "$plist" 2>/dev/null || true
                done
                msg_ok "launchd plist 已清理" ;;
            openrc)
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    ${SUDO:-} rc-service "$svc" stop 2>/dev/null || true
                    ${SUDO:-} rc-update del "$svc" 2>/dev/null || true
                done
                msg_ok "openrc 服务已清理" ;;
        esac
        msg_info "卸载 npm 包..."
        if npm uninstall -g openclaw 2>/dev/null; then
            msg_ok "npm 包已卸载"
        else
            local np=""
            np=$(npm prefix -g 2>/dev/null || echo "/usr/local")
            ${SUDO:-} rm -f "${np}/bin/openclaw" 2>/dev/null && msg_ok "openclaw 可执行文件已删除" || true
            ${SUDO:-} rm -rf "${np}/lib/node_modules/openclaw" 2>/dev/null && msg_ok "openclaw 模块目录已删除" || true
        fi
        if ! has_cmd openclaw; then
            msg_ok "openclaw 命令已移除"
        else
            msg_warn "openclaw 命令仍存在,可能需要手动删除: $(command -v openclaw)"
        fi
    else
        msg_info "未检测到 npm 本地安装,跳过"
    fi
    msg_step "第5步: 删除配置目录..."
    if [[ -d "$OPENCLAW_CONFIG_DIR" ]]; then
        if confirm "删除配置目录($OPENCLAW_CONFIG_DIR)? 包含所有配置和日志"; then
            rm -rf "$OPENCLAW_CONFIG_DIR" && msg_ok "配置目录已删除" || msg_warn "配置目录删除失败"
        fi
    else
        msg_info "配置目录不存在,跳过"
    fi
    msg_step "第6步: 清理依赖标记..."
    rm -f "$DEPS_STAMP" 2>/dev/null || true
    msg_ok "依赖标记已清理"
    G_API_KEYS=(); G_API_MODELS=(); G_API_TYPES=(); G_API_URLS=(); G_DEFAULT_PROVIDER=""
    echo ""
    print_line
    echo -e "${GREEN}${BOLD}卸载完成!${NC}"
    echo -e "  如需重新安装,重新运行本脚本即可"
    print_line
    wait_and_return 3
}
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'BANNER'
  ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗ ██╗    ██╗
 ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██║    ██║
 ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║ █╗ ██║
 ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║███╗██║
 ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚███╔███╔╝
  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝
BANNER
    echo -e "${NC}"
    echo -e "  ${DIM}${SCRIPT_VERSION} | npm + Docker官方 + Docker中文版 | 多平台多架构${NC}\n"
    detect_system; detect_region; load_config_from_file 2>/dev/null || true
    local sc="${RED}"
    local st="未安装"
    if is_openclaw_installed; then
        gateway_health_check && { sc="${GREEN}"; st="运行中●"; } || { sc="${YELLOW}"; st="已停止"; }
    fi
    local cs_txt="未创建"
    local cs_c="${DIM}"
    local cfg=""
    cfg=$(get_active_config_path)
    if [[ -f "$cfg" ]]; then
        json_is_valid "$cfg" && { cs_c="${GREEN}"; cs_txt="有效"; } || { cs_c="${RED}"; cs_txt="损坏!"; }
    fi
    local ml_txt="npm/本地"
    local ml_c="${NC}"
    if _container_exists "$DOCKER_CONTAINER_ZH"; then
        ml_c="${CYAN}"; ml_txt="Docker(中文)"
    elif _container_exists "$DOCKER_CONTAINER"; then
        ml_c="${CYAN}"; ml_txt="Docker(官方)"
    fi
    local rg_txt="${G_REGION:-?}"
    local rg_c="${DIM}"
    is_china && { rg_c="${YELLOW}"; rg_txt="国内CN"; }
    echo -e "  GW:${sc}${st}${NC}  模式:${ml_c}${ml_txt}${NC}  配置:${cs_c}${cs_txt}${NC}  网络:${rg_c}${rg_txt}${NC}$(
        [[ -n "${G_DEFAULT_PROVIDER:-}" ]] && echo "  AI:${CYAN}${G_DEFAULT_PROVIDER}${NC}")"
    print_line
}
main_menu() {
    while true; do
        show_banner
        echo -e "${WHITE}${BOLD}  主菜单${NC}\n"
        echo -e "  ${BOLD}${GREEN}[1]${NC}  ${ROCKET} npm本地安装"
        echo -e "  ${BOLD}${GREEN}[2]${NC}  ${DOCKER_ICO} Docker部署(官方/中文)"
        echo -e "  ${BOLD}${CYAN}[3]${NC}  配置自定义API"
        echo -e "  ${BOLD}${CYAN}[4]${NC}  内置Provider密钥"
        echo -e "  ${BOLD}${CYAN}[5]${NC}  ${LOBSTER} 局域网访问"
        echo -e "  ${BOLD}${CYAN}[6]${NC}  ${PLUGIN} 安装插件"
        echo -e "  ${BOLD}${YELLOW}[7]${NC}  启动  ${BOLD}${YELLOW}[8]${NC} 重启  ${BOLD}${YELLOW}[9]${NC} 停止  ${BOLD}${YELLOW}[10]${NC} 状态"
        echo -e "  ${BOLD}${MAGENTA}[11]${NC} ${KEY} 令牌管理"
        echo -e "  ${BOLD}${MAGENTA}[12]${NC} Dashboard信息"
        echo -e "  ${BOLD}${MAGENTA}[13]${NC} 版本/升级"
        echo -e "  ${BOLD}${MAGENTA}[14]${NC} 日志"
        echo -e "  ${BOLD}${MAGENTA}[15]${NC} 快捷命令"
        echo -e "  ${BOLD}${MAGENTA}[16]${NC} 修复配置"
        echo -e "  ${BOLD}${MAGENTA}[17]${NC} 验证配置"
        echo -e "  ${BOLD}${MAGENTA}[18]${NC} ${DOCTOR} 诊断修复"
        echo -e "  ${BOLD}${MAGENTA}[19]${NC} 命令速查"
        echo -e "  ${BOLD}${MAGENTA}[20]${NC} 系统信息"
        echo -e "  ${BOLD}${GREEN}[21]${NC} setup向导"
        echo -e "  ${BOLD}${YELLOW}[22]${NC} ${LINK} 修复Agent认证"
        echo -e "  ${BOLD}${YELLOW}[23]${NC} 清理不兼容字段"
        echo -e "  ${BOLD}${YELLOW}[24]${NC} 转换URL(Docker兼容)"
        echo -e "  ${BOLD}${RED}[25]${NC} ${TRASH} 卸载"
        echo -e "  ${BOLD}[0]${NC}  退出\n"
        print_line
        echo -ne "  ${BOLD}请输入: ${NC}"
        local choice=""
        read_input choice ""
        case "$choice" in
            1) install_openclaw_npm ;;
            2) deploy_docker ;;
            3) configure_custom_api; wait_and_return 2 ;;
            4) configure_builtin_providers ;;
            5) configure_lan_access ;;
            6) install_plugins ;;
            7) manage_service start ;;
            8) manage_service restart ;;
            9) manage_service stop ;;
            10) manage_service status ;;
            11) show_token_manager ;;
            12) show_dashboard_info; wait_and_return 5 ;;
            13) show_version ;;
            14) view_logs ;;
            15) quick_commands ;;
            16) repair_broken_config ;;
            17) validate_config; wait_and_return 3 ;;
            18) diagnose_and_fix ;;
            19) show_command_reference ;;
            20) print_sysinfo; wait_and_return 3 ;;
            21) run_setup_wizard ;;
            22) fix_agent_auth_menu ;;
            23) sanitize_config_for_schema | sed 's/^/  /'; openclaw_cmd doctor --fix >> "$LOG_FILE" 2>&1 || true; msg_ok "已清理"; wait_and_return 3 ;;
            24) is_docker_mode && { convert_urls_for_docker_mode | sed 's/^/  /'; msg_ok "已转换"; confirm "立即重启?" && manage_service restart >/dev/null 2>&1; } || msg_warn "非Docker模式无需转换"; wait_and_return 3 ;;
            25) uninstall_openclaw ;;
            0) echo -e "\n${GREEN}再见!${NC}\n"; exit 0 ;;
            "") : ;;
            *) msg_warn "无效:${choice}"; sleep 1 ;;
        esac
    done
}
init_privilege
while [[ "${1:-}" =~ ^-- ]]; do
    case "$1" in
        --china) OPENCLAW_REGION="china"; G_REGION="china"; shift ;;
        --overseas) OPENCLAW_REGION="overseas"; G_REGION="overseas"; shift ;;
        --help) show_command_reference; exit 0 ;;
        *) break ;;
    esac
done
case "${1:-}" in
    install) detect_system; detect_region; install_openclaw_npm ;;
    docker) detect_system; detect_region; deploy_docker ;;
    docker-zh|zh|zhcn) detect_system; detect_region; _deploy_docker_zh ;;
    lan) detect_system; detect_region; configure_lan_access ;;
    config) detect_system; detect_region; configure_builtin_providers ;;
    custom) detect_system; detect_region; configure_custom_api ;;
    token) detect_system; show_token_manager ;;
    validate) detect_system; validate_config; wait_and_return 3 ;;
    repair) detect_system; repair_broken_config ;;
    sanitize) detect_system; sanitize_config_for_schema ;;
    convert-urls) detect_system; convert_urls_for_docker_mode ;;
    start) detect_system; manage_service start ;;
    stop) detect_system; manage_service stop ;;
    restart) detect_system; manage_service restart ;;
    status) detect_system; manage_service status ;;
    fix-agent|agent-auth) detect_system; detect_region; fix_agent_auth_menu ;;
    plugins) install_plugins ;;
    version) detect_system; show_version ;;
    diagnose) detect_system; detect_region; diagnose_and_fix ;;
    uninstall) detect_system; uninstall_openclaw ;;
    setup) detect_system; run_setup_wizard ;;
    url) detect_system; load_config_from_file; show_dashboard_info; wait_and_return 3 ;;
    sysinfo) detect_system; detect_region; print_sysinfo; wait_and_return 3 ;;
    ref|help) show_command_reference ;;
    cmds) detect_system; quick_commands ;;
    *) main_menu ;;
esac
