#!/usr/bin/env bash

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

OK="✅"; FAIL="❌"; WARN="⚠️ "; INFO="ℹ️ "
ARROW="➜"; ROCKET="🚀"; TRASH="🗑️ "
DOCTOR="🩺"; POWER="⚡"; GEAR="⚙️ "
LOBSTER="🦞"; DOCKER="🐳"; PLUGIN="🔌"; KEY="🔐"; LINK="🔗"

OPENCLAW_PORT=18789
OPENCLAW_SERVICE="openclaw"
OPENCLAW_SERVICE_CANDIDATES=("openclaw" "openclaw-gateway")
OPENCLAW_CONFIG_DIR="$HOME/.openclaw"
OPENCLAW_JSON="$OPENCLAW_CONFIG_DIR/openclaw.json"
OPENCLAW_LOG_DIR="$OPENCLAW_CONFIG_DIR/logs"
OPENCLAW_AGENTS_DIR="$OPENCLAW_CONFIG_DIR/agents"
SCRIPT_VERSION="v1.0.7"
NODE_MIN_VERSION=22
NODE_RECOMMENDED_VERSION=24
LOG_FILE="/tmp/openclaw_install_$(date +%Y%m%d_%H%M%S).log"

GITHUB_REPO="https://github.com/openclaw/openclaw"
OPENCLAW_INSTALL_URL="https://openclaw.ai/install.sh"

DOCKER_IMAGE="ghcr.io/openclaw/openclaw"
DOCKER_IMAGE_MIRROR="openclaw/openclaw"
DOCKER_CONTAINER="openclaw-core"
DOCKER_DATA_DIR="$HOME/openclaw"
DOCKER_UID=1000

WECHAT_PLUGIN_PKG="@tencent-weixin/openclaw-weixin"
FEISHU_PLUGIN_PKG="@m1heng-clawd/feishu"

VALID_BIND_VALUES=("auto" "lan" "loopback" "custom" "tailnet")

_NVM_LATEST=""
_NODE_LTS_VERSIONS=""
_NODE_LATEST_VERSION=""

declare -gA G_API_KEYS=()
declare -gA G_API_MODELS=()
declare -gA G_API_TYPES=()
declare -gA G_API_URLS=()
declare -g  G_DEFAULT_PROVIDER=""

print_line() { echo -e "${DIM}$(printf '─%.0s' {1..60})${NC}"; }
msg_ok()    { echo -e "${GREEN}${OK}  $*${NC}"; }
msg_fail()  { echo -e "${RED}${FAIL}  $*${NC}"; }
msg_warn()  { echo -e "${YELLOW}${WARN} $*${NC}"; }
msg_info()  { echo -e "${CYAN}${INFO} $*${NC}"; }
msg_step()  { echo -e "\n${BLUE}${BOLD}${ARROW} $*${NC}"; }

msg_title() {
    echo ""
    local title="$1" width=58
    local tlen=${#title}
    local lpad=$(( (width - tlen) / 2 ))
    local rpad=$(( width - tlen - lpad ))
    echo -e "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    printf "${MAGENTA}${BOLD}║%${lpad}s%s%${rpad}s║${NC}\n" "" "$title" ""
    echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

wait_and_return() {
    local wait_time="${1:-3}"
    echo ""
    echo -ne "${DIM}${wait_time} 秒后返回...${NC}"
    sleep "$wait_time"
    echo ""
}

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
    local answer
    echo -ne "${YELLOW}${WARN} ${prompt} [y/N]: ${NC}"
    read -r answer </dev/tty 2>/dev/null || answer="n"
    [[ "$answer" =~ ^[Yy]$ ]]
}

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
has_cmd() { command -v "$1" &>/dev/null; }

get_local_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip=$(ipconfig getifaddr en0 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(ipconfig getifaddr en1 2>/dev/null)
    [[ -z "$ip" ]] && ip="127.0.0.1"
    echo "$ip"
}

is_lan_url() {
    local url="$1"
    [[ "$url" =~ ^https?://192\.168\. ]] && return 0
    [[ "$url" =~ ^https?://10\. ]] && return 0
    [[ "$url" =~ ^https?://172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$url" =~ ^https?://127\. ]] && return 0
    [[ "$url" =~ ^https?://localhost ]] && return 0
    return 1
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

safe_run() {
    local desc="$1"; shift
    if "$@" >> "$LOG_FILE" 2>&1; then
        msg_ok "$desc"; return 0
    else
        msg_warn "$desc 失败 (详见 $LOG_FILE)"; return 1
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
        echo "${DOCKER_DATA_DIR}/.openclaw/openclaw.json"
    else
        echo "$OPENCLAW_JSON"
    fi
}

openclaw_cmd() {
    if has_cmd openclaw; then
        openclaw "$@"
    elif docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        docker exec "$DOCKER_CONTAINER" openclaw "$@"
    else
        echo "openclaw 未安装" >&2
        return 1
    fi
}

fix_docker_ownership() {
    if is_docker_mode && [[ -d "$DOCKER_DATA_DIR" ]]; then
        chown -R "${DOCKER_UID}:${DOCKER_UID}" "${DOCKER_DATA_DIR}" 2>/dev/null \
            || sudo chown -R "${DOCKER_UID}:${DOCKER_UID}" "${DOCKER_DATA_DIR}" 2>/dev/null || true
    fi
}

json_is_valid() {
    local cfg="${1:-$(get_active_config_path)}"
    [[ ! -f "$cfg" ]] && return 1
    if has_cmd python3; then
        python3 -c "import json; json.load(open('$cfg'))" 2>/dev/null
    elif has_cmd jq; then
        jq empty "$cfg" 2>/dev/null
    else
        return 0
    fi
}

backup_config() {
    local cfg="${1:-$(get_active_config_path)}"
    [[ ! -f "$cfg" ]] && return 0
    local backup="${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$cfg" "$backup" 2>/dev/null && echo "$backup"
}

atomic_write_json() {
    local cfg="$1" content="$2"
    local tmp="${cfg}.tmp.$$"
    mkdir -p "$(dirname "$cfg")"
    printf '%s' "$content" > "$tmp"
    if has_cmd python3; then
        if ! python3 -c "import json; json.load(open('$tmp'))" 2>/dev/null; then
            rm -f "$tmp"
            return 1
        fi
    fi
    mv "$tmp" "$cfg"
    chmod 600 "$cfg"
    fix_docker_ownership
    return 0
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
    gw["bind"] = "loopback"
    changed.append("gateway.bind: localhost -> loopback")
elif gw.get("bind") not in VALID_BIND:
    gw["bind"] = "loopback"
    changed.append("gateway.bind: 无效值 -> loopback")

if not gw.get("mode"):
    gw["mode"] = "local"
    changed.append("gateway.mode -> local")

for bad_key in BAD_ROOT_KEYS:
    if bad_key in cfg:
        del cfg[bad_key]
        changed.append(f"删除 {bad_key}")

if "agents" in cfg and isinstance(cfg["agents"], dict):
    defaults = cfg["agents"].get("defaults", {})
    if isinstance(defaults, dict):
        if "model" in defaults:
            del defaults["model"]
            changed.append("删除 agents.defaults.model")
        if not defaults:
            del cfg["agents"]["defaults"]
    if not cfg.get("agents"):
        del cfg["agents"]

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
    sys.exit(0)
else:
    print("NOCHANGE")
    sys.exit(0)
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
            changed.append(f"providers.{name}: 局域网URL -> host.docker.internal")

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

get_nvm_latest_version() {
    [[ -n "$_NVM_LATEST" ]] && { echo "$_NVM_LATEST"; return; }
    local ver
    ver=$(curl -s --max-time 5 --connect-timeout 3 \
        "https://api.github.com/repos/nvm-sh/nvm/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | grep -o 'v[0-9.]*')
    _NVM_LATEST="${ver:-v0.40.1}"
    echo "$_NVM_LATEST"
}

get_openclaw_latest_version() {
    curl -s --max-time 5 --connect-timeout 3 "https://registry.npmjs.org/openclaw/latest" 2>/dev/null \
        | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || echo ""
}

detect_system() {
    OS=""; PKG_MANAGER=""; INSTALL_CMD=""; UPDATE_CMD=""
    SERVICE_MANAGER=""; PRETTY_NAME=""

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
                INSTALL_CMD="sudo apt-get install -y"; UPDATE_CMD="sudo apt-get update -qq" ;;
            centos|rhel|rocky|almalinux|ol)
                OS="rhel"; PKG_MANAGER="yum"
                INSTALL_CMD="sudo yum install -y"; UPDATE_CMD="sudo yum update -y" ;;
            fedora)
                OS="fedora"; PKG_MANAGER="dnf"
                INSTALL_CMD="sudo dnf install -y"; UPDATE_CMD="sudo dnf update -y" ;;
            arch|manjaro|endeavouros)
                OS="arch"; PKG_MANAGER="pacman"
                INSTALL_CMD="sudo pacman -S --noconfirm"; UPDATE_CMD="sudo pacman -Sy" ;;
            alpine)
                OS="alpine"; PKG_MANAGER="apk"
                INSTALL_CMD="sudo apk add"; UPDATE_CMD="sudo apk update" ;;
            *)  OS="unknown"; PKG_MANAGER="unknown" ;;
        esac
        SERVICE_MANAGER="systemd"
        [[ "$OS" == "alpine" ]] && SERVICE_MANAGER="openrc"
    else
        OS="unknown"
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   ARCH_LABEL="x86_64 (64位)"   ;;
        aarch64|arm64)  ARCH_LABEL="ARM64 (64位)"    ;;
        armv7l|armv6l)  ARCH_LABEL="ARMv7/v6 (32位)" ;;
        i386|i686)      ARCH_LABEL="x86 (32位)"      ;;
        *)              ARCH_LABEL="$ARCH"             ;;
    esac
}

print_sysinfo() {
    detect_system
    echo -e "${CYAN}${BOLD}系统信息${NC}"
    print_line
    echo -e "  ${BOLD}操作系统${NC}    : $(echo "${OS}" | tr '[:lower:]' '[:upper:]') (${PRETTY_NAME})"
    echo -e "  ${BOLD}架构${NC}        : ${ARCH_LABEL}"
    echo -e "  ${BOLD}包管理器${NC}    : ${PKG_MANAGER}"
    echo -e "  ${BOLD}服务管理器${NC}  : ${SERVICE_MANAGER}"
    echo -e "  ${BOLD}主机名${NC}      : $(hostname)"
    echo -e "  ${BOLD}内存${NC}        : $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' \
                             || sysctl hw.memsize 2>/dev/null | awk '{printf "%.1fGB",$2/1073741824}' \
                             || echo '未知')"
    echo -e "  ${BOLD}CPU${NC}         : $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?') 核"
    echo -e "  ${BOLD}磁盘可用${NC}    : $(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo '未知')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}npm${NC}         : $(npm -v 2>/dev/null | sed 's/^/v/' || echo '未安装')"
    echo -e "  ${BOLD}Docker${NC}      : $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo '未安装')"
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw_cmd --version 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}部署方式${NC}    : $(_detect_deploy_mode)"
    echo -e "  ${BOLD}配置路径${NC}    : $(get_active_config_path)"
    local cfg_path
    cfg_path=$(get_active_config_path)
    echo -e "  ${BOLD}配置文件${NC}    : $([[ -f "$cfg_path" ]] && (json_is_valid "$cfg_path" && echo "${GREEN}有效${NC}" || echo "${RED}损坏${NC}") || echo '未创建')"
    if [[ -n "${G_DEFAULT_PROVIDER:-}" ]]; then
        echo -e "  ${BOLD}默认 AI${NC}     : ${GREEN}${G_DEFAULT_PROVIDER}${NC}"
    fi
    print_line
}

_detect_deploy_mode() {
    if is_docker_mode; then
        echo "Docker 容器"
    elif has_cmd openclaw; then
        echo "本地安装 (npm)"
    else
        echo "未部署"
    fi
}

repair_broken_config() {
    msg_title "🛠️  修复损坏的配置"

    local cfg
    cfg=$(get_active_config_path)

    if [[ ! -f "$cfg" ]]; then
        msg_info "配置不存在,创建最小配置"
        _create_minimal_config
        wait_and_return 2
        return 0
    fi

    if json_is_valid; then
        msg_ok "JSON 有效"
        echo ""
        msg_step "运行 schema 兼容清理..."
        local result
        result=$(sanitize_config_for_schema 2>&1)
        if [[ "$result" == "NOCHANGE" ]]; then
            msg_ok "无需修改"
        else
            echo "$result" | sed 's/^/  /'
            msg_ok "已清理"
        fi
        wait_and_return 3
        return 0
    fi

    msg_fail "JSON 格式损坏"
    echo -e "${CYAN}文件:${NC} $cfg"
    echo ""

    if has_cmd python3; then
        local err
        err=$(python3 -c "import json; json.load(open('$cfg'))" 2>&1 | tail -1)
        echo -e "${YELLOW}错误:${NC} $err"
        echo ""
    fi

    echo -e "${BOLD}方案:${NC}"
    echo -e "  ${BOLD}1)${NC} 备份并重建 ${GREEN}(推荐)${NC}"
    echo -e "  ${BOLD}2)${NC} 编辑器手动修复"
    echo -e "  ${BOLD}3)${NC} 智能修剪"
    echo -e "  ${BOLD}0)${NC} 取消"
    echo ""
    echo -ne "${BOLD}选择: ${NC}"
    local rc
    read_input rc "0"

    case "$rc" in
        1)
            local backup
            backup=$(backup_config)
            [[ -n "$backup" ]] && msg_ok "已备份: $backup"
            _create_minimal_config
            msg_ok "已重建"
            ;;
        2)
            local backup
            backup=$(backup_config)
            [[ -n "$backup" ]] && msg_ok "已备份: $backup"
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
        3) _smart_repair_config ;;
        0) msg_info "已取消" ;;
        *) msg_warn "无效" ;;
    esac

    wait_and_return 3
    return 0
}

_smart_repair_config() {
    if ! has_cmd python3; then
        msg_fail "需要 python3"
        return 1
    fi

    local cfg
    cfg=$(get_active_config_path)
    local backup
    backup=$(backup_config)
    [[ -n "$backup" ]] && msg_ok "已备份: $backup"

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
        "models": {"mode": "merge", "providers": {}}
    }
    with open(path, 'w') as f:
        json.dump(minimal, f, indent=2, ensure_ascii=False)
    print("FALLBACK")
PYEOF

    if json_is_valid; then
        sanitize_config_for_schema
        fix_docker_ownership
        msg_ok "完成"
    else
        msg_fail "仍无效"
    fi
}

load_config_from_file() {
    local cfg
    cfg=$(get_active_config_path)
    [[ ! -f "$cfg" ]] && return 0
    json_is_valid || return 0

    if has_cmd python3; then
        local result
        result=$(python3 - "$cfg" << 'PYEOF' 2>/dev/null
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
        if key:
            print(f'G_API_KEYS[{provider}]="{key}"')
        if models:
            print(f'G_API_MODELS[{provider}]="{models}"')
        elif model:
            print(f'G_API_MODELS[{provider}]="{model}"')

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

    if base_url:
        print(f'G_API_URLS[{name}]="{base_url}"')
    if api_key:
        print(f'G_API_KEYS[{name}]="{api_key}"')
    if api_type:
        print(f'G_API_TYPES[{name}]="{api_type}"')
    if models_str:
        print(f'G_API_MODELS[{name}]="{models_str}"')

    if not first_custom:
        first_custom = name

if first_custom:
    print(f'G_DEFAULT_PROVIDER="{first_custom}"')
PYEOF
)
        [[ -n "${result:-}" ]] && eval "$result" 2>/dev/null || true
    fi
}

get_gateway_token() {
    local cfg
    cfg=$(get_active_config_path)
    [[ ! -f "$cfg" ]] && return 1
    json_is_valid || return 1

    if has_cmd python3; then
        python3 -c "
import json
try:
    c = json.load(open('$cfg'))
    t = c.get('gateway', {}).get('auth', {}).get('token', '')
    print(t)
except: pass
" 2>/dev/null
    fi
}

show_token_manager() {
    msg_title "${KEY} 网关令牌管理"

    if ! json_is_valid; then
        msg_fail "配置无效,请用菜单 [16] 修复"
        wait_and_return 3
        return 0
    fi

    local token local_ip
    token=$(get_gateway_token)
    local_ip=$(get_local_ip)

    echo -e "${CYAN}${BOLD}令牌状态${NC}"
    print_line
    if [[ -n "$token" ]]; then
        echo -e "  ${BOLD}状态:${NC}   ${GREEN}已设置${NC}"
        echo -e "  ${BOLD}Token:${NC}  ${YELLOW}${token}${NC}"
        echo ""
        echo -e "  ${BOLD}访问 URL:${NC}"
        echo -e "  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}?token=${token}${NC}"
    else
        echo -e "  ${BOLD}状态:${NC}   ${DIM}未设置${NC}"
        echo -e "  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${NC}"
    fi
    print_line
    echo ""

    echo -e "  ${BOLD}1)${NC} 查看令牌"
    echo -e "  ${BOLD}2)${NC} 生成新令牌"
    echo -e "  ${BOLD}3)${NC} 手动设置"
    echo -e "  ${BOLD}4)${NC} 删除令牌"
    echo -e "  ${BOLD}5)${NC} dashboard --no-open"
    echo -e "  ${BOLD}0)${NC} 返回"
    echo ""
    echo -ne "${BOLD}选择: ${NC}"
    local tc
    read_input tc "0"

    case "$tc" in
        1) [[ -n "$token" ]] && echo -e "\n${YELLOW}${token}${NC}" || msg_warn "未设置" ;;
        2)
            local new_token
            new_token=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null | tr -d '\n' || echo "$(date +%s%N)")
            _set_gateway_token "$new_token"
            ;;
        3)
            echo -ne "\n${BOLD}令牌 (至少 16 字符): ${NC}"
            local ct
            read_input ct ""
            [[ ${#ct} -lt 16 ]] && msg_fail "太短" || _set_gateway_token "$ct"
            ;;
        4) confirm "确认删除?" && _remove_gateway_token ;;
        5) is_openclaw_installed && openclaw_cmd dashboard --no-open 2>&1 | tail -20 || msg_fail "未安装" ;;
        0) return 0 ;;
        *) msg_warn "无效" ;;
    esac

    wait_and_return 3
    return 0
}

_set_gateway_token() {
    local new_token="$1"
    local cfg
    cfg=$(get_active_config_path)

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
        echo -e "\n${GREEN}${BOLD}新令牌:${NC} ${YELLOW}${new_token}${NC}"
        confirm "重启 Gateway?" && manage_service restart >/dev/null 2>&1
    fi
}

_remove_gateway_token() {
    local cfg
    cfg=$(get_active_config_path)

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

    msg_step "同步认证到 Agent [${agent_name}] provider=${provider_name}..."

    if ! is_openclaw_installed; then
        msg_warn "未安装,跳过"
        return 1
    fi

    if _write_agent_auth_file "$agent_name" "$provider_name" "$base_url" "$api_key" "$api_type"; then
        msg_ok "Agent [${agent_name}] ← ${provider_name}"
        return 0
    else
        msg_warn "注入失败 (${provider_name})"
        return 1
    fi
}

_write_agent_auth_file() {
    local agent_name="$1"
    local provider="$2"
    local base_url="$3"
    local api_key="$4"
    local api_type="$5"

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
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}

entry = {
    "provider": provider,
    "apiKey": api_key,
    "baseUrl": base_url,
    "api": api_type,
    "kind": "static",
    "portable": True
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
    msg_title "${LINK} 修复 Agent 认证"

    if ! is_openclaw_installed; then
        msg_fail "未安装"
        wait_and_return 2
        return 0
    fi

    if ! json_is_valid; then
        msg_fail "配置损坏,请先修复"
        wait_and_return 3
        return 0
    fi

    load_config_from_file

    if [[ ${#G_API_URLS[@]} -eq 0 && ${#G_API_KEYS[@]} -eq 0 ]]; then
        msg_fail "无 Provider 配置"
        wait_and_return 3
        return 0
    fi

    echo -e "${CYAN}当前 Agents:${NC}"
    openclaw_cmd agents list 2>&1 | head -15 | sed 's/^/  /' || echo "  (无法列出)"
    echo ""

    echo -ne "${BOLD}Agent 名 (默认: main): ${NC}"
    local agent_name
    read_input agent_name "main"

    echo ""
    echo -e "${CYAN}将同步:${NC}"
    for p in "${!G_API_URLS[@]}"; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        echo -e "  • ${BOLD}$p${NC} → ${DIM}${G_API_URLS[$p]}${NC}"
    done
    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        echo -e "  • ${BOLD}$p${NC} ${DIM}(内置)${NC}"
    done
    echo ""

    local inject_openai_alias=false
    if [[ ${#G_API_URLS[@]} -gt 0 ]] && [[ -z "${G_API_KEYS[openai]:-}" ]]; then
        echo -e "${YELLOW}💡 检测到自定义 Provider 但无 openai${NC}"
        confirm "以 openai 别名注入 (解决前端默认调用问题)?" && inject_openai_alias=true
        echo ""
    fi

    confirm "确认?" || { wait_and_return 2; return 0; }

    local ok=0 fail=0
    local first_custom=""

    for p in "${!G_API_URLS[@]}"; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        [[ -z "$first_custom" ]] && first_custom="$p"
        local url="${G_API_URLS[$p]}"
        if is_docker_mode && is_lan_url "$url"; then
            url=$(convert_url_for_docker "$url")
        fi
        echo ""
        sync_agent_auth "$p" "$url" "${G_API_KEYS[$p]}" "${G_API_TYPES[$p]:-openai-completions}" "$agent_name" && ((ok++)) || ((fail++))
    done

    if $inject_openai_alias && [[ -n "$first_custom" ]]; then
        echo ""
        local url="${G_API_URLS[$first_custom]}"
        if is_docker_mode && is_lan_url "$url"; then
            url=$(convert_url_for_docker "$url")
        fi
        sync_agent_auth "openai" "$url" "${G_API_KEYS[$first_custom]}" "${G_API_TYPES[$first_custom]:-openai-completions}" "$agent_name" && ((ok++)) || ((fail++))
    fi

    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        [[ "$p" == "openai" ]] && $inject_openai_alias && continue
        echo ""
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

    echo ""
    msg_step "重启 Gateway..."
    manage_service restart >/dev/null 2>&1
    sleep 3

    echo ""
    print_line
    echo -e "${BOLD}结果:${NC}  成功 ${GREEN}${ok}${NC}  失败 ${RED}${fail}${NC}"
    print_line

    echo -e "\n${YELLOW}💡 浏览器 Ctrl+Shift+R 硬刷新${NC}"

    wait_and_return 5
    return 0
}

_gateway_health_check() {
    local urls=(
        "http://127.0.0.1:${OPENCLAW_PORT}"
        "http://127.0.0.1:${OPENCLAW_PORT}/health"
        "http://127.0.0.1:${OPENCLAW_PORT}/healthz"
        "http://localhost:${OPENCLAW_PORT}"
    )

    for url in "${urls[@]}"; do
        local code
        code=$(curl -s -o /dev/null --max-time 2 --connect-timeout 2 -w "%{http_code}" "$url" 2>/dev/null || echo "000")
        if [[ "$code" =~ ^(200|401|403|404)$ ]]; then
            return 0
        fi
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

_persist_default_agent_model() {
    local provider="$1"
    local model="$2"

    if ! is_openclaw_installed; then
        return 1
    fi

    local full_model="${provider}/${model}"
    msg_info "设置默认模型: $full_model"

    if has_cmd python3; then
        local cfg
        cfg=$(get_active_config_path)
        if [[ -f "$cfg" ]] && json_is_valid; then
            python3 - "$cfg" "$provider" "$model" << 'PYEOF'
import json, sys, os

cfg_path, provider, model = sys.argv[1:4]
try:
    with open(cfg_path) as f:
        c = json.load(f)
except Exception:
    sys.exit(1)

agents = c.setdefault("agents", {})
main_agent = agents.setdefault("main", {})
main_agent.setdefault("model", {})
main_agent["model"]["primary"] = f"{provider}/{model}"

tmp = cfg_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
os.replace(tmp, cfg_path)
print("OK")
PYEOF
            chmod 600 "$cfg"
            fix_docker_ownership
            msg_ok "默认模型已固化"
            return 0
        fi
    fi

    msg_warn "无法固化默认模型,请在 UI 手动选择"
    return 1
}

configure_custom_api() {
    msg_title "🔧 自定义 API 一键部署"

    local cfg
    cfg=$(get_active_config_path)

    if [[ -f "$cfg" ]] && ! json_is_valid; then
        msg_fail "配置损坏,请先用菜单 [16] 修复"
        wait_and_return 3
        return 1
    fi

    local docker_mode=false
    is_docker_mode && docker_mode=true

    echo -e "${CYAN}${BOLD}━━━ 配置 + Agent 认证 + Gateway 启动 ━━━${NC}"
    if $docker_mode; then
        echo -e "${YELLOW}💡 检测到 Docker 部署模式${NC}"
        echo -e "${DIM}   局域网 IP 将自动转换为 host.docker.internal${NC}"
    fi
    echo ""

    echo -ne "${CYAN}Provider 名称 (推荐: openai / new-api / ollama): ${NC}"
    local provider_name
    read_input provider_name "openai"
    provider_name=$(echo "$provider_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    echo ""
    echo -e "${YELLOW}💡 OpenAI 兼容 API 建议名字叫 openai${NC}"
    echo ""

    echo -e "${DIM}URL 示例:${NC}"
    echo -e "  ${DIM}• http://192.168.x.x:xxxx${NC}"
    echo -e "  ${DIM}• https://api.deepseek.com/v1${NC}"
    echo -e "  ${DIM}• http://127.0.0.1:11434${NC}"
    echo ""
    echo -ne "${CYAN}API Base URL: ${NC}"
    local base_url
    read_input base_url ""

    [[ -z "$base_url" ]] && { msg_warn "URL 不能为空"; wait_and_return 2; return 1; }

    local final_url="$base_url"
    if $docker_mode && is_lan_url "$base_url"; then
        local converted
        converted=$(convert_url_for_docker "$base_url")
        if [[ "$converted" != "$base_url" ]]; then
            echo ""
            msg_warn "Docker 模式检测到局域网 URL"
            echo -e "  ${DIM}原始:${NC} $base_url"
            echo -e "  ${DIM}转换:${NC} ${GREEN}$converted${NC}"
            echo ""
            if confirm "使用转换后的 URL?"; then
                final_url="$converted"
            fi
        fi
    fi

    echo ""
    echo -ne "${CYAN}API Key (本地服务输入 'local'): ${NC}"
    local api_key
    read_input_silent api_key "local"

    echo ""
    echo -e "${CYAN}${BOLD}API 类型:${NC}"
    echo -e "  ${BOLD}1)${NC} openai-completions"
    echo -e "  ${BOLD}2)${NC} openai-responses"
    echo -e "  ${BOLD}3)${NC} ollama"
    echo -e "  ${BOLD}4)${NC} anthropic-messages"
    echo ""
    echo -ne "${CYAN}选择 [1-4] (默认: 1): ${NC}"
    local api_choice
    read_input api_choice "1"

    local api_type
    case "$api_choice" in
        2) api_type="openai-responses" ;;
        3) api_type="ollama" ;;
        4) api_type="anthropic-messages" ;;
        *) api_type="openai-completions" ;;
    esac

    echo ""
    echo -ne "${CYAN}模型 ID (多个用逗号分隔): ${NC}"
    local model_ids
    read_input model_ids ""

    [[ -z "$model_ids" ]] && { msg_warn "模型 ID 不能为空"; wait_and_return 2; return 1; }

    echo ""
    local default_model
    if [[ "$model_ids" == *","* ]]; then
        echo -e "${CYAN}多个模型,选择默认:${NC}"
        local i=1
        declare -a m_arr=()
        IFS=',' read -ra m_arr <<< "$model_ids"
        for m in "${m_arr[@]}"; do
            m=$(echo "$m" | xargs)
            echo "  ${i}) $m"
            ((i++))
        done
        echo ""
        echo -ne "${CYAN}选择 [1-$((i-1))] (默认: 1): ${NC}"
        local dc
        read_input dc "1"
        [[ "$dc" =~ ^[0-9]+$ ]] && (( dc >= 1 && dc <= ${#m_arr[@]} )) || dc=1
        default_model=$(echo "${m_arr[$((dc-1))]}" | xargs)
    else
        default_model=$(echo "$model_ids" | xargs)
    fi

    local inject_openai_alias=false
    if [[ "$provider_name" != "openai" ]]; then
        echo ""
        confirm "同时以 openai 别名注入认证 (强烈推荐)?" && inject_openai_alias=true
    fi

    G_API_URLS["$provider_name"]="$final_url"
    G_API_KEYS["$provider_name"]="$api_key"
    G_API_TYPES["$provider_name"]="$api_type"
    G_API_MODELS["$provider_name"]="$model_ids"
    G_DEFAULT_PROVIDER="$provider_name"

    echo ""
    print_line
    echo -e "${GREEN}${BOLD}开始一键部署...${NC}"
    print_line

    echo ""
    msg_step "步骤 1/6: 写入配置..."
    _write_custom_provider_config "$provider_name" "$default_model"

    echo ""
    msg_step "步骤 2/6: 同步认证到 main Agent..."
    sync_agent_auth "$provider_name" "$final_url" "$api_key" "$api_type" "main" || true

    if $inject_openai_alias; then
        echo ""
        msg_step "步骤 3/6: 注入 openai 别名..."
        sync_agent_auth "openai" "$final_url" "$api_key" "$api_type" "main" || true
    fi

    echo ""
    msg_step "步骤 4/6: schema 兼容清理..."
    sanitize_config_for_schema | sed 's/^/  /'

    echo ""
    msg_step "步骤 5/6: 固化默认模型..."
    _persist_default_agent_model "$provider_name" "$default_model"

    echo ""
    msg_step "步骤 6/6: 重启 Gateway..."
    manage_service restart >/dev/null 2>&1 || true

    echo -ne "  等待就绪"
    local i=0
    local started=false
    while (( i < 30 )); do
        sleep 1; echo -ne "."
        if _gateway_health_check; then
            started=true
            break
        fi
        ((i++))
    done
    echo ""

    if $started; then
        msg_ok "Gateway 已启动并可访问"
    else
        msg_warn "健康检测未通过"
        echo ""
        echo -e "${CYAN}日志尾部:${NC}"
        if $docker_mode; then
            docker logs --tail 15 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
        else
            tail -15 "$OPENCLAW_LOG_DIR/gateway.out" 2>/dev/null | sed 's/^/  /'
        fi
        echo ""
        if docker logs --tail 30 "$DOCKER_CONTAINER" 2>&1 | grep -qE "\[gateway\] ready|http server listening" 2>/dev/null; then
            msg_ok "日志显示 Gateway ready — 可能是防火墙问题,请直接尝试浏览器访问"
        fi
    fi

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║          🎉 一键部署完成!                                ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Provider:${NC}  ${CYAN}${provider_name}${NC}"
    echo -e "  ${BOLD}Base URL:${NC}  ${final_url}"
    echo -e "  ${BOLD}API Type:${NC}  ${CYAN}${api_type}${NC}"
    echo -e "  ${BOLD}默认模型:${NC}  ${GREEN}${provider_name}/${default_model}${NC}"
    $inject_openai_alias && echo -e "  ${BOLD}openai 别名:${NC} ${GREEN}已注入${NC}"
    $docker_mode && [[ "$final_url" != "$base_url" ]] && echo -e "  ${BOLD}URL 转换:${NC}  ${GREEN}✓${NC}"
    echo ""

    show_dashboard_info

    echo ""
    echo -e "${YELLOW}${BOLD}📋 使用说明:${NC}"
    echo -e "  1. 打开 Dashboard URL"
    echo -e "  2. 硬刷新: ${BOLD}Ctrl+Shift+R${NC}"
    echo -e "  3. 模型选择器选: ${CYAN}${provider_name}/${default_model}${NC}"
    echo ""

    return 0
}

_write_custom_provider_config() {
    local provider_name="$1"
    local default_model="$2"
    local cfg
    cfg=$(get_active_config_path)

    mkdir -p "$(dirname "$cfg")"

    if has_cmd python3; then
        local base_url="${G_API_URLS[$provider_name]:-}"
        local api_key="${G_API_KEYS[$provider_name]:-local}"
        local api_type="${G_API_TYPES[$provider_name]:-openai-completions}"
        local models_str="${G_API_MODELS[$provider_name]:-}"

        python3 - "$cfg" "$provider_name" "$base_url" "$api_key" "$api_type" "$models_str" << 'PYEOF'
import json, sys, os

cfg_path = sys.argv[1]
provider_name = sys.argv[2]
base_url = sys.argv[3]
api_key = sys.argv[4]
api_type = sys.argv[5]
models_str = sys.argv[6]

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
    defaults = config["agents"].get("defaults", {})
    if isinstance(defaults, dict) and "model" in defaults:
        del defaults["model"]

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
            "id": model_id,
            "name": model_id,
            "reasoning": False,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 128000,
            "maxTokens": 8192
        })

config["models"]["providers"][provider_name] = {
    "baseUrl": base_url,
    "apiKey": api_key,
    "api": api_type,
    "models": models_list
}

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
    else
        _write_custom_provider_bash "$provider_name"
    fi
}

_write_custom_provider_bash() {
    local provider_name="$1"
    local cfg
    cfg=$(get_active_config_path)
    local base_url="${G_API_URLS[$provider_name]:-}"
    local api_key="${G_API_KEYS[$provider_name]:-local}"
    local api_type="${G_API_TYPES[$provider_name]:-openai-completions}"
    local models_str="${G_API_MODELS[$provider_name]:-}"

    local models_json="["
    local first=true
    IFS=',' read -ra model_arr <<< "$models_str"
    for m in "${model_arr[@]}"; do
        m=$(echo "$m" | xargs)
        [[ -z "$m" ]] && continue
        $first || models_json+=","
        first=false
        models_json+="{\"id\":\"$m\",\"name\":\"$m\",\"reasoning\":false,\"input\":[\"text\"],\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0},\"contextWindow\":128000,\"maxTokens\":8192}"
    done
    models_json+="]"

    local content
    content=$(cat << EOF
{
  "gateway": {
    "mode": "local",
    "bind": "loopback"
  },
  "models": {
    "mode": "merge",
    "providers": {
      "${provider_name}": {
        "baseUrl": "${base_url}",
        "apiKey": "${api_key}",
        "api": "${api_type}",
        "models": ${models_json}
      }
    }
  }
}
EOF
)
    atomic_write_json "$cfg" "$content" && msg_ok "配置已创建" || msg_fail "失败"
}

validate_config() {
    local cfg
    cfg=$(get_active_config_path)

    msg_step "验证配置..."

    if [[ ! -f "$cfg" ]]; then
        msg_fail "配置不存在"
        return 1
    fi

    if ! json_is_valid; then
        msg_fail "JSON 无效,请用菜单 [16] 修复"
        return 1
    fi

    if is_openclaw_installed; then
        local out
        out=$(openclaw_cmd config validate 2>&1)
        if echo "$out" | grep -qiE "Invalid input|invalid config"; then
            msg_fail "Schema 验证失败:"
            echo "$out" | grep -iE "×|invalid|allowed" | head -10 | sed 's/^/  /'
            echo ""
            if confirm "自动清理不兼容字段?"; then
                sanitize_config_for_schema | sed 's/^/  /'
                echo ""
                msg_info "重新验证..."
                out=$(openclaw_cmd config validate 2>&1)
                if echo "$out" | grep -qiE "Invalid input"; then
                    msg_fail "仍失败:"
                    echo "$out" | head -20 | sed 's/^/  /'
                    return 1
                else
                    msg_ok "通过"
                    return 0
                fi
            fi
            return 1
        else
            msg_ok "openclaw config validate 通过"
            return 0
        fi
    fi
    return 0
}

ensure_minimal_config() {
    local cfg
    cfg=$(get_active_config_path)
    mkdir -p "$(dirname "$cfg")"

    if [[ ! -f "$cfg" ]]; then
        _create_minimal_config
        return
    fi

    if ! json_is_valid; then
        msg_warn "配置损坏,备份并重建"
        backup_config
        _create_minimal_config
        return
    fi

    sanitize_config_for_schema >/dev/null 2>&1 || true
}

_create_minimal_config() {
    local cfg
    cfg=$(get_active_config_path)

    local content='{
  "gateway": {
    "mode": "local",
    "bind": "loopback"
  },
  "models": {
    "mode": "merge",
    "providers": {}
  }
}'
    atomic_write_json "$cfg" "$content" && msg_ok "最小配置已创建" || msg_fail "失败"
}

configure_lan_access() {
    msg_title "${LOBSTER} 局域网 UI 访问"

    if ! is_openclaw_installed; then
        msg_fail "OpenClaw 未安装"
        wait_and_return 2; return 0
    fi

    if ! json_is_valid; then
        msg_fail "配置损坏,请先用菜单 [16] 修复"
        wait_and_return 3
        return 0
    fi

    local cfg
    cfg=$(get_active_config_path)

    echo -e "${CYAN}配置文件:${NC} ${DIM}${cfg}${NC}"
    echo ""

    echo -e "${CYAN}当前 gateway 配置:${NC}"
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

    echo ""
    print_line
    echo -e "${BOLD}将执行的修改:${NC}"
    echo -e "  ${CYAN}gateway.bind${NC} → ${GREEN}\"lan\"${NC}  ${DIM}(局域网监听)${NC}"
    echo -e "  ${CYAN}gateway.auth.token${NC} → ${GREEN}自动生成${NC}"
    echo -e "  ${CYAN}gateway.controlUi.*${NC} → ${GREEN}放宽认证${NC}"
    echo ""
    echo -e "${RED}${WARN} 勿将端口暴露公网!${NC}"
    echo ""

    confirm "确认?" || { msg_info "已取消"; wait_and_return 2; return 0; }

    local backup
    backup=$(backup_config)
    [[ -n "$backup" ]] && msg_ok "已备份: $backup"

    mkdir -p "$(dirname "$cfg")"
    local gw_token=""
    if has_cmd python3; then
        local py_result
        py_result=$(python3 - "$cfg" << 'PYEOF'
import json, sys, os, secrets

cfg_path = sys.argv[1]
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
    d = cfg["agents"].get("defaults", {})
    if isinstance(d, dict) and "model" in d:
        del d["model"]

gw = cfg.setdefault("gateway", {})
gw["mode"] = "local"
gw["bind"] = "lan"

auth = gw.setdefault("auth", {})
if not auth.get("token"):
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
            gw_token=$(echo "$py_result" | grep '^TOKEN=' | cut -d= -f2)
            fix_docker_ownership
            msg_ok "局域网配置已写入"
        else
            msg_fail "写入失败"
            wait_and_return 2; return 0
        fi
    fi

    echo ""
    msg_step "验证..."
    local vout
    vout=$(openclaw_cmd config validate 2>&1)
    if echo "$vout" | grep -qiE "Invalid input"; then
        msg_fail "验证失败,清理..."
        sanitize_config_for_schema | sed 's/^/  /'
    else
        msg_ok "通过"
    fi

    echo ""
    msg_step "重启 Gateway..."
    manage_service restart >/dev/null 2>&1

    echo -ne "  等待就绪"
    local i=0
    local started=false
    while (( i < 20 )); do
        sleep 1; echo -ne "."
        if curl -s --max-time 2 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
            started=true
            break
        fi
        ((i++))
    done
    echo ""

    if $started; then
        msg_ok "Gateway 已启动"
    else
        msg_warn "未响应"
    fi

    local local_ip; local_ip=$(get_local_ip)
    local token_qs=""
    [[ -n "$gw_token" ]] && token_qs="?token=${gw_token}"
    echo ""
    echo -e "${GREEN}${BOLD}局域网 UI 访问信息${NC}"
    print_line
    echo -e "  ${BOLD}本机:${NC}    ${CYAN}http://127.0.0.1:${OPENCLAW_PORT}${NC}"
    echo -e "  ${BOLD}局域网:${NC}  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${token_qs}${NC}"
    if [[ -n "$gw_token" ]]; then
        echo ""
        echo -e "  ${BOLD}WebSocket:${NC}    ${YELLOW}ws://${local_ip}:${OPENCLAW_PORT}${NC}"
        echo -e "  ${BOLD}网关令牌:${NC}     ${YELLOW}${gw_token}${NC}"
    fi
    echo ""
    echo -e "  ${RED}⚠️  勿暴露公网!${NC}"
    print_line
    echo ""
    echo -e "${CYAN}${BOLD}📋 在浏览器登录:${NC}"
    echo -e "  1. 打开: ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${token_qs}${NC}"
    echo -e "  2. 或手动:"
    echo -e "     ${DIM}WebSocket:${NC} ${YELLOW}ws://${local_ip}:${OPENCLAW_PORT}${NC}"
    echo -e "     ${DIM}令牌:${NC}      ${YELLOW}${gw_token}${NC}"
    echo -e "  3. 点击 ${BOLD}[连接]${NC}"
    echo ""

    log "LAN configured"
    wait_and_return 5; return 0
}

install_plugins() {
    msg_title "${PLUGIN} 安装插件"

    if ! is_openclaw_installed; then
        msg_fail "未安装"
        wait_and_return 2; return 0
    fi

    echo -e "  ${BOLD}1)${NC} ${LOBSTER} 微信"
    echo -e "  ${BOLD}2)${NC} ${LOBSTER} 飞书"
    echo -e "  ${BOLD}3)${NC} 全部"
    echo -e "  ${BOLD}0)${NC} 返回"
    echo ""
    echo -ne "${BOLD}选择: ${NC}"
    local choice
    read_input choice "0"

    case "$choice" in
        1) _install_single_plugin "微信" "$WECHAT_PLUGIN_PKG" ;;
        2) _install_single_plugin "飞书" "$FEISHU_PLUGIN_PKG" ;;
        3)
            _install_single_plugin "微信" "$WECHAT_PLUGIN_PKG"
            _install_single_plugin "飞书" "$FEISHU_PLUGIN_PKG"
            ;;
        0) return 0 ;;
        *) msg_warn "无效" ;;
    esac

    wait_and_return 3; return 0
}

_install_single_plugin() {
    local name="$1" pkg="$2"
    echo ""
    msg_step "安装 ${name}..."
    if openclaw_cmd plugins install "${pkg}" --force 2>&1 | tee -a "$LOG_FILE"; then
        msg_ok "${name} 成功"
    else
        msg_fail "${name} 失败"
    fi
}

deploy_docker() {
    msg_title "${DOCKER} Docker 部署"

    if ! has_cmd docker; then
        msg_warn "未检测到 Docker,安装中..."
        _install_docker || { wait_and_return 3; return 0; }
    fi

    echo -e "${CYAN}Docker:${NC} $(docker --version 2>/dev/null || echo '未知')"
    echo ""

    if docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        local container_status
        container_status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")
        echo -e "${CYAN}已有容器:${NC} ${BOLD}${container_status}${NC}"
        echo ""
        echo -e "  ${BOLD}1)${NC} 启动  ${BOLD}2)${NC} 停止  ${BOLD}3)${NC} 重启"
        echo -e "  ${BOLD}4)${NC} 删除重部署  ${BOLD}5)${NC} 日志  ${BOLD}6)${NC} Shell"
        echo -e "  ${BOLD}0)${NC} 返回"
        echo ""
        echo -ne "${BOLD}选择: ${NC}"
        local dc
        read_input dc "0"

        case "$dc" in
            1) docker start "$DOCKER_CONTAINER" && msg_ok "已启动" ;;
            2) docker stop  "$DOCKER_CONTAINER" && msg_ok "已停止" ;;
            3) docker restart "$DOCKER_CONTAINER" && msg_ok "已重启" ;;
            4) confirm "确认?" && { docker rm -f "$DOCKER_CONTAINER"; _docker_run; } ;;
            5) trap 'echo ""; msg_info "退出"' INT; docker logs -f "$DOCKER_CONTAINER" || true; trap - INT ;;
            6) docker exec -it "$DOCKER_CONTAINER" /bin/sh 2>/dev/null || docker exec -it "$DOCKER_CONTAINER" /bin/bash 2>/dev/null ;;
            0) return 0 ;;
        esac
    else
        echo -ne "  端口 (默认: ${OPENCLAW_PORT}): "
        local port; read_input port "$OPENCLAW_PORT"
        echo -ne "  数据目录 (默认: ${DOCKER_DATA_DIR}): "
        local data_dir; read_input data_dir "$DOCKER_DATA_DIR"

        echo ""
        echo -e "${CYAN}${BOLD}网络模式:${NC}"
        echo -e "  ${BOLD}1)${NC} bridge + host.docker.internal ${DIM}(默认,自动映射宿主机)${NC}"
        echo -e "  ${BOLD}2)${NC} host                          ${DIM}(容器共享宿主机网络)${NC}"
        echo ""
        echo -ne "${CYAN}选择 [1-2] (默认: 1): ${NC}"
        local nm; read_input nm "1"
        local network_mode="bridge"
        [[ "$nm" == "2" ]] && network_mode="host"

        local extra_opts=""
        confirm "  启用局域网 UI 访问?" && extra_opts="--lan"
        mkdir -p "$data_dir"
        _docker_run "$port" "$data_dir" "$extra_opts" "$network_mode"
    fi

    wait_and_return 3; return 0
}

_docker_run() {
    local port="${1:-$OPENCLAW_PORT}"
    local data_dir="${2:-$DOCKER_DATA_DIR}"
    local extra="${3:-}"
    local network_mode="${4:-bridge}"
    local image="$DOCKER_IMAGE"

    mkdir -p "${data_dir}/.openclaw" "${data_dir}/workspace"
    chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}" 2>/dev/null \
        || sudo chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}" 2>/dev/null || true

    msg_step "拉取镜像..."
    if docker pull "${image}:latest" 2>&1 | tail -3; then
        msg_ok "拉取成功"
    else
        msg_warn "GHCR 失败,尝试 Docker Hub..."
        if docker pull "${DOCKER_IMAGE_MIRROR}:latest" 2>&1 | tail -3; then
            image="$DOCKER_IMAGE_MIRROR"
        fi
    fi

    local container_config="${data_dir}/.openclaw/openclaw.json"
    local bind_v="loopback"
    [[ "$extra" == "--lan" ]] && bind_v="lan"

    msg_info "准备初始配置 (bind: $bind_v)..."
    local need_create=true
    if [[ -f "$container_config" ]] && has_cmd python3; then
        if python3 -c "
import json
c=json.load(open('$container_config'))
assert c.get('gateway',{}).get('bind') in ['auto','lan','loopback','custom','tailnet']
assert c.get('gateway',{}).get('mode') == 'local'
" 2>/dev/null; then
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
  "gateway": {
    "mode": "local",
    "bind": "${bind_v}"
  },
  "models": {
    "mode": "merge",
    "providers": {}
  }
}
EOF
)
        atomic_write_json "$container_config" "$content"
    fi

    chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}/.openclaw" 2>/dev/null \
        || sudo chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}/.openclaw" 2>/dev/null || true

    msg_step "启动容器 (网络模式: ${network_mode})..."
    local run_cmd=(
        docker run -d
        --name "$DOCKER_CONTAINER"
        --restart unless-stopped
        -v "${data_dir}/.openclaw:/home/node/.openclaw"
        -v "${data_dir}/workspace:/home/node/workspace"
    )

    if [[ "$network_mode" == "host" ]]; then
        run_cmd+=(--network host)
    else
        run_cmd+=(
            -p "${port}:18789"
            --add-host=host.docker.internal:host-gateway
        )
    fi

    run_cmd+=("${image}:latest")

    if "${run_cmd[@]}" 2>&1 | tail -2; then
        sleep 3

        local status
        status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")

        if [[ "$status" != "running" ]]; then
            msg_fail "容器启动后立即退出 (状态: $status)"
            echo ""
            echo -e "${YELLOW}${BOLD}容器日志:${NC}"
            print_line
            docker logs --tail 30 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
            print_line
            return 1
        fi

        msg_ok "容器已启动"

        echo -ne "  等待服务就绪"
        local i=0
        local ready=false
        while (( i < 25 )); do
            sleep 1; echo -ne "."
            if curl -s --max-time 2 "http://127.0.0.1:${port}" &>/dev/null; then
                ready=true; break
            fi
            ((i++))
        done
        echo ""

        if ! $ready; then
            msg_warn "端口未响应,查看日志:"
            docker logs --tail 20 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
        fi

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

        echo ""
        local local_ip; local_ip=$(get_local_ip)
        echo -e "${GREEN}${BOLD}部署完成!${NC}"
        echo -e "  ${BOLD}本机:${NC}   ${CYAN}http://127.0.0.1:${port}${NC}"
        echo -e "  ${BOLD}局域网:${NC} ${CYAN}http://${local_ip}:${port}${NC}"
        echo -e "  ${BOLD}网络:${NC}   ${network_mode}"
        echo ""
        echo -e "${CYAN}提示:${NC}"
        echo -e "  ${DIM}• 访问宿主机服务用: host.docker.internal:端口${NC}"
        echo -e "  ${DIM}• 菜单 [4] 配置自定义 API 会自动转换局域网 URL${NC}"

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
            safe_run "apt update"   sudo apt-get update -qq
            safe_run "依赖"         sudo apt-get install -y ca-certificates curl gnupg lsb-release
            safe_run "Docker"       bash -c "curl -fsSL https://get.docker.com | sh" ;;
        rhel|fedora)
            safe_run "Docker"       bash -c "curl -fsSL https://get.docker.com | sh" ;;
        arch)
            safe_run "Docker"       sudo pacman -S --noconfirm docker ;;
        alpine)
            safe_run "Docker"       sudo apk add docker ;;
        macos)
            msg_info "请手动安装 Docker Desktop"
            return 1 ;;
        *)
            safe_run "Docker"       bash -c "curl -fsSL https://get.docker.com | sh" ;;
    esac
    case "$SERVICE_MANAGER" in
        systemd) sudo systemctl enable --now docker 2>/dev/null || true; sudo usermod -aG docker "$USER" 2>/dev/null || true ;;
        openrc)  sudo rc-update add docker 2>/dev/null || true; sudo service docker start 2>/dev/null || true ;;
    esac
    has_cmd docker && msg_ok "Docker 安装成功" || { msg_fail "失败"; return 1; }
}

show_command_reference() {
    msg_title "${LOBSTER} 命令速查"

    local use_docker=false
    is_docker_mode && use_docker=true
    local prefix=""
    $use_docker && prefix="docker exec ${DOCKER_CONTAINER} "

    echo -e "${CYAN}${BOLD}🔧 服务${NC}"; print_line
    _cmd_row "${prefix}openclaw setup"               "初始化"
    _cmd_row "${prefix}openclaw gateway run"         "前台调试"
    _cmd_row "${prefix}openclaw gateway restart"     "重启"
    _cmd_row "${prefix}openclaw gateway status"      "状态"
    _cmd_row "${prefix}openclaw dashboard --no-open" "获取 URL"
    echo ""

    if $use_docker; then
        echo -e "${CYAN}${BOLD}🐳 Docker 专属${NC}"; print_line
        _cmd_row "docker logs -f ${DOCKER_CONTAINER}"      "实时日志"
        _cmd_row "docker restart ${DOCKER_CONTAINER}"      "重启容器"
        _cmd_row "docker exec -it ${DOCKER_CONTAINER} sh"  "进入容器"
        _cmd_row "cat ${DOCKER_DATA_DIR}/.openclaw/openclaw.json"  "查看配置"
        echo ""
    fi

    echo -e "${CYAN}${BOLD}🔗 Agent${NC}"; print_line
    _cmd_row "${prefix}openclaw agents list"              "列出"
    _cmd_row "${prefix}openclaw agents auth list main"    "认证列表"
    _cmd_row "${prefix}openclaw agents login main"        "交互登录"
    echo ""

    echo -e "${RED}${BOLD}⚠️  Schema 规范${NC}"; print_line
    _cmd_row "gateway.bind 允许值"                             "auto/lan/loopback/custom/tailnet"
    _cmd_row "${prefix}openclaw config set gateway.bind lan"   "启用局域网"
    _cmd_row "${prefix}openclaw doctor --fix"                  "自动修复"
    echo ""

    wait_and_return 3; return 0
}

_cmd_row() {
    printf "  ${CYAN}%-52s${NC} ${DIM}%s${NC}\n" "$1" "$2"
}

run_setup_wizard() {
    msg_title "🔧 setup 向导"

    if ! is_openclaw_installed; then
        msg_fail "未安装"
        wait_and_return 2; return 0
    fi

    if ! json_is_valid; then
        msg_fail "配置损坏,请先修复"
        wait_and_return 3
        return 0
    fi

    ensure_minimal_config

    if ! confirm "运行 openclaw setup?"; then
        wait_and_return 2; return 0
    fi

    openclaw_cmd setup </dev/tty && msg_ok "完成" || msg_warn "退出"

    confirm "重启?" && manage_service restart >/dev/null 2>&1

    wait_and_return 3; return 0
}

quick_commands() {
    msg_title "${GEAR} 快捷命令"

    if ! is_openclaw_installed; then
        msg_fail "未安装"
        wait_and_return 2; return 0
    fi

    echo -e "  ${BOLD}1)${NC}  openclaw setup"
    echo -e "  ${BOLD}2)${NC}  openclaw status"
    echo -e "  ${BOLD}3)${NC}  openclaw health"
    echo -e "  ${BOLD}4)${NC}  openclaw doctor --fix"
    echo -e "  ${BOLD}5)${NC}  openclaw logs"
    echo -e "  ${BOLD}6)${NC}  openclaw models status"
    echo -e "  ${BOLD}7)${NC}  openclaw models list"
    echo -e "  ${BOLD}8)${NC}  openclaw config validate"
    echo -e "  ${BOLD}9)${NC}  openclaw dashboard --no-open"
    echo -e "  ${BOLD}10)${NC} openclaw agents list"
    echo -e "  ${BOLD}11)${NC} openclaw gateway run (前台)"
    echo -e "  ${BOLD}12)${NC} 验证配置"
    echo -e "  ${BOLD}13)${NC} 配置自定义 API"
    echo -e "  ${BOLD}0)${NC}  返回"
    echo ""
    echo -ne "${BOLD}选择: ${NC}"
    local qc
    read_input qc "0"

    echo ""
    case "$qc" in
        1)  openclaw_cmd setup </dev/tty 2>&1 ;;
        2)  openclaw_cmd status ;;
        3)  openclaw_cmd health ;;
        4)  openclaw_cmd doctor --fix ;;
        5)  trap 'echo ""; msg_info "退出"' INT; openclaw_cmd logs 2>&1 || true; trap - INT ;;
        6)  openclaw_cmd models status ;;
        7)  openclaw_cmd models list ;;
        8)  openclaw_cmd config validate ;;
        9)  openclaw_cmd dashboard --no-open ;;
        10) openclaw_cmd agents list ;;
        11) msg_info "Ctrl+C 退出"; trap 'echo ""; msg_info "退出"' INT; openclaw_cmd gateway run 2>&1; trap - INT ;;
        12) validate_config ;;
        13) configure_custom_api ;;
        0)  return 0 ;;
        *)  msg_warn "无效" ;;
    esac

    wait_and_return 2; return 0
}

configure_api_keys() {
    msg_title "🔑 内置 Provider API 密钥"

    if [[ -f "$(get_active_config_path)" ]] && ! json_is_valid; then
        msg_fail "配置损坏"
        wait_and_return 3
        return 1
    fi

    load_config_from_file
    mkdir -p "$(dirname "$(get_active_config_path)")"

    if [[ ${#G_API_KEYS[@]} -gt 0 ]]; then
        echo -e "${CYAN}已有配置:${NC}"
        for p in anthropic openai google deepseek groq mistral; do
            [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
            local dt=""; [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && dt=" ${GREEN}[默认]${NC}"
            echo -e "  ${BOLD}${p}${NC}: ${DIM}${G_API_KEYS[$p]:0:8}****${NC} → ${G_API_MODELS[$p]%%,*}${dt}"
        done
        echo ""
    fi

    echo "  1) Anthropic   2) OpenAI   3) Google   4) DeepSeek"
    echo "  5) Groq        6) Mistral  7) 自定义 API  0) 保存"
    echo ""

    while true; do
        echo -ne "${BOLD}编号(0完成): ${NC}"
        local c
        read_input c "0"
        case "$c" in
            0) break ;;
            1) _cfg_builtin_provider anthropic "sk-ant-..." "claude-sonnet-4-5" ;;
            2) _cfg_builtin_provider openai "sk-..." "gpt-4o" ;;
            3) _cfg_builtin_provider google "" "gemini-2.5-flash" ;;
            4) _cfg_builtin_provider deepseek "sk-..." "deepseek-chat" ;;
            5) _cfg_builtin_provider groq "gsk_..." "llama-3.3-70b-versatile" ;;
            6) _cfg_builtin_provider mistral "" "mistral-large-latest" ;;
            7) configure_custom_api ;;
            *) msg_warn "请输入 0-7" ;;
        esac
    done

    if [[ ${#G_API_KEYS[@]} -eq 0 && ${#G_API_URLS[@]} -eq 0 ]]; then
        msg_warn "未配置"
        return 0
    fi

    msg_step "保存..."
    ensure_minimal_config
    _write_builtin_providers_config
    _show_config_summary

    if is_openclaw_installed; then
        echo ""
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
            msg_step "重启..."
            manage_service restart >/dev/null 2>&1
        fi
    fi

    echo ""
    validate_config
    return 0
}

_write_builtin_providers_config() {
    local cfg
    cfg=$(get_active_config_path)
    has_cmd python3 || return 1

    local py_code='
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
'

    for p in anthropic openai google deepseek groq mistral; do
        if [[ -n "${G_API_KEYS[$p]:-}" ]]; then
            local safe_key="${G_API_KEYS[$p]}"
            safe_key="${safe_key//\\/\\\\}"
            safe_key="${safe_key//\'/\\\'}"
            py_code+="
c.setdefault('$p', {})['apiKey'] = '${safe_key}'
"
            if [[ -n "${G_API_MODELS[$p]:-}" ]]; then
                local first_model="${G_API_MODELS[$p]%%,*}"
                py_code+="
c['$p']['model'] = '${first_model}'
c['$p']['models'] = '${G_API_MODELS[$p]}'
"
            fi
        fi
    done

    py_code+='
with open(cfg_path, "w") as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
'

    python3 -c "$py_code" "$cfg"
    chmod 600 "$cfg"
    fix_docker_ownership
    msg_ok "配置已保存"
}

_cfg_builtin_provider() {
    local p="$1" hint="$2" rec="$3"
    echo ""
    echo -e "${CYAN}${BOLD}─── ${p} ───${NC}"
    local ek="${G_API_KEYS[$p]:-}"
    [[ -n "$ek" ]] && echo -e "  ${DIM}已有: ${ek:0:8}****${NC}"
    echo -ne "  Key${hint:+ ($hint)}: "
    local nk
    read_input_silent nk ""

    if [[ -z "$nk" ]]; then
        [[ -n "$ek" ]] && msg_info "保留" || msg_warn "跳过"
        return
    fi

    G_API_KEYS["$p"]="$nk"

    echo -ne "  模型 (默认: $rec): "
    local sm
    read_input sm "$rec"
    G_API_MODELS["$p"]="$sm"

    msg_ok "${p}: ${sm}"
    [[ -z "$G_DEFAULT_PROVIDER" ]] && G_DEFAULT_PROVIDER="$p"
}

_show_config_summary() {
    print_line
    echo -e "${BOLD}摘要${NC}"
    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        echo -e "  ${BOLD}${p}${NC}  ${DIM}${G_API_KEYS[$p]:0:10}****${NC} → ${CYAN}${G_API_MODELS[$p]:-}${NC}"
    done
    for p in "${!G_API_URLS[@]}"; do
        [[ -z "${G_API_URLS[$p]:-}" ]] && continue
        echo -e "  ${BOLD}${p}${NC}  ${DIM}${G_API_URLS[$p]}${NC}"
    done
    print_line
}

_try_systemd() {
    local svc
    for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
        sudo systemctl "$@" "$svc" 2>/dev/null && return 0
        systemctl --user "$@" "$svc" 2>/dev/null && return 0
    done
    return 1
}

_try_openrc() {
    local svc
    for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
        sudo rc-service "$svc" "$1" 2>/dev/null && return 0
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

service_action() {
    local action="$1"
    detect_system

    if is_docker_mode; then
        case "$action" in
            start)   docker start "$DOCKER_CONTAINER" 2>/dev/null || true ;;
            stop)    docker stop  "$DOCKER_CONTAINER" 2>/dev/null || true ;;
            restart) docker restart "$DOCKER_CONTAINER" 2>/dev/null || true ;;
            status)
                docker inspect --format='Status: {{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null
                echo ""
                docker logs --tail 15 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
                ;;
            enable)  msg_info "Docker restart=unless-stopped 已启用" ;;
        esac
        return 0
    fi

    if ! has_cmd openclaw; then
        return 1
    fi

    case "$SERVICE_MANAGER" in
        systemd)
            case "$action" in
                start)   _try_systemd start ;;
                stop)    _try_systemd stop ;;
                restart) _try_systemd restart ;;
                enable)  _try_systemd enable --now ;;
                status)  _try_systemd status --no-pager ;;
            esac ;;
        openrc)
            _try_openrc "$action" || { [[ "$action" == "enable" ]] && sudo rc-update add openclaw 2>/dev/null || true; } ;;
        launchd)
            _try_launchd "$action" ;;
        *)
            case "$action" in
                start)   openclaw gateway start >> "$LOG_FILE" 2>&1 & ;;
                stop)    openclaw gateway stop  >> "$LOG_FILE" 2>&1 || true ;;
                restart) openclaw gateway stop  >> "$LOG_FILE" 2>&1 || true; sleep 1; openclaw gateway start >> "$LOG_FILE" 2>&1 & ;;
                status)  openclaw gateway status 2>/dev/null || echo "未知" ;;
            esac ;;
    esac
    return 0
}

show_dashboard_info() {
    local local_ip
    local_ip=$(get_local_ip)
    local public_ip
    public_ip=$(curl -s --max-time 3 --connect-timeout 2 https://api.ipify.org 2>/dev/null \
             || curl -s --max-time 3 --connect-timeout 2 https://ifconfig.me 2>/dev/null || echo "无法获取")

    [[ -z "$G_DEFAULT_PROVIDER" ]] && load_config_from_file

    local bind_mode="loopback"
    local token=""
    local cfg
    cfg=$(get_active_config_path)
    if [[ -f "$cfg" ]] && json_is_valid && has_cmd python3; then
        bind_mode=$(python3 -c "
import json
try:
    c=json.load(open('$cfg'))
    print(c.get('gateway',{}).get('bind','loopback'))
except: print('loopback')
" 2>/dev/null || echo "loopback")
        token=$(get_gateway_token)
    fi

    local token_qs=""
    [[ -n "$token" ]] && token_qs="?token=${token}"

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║            🎉 OpenClaw 访问信息                          ║${NC}"
    echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}本机:${NC}    ${CYAN}http://127.0.0.1:${OPENCLAW_PORT}${token_qs}${NC}"
    if [[ "$bind_mode" == "lan" ]]; then
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}局域网:${NC}  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${token_qs}${NC} ${GREEN}(已启用)${NC}"
    else
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}局域网:${NC}  ${DIM}未启用 (菜单[5]启用)${NC}"
    fi
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}SSH隧道:${NC} ${YELLOW}ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} user@${public_ip}${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}bind:${NC}    ${bind_mode}"
    if [[ -n "$token" ]]; then
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}Token:${NC}   ${YELLOW}${token}${NC}"
    fi
    if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
        local dm="${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
        dm="${dm%%,*}"
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}默认AI:${NC}  ${CYAN}${G_DEFAULT_PROVIDER}${NC} → ${dm}"
    fi
    echo -e "${GREEN}${BOLD}║${NC}  ${RED}⚠️  勿暴露公网!${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ -n "$token" ]] && [[ "$bind_mode" == "lan" ]]; then
        echo -e "${CYAN}${BOLD}浏览器 UI 登录信息:${NC}"
        echo -e "  ${BOLD}WebSocket:${NC} ${YELLOW}ws://${local_ip}:${OPENCLAW_PORT}${NC}"
        echo -e "  ${BOLD}令牌:${NC}      ${YELLOW}${token}${NC}"
        echo ""
    fi
}

install_openclaw() {
    msg_title "${ROCKET} 安装 OpenClaw"
    detect_system
    echo -e "${CYAN}环境:${NC} ${BOLD}${OS} ${ARCH_LABEL}${NC}"
    echo ""

    if has_cmd openclaw; then
        local iv
        iv=$(openclaw --version 2>/dev/null || echo "未知")
        msg_warn "已安装 ($iv)"
        confirm "重新安装?" || return 0
    fi

    msg_step "步骤 1/5: 系统依赖..."
    case "$OS" in
        debian)
            safe_run "apt update" sudo apt-get update -qq
            safe_run "依赖" sudo apt-get install -y curl wget git build-essential ca-certificates gnupg python3 jq ;;
        rhel|fedora)
            safe_run "更新" bash -c "$UPDATE_CMD"
            safe_run "依赖" bash -c "$INSTALL_CMD curl wget git gcc gcc-c++ make python3 jq" ;;
        arch)
            safe_run "pacman" sudo pacman -Sy --noconfirm
            safe_run "依赖" sudo pacman -S --noconfirm curl wget git base-devel python jq ;;
        alpine)
            safe_run "apk update" sudo apk update
            safe_run "依赖" sudo apk add curl wget git build-base python3 jq ;;
        macos)
            has_cmd brew || safe_run "Homebrew" bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            safe_run "工具" brew install curl wget git jq ;;
    esac
    msg_ok "依赖完成"

    msg_step "步骤 2/5: Node.js..."
    install_nodejs || { msg_fail "Node.js 安装失败"; wait_and_return 3; return 1; }

    msg_step "步骤 3/5: 安装 OpenClaw..."
    echo -e "  ${BOLD}1)${NC} 官方脚本 ${GREEN}[推荐]${NC}"
    echo -e "  ${BOLD}2)${NC} npm 安装"
    echo -e "  ${BOLD}3)${NC} GitHub 源码编译"
    echo ""
    echo -ne "${BOLD}请选择 [1-3] (默认: 1): ${NC}"
    local ic
    read_input ic "1"

    msg_info "正在安装,请稍候..."

    case "$ic" in
        2)
            msg_info "执行 npm install -g openclaw@latest ..."
            if npm install -g openclaw@latest >> "$LOG_FILE" 2>&1; then
                msg_ok "npm 安装成功"
            else
                msg_fail "npm 安装失败 (详见 $LOG_FILE)"
            fi
            ;;
        3)
            echo -ne "${BOLD}仓库地址 (默认: ${GITHUB_REPO}): ${NC}"
            local repo
            read_input repo "$GITHUB_REPO"
            local tmp="/tmp/oc_src_$$"
            msg_info "正在克隆 $repo ..."
            git clone "$repo" "$tmp" >> "$LOG_FILE" 2>&1 || { msg_fail "clone 失败"; return 1; }
            pushd "$tmp" > /dev/null
            has_cmd pnpm || npm install -g pnpm >> "$LOG_FILE" 2>&1 || true
            msg_info "正在编译..."
            pnpm install >> "$LOG_FILE" 2>&1 || true
            pnpm run build >> "$LOG_FILE" 2>&1 || true
            pnpm install -g . >> "$LOG_FILE" 2>&1 || true
            popd > /dev/null
            rm -rf "$tmp"
            ;;
        *)
            msg_info "正在下载官方安装脚本..."
            if curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 --connect-timeout 10 "$OPENCLAW_INSTALL_URL" 2>/dev/null | bash >> "$LOG_FILE" 2>&1; then
                msg_ok "官方脚本安装成功"
            else
                msg_warn "官方脚本失败,回退到 npm 安装..."
                npm install -g openclaw@latest >> "$LOG_FILE" 2>&1 || true
            fi
            ;;
    esac

    _refresh_node_path
    has_cmd openclaw || { msg_fail "安装失败,请检查日志: $LOG_FILE"; wait_and_return 5; return 1; }
    msg_ok "OpenClaw $(openclaw --version 2>/dev/null) 安装成功"

    msg_step "步骤 4/5: 配置..."
    ensure_minimal_config

    echo ""
    echo -e "${CYAN}下一步:${NC}"
    echo -e "  ${BOLD}1)${NC} 配置自定义 API ${GREEN}(推荐)${NC}"
    echo -e "  ${BOLD}2)${NC} 配置内置 Provider"
    echo -e "  ${BOLD}3)${NC} 跳过"
    echo ""
    echo -ne "${BOLD}选择: ${NC}"
    local next
    read_input next "3"
    case "$next" in
        1) configure_custom_api ;;
        2) configure_api_keys ;;
    esac

    msg_step "步骤 5/5: 启动..."
    manage_service start >/dev/null 2>&1
    sleep 3

    if curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
        msg_ok "Gateway 已启动!"
    else
        msg_warn "Gateway 未响应,可稍后手动启动"
    fi

    echo ""
    if confirm "配置局域网访问 (其他设备打开 UI)?"; then
        configure_lan_access
    else
        show_dashboard_info
    fi

    log "Installation completed"
    wait_and_return 3
    return 0
}

install_nodejs() {
    msg_step "检测 Node.js..."

    if has_cmd node; then
        local ver
        ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$ver" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v) 已满足要求 (>= v${NODE_MIN_VERSION})"
            return 0
        else
            msg_warn "Node.js $(node -v) 版本过低,需要 >= v${NODE_MIN_VERSION}"
        fi
    else
        msg_info "Node.js 未安装"
    fi

    local tv="$NODE_RECOMMENDED_VERSION"

    echo ""
    echo -e "  ${BOLD}1)${NC} NodeSource 安装 v${tv} ${GREEN}(推荐)${NC}"
    echo -e "  ${BOLD}2)${NC} nvm 安装"
    echo -e "  ${BOLD}3)${NC} 系统包管理器安装"
    echo -e "  ${BOLD}4)${NC} 跳过 (手动安装)"
    echo ""
    echo -ne "${BOLD}请选择 [1-4] (默认: 1): ${NC}"
    local nc
    read_input nc "1"

    if [[ "$nc" == "1" || "$nc" == "2" ]]; then
        echo ""
        echo -ne "${BOLD}安装 Node.js 主版本号 (默认: ${tv}): ${NC}"
        local custom_ver
        read_input custom_ver "$tv"
        custom_ver=$(echo "$custom_ver" | tr -d 'vV ')
        [[ "$custom_ver" =~ ^[0-9]+$ ]] && tv="$custom_ver"
    fi

    msg_info "正在安装 Node.js v${tv},请稍候..."

    case "$nc" in
        1) _install_node_nodesource "$tv" ;;
        2) _install_node_nvm "$tv" ;;
        3) _install_node_native ;;
        4) msg_info "请手动安装: https://nodejs.org/en/download/"; return 1 ;;
        *) _install_node_nodesource "$tv" ;;
    esac

    _refresh_node_path

    if has_cmd node; then
        local iv
        iv=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$iv" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v) 安装成功"
            return 0
        fi
    fi
    msg_fail "Node.js 安装失败"
    return 1
}

_install_node_nodesource() {
    local version="$1"
    case "$OS" in
        debian)
            safe_run "NodeSource" bash -c "curl -fsSL https://deb.nodesource.com/setup_${version}.x | sudo -E bash -"
            safe_run "nodejs" sudo apt-get install -y nodejs ;;
        rhel|fedora)
            safe_run "NodeSource" bash -c "curl -fsSL https://rpm.nodesource.com/setup_${version}.x | sudo bash -"
            safe_run "nodejs" sudo "$PKG_MANAGER" install -y nodejs ;;
        arch)
            safe_run "nodejs" sudo pacman -S --noconfirm nodejs npm ;;
        alpine)
            safe_run "nodejs" sudo apk add nodejs npm ;;
        macos)
            has_cmd brew || { msg_fail "需要 Homebrew"; return 1; }
            safe_run "node@${version}" brew install "node@${version}"
            brew link --force --overwrite "node@${version}" 2>/dev/null || true ;;
    esac
}

_install_node_nvm() {
    local version="$1"
    local nvm_ver
    nvm_ver=$(get_nvm_latest_version)
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
            safe_run "apt" sudo apt-get update -qq
            safe_run "nodejs" sudo apt-get install -y nodejs npm ;;
        rhel)
            safe_run "nodejs" sudo yum install -y nodejs npm ;;
        fedora)
            safe_run "nodejs" sudo dnf install -y nodejs npm ;;
        arch)
            safe_run "nodejs" sudo pacman -S --noconfirm nodejs npm ;;
        alpine)
            safe_run "nodejs" sudo apk add nodejs npm ;;
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
}

show_version() {
    msg_title "📦 版本信息"
    is_openclaw_installed || { msg_fail "未安装"; wait_and_return 2; return 0; }
    print_line
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw_cmd --version 2>/dev/null || echo '未知')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}npm${NC}         : v$(npm -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}Docker${NC}      : $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo '未安装')"
    echo -e "  ${BOLD}部署${NC}        : $(_detect_deploy_mode)"
    echo -e "  ${BOLD}脚本${NC}        : ${SCRIPT_VERSION}"
    print_line
    echo ""

    msg_info "检查最新版本..."
    local latest current
    latest=$(get_openclaw_latest_version)
    current=$(openclaw_cmd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
    echo -e "  当前: ${current}  最新: ${latest:-无法获取}"

    if [[ -n "$latest" && "$latest" != "$current" ]]; then
        confirm "升级?" && {
            if is_docker_mode; then
                docker pull "${DOCKER_IMAGE}:latest" && docker rm -f "$DOCKER_CONTAINER" && _docker_run "$OPENCLAW_PORT" "$DOCKER_DATA_DIR"
            else
                npm install -g openclaw@latest 2>&1 | tail -5 && msg_ok "已升级" || msg_fail "失败"
            fi
        }
    else
        msg_ok "已是最新"
    fi

    wait_and_return 3
    return 0
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

                if ! docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
                    docker start "$DOCKER_CONTAINER" >/dev/null 2>&1
                    sleep 5
                fi

                local status
                status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")

                if [[ "$status" == "running" ]]; then
                    echo -ne "  等待就绪"
                    local i=0
                    local ok=false
                    while (( i < 20 )); do
                        sleep 1; echo -ne "."
                        if curl -s --max-time 2 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                            ok=true; break
                        fi
                        ((i++))
                    done
                    echo ""
                    if $ok; then
                        msg_ok "容器启动成功"
                        show_dashboard_info
                    else
                        msg_warn "端口无响应,容器日志:"
                        docker logs --tail 25 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
                    fi
                else
                    msg_fail "容器状态: $status"
                    echo ""
                    echo -e "${YELLOW}${BOLD}容器日志:${NC}"
                    print_line
                    docker logs --tail 30 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
                    print_line
                    echo ""
                    echo -e "${CYAN}排查:${NC}"
                    echo -e "  ${DIM}配置: ${DOCKER_DATA_DIR}/.openclaw/openclaw.json${NC}"
                    echo -e "  ${DIM}菜单 [24] 清理不兼容字段${NC}"
                    echo -e "  ${DIM}菜单 [16] 修复配置${NC}"
                fi
                wait_and_return 5
                return 0
            fi

            ensure_minimal_config

            pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
            rm -f "$OPENCLAW_CONFIG_DIR/gateway.lock" "$OPENCLAW_CONFIG_DIR"/*.pid 2>/dev/null || true
            sleep 1

            local port_pid=""
            if has_cmd lsof; then
                port_pid=$(lsof -ti :$OPENCLAW_PORT 2>/dev/null | head -1)
            elif has_cmd ss; then
                port_pid=$(ss -lntp 2>/dev/null | grep ":$OPENCLAW_PORT" | grep -oP 'pid=\K[0-9]+' | head -1)
            fi
            if [[ -n "$port_pid" ]]; then
                msg_warn "端口 $OPENCLAW_PORT 被 PID $port_pid 占用,释放..."
                kill -9 "$port_pid" 2>/dev/null || sudo kill -9 "$port_pid" 2>/dev/null || true
                sleep 2
            fi

            if ! has_cmd openclaw; then
                msg_fail "宿主机未安装 openclaw"
                echo ""
                echo -e "  ${BOLD}A)${NC} 安装 npm 版本 → 菜单 [1]"
                echo -e "  ${BOLD}B)${NC} 使用 Docker  → 菜单 [2]"
                wait_and_return 5
                return 0
            fi

            if ! json_is_valid; then
                msg_fail "配置损坏,请用菜单 [16] 修复"
                wait_and_return 3
                return 0
            fi

            msg_step "验证配置..."
            local validate_out
            validate_out=$(openclaw config validate 2>&1)
            if echo "$validate_out" | grep -qiE "Invalid input|invalid config"; then
                msg_warn "验证失败:"
                echo "$validate_out" | grep -iE "×|invalid|allowed" | head -8 | sed 's/^/  /'
                echo ""
                msg_step "自动清理..."
                sanitize_config_for_schema | sed 's/^/  /'
                sleep 1
            else
                msg_ok "配置有效"
            fi

            mkdir -p "$OPENCLAW_LOG_DIR"
            local out_log="$OPENCLAW_LOG_DIR/gateway.out"
            > "$out_log"

            msg_info "尝试通过 systemd 启动..."
            service_action start
            sleep 3

            if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                msg_ok "启动成功"
                show_dashboard_info
                wait_and_return 3
                return 0
            fi

            msg_warn "systemd 未响应,后台运行..."
            local openclaw_bin
            openclaw_bin=$(command -v openclaw)
            if [[ -z "$openclaw_bin" ]]; then
                msg_fail "找不到 openclaw"
                wait_and_return 3
                return 0
            fi

            nohup "$openclaw_bin" gateway run > "$out_log" 2>&1 &
            local bg_pid=$!
            sleep 6

            if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                msg_ok "后台运行成功 (PID: $bg_pid)"
                show_dashboard_info
            else
                msg_fail "Gateway 启动失败"
                echo ""
                echo -e "${YELLOW}${BOLD}错误日志:${NC}"
                print_line
                tail -25 "$out_log" 2>/dev/null | sed 's/^/  /' || echo "  (无日志)"
                print_line
                echo ""
                echo -e "${CYAN}修复:${NC}"
                echo -e "  ${BOLD}1)${NC} 菜单 [16] 修复配置"
                echo -e "  ${BOLD}2)${NC} 菜单 [24] 清理字段"
                echo -e "  ${BOLD}3)${NC} 手动: ${YELLOW}openclaw gateway run${NC}"
            fi
            ;;
        stop)
            confirm "确认停止?" && {
                if $docker_mode; then
                    docker stop "$DOCKER_CONTAINER" 2>/dev/null && msg_ok "容器已停止" || msg_warn "失败"
                else
                    if json_is_valid && has_cmd openclaw; then
                        service_action stop 2>/dev/null || true
                        openclaw gateway stop 2>/dev/null || true
                    fi
                    pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
                    sleep 1
                    msg_ok "已停止"
                fi
            } || msg_info "已取消" ;;
        restart)
            msg_step "重启..."
            if $docker_mode; then
                docker restart "$DOCKER_CONTAINER" >/dev/null 2>&1
                sleep 5

                local st
                st=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")
                if [[ "$st" == "running" ]]; then
                    echo -ne "  等待就绪"
                    local i=0
                    while (( i < 20 )); do
                        sleep 1; echo -ne "."
                        curl -s --max-time 2 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null && break
                        ((i++))
                    done
                    echo ""
                    msg_ok "已重启"
                    show_dashboard_info
                else
                    msg_fail "重启失败,状态: $st"
                    docker logs --tail 20 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
                fi
            else
                if json_is_valid; then
                    service_action stop 2>/dev/null || true
                fi
                pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
                sleep 2
                manage_service start
                return 0
            fi ;;
        status)
            msg_step "状态:"
            echo ""
            if $docker_mode; then
                echo -e "${CYAN}Docker 容器:${NC}"
                docker ps -a --filter "name=$DOCKER_CONTAINER" --format "  Name: {{.Names}}\n  Status: {{.Status}}\n  Ports: {{.Ports}}"
                echo ""
                echo -e "${CYAN}容器日志:${NC}"
                docker logs --tail 15 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
            else
                service_action status
                echo ""
                echo -e "${CYAN}进程:${NC}"
                ps aux | grep -iE "openclaw" | grep -v grep | grep -v "openclaw-manager" | head -5 | sed 's/^/  /' || echo "  (无)"
            fi
            echo ""
            echo -e "${CYAN}端口 ($OPENCLAW_PORT):${NC}"
            ss -lntp 2>/dev/null | grep ":$OPENCLAW_PORT" | sed 's/^/  /' || echo "  未监听"

            load_config_from_file
            show_dashboard_info ;;
    esac
    wait_and_return 5
    return 0
}

diagnose_and_fix() {
    msg_title "${DOCTOR} 诊断与修复"
    detect_system
    local issues=0 fixed=0
    local cfg
    cfg=$(get_active_config_path)

    echo -e "${CYAN}${BOLD}检测中...${NC}"
    echo -e "${DIM}模式: $(_detect_deploy_mode)  配置: $cfg${NC}"
    echo ""

    _chk() { echo -ne "  [${1}] ${2}...  "; }
    _pass() { echo -e "${GREEN}${OK} $*${NC}"; }
    _fail_msg() { echo -e "${RED}${FAIL} $*${NC}"; }

    _chk "1/10" "OpenClaw"
    if is_openclaw_installed; then
        _pass "$(openclaw_cmd --version 2>/dev/null)"
    else
        _fail_msg "未安装"
        ((issues++))
    fi

    _chk "2/10" "配置存在"
    if [[ -f "$cfg" ]]; then
        _pass "存在"
    else
        _fail_msg "不存在"
        ((issues++))
        confirm "  创建?" && { _create_minimal_config; ((fixed++)); }
    fi

    _chk "3/10" "JSON 有效"
    if [[ -f "$cfg" ]]; then
        if json_is_valid; then
            _pass "有效"
        else
            _fail_msg "损坏!"
            ((issues++))
            confirm "  修复?" && { backup_config; _create_minimal_config; ((fixed++)); }
        fi
    else
        echo -e "${DIM}跳过${NC}"
    fi

    _chk "4/10" "gateway.bind"
    if [[ -f "$cfg" ]] && json_is_valid && has_cmd python3; then
        local bind_v
        bind_v=$(python3 -c "
import json
try:
    c=json.load(open('$cfg'))
    print(c.get('gateway',{}).get('bind',''))
except: print('')
" 2>/dev/null || echo "")
        if [[ "$bind_v" =~ ^(auto|lan|loopback|custom|tailnet)$ ]]; then
            _pass "bind=$bind_v"
        else
            _fail_msg "bind='$bind_v' 无效"
            ((issues++))
            confirm "  修复?" && { sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        fi
    else
        echo -e "${DIM}跳过${NC}"
    fi

    _chk "5/10" "非法根字段"
    if [[ -f "$cfg" ]] && json_is_valid && has_cmd python3; then
        local bad_keys
        bad_keys=$(python3 -c "
import json
try:
    c=json.load(open('$cfg'))
    bad = [k for k in ['ui','defaultProvider'] if k in c]
    ag = c.get('agents',{})
    if isinstance(ag,dict) and 'model' in ag.get('defaults',{}):
        bad.append('agents.defaults.model')
    print(','.join(bad))
except: print('')
" 2>/dev/null || echo "")
        if [[ -z "$bad_keys" ]]; then
            _pass "无"
        else
            _fail_msg "存在: $bad_keys"
            ((issues++))
            confirm "  清理?" && { sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        fi
    else
        echo -e "${DIM}跳过${NC}"
    fi

    _chk "6/10" "openclaw schema"
    if is_openclaw_installed && json_is_valid; then
        local schema_out
        schema_out=$(openclaw_cmd config validate 2>&1)
        if echo "$schema_out" | grep -qiE "Invalid input"; then
            _fail_msg "失败"
            ((issues++))
            echo ""
            echo "$schema_out" | grep -iE "×|invalid|allowed" | head -5 | sed 's/^/    /'
            confirm "  自动清理?" && { sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        else
            _pass "通过"
        fi
    else
        echo -e "${DIM}跳过${NC}"
    fi

    _chk "7/10" "Docker URL 兼容"
    if is_docker_mode && [[ -f "$cfg" ]] && json_is_valid && has_cmd python3; then
        local lan_urls
        lan_urls=$(python3 -c "
import json, re
try:
    c = json.load(open('$cfg'))
    p = re.compile(r'^https?://(127\.|localhost|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)')
    bad = []
    for name, pcfg in c.get('models', {}).get('providers', {}).items():
        url = pcfg.get('baseUrl', '') if isinstance(pcfg, dict) else ''
        if p.match(url):
            bad.append(name)
    print(','.join(bad))
except: print('')
" 2>/dev/null || echo "")
        if [[ -z "$lan_urls" ]]; then
            _pass "无需转换"
        else
            _fail_msg "局域网 URL: $lan_urls (容器无法访问)"
            ((issues++))
            confirm "  转换为 host.docker.internal?" && { convert_urls_for_docker_mode | sed 's/^/    /'; ((fixed++)); }
        fi
    else
        echo -e "${DIM}跳过${NC}"
    fi

    _chk "8/10" "Agent 认证"
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
            _pass "存在"
        else
            _fail_msg "缺失"
            ((issues++))
            confirm "  修复 (菜单[23])?" && { fix_agent_auth_menu; ((fixed++)); }
        fi
    else
        echo -e "${DIM}跳过${NC}"
    fi

    _chk "9/10" "Gateway 端口"
    if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
        _pass "响应"
    else
        echo -e "${YELLOW}${WARN} 无响应${NC}"
        ((issues++))
        confirm "  启动?" && { manage_service start >/dev/null; ((fixed++)); }
    fi

    _chk "10/10" "磁盘"
    local da
    da=$(df "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999999")
    [[ "$da" -gt 1048576 ]] && _pass "$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')" || { _fail_msg "不足"; ((issues++)); }

    if is_openclaw_installed; then
        echo ""
        msg_step "openclaw doctor --fix..."
        openclaw_cmd doctor --fix 2>&1 | tail -15 | sed 's/^/    /' || true
    fi

    echo ""
    print_line
    echo -e "${BOLD}结果:${NC}  问题 ${RED}${issues}${NC}  修复 ${GREEN}${fixed}${NC}"
    print_line

    wait_and_return 3
    return 0
}

view_logs() {
    msg_title "📋 日志"
    echo "  1) 实时 Gateway  2) systemd  3) 文件  4) Docker  5) 脚本  6) gateway.out  0) 返回"
    echo ""
    echo -ne "${BOLD}选择: ${NC}"
    local lc
    read_input lc "0"

    case "$lc" in
        1)
            trap 'echo ""; msg_info "退出"' INT
            if is_docker_mode; then
                docker logs -f "$DOCKER_CONTAINER" 2>&1 || true
            else
                openclaw_cmd gateway logs --follow 2>/dev/null \
                    || openclaw_cmd logs 2>/dev/null \
                    || tail -f "${OPENCLAW_LOG_DIR}/gateway.log" 2>/dev/null \
                    || msg_fail "无法获取"
            fi
            trap - INT ;;
        2)
            detect_system
            if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
                local svc
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    sudo journalctl -u "$svc" -n 100 --no-pager 2>/dev/null && break
                done
            fi ;;
        3)
            local log_dir="$OPENCLAW_LOG_DIR"
            is_docker_mode && log_dir="${DOCKER_DATA_DIR}/.openclaw/logs"
            if [[ -d "$log_dir" ]]; then
                ls -lh "$log_dir" 2>/dev/null
                echo -ne "${BOLD}文件名 (Enter最新): ${NC}"
                local lf; read_input lf ""
                if [[ -n "$lf" ]]; then
                    less "${log_dir}/${lf}" 2>/dev/null
                else
                    local ll
                    ll=$(ls -t "${log_dir}"/*.log 2>/dev/null | head -1 || echo "")
                    [[ -n "$ll" ]] && less "$ll" || msg_warn "无日志"
                fi
            fi ;;
        4)
            if docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
                trap 'echo ""; msg_info "退出"' INT
                docker logs -f "$DOCKER_CONTAINER" 2>&1 || true
                trap - INT
            fi ;;
        5)
            [[ -f "$LOG_FILE" ]] && less "$LOG_FILE" || msg_warn "不存在" ;;
        6)
            [[ -f "$OPENCLAW_LOG_DIR/gateway.out" ]] && less "$OPENCLAW_LOG_DIR/gateway.out" || msg_warn "不存在" ;;
        0) return 0 ;;
    esac
    wait_and_return 2
    return 0
}

uninstall_openclaw() {
    msg_title "${TRASH} 卸载"
    echo -e "${RED}${BOLD}⚠️  卸载 OpenClaw${NC}"
    echo ""
    confirm "确认?" || { wait_and_return 2; return 0; }
    detect_system

    docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER" && {
        docker stop "$DOCKER_CONTAINER" 2>/dev/null || true
        confirm "删除容器?" && docker rm -f "$DOCKER_CONTAINER" 2>/dev/null
        confirm "删除镜像?" && {
            docker rmi "${DOCKER_IMAGE}:latest" 2>/dev/null || true
            docker rmi "${DOCKER_IMAGE_MIRROR}:latest" 2>/dev/null || true
        }
        confirm "删除数据目录 (${DOCKER_DATA_DIR})?" && rm -rf "$DOCKER_DATA_DIR"
    }

    if has_cmd openclaw; then
        pkill -9 -f openclaw 2>/dev/null || true
        service_action stop 2>/dev/null || true
        case "$SERVICE_MANAGER" in
            systemd)
                local svc
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    sudo systemctl disable "$svc" 2>/dev/null || true
                    systemctl --user disable "$svc" 2>/dev/null || true
                    sudo rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
                done
                sudo systemctl daemon-reload 2>/dev/null || true ;;
            launchd)
                _try_launchd stop 2>/dev/null || true
                rm -f "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist" 2>/dev/null || true ;;
            openrc)
                local svc
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    sudo rc-update del "$svc" 2>/dev/null || true
                done ;;
        esac
        npm uninstall -g openclaw >> "$LOG_FILE" 2>&1 || {
            local np; np=$(npm prefix -g 2>/dev/null || echo "/usr/local")
            sudo rm -f "${np}/bin/openclaw" 2>/dev/null || true
            sudo rm -rf "${np}/lib/node_modules/openclaw" 2>/dev/null || true
        }
    fi

    echo ""
    confirm "删除配置目录 ($OPENCLAW_CONFIG_DIR)?" && {
        rm -rf "$OPENCLAW_CONFIG_DIR"
        G_API_KEYS=()
        G_API_MODELS=()
        G_API_TYPES=()
        G_API_URLS=()
        G_DEFAULT_PROVIDER=""
    }

    msg_ok "已卸载"
    wait_and_return 3
    return 0
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
    echo -e "        ${DIM}${SCRIPT_VERSION} | Docker+局域网+Agent 一键部署${NC}"
    echo ""

    detect_system
    load_config_from_file 2>/dev/null || true

    local sc="${RED}" st="未安装"
    if is_openclaw_installed; then
        curl -s --max-time 2 --connect-timeout 1 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null \
            && { sc="${GREEN}"; st="运行中 ●"; } \
            || { sc="${YELLOW}"; st="未运行"; }
    fi

    local cfg_status="${DIM}未创建${NC}"
    local cfg
    cfg=$(get_active_config_path)
    if [[ -f "$cfg" ]]; then
        json_is_valid && cfg_status="${GREEN}有效${NC}" || cfg_status="${RED}${BOLD}损坏!${NC}"
    fi

    local bind_v=""
    if json_is_valid && has_cmd python3; then
        bind_v=$(python3 -c "
import json
try:
    c=json.load(open('$cfg'))
    print(c.get('gateway',{}).get('bind',''))
except: pass
" 2>/dev/null || echo "")
    fi

    local mode_label="npm"
    is_docker_mode && mode_label="${CYAN}Docker${NC}"

    local mi=""
    if [[ -n "${G_DEFAULT_PROVIDER:-}" ]]; then
        local dm="${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
        dm="${dm%%,*}"
        [[ -n "$dm" ]] && mi="  ${DIM}|${NC} ${CYAN}${G_DEFAULT_PROVIDER}${NC}"
    fi

    echo -e "  ${DIM}系统:${NC} ${OS^^}  ${DIM}|${NC}  ${DIM}GW:${NC} ${sc}${st}${NC}  ${DIM}|${NC}  ${DIM}模式:${NC} ${mode_label}  ${DIM}|${NC}  ${DIM}配置:${NC} ${cfg_status}  ${DIM}|${NC}  ${DIM}bind:${NC} ${bind_v:-?}${mi}"
    print_line
}

main_menu() {
    while true; do
        show_banner
        echo -e "${WHITE}${BOLD}  主菜单${NC}"
        echo ""
        echo -e "${BOLD}  ── 安装 ──${NC}"
        echo -e "  ${BOLD}${GREEN}[1]${NC}  ${ROCKET} 本地安装 / 重装"
        echo -e "  ${BOLD}${GREEN}[2]${NC}  ${DOCKER} Docker 部署"
        echo ""
        echo -e "${BOLD}  ── 配置 ──${NC}"
        echo -e "  ${BOLD}${CYAN}[3]${NC}  🔑 内置 Provider API 密钥"
        echo -e "  ${BOLD}${CYAN}[4]${NC}  🔧 自定义 API ${GREEN}(一键部署)${NC}"
        echo -e "  ${BOLD}${CYAN}[5]${NC}  ${LOBSTER} 局域网 UI 访问"
        echo -e "  ${BOLD}${CYAN}[6]${NC}  ${PLUGIN} 安装插件"
        echo ""
        echo -e "${BOLD}  ── 服务 ──${NC}"
        echo -e "  ${BOLD}${YELLOW}[7]${NC}  ${POWER} 启动    ${BOLD}${YELLOW}[8]${NC} 🔄 重启    ${BOLD}${YELLOW}[9]${NC} ⏹  停止    ${BOLD}${YELLOW}[10]${NC} 📈 状态"
        echo ""
        echo -e "${BOLD}  ── 工具 ──${NC}"
        echo -e "  ${BOLD}${MAGENTA}[11]${NC} ${KEY} 网关令牌管理"
        echo -e "  ${BOLD}${MAGENTA}[12]${NC} 📊 控制面板 URL"
        echo -e "  ${BOLD}${MAGENTA}[13]${NC} 📦 版本 / 升级"
        echo -e "  ${BOLD}${MAGENTA}[14]${NC} 📋 日志"
        echo -e "  ${BOLD}${MAGENTA}[15]${NC} ${GEAR} 快捷命令"
        echo -e "  ${BOLD}${MAGENTA}[16]${NC} 🛠️  修复损坏配置"
        echo -e "  ${BOLD}${MAGENTA}[17]${NC} ✅ 验证配置"
        echo -e "  ${BOLD}${MAGENTA}[18]${NC} ${DOCTOR} 诊断修复"
        echo -e "  ${BOLD}${MAGENTA}[19]${NC} 📖 命令速查"
        echo -e "  ${BOLD}${MAGENTA}[20]${NC} ℹ️  系统信息"
        echo -e "  ${BOLD}${GREEN}[21]${NC} 🔧 setup 向导"
        echo -e "  ${BOLD}${RED}[22]${NC} ${TRASH} 卸载"
        echo -e "  ${BOLD}${YELLOW}[23]${NC} ${LINK} 修复 Agent 认证"
        echo -e "  ${BOLD}${YELLOW}[24]${NC} 🧹 清理不兼容字段"
        echo -e "  ${BOLD}${YELLOW}[25]${NC} 🌐 转换 URL (Docker兼容)"
        echo -e "  ${BOLD}[0]${NC}  🚪 退出"
        echo ""
        print_line
        echo -ne "  ${BOLD}请输入: ${NC}"
        local choice
        read_input choice ""

        case "$choice" in
            1)  install_openclaw ;;
            2)  deploy_docker ;;
            3)  configure_api_keys; wait_and_return 2 ;;
            4)  configure_custom_api; wait_and_return 2 ;;
            5)  configure_lan_access ;;
            6)  install_plugins ;;
            7)  manage_service start ;;
            8)  manage_service restart ;;
            9)  manage_service stop ;;
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
            22) uninstall_openclaw ;;
            23) fix_agent_auth_menu ;;
            24) sanitize_config_for_schema | sed 's/^/  /'; msg_ok "已清理"; wait_and_return 3 ;;
            25)
                if is_docker_mode; then
                    convert_urls_for_docker_mode | sed 's/^/  /'
                    msg_ok "已转换,请重启 Gateway"
                    confirm "立即重启?" && manage_service restart >/dev/null 2>&1
                else
                    msg_warn "非 Docker 模式,无需转换"
                fi
                wait_and_return 3 ;;
            0)  echo ""; echo -e "${GREEN}${BOLD}再见!👋${NC}"; echo ""; exit 0 ;;
            *)  msg_warn "无效: ${choice}"; sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    install)    detect_system; install_openclaw ;;
    docker)     detect_system; deploy_docker ;;
    lan)        detect_system; configure_lan_access ;;
    plugins)    install_plugins ;;
    setup)      detect_system; run_setup_wizard ;;
    start)      detect_system; manage_service start ;;
    stop)       detect_system; manage_service stop ;;
    restart)    detect_system; manage_service restart ;;
    status)     detect_system; manage_service status ;;
    version)    show_version ;;
    diagnose)   detect_system; diagnose_and_fix ;;
    uninstall)  detect_system; uninstall_openclaw ;;
    url)        load_config_from_file; show_dashboard_info ;;
    config)     detect_system; configure_api_keys ;;
    custom)     detect_system; configure_custom_api ;;
    validate)   validate_config ;;
    repair)     repair_broken_config ;;
    token)      show_token_manager ;;
    sanitize)   sanitize_config_for_schema ;;
    convert-urls) convert_urls_for_docker_mode ;;
    fix-agent|agent-auth) detect_system; fix_agent_auth_menu ;;
    ref|help)   show_command_reference ;;
    cmds)       detect_system; quick_commands ;;
    *)          main_menu ;;
esac
