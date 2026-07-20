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
SCRIPT_VERSION="v1.0.6"
NODE_MIN_VERSION=22
NODE_RECOMMENDED_VERSION=24
LOG_FILE="/tmp/openclaw_install_$(date +%Y%m%d_%H%M%S).log"

GITHUB_REPO="https://github.com/anthropics/anthropic-quickstarts"
OPENCLAW_INSTALL_URL="https://openclaw.ai/install.sh"

DOCKER_IMAGE="ghcr.io/anthropics/anthropic-quickstarts"
DOCKER_IMAGE_MIRROR="anthropic/quickstarts"
DOCKER_CONTAINER="openclaw-core"
DOCKER_DATA_DIR="$HOME/openclaw"
DOCKER_UID=1000

WECHAT_PLUGIN_PKG="@anthropic/claude-code-weixin"
FEISHU_PLUGIN_PKG="@anthropic/claude-code-feishu"

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
    changed.append(f"gateway.bind: invalid -> loopback")

if not gw.get("mode"):
    gw["mode"] = "local"
    changed.append("gateway.mode -> local")

for bad_key in BAD_ROOT_KEYS:
    if bad_key in cfg:
        del cfg[bad_key]
        changed.append(f"removed {bad_key}")

if "agents" in cfg and isinstance(cfg["agents"], dict):
    defaults = cfg["agents"].get("defaults", {})
    if isinstance(defaults, dict):
        if "model" in defaults:
            del defaults["model"]
            changed.append("removed agents.defaults.model")
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
            changed.append(f"providers.{name}: LAN URL -> host.docker.internal")

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
    ver=$(curl -s --max-time 8 \
        "https://api.github.com/repos/nvm-sh/nvm/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | grep -o 'v[0-9.]*')
    [[ -z "$ver" ]] && ver=$(curl -s --max-time 8 \
        "https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/README.md" 2>/dev/null \
        | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
    _NVM_LATEST="${ver:-v0.40.1}"
    echo "$_NVM_LATEST"
}

get_node_lts_versions() {
    [[ -n "$_NODE_LTS_VERSIONS" ]] && { echo "$_NODE_LTS_VERSIONS"; return; }
    local v
    v=$(curl -s --max-time 8 "https://nodejs.org/dist/index.json" 2>/dev/null \
        | grep -o '"version":"v[0-9]*\.[0-9]*\.[0-9]*","[^}]*"lts":"[^f][^"]*"' \
        | grep -o '"version":"v[0-9]*' | grep -o '[0-9]*$' \
        | sort -rn | awk '!seen[$0]++' | head -5 | tr '\n' ' ')
    _NODE_LTS_VERSIONS="${v:-24 22 20}"
    echo "$_NODE_LTS_VERSIONS"
}

get_node_latest_major() {
    [[ -n "$_NODE_LATEST_VERSION" ]] && { echo "$_NODE_LATEST_VERSION"; return; }
    local v
    v=$(curl -s --max-time 8 "https://nodejs.org/dist/index.json" 2>/dev/null \
        | grep -o '"version":"v[0-9]*' | head -1 | grep -o '[0-9]*$')
    _NODE_LATEST_VERSION="${v:-$NODE_RECOMMENDED_VERSION}"
    echo "$_NODE_LATEST_VERSION"
}

get_openclaw_latest_version() {
    curl -s --max-time 8 "https://registry.npmjs.org/openclaw/latest" 2>/dev/null \
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
        x86_64|amd64)   ARCH_LABEL="x86_64 (64-bit)"   ;;
        aarch64|arm64)  ARCH_LABEL="ARM64 (64-bit)"    ;;
        armv7l|armv6l)  ARCH_LABEL="ARMv7/v6 (32-bit)" ;;
        i386|i686)      ARCH_LABEL="x86 (32-bit)"      ;;
        *)              ARCH_LABEL="$ARCH"             ;;
    esac
}

print_sysinfo() {
    detect_system
    echo -e "${CYAN}${BOLD}System Info${NC}"
    print_line
    echo -e "  ${BOLD}OS${NC}          : $(echo "${OS}" | tr '[:lower:]' '[:upper:]') (${PRETTY_NAME})"
    echo -e "  ${BOLD}Arch${NC}        : ${ARCH_LABEL}"
    echo -e "  ${BOLD}Package Mgr${NC} : ${PKG_MANAGER}"
    echo -e "  ${BOLD}Service Mgr${NC} : ${SERVICE_MANAGER}"
    echo -e "  ${BOLD}Hostname${NC}    : $(hostname)"
    echo -e "  ${BOLD}Memory${NC}      : $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' \
                             || sysctl hw.memsize 2>/dev/null | awk '{printf "%.1fGB",$2/1073741824}' \
                             || echo 'N/A')"
    echo -e "  ${BOLD}CPU${NC}         : $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?') cores"
    echo -e "  ${BOLD}Disk Free${NC}   : $(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo 'N/A')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo 'Not installed')"
    echo -e "  ${BOLD}npm${NC}         : $(npm -v 2>/dev/null | sed 's/^/v/' || echo 'Not installed')"
    echo -e "  ${BOLD}Docker${NC}      : $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo 'Not installed')"
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw_cmd --version 2>/dev/null || echo 'Not installed')"
    echo -e "  ${BOLD}Deploy Mode${NC} : $(_detect_deploy_mode)"
    echo -e "  ${BOLD}Config Path${NC} : $(get_active_config_path)"
    local cfg_path
    cfg_path=$(get_active_config_path)
    echo -e "  ${BOLD}Config${NC}      : $([[ -f "$cfg_path" ]] && (json_is_valid "$cfg_path" && echo "${GREEN}Valid${NC}" || echo "${RED}Corrupted${NC}") || echo 'Not created')"
    if [[ -n "${G_DEFAULT_PROVIDER:-}" ]]; then
        echo -e "  ${BOLD}Default AI${NC}  : ${GREEN}${G_DEFAULT_PROVIDER}${NC}"
    fi
    print_line
}

_detect_deploy_mode() {
    if is_docker_mode; then
        echo "Docker Container"
    elif has_cmd openclaw; then
        echo "Local Install (npm)"
    else
        echo "Not Deployed"
    fi
}

repair_broken_config() {
    msg_title "Repair Config"

    local cfg
    cfg=$(get_active_config_path)

    if [[ ! -f "$cfg" ]]; then
        msg_info "Config does not exist, creating minimal config"
        _create_minimal_config
        wait_and_return 2
        return 0
    fi

    if json_is_valid; then
        msg_ok "JSON is valid"
        echo ""
        msg_step "Running schema cleanup..."
        local result
        result=$(sanitize_config_for_schema 2>&1)
        if [[ "$result" == "NOCHANGE" ]]; then
            msg_ok "No changes needed"
        else
            echo "$result" | sed 's/^/  /'
            msg_ok "Cleaned up"
        fi
        wait_and_return 3
        return 0
    fi

    msg_fail "JSON format is corrupted"
    echo -e "${CYAN}File:${NC} $cfg"
    echo ""

    if has_cmd python3; then
        local err
        err=$(python3 -c "import json; json.load(open('$cfg'))" 2>&1 | tail -1)
        echo -e "${YELLOW}Error:${NC} $err"
        echo ""
    fi

    echo -e "${BOLD}Options:${NC}"
    echo -e "  ${BOLD}1)${NC} Backup and rebuild ${GREEN}(recommended)${NC}"
    echo -e "  ${BOLD}2)${NC} Manual edit"
    echo -e "  ${BOLD}3)${NC} Smart repair"
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    echo -ne "${BOLD}Choose: ${NC}"
    local rc
    read -r rc </dev/tty || rc="0"

    case "$rc" in
        1)
            local backup
            backup=$(backup_config)
            [[ -n "$backup" ]] && msg_ok "Backed up: $backup"
            _create_minimal_config
            msg_ok "Rebuilt"
            ;;
        2)
            local backup
            backup=$(backup_config)
            [[ -n "$backup" ]] && msg_ok "Backed up: $backup"
            local editor="${EDITOR:-nano}"
            has_cmd "$editor" || editor="vi"
            $editor "$cfg" </dev/tty
            if json_is_valid; then
                msg_ok "Repair successful"
                sanitize_config_for_schema
            else
                msg_fail "Still invalid"
            fi
            ;;
        3) _smart_repair_config ;;
        0) msg_info "Cancelled" ;;
        *) msg_warn "Invalid choice" ;;
    esac

    wait_and_return 3
    return 0
}

_smart_repair_config() {
    if ! has_cmd python3; then
        msg_fail "Requires python3"
        return 1
    fi

    local cfg
    cfg=$(get_active_config_path)
    local backup
    backup=$(backup_config)
    [[ -n "$backup" ]] && msg_ok "Backed up: $backup"

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
        msg_ok "Completed"
    else
        msg_fail "Still invalid"
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
    msg_title "${KEY} Gateway Token Manager"

    if ! json_is_valid; then
        msg_fail "Config invalid, please repair with menu [16]"
        wait_and_return 3
        return 0
    fi

    local token local_ip
    token=$(get_gateway_token)
    local_ip=$(get_local_ip)

    echo -e "${CYAN}${BOLD}Token Status${NC}"
    print_line
    if [[ -n "$token" ]]; then
        echo -e "  ${BOLD}Status:${NC}  ${GREEN}Set${NC}"
        echo -e "  ${BOLD}Token:${NC}   ${YELLOW}${token}${NC}"
        echo ""
        echo -e "  ${BOLD}Access URL:${NC}"
        echo -e "  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}?token=${token}${NC}"
    else
        echo -e "  ${BOLD}Status:${NC}  ${DIM}Not set${NC}"
        echo -e "  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${NC}"
    fi
    print_line
    echo ""

    echo -e "  ${BOLD}1)${NC} View token"
    echo -e "  ${BOLD}2)${NC} Generate new token"
    echo -e "  ${BOLD}3)${NC} Set manually"
    echo -e "  ${BOLD}4)${NC} Remove token"
    echo -e "  ${BOLD}5)${NC} dashboard --no-open"
    echo -e "  ${BOLD}0)${NC} Return"
    echo ""
    echo -ne "${BOLD}Choose: ${NC}"
    local tc
    read -r tc </dev/tty || tc="0"

    case "$tc" in
        1) [[ -n "$token" ]] && echo -e "\n${YELLOW}${token}${NC}" || msg_warn "Not set" ;;
        2)
            local new_token
            new_token=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null | tr -d '\n' || echo "$(date +%s%N)")
            _set_gateway_token "$new_token"
            ;;
        3)
            echo -ne "\n${BOLD}Token (min 16 chars): ${NC}"
            local ct; read -r ct </dev/tty || ct=""
            [[ ${#ct} -lt 16 ]] && msg_fail "Too short" || _set_gateway_token "$ct"
            ;;
        4) confirm "Confirm delete?" && _remove_gateway_token ;;
        5) is_openclaw_installed && openclaw_cmd dashboard --no-open 2>&1 | tail -20 || msg_fail "Not installed" ;;
        0) return 0 ;;
        *) msg_warn "Invalid" ;;
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
        msg_ok "Token updated"
        echo -e "\n${GREEN}${BOLD}New Token:${NC} ${YELLOW}${new_token}${NC}"
        confirm "Restart Gateway?" && manage_service restart >/dev/null 2>&1
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
        msg_ok "Token removed"
    fi
}

sync_agent_auth() {
    local provider_name="$1"
    local base_url="$2"
    local api_key="$3"
    local api_type="$4"
    local agent_name="${5:-main}"

    msg_step "Syncing auth to Agent [${agent_name}] provider=${provider_name}..."

    if ! is_openclaw_installed; then
        msg_warn "Not installed, skipping"
        return 1
    fi

    local success=false

    if _write_agent_auth_file "$agent_name" "$provider_name" "$base_url" "$api_key" "$api_type"; then
        success=true
    fi

    if $success; then
        msg_ok "Agent [${agent_name}] <- ${provider_name}"
        return 0
    else
        msg_warn "Injection failed (${provider_name})"
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
    msg_title "${LINK} Fix Agent Auth"

    if ! is_openclaw_installed; then
        msg_fail "Not installed"
        wait_and_return 2
        return 0
    fi

    if ! json_is_valid; then
        msg_fail "Config corrupted, please repair first"
        wait_and_return 3
        return 0
    fi

    load_config_from_file

    if [[ ${#G_API_URLS[@]} -eq 0 && ${#G_API_KEYS[@]} -eq 0 ]]; then
        msg_fail "No Provider configured"
        wait_and_return 3
        return 0
    fi

    echo -e "${CYAN}Current Agents:${NC}"
    openclaw_cmd agents list 2>&1 | head -15 | sed 's/^/  /' || echo "  (cannot list)"
    echo ""

    echo -ne "${BOLD}Agent name (default: main): ${NC}"
    local agent_name
    read -r agent_name </dev/tty || agent_name="main"
    agent_name=${agent_name:-main}

    echo ""
    echo -e "${CYAN}Will sync:${NC}"
    for p in "${!G_API_URLS[@]}"; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        echo -e "  * ${BOLD}$p${NC} -> ${DIM}${G_API_URLS[$p]}${NC}"
    done
    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        echo -e "  * ${BOLD}$p${NC} ${DIM}(builtin)${NC}"
    done
    echo ""

    local inject_openai_alias=false
    if [[ ${#G_API_URLS[@]} -gt 0 ]] && [[ -z "${G_API_KEYS[openai]:-}" ]]; then
        echo -e "${YELLOW}Detected custom Provider but no openai${NC}"
        confirm "Inject as openai alias (recommended)?" && inject_openai_alias=true
        echo ""
    fi

    confirm "Confirm?" || { wait_and_return 2; return 0; }

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
    msg_step "Restarting Gateway..."
    manage_service restart >/dev/null 2>&1
    sleep 3

    echo ""
    print_line
    echo -e "${BOLD}Result:${NC}  Success ${GREEN}${ok}${NC}  Failed ${RED}${fail}${NC}"
    print_line

    echo -e "\n${YELLOW}Browser Ctrl+Shift+R to hard refresh${NC}"

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
        code=$(curl -s -o /dev/null --max-time 2 -w "%{http_code}" "$url" 2>/dev/null || echo "000")
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
    msg_info "Setting default model: $full_model"

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
            msg_ok "Default model persisted"
            return 0
        fi
    fi

    msg_warn "Cannot persist default model, please select in UI"
    return 1
}

configure_custom_api() {
    msg_title "Custom API One-Click Deploy"

    local cfg
    cfg=$(get_active_config_path)

    if [[ -f "$cfg" ]] && ! json_is_valid; then
        msg_fail "Config corrupted, please repair with menu [16]"
        wait_and_return 3
        return 1
    fi

    local docker_mode=false
    is_docker_mode && docker_mode=true

    echo -e "${CYAN}${BOLD}Config + Agent Auth + Gateway Start${NC}"
    if $docker_mode; then
        echo -e "${YELLOW}Detected Docker deploy mode${NC}"
        echo -e "${DIM}   LAN IP will auto-convert to host.docker.internal${NC}"
    fi
    echo ""

    echo -ne "${CYAN}Provider name (recommend: openai / new-api / ollama): ${NC}"
    local provider_name
    read -r provider_name </dev/tty || provider_name=""
    provider_name=${provider_name:-openai}
    provider_name=$(echo "$provider_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    echo ""
    echo -e "${YELLOW}OpenAI compatible API recommended name: openai${NC}"
    echo ""

    echo -e "${DIM}URL examples:${NC}"
    echo -e "  ${DIM}* http://192.168.x.x:xxxx${NC}"
    echo -e "  ${DIM}* https://api.deepseek.com/v1${NC}"
    echo -e "  ${DIM}* http://127.0.0.1:11434${NC}"
    echo ""
    echo -ne "${CYAN}API Base URL: ${NC}"
    local base_url
    read -r base_url </dev/tty || base_url=""

    [[ -z "$base_url" ]] && { msg_warn "URL cannot be empty"; return 1; }

    local final_url="$base_url"
    if $docker_mode && is_lan_url "$base_url"; then
        local converted
        converted=$(convert_url_for_docker "$base_url")
        if [[ "$converted" != "$base_url" ]]; then
            echo ""
            msg_warn "Docker mode detected LAN URL"
            echo -e "  ${DIM}Original:${NC} $base_url"
            echo -e "  ${DIM}Converted:${NC} ${GREEN}$converted${NC}"
            echo ""
            if confirm "Use converted URL?"; then
                final_url="$converted"
            fi
        fi
    fi

    echo ""
    echo -ne "${CYAN}API Key (enter 'local' for local service): ${NC}"
    local api_key
    read -rs api_key </dev/tty || api_key=""
    echo ""
    api_key=${api_key:-local}

    echo ""
    echo -e "${CYAN}${BOLD}API Type:${NC}"
    echo -e "  ${BOLD}1)${NC} openai-completions"
    echo -e "  ${BOLD}2)${NC} openai-responses"
    echo -e "  ${BOLD}3)${NC} ollama"
    echo -e "  ${BOLD}4)${NC} anthropic-messages"
    echo ""
    echo -ne "${CYAN}Choose [1-4] (default: 1): ${NC}"
    local api_choice
    read -r api_choice </dev/tty || api_choice="1"

    local api_type
    case "$api_choice" in
        2) api_type="openai-responses" ;;
        3) api_type="ollama" ;;
        4) api_type="anthropic-messages" ;;
        *) api_type="openai-completions" ;;
    esac

    echo ""
    echo -ne "${CYAN}Model ID (comma separated for multiple): ${NC}"
    local model_ids
    read -r model_ids </dev/tty || model_ids=""

    [[ -z "$model_ids" ]] && { msg_warn "Model ID cannot be empty"; return 1; }

    echo ""
    local default_model
    if [[ "$model_ids" == *","* ]]; then
        echo -e "${CYAN}Multiple models, select default:${NC}"
        local i=1
        declare -a m_arr=()
        IFS=',' read -ra m_arr <<< "$model_ids"
        for m in "${m_arr[@]}"; do
            m=$(echo "$m" | xargs)
            echo "  ${i}) $m"
            ((i++))
        done
        echo ""
        echo -ne "${CYAN}Choose [1-$((i-1))] (default: 1): ${NC}"
        local dc
        read -r dc </dev/tty || dc="1"
        [[ "$dc" =~ ^[0-9]+$ ]] && (( dc >= 1 && dc <= ${#m_arr[@]} )) || dc=1
        default_model=$(echo "${m_arr[$((dc-1))]}" | xargs)
    else
        default_model=$(echo "$model_ids" | xargs)
    fi

    local inject_openai_alias=false
    if [[ "$provider_name" != "openai" ]]; then
        echo ""
        confirm "Also inject as openai alias (strongly recommended)?" && inject_openai_alias=true
    fi

    G_API_URLS["$provider_name"]="$final_url"
    G_API_KEYS["$provider_name"]="$api_key"
    G_API_TYPES["$provider_name"]="$api_type"
    G_API_MODELS["$provider_name"]="$model_ids"
    G_DEFAULT_PROVIDER="$provider_name"

    echo ""
    print_line
    echo -e "${GREEN}${BOLD}Starting one-click deploy...${NC}"
    print_line

    echo ""
    msg_step "Step 1/6: Writing config..."
    _write_custom_provider_config "$provider_name" "$default_model"

    echo ""
    msg_step "Step 2/6: Syncing auth to main Agent..."
    sync_agent_auth "$provider_name" "$final_url" "$api_key" "$api_type" "main" || true

    if $inject_openai_alias; then
        echo ""
        msg_step "Step 3/6: Injecting openai alias..."
        sync_agent_auth "openai" "$final_url" "$api_key" "$api_type" "main" || true
    fi

    echo ""
    msg_step "Step 4/6: Schema cleanup..."
    sanitize_config_for_schema | sed 's/^/  /'

    echo ""
    msg_step "Step 5/6: Persisting default model..."
    _persist_default_agent_model "$provider_name" "$default_model"

    echo ""
    msg_step "Step 6/6: Restarting Gateway..."
    manage_service restart >/dev/null 2>&1 || true

    echo -ne "  Waiting for ready"
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
        msg_ok "Gateway started and accessible"
    else
        msg_warn "Health check failed"
        echo ""
        echo -e "${CYAN}Log tail:${NC}"
        if $docker_mode; then
            docker logs --tail 15 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
        else
            tail -15 "$OPENCLAW_LOG_DIR/gateway.out" 2>/dev/null | sed 's/^/  /'
        fi
        echo ""
        if docker logs --tail 30 "$DOCKER_CONTAINER" 2>&1 | grep -qE "\[gateway\] ready|http server listening" 2>/dev/null; then
            msg_ok "Log shows Gateway ready - may be firewall issue, try browser access"
        fi
    fi

    echo ""
    echo -e "${GREEN}${BOLD}One-Click Deploy Complete!${NC}"
    echo ""
    echo -e "  ${BOLD}Provider:${NC}  ${CYAN}${provider_name}${NC}"
    echo -e "  ${BOLD}Base URL:${NC}  ${final_url}"
    echo -e "  ${BOLD}API Type:${NC}  ${CYAN}${api_type}${NC}"
    echo -e "  ${BOLD}Default Model:${NC}  ${GREEN}${provider_name}/${default_model}${NC}"
    $inject_openai_alias && echo -e "  ${BOLD}openai alias:${NC} ${GREEN}Injected${NC}"
    $docker_mode && [[ "$final_url" != "$base_url" ]] && echo -e "  ${BOLD}URL Converted:${NC}  ${GREEN}Yes${NC}"
    echo ""

    show_dashboard_info

    echo ""
    echo -e "${YELLOW}${BOLD}Usage:${NC}"
    echo -e "  1. Open Dashboard URL"
    echo -e "  2. Hard refresh: ${BOLD}Ctrl+Shift+R${NC}"
    echo -e "  3. Select model: ${CYAN}${provider_name}/${default_model}${NC}"
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
        msg_ok "Config written"
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
    atomic_write_json "$cfg" "$content" && msg_ok "Config created" || msg_fail "Failed"
}

validate_config() {
    local cfg
    cfg=$(get_active_config_path)

    msg_step "Validating config..."

    if [[ ! -f "$cfg" ]]; then
        msg_fail "Config does not exist"
        return 1
    fi

    if ! json_is_valid; then
        msg_fail "JSON invalid, please repair with menu [16]"
        return 1
    fi

    if is_openclaw_installed; then
        local out
        out=$(openclaw_cmd config validate 2>&1)
        if echo "$out" | grep -qiE "Invalid input|invalid config"; then
            msg_fail "Schema validation failed:"
            echo "$out" | grep -iE "×|invalid|allowed" | head -10 | sed 's/^/  /'
            echo ""
            if confirm "Auto cleanup incompatible fields?"; then
                sanitize_config_for_schema | sed 's/^/  /'
                echo ""
                msg_info "Re-validating..."
                out=$(openclaw_cmd config validate 2>&1)
                if echo "$out" | grep -qiE "Invalid input"; then
                    msg_fail "Still failed:"
                    echo "$out" | head -20 | sed 's/^/  /'
                    return 1
                else
                    msg_ok "Passed"
                    return 0
                fi
            fi
            return 1
        else
            msg_ok "openclaw config validate passed"
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
        msg_warn "Config corrupted, backup and rebuild"
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
    atomic_write_json "$cfg" "$content" && msg_ok "Minimal config created" || msg_fail "Failed"
}

configure_lan_access() {
    msg_title "${LOBSTER} LAN UI Access"

    if ! is_openclaw_installed; then
        msg_fail "OpenClaw not installed"
        wait_and_return 2; return 0
    fi

    if ! json_is_valid; then
        msg_fail "Config corrupted, please repair with menu [16]"
        wait_and_return 3
        return 0
    fi

    local cfg
    cfg=$(get_active_config_path)

    echo -e "${CYAN}Config file:${NC} ${DIM}${cfg}${NC}"
    echo ""

    echo -e "${CYAN}Current gateway config:${NC}"
    if [[ -f "$cfg" ]] && has_cmd python3; then
        python3 - "$cfg" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    gw = cfg.get("gateway", {})
    print(f"  bind       : {gw.get('bind', 'not set')}")
    print(f"  mode       : {gw.get('mode', 'not set')}")
    auth = gw.get("auth", {})
    print(f"  auth.mode  : {auth.get('mode', 'not set')}")
    print(f"  auth.token : {'set' if auth.get('token') else 'not set'}")
    ui = gw.get("controlUi", {})
    print(f"  controlUi  : {json.dumps(ui, ensure_ascii=False)}")
except Exception as e:
    print(f"  Read failed: {e}")
PYEOF
    fi

    echo ""
    print_line
    echo -e "${BOLD}Changes to apply:${NC}"
    echo -e "  ${CYAN}gateway.bind${NC} -> ${GREEN}\"lan\"${NC}  ${DIM}(LAN listen)${NC}"
    echo -e "  ${CYAN}gateway.auth.token${NC} -> ${GREEN}auto-generate${NC}"
    echo -e "  ${CYAN}gateway.controlUi.*${NC} -> ${GREEN}relaxed auth${NC}"
    echo ""
    echo -e "${RED}${WARN} Do not expose port to public internet!${NC}"
    echo ""

    confirm "Confirm?" || { msg_info "Cancelled"; wait_and_return 2; return 0; }

    local backup
    backup=$(backup_config)
    [[ -n "$backup" ]] && msg_ok "Backed up: $backup"

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
            msg_ok "LAN config written"
        else
            msg_fail "Write failed"
            wait_and_return 2; return 0
        fi
    fi

    echo ""
    msg_step "Validating..."
    local vout
    vout=$(openclaw_cmd config validate 2>&1)
    if echo "$vout" | grep -qiE "Invalid input"; then
        msg_fail "Validation failed, cleaning..."
        sanitize_config_for_schema | sed 's/^/  /'
    else
        msg_ok "Passed"
    fi

    echo ""
    msg_step "Restarting Gateway..."
    manage_service restart >/dev/null 2>&1

    echo -ne "  Waiting for ready"
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
        msg_ok "Gateway started"
    else
        msg_warn "No response"
    fi

    local local_ip; local_ip=$(get_local_ip)
    local token_qs=""
    [[ -n "$gw_token" ]] && token_qs="?token=${gw_token}"
    echo ""
    echo -e "${GREEN}${BOLD}LAN UI Access Info${NC}"
    print_line
    echo -e "  ${BOLD}Local:${NC}    ${CYAN}http://127.0.0.1:${OPENCLAW_PORT}${NC}"
    echo -e "  ${BOLD}LAN:${NC}      ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${token_qs}${NC}"
    if [[ -n "$gw_token" ]]; then
        echo ""
        echo -e "  ${BOLD}WebSocket:${NC}    ${YELLOW}ws://${local_ip}:${OPENCLAW_PORT}${NC}"
        echo -e "  ${BOLD}Token:${NC}        ${YELLOW}${gw_token}${NC}"
    fi
    echo ""
    echo -e "  ${RED}Do not expose to public internet!${NC}"
    print_line
    echo ""
    echo -e "${CYAN}${BOLD}Browser login:${NC}"
    echo -e "  1. Open: ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${token_qs}${NC}"
    echo -e "  2. Or manually:"
    echo -e "     ${DIM}WebSocket:${NC} ${YELLOW}ws://${local_ip}:${OPENCLAW_PORT}${NC}"
    echo -e "     ${DIM}Token:${NC}      ${YELLOW}${gw_token}${NC}"
    echo -e "  3. Click ${BOLD}[Connect]${NC}"
    echo ""

    log "LAN configured"
    wait_and_return 5; return 0
}

install_plugins() {
    msg_title "${PLUGIN} Install Plugins"

    if ! is_openclaw_installed; then
        msg_fail "Not installed"
        wait_and_return 2; return 0
    fi

    echo -e "  ${BOLD}1)${NC} ${LOBSTER} WeChat"
    echo -e "  ${BOLD}2)${NC} ${LOBSTER} Feishu"
    echo -e "  ${BOLD}3)${NC} All"
    echo -e "  ${BOLD}0)${NC} Return"
    echo ""
    echo -ne "${BOLD}Choose: ${NC}"
    local choice
    read -r choice </dev/tty || choice="0"

    case "$choice" in
        1) _install_single_plugin "WeChat" "$WECHAT_PLUGIN_PKG" ;;
        2) _install_single_plugin "Feishu" "$FEISHU_PLUGIN_PKG" ;;
        3)
            _install_single_plugin "WeChat" "$WECHAT_PLUGIN_PKG"
            _install_single_plugin "Feishu" "$FEISHU_PLUGIN_PKG"
            ;;
        0) return 0 ;;
        *) msg_warn "Invalid" ;;
    esac

    wait_and_return 3; return 0
}

_install_single_plugin() {
    local name="$1" pkg="$2"
    echo ""
    msg_step "Installing ${name}..."
    if openclaw_cmd plugins install "${pkg}" --force 2>&1 | tee -a "$LOG_FILE"; then
        msg_ok "${name} success"
    else
        msg_fail "${name} failed"
    fi
}

deploy_docker() {
    msg_title "${DOCKER} Docker Deploy"

    if ! has_cmd docker; then
        msg_warn "Docker not detected, installing..."
        _install_docker || { wait_and_return 3; return 0; }
    fi

    echo -e "${CYAN}Docker:${NC} $(docker --version 2>/dev/null || echo 'unknown')"
    echo ""

    if docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        local container_status
        container_status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")
        echo -e "${CYAN}Existing container:${NC} ${BOLD}${container_status}${NC}"
        echo ""
        echo -e "  ${BOLD}1)${NC} Start  ${BOLD}2)${NC} Stop  ${BOLD}3)${NC} Restart"
        echo -e "  ${BOLD}4)${NC} Delete and redeploy  ${BOLD}5)${NC} Logs  ${BOLD}6)${NC} Shell"
        echo -e "  ${BOLD}0)${NC} Return"
        echo ""
        echo -ne "${BOLD}Choose: ${NC}"
        local dc
        read -r dc </dev/tty || dc="0"

        case "$dc" in
            1) docker start "$DOCKER_CONTAINER" && msg_ok "Started" ;;
            2) docker stop  "$DOCKER_CONTAINER" && msg_ok "Stopped" ;;
            3) docker restart "$DOCKER_CONTAINER" && msg_ok "Restarted" ;;
            4) confirm "Confirm?" && { docker rm -f "$DOCKER_CONTAINER"; _docker_run; } ;;
            5) trap 'echo ""; msg_info "Exit"' INT; docker logs -f "$DOCKER_CONTAINER" || true; trap - INT ;;
            6) docker exec -it "$DOCKER_CONTAINER" /bin/sh 2>/dev/null || docker exec -it "$DOCKER_CONTAINER" /bin/bash 2>/dev/null ;;
            0) return 0 ;;
        esac
    else
        echo -ne "  Port (default: ${OPENCLAW_PORT}): "
        local port; read -r port </dev/tty || port=""; port=${port:-$OPENCLAW_PORT}
        echo -ne "  Data dir (default: ${DOCKER_DATA_DIR}): "
        local data_dir; read -r data_dir </dev/tty || data_dir=""; data_dir=${data_dir:-$DOCKER_DATA_DIR}

        echo ""
        echo -e "${CYAN}${BOLD}Network mode:${NC}"
        echo -e "  ${BOLD}1)${NC} bridge + host.docker.internal ${DIM}(default, auto map host)${NC}"
        echo -e "  ${BOLD}2)${NC} host                          ${DIM}(container shares host network)${NC}"
        echo ""
        echo -ne "${CYAN}Choose [1-2] (default: 1): ${NC}"
        local nm; read -r nm </dev/tty || nm="1"
        local network_mode="bridge"
        [[ "$nm" == "2" ]] && network_mode="host"

        local extra_opts=""
        confirm "  Enable LAN UI access?" && extra_opts="--lan"
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

    msg_step "Pulling image..."
    if docker pull "${image}:latest" 2>&1 | tail -3; then
        msg_ok "Pull success"
    else
        msg_warn "GHCR failed, trying Docker Hub..."
        if docker pull "${DOCKER_IMAGE_MIRROR}:latest" 2>&1 | tail -3; then
            image="$DOCKER_IMAGE_MIRROR"
        fi
    fi

    local container_config="${data_dir}/.openclaw/openclaw.json"
    local bind_v="loopback"
    [[ "$extra" == "--lan" ]] && bind_v="lan"

    msg_info "Preparing initial config (bind: $bind_v)..."
    local need_create=true
    if [[ -f "$container_config" ]] && has_cmd python3; then
        if python3 -c "
import json
c=json.load(open('$container_config'))
assert c.get('gateway',{}).get('bind') in ['auto','lan','loopback','custom','tailnet']
assert c.get('gateway',{}).get('mode') == 'local'
" 2>/dev/null; then
            msg_info "Existing config valid, keeping"
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
            msg_warn "Existing config invalid, backup and overwrite"
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

    msg_step "Starting container (network: ${network_mode})..."
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
            msg_fail "Container exited after start (status: $status)"
            echo ""
            echo -e "${YELLOW}${BOLD}Container logs:${NC}"
            print_line
            docker logs --tail 30 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
            print_line
            echo ""
            echo -e "${CYAN}Common causes:${NC}"
            echo -e "  * Config format error (${container_config})"
            echo -e "  * Port conflict"
            echo -e "  * Image corrupted"
            return 1
        fi

        msg_ok "Container started"

        echo -ne "  Waiting for service ready"
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
            msg_warn "Port not responding, logs:"
            docker logs --tail 20 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
        fi

        if [[ "$extra" == "--lan" ]]; then
            msg_step "Configuring LAN controlUi..."
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.bind lan >/dev/null 2>&1 || true
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.controlUi.allowInsecureAuth true >/dev/null 2>&1 || true
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true >/dev/null 2>&1 || true
            docker restart "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
            sleep 3
            msg_ok "LAN mode enabled"
        fi

        echo ""
        local local_ip; local_ip=$(get_local_ip)
        echo -e "${GREEN}${BOLD}Deploy complete!${NC}"
        echo -e "  ${BOLD}Local:${NC}   ${CYAN}http://127.0.0.1:${port}${NC}"
        echo -e "  ${BOLD}LAN:${NC}     ${CYAN}http://${local_ip}:${port}${NC}"
        echo -e "  ${BOLD}Network:${NC} ${network_mode}"
        echo ""
        echo -e "${CYAN}Tips:${NC}"
        echo -e "  ${DIM}* Access host services: host.docker.internal:port${NC}"
        echo -e "  ${DIM}* Menu [4] configure custom API auto-converts LAN URLs${NC}"

        log "Docker deployed (network: $network_mode)"
    else
        msg_fail "Start failed"
    fi
}

_install_docker() {
    detect_system
    msg_step "Installing Docker..."
    case "$OS" in
        debian)
            safe_run "apt update"   sudo apt-get update -qq
            safe_run "deps"         sudo apt-get install -y ca-certificates curl gnupg lsb-release
            safe_run "Docker"       bash -c "curl -fsSL https://get.docker.com | sh" ;;
        rhel|fedora)
            safe_run "Docker"       bash -c "curl -fsSL https://get.docker.com | sh" ;;
        arch)
            safe_run "Docker"       sudo pacman -S --noconfirm docker ;;
        alpine)
            safe_run "Docker"       sudo apk add docker ;;
        macos)
            msg_info "Please install Docker Desktop manually"
            return 1 ;;
        *)
            safe_run "Docker"       bash -c "curl -fsSL https://get.docker.com | sh" ;;
    esac
    case "$SERVICE_MANAGER" in
        systemd) sudo systemctl enable --now docker 2>/dev/null || true; sudo usermod -aG docker "$USER" 2>/dev/null || true ;;
        openrc)  sudo rc-update add docker 2>/dev/null || true; sudo service docker start 2>/dev/null || true ;;
    esac
    has_cmd docker && msg_ok "Docker installed" || { msg_fail "Failed"; return 1; }
}

show_command_reference() {
    msg_title "${LOBSTER} Command Reference"

    local use_docker=false
    is_docker_mode && use_docker=true
    local prefix=""
    $use_docker && prefix="docker exec ${DOCKER_CONTAINER} "

    echo -e "${CYAN}${BOLD}Service${NC}"; print_line
    _cmd_row "${prefix}openclaw setup"               "Initialize"
    _cmd_row "${prefix}openclaw gateway run"         "Foreground debug"
    _cmd_row "${prefix}openclaw gateway restart"     "Restart"
    _cmd_row "${prefix}openclaw gateway status"      "Status"
    _cmd_row "${prefix}openclaw dashboard --no-open" "Get URL"
    echo ""

    if $use_docker; then
        echo -e "${CYAN}${BOLD}Docker Specific${NC}"; print_line
        _cmd_row "docker logs -f ${DOCKER_CONTAINER}"      "Live logs"
        _cmd_row "docker restart ${DOCKER_CONTAINER}"      "Restart container"
        _cmd_row "docker exec -it ${DOCKER_CONTAINER} sh"  "Enter container"
        _cmd_row "cat ${DOCKER_DATA_DIR}/.openclaw/openclaw.json"  "View config"
        echo ""
    fi

    echo -e "${CYAN}${BOLD}Agent${NC}"; print_line
    _cmd_row "${prefix}openclaw agents list"              "List"
    _cmd_row "${prefix}openclaw agents auth list main"    "Auth list"
    _cmd_row "${prefix}openclaw agents login main"        "Interactive login"
    echo ""

    echo -e "${RED}${BOLD}Schema${NC}"; print_line
    _cmd_row "gateway.bind allowed"                             "auto/lan/loopback/custom/tailnet"
    _cmd_row "${prefix}openclaw config set gateway.bind lan"   "Enable LAN"
    _cmd_row "${prefix}openclaw doctor --fix"                  "Auto fix"
    echo ""

    wait_and_return 3; return 0
}

_cmd_row() {
    printf "  ${CYAN}%-52s${NC} ${DIM}%s${NC}\n" "$1" "$2"
}

run_setup_wizard() {
    msg_title "Setup Wizard"

    if ! is_openclaw_installed; then
        msg_fail "Not installed"
        wait_and_return 2; return 0
    fi

    if ! json_is_valid; then
        msg_fail "Config corrupted, please repair first"
        wait_and_return 3
        return 0
    fi

    ensure_minimal_config

    if ! confirm "Run openclaw setup?"; then
        wait_and_return 2; return 0
    fi

    openclaw_cmd setup </dev/tty && msg_ok "Complete" || msg_warn "Exited"

    confirm "Restart?" && manage_service restart >/dev/null 2>&1

    wait_and_return 3; return 0
}

quick_commands() {
    msg_title "${GEAR} Quick Commands"

    if ! is_openclaw_installed; then
        msg_fail "Not installed"
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
    echo -e "  ${BOLD}11)${NC} openclaw gateway run (foreground)"
    echo -e "  ${BOLD}12)${NC} Validate config"
    echo -e "  ${BOLD}13)${NC} Configure custom API"
    echo -e "  ${BOLD}0)${NC}  Return"
    echo ""
    echo -ne "${BOLD}Choose: ${NC}"
    local qc
    read -r qc </dev/tty || qc="0"

    echo ""
    case "$qc" in
        1)  openclaw_cmd setup </dev/tty 2>&1 ;;
        2)  openclaw_cmd status ;;
        3)  openclaw_cmd health ;;
        4)  openclaw_cmd doctor --fix ;;
        5)  trap 'echo ""; msg_info "Exit"' INT; openclaw_cmd logs 2>&1 || true; trap - INT ;;
        6)  openclaw_cmd models status ;;
        7)  openclaw_cmd models list ;;
        8)  openclaw_cmd config validate ;;
        9)  openclaw_cmd dashboard --no-open ;;
        10) openclaw_cmd agents list ;;
        11) msg_info "Ctrl+C to exit"; trap 'echo ""; msg_info "Exit"' INT; openclaw_cmd gateway run 2>&1; trap - INT ;;
        12) validate_config ;;
        13) configure_custom_api ;;
        0)  return 0 ;;
        *)  msg_warn "Invalid" ;;
    esac

    wait_and_return 2; return 0
}

configure_api_keys() {
    msg_title "Builtin Provider API Keys"

    if [[ -f "$(get_active_config_path)" ]] && ! json_is_valid; then
        msg_fail "Config corrupted"
        wait_and_return 3
        return 1
    fi

    load_config_from_file
    mkdir -p "$(dirname "$(get_active_config_path)")"

    if [[ ${#G_API_KEYS[@]} -gt 0 ]]; then
        echo -e "${CYAN}Existing config:${NC}"
        for p in anthropic openai google deepseek groq mistral; do
            [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
            local dt=""; [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && dt=" ${GREEN}[default]${NC}"
            echo -e "  ${BOLD}${p}${NC}: ${DIM}${G_API_KEYS[$p]:0:8}****${NC} -> ${G_API_MODELS[$p]%%,*}${dt}"
        done
        echo ""
    fi

    echo "  1) Anthropic   2) OpenAI   3) Google   4) DeepSeek"
    echo "  5) Groq        6) Mistral  7) Custom API  0) Save"
    echo ""

    while true; do
        echo -ne "${BOLD}Number (0 to finish): ${NC}"; local c; read -r c </dev/tty || c="0"
        case "$c" in
            0) break ;;
            1) _cfg_builtin_provider anthropic "sk-ant-..." "claude-sonnet-4-5" ;;
            2) _cfg_builtin_provider openai "sk-..." "gpt-4o" ;;
            3) _cfg_builtin_provider google "" "gemini-2.5-flash" ;;
            4) _cfg_builtin_provider deepseek "sk-..." "deepseek-chat" ;;
            5) _cfg_builtin_provider groq "gsk_..." "llama-3.3-70b-versatile" ;;
            6) _cfg_builtin_provider mistral "" "mistral-large-latest" ;;
            7) configure_custom_api ;;
            *) msg_warn "0-7" ;;
        esac
    done

    if [[ ${#G_API_KEYS[@]} -eq 0 && ${#G_API_URLS[@]} -eq 0 ]]; then
        msg_warn "Nothing configured"
        return 0
    fi

    msg_step "Saving..."
    ensure_minimal_config
    _write_builtin_providers_config
    _show_config_summary

    if is_openclaw_installed; then
        echo ""
        if confirm "Sync auth to main Agent?"; then
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
            msg_step "Restarting..."
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
            py_code+="
c.setdefault('$p', {})['apiKey'] = '${G_API_KEYS[$p]}'
"
            if [[ -n "${G_API_MODELS[$p]:-}" ]]; then
                py_code+="
c['$p']['model'] = '${G_API_MODELS[$p]%%,*}'
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
    msg_ok "Config saved"
}

_cfg_builtin_provider() {
    local p="$1" hint="$2" rec="$3"
    echo ""
    echo -e "${CYAN}${BOLD}--- ${p} ---${NC}"
    local ek="${G_API_KEYS[$p]:-}"
    [[ -n "$ek" ]] && echo -e "  ${DIM}Existing: ${ek:0:8}****${NC}"
    echo -ne "  Key${hint:+ ($hint)}: "
    local nk
    read -rs nk </dev/tty
    echo ""

    if [[ -z "$nk" ]]; then
        [[ -n "$ek" ]] && msg_info "Kept" || msg_warn "Skipped"
        return
    fi

    G_API_KEYS["$p"]="$nk"

    echo -ne "  Model (default: $rec): "
    local sm
    read -r sm </dev/tty || sm=""
    sm=${sm:-$rec}
    G_API_MODELS["$p"]="$sm"

    msg_ok "${p}: ${sm}"
    [[ -z "$G_DEFAULT_PROVIDER" ]] && G_DEFAULT_PROVIDER="$p"
}

_show_config_summary() {
    print_line
    echo -e "${BOLD}Summary${NC}"
    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        echo -e "  ${BOLD}${p}${NC}  ${DIM}${G_API_KEYS[$p]:0:10}****${NC} -> ${CYAN}${G_API_MODELS[$p]:-}${NC}"
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
            enable)  msg_info "Docker restart=unless-stopped enabled" ;;
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
                status)  openclaw gateway status 2>/dev/null || echo "Unknown" ;;
            esac ;;
    esac
    return 0
}

show_dashboard_info() {
    local local_ip
    local_ip=$(get_local_ip)
    local public_ip
    public_ip=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null \
             || curl -s --max-time 4 https://ifconfig.me 2>/dev/null || echo "N/A")

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
    echo -e "${GREEN}${BOLD}OpenClaw Access Info${NC}"
    print_line
    echo -e "  ${BOLD}Local:${NC}    ${CYAN}http://127.0.0.1:${OPENCLAW_PORT}${token_qs}${NC}"
    if [[ "$bind_mode" == "lan" ]]; then
        echo -e "  ${BOLD}LAN:${NC}      ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${token_qs}${NC} ${GREEN}(enabled)${NC}"
    else
        echo -e "  ${BOLD}LAN:${NC}      ${DIM}Not enabled (menu[5] to enable)${NC}"
    fi
    echo -e "  ${BOLD}SSH Tunnel:${NC} ${YELLOW}ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} user@${public_ip}${NC}"
    echo -e "  ${BOLD}bind:${NC}    ${bind_mode}"
    if [[ -n "$token" ]]; then
        echo -e "  ${BOLD}Token:${NC}   ${YELLOW}${token}${NC}"
    fi
    if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
        local dm="${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
        dm="${dm%%,*}"
        echo -e "  ${BOLD}Default AI:${NC}  ${CYAN}${G_DEFAULT_PROVIDER}${NC} -> ${dm}"
    fi
    echo -e "  ${RED}Do not expose to public internet!${NC}"
    print_line
    echo ""

    if [[ -n "$token" ]] && [[ "$bind_mode" == "lan" ]]; then
        echo -e "${CYAN}${BOLD}Browser UI Login:${NC}"
        echo -e "  ${BOLD}WebSocket:${NC} ${YELLOW}ws://${local_ip}:${OPENCLAW_PORT}${NC}"
        echo -e "  ${BOLD}Token:${NC}     ${YELLOW}${token}${NC}"
        echo ""
    fi
}

install_openclaw() {
    msg_title "${ROCKET} Install OpenClaw"
    detect_system
    echo -e "${CYAN}Environment:${NC} ${BOLD}${OS} ${ARCH_LABEL}${NC}"
    echo ""

    if has_cmd openclaw; then
        local iv
        iv=$(openclaw --version 2>/dev/null || echo "unknown")
        msg_warn "Already installed ($iv)"
        confirm "Reinstall?" || return 0
    fi

    msg_step "Step 1/5: System dependencies..."
    case "$OS" in
        debian)
            safe_run "apt update" sudo apt-get update -qq
            safe_run "deps" sudo apt-get install -y curl wget git build-essential ca-certificates gnupg python3 jq ;;
        rhel|fedora)
            safe_run "update" bash -c "$UPDATE_CMD"
            safe_run "deps" bash -c "$INSTALL_CMD curl wget git gcc gcc-c++ make python3 jq" ;;
        arch)
            safe_run "pacman" sudo pacman -Sy --noconfirm
            safe_run "deps" sudo pacman -S --noconfirm curl wget git base-devel python jq ;;
        alpine)
            safe_run "apk update" sudo apk update
            safe_run "deps" sudo apk add curl wget git build-base python3 jq ;;
        macos)
            has_cmd brew || safe_run "Homebrew" bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            safe_run "tools" brew install curl wget git jq ;;
    esac
    msg_ok "Dependencies complete"

    msg_step "Step 2/5: Node.js..."
    install_nodejs || { msg_fail "Node.js failed"; wait_and_return 3; return 1; }

    msg_step "Step 3/5: Installing OpenClaw..."
    echo "  1) Official script [recommended]"
    echo "  2) npm"
    echo "  3) GitHub source"
    echo ""
    echo -ne "${BOLD}Choose [1-3] (default:1): ${NC}"
    local ic
    read -r ic </dev/tty || ic="1"
    ic=${ic:-1}

    case "$ic" in
        1)
            if curl -fsSL --proto '=https' --tlsv1.2 "$OPENCLAW_INSTALL_URL" | bash >> "$LOG_FILE" 2>&1; then
                msg_ok "Official success"
            else
                msg_warn "npm fallback..."
                npm install -g openclaw@latest >> "$LOG_FILE" 2>&1 || true
            fi ;;
        2)
            npm install -g openclaw@latest 2>&1 | tee -a "$LOG_FILE" || true ;;
        3)
            echo -ne "${BOLD}Repo: ${NC}"
            local repo
            read -r repo </dev/tty || repo=""
            repo=${repo:-"$GITHUB_REPO"}
            local tmp="/tmp/oc_src_$$"
            git clone "$repo" "$tmp" >> "$LOG_FILE" 2>&1 || { msg_fail "clone failed"; return 1; }
            pushd "$tmp" > /dev/null
            has_cmd pnpm || npm install -g pnpm >> "$LOG_FILE" 2>&1 || true
            pnpm install >> "$LOG_FILE" 2>&1 || true
            pnpm run build >> "$LOG_FILE" 2>&1 || true
            pnpm install -g . >> "$LOG_FILE" 2>&1 || true
            popd > /dev/null
            rm -rf "$tmp" ;;
    esac

    _refresh_node_path
    has_cmd openclaw || { msg_fail "Install failed"; wait_and_return 3; return 1; }
    msg_ok "OpenClaw $(openclaw --version 2>/dev/null) success"

    msg_step "Step 4/5: Config..."
    ensure_minimal_config

    echo ""
    echo -e "${CYAN}Next step:${NC}"
    echo -e "  ${BOLD}1)${NC} Configure custom API ${GREEN}(recommended)${NC}"
    echo -e "  ${BOLD}2)${NC} Configure builtin Provider"
    echo -e "  ${BOLD}3)${NC} Skip"
    echo ""
    echo -ne "${BOLD}Choose: ${NC}"
    local next
    read -r next </dev/tty || next="3"
    case "$next" in
        1) configure_custom_api ;;
        2) configure_api_keys ;;
    esac

    msg_step "Step 5/5: Starting..."
    manage_service start >/dev/null 2>&1
    sleep 3

    if curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
        msg_ok "Gateway started!"
    else
        msg_warn "No response"
    fi

    echo ""
    if confirm "Configure LAN access (other devices open UI)?"; then
        configure_lan_access
    else
        show_dashboard_info
    fi

    log "Installation completed"
    wait_and_return 3
    return 0
}

pick_node_version() {
    echo -e "\n${CYAN}Getting version list...${NC}" >&2
    local lts_list
    lts_list=$(get_node_lts_versions)
    local latest_major
    latest_major=$(get_node_latest_major)
    local first_lts
    first_lts=$(echo "$lts_list" | awk '{print $1}')

    echo -e "\n${CYAN}Select version:${NC}" >&2
    local idx=1
    declare -a vmap=()

    if [[ "$latest_major" != "$first_lts" ]]; then
        printf "  %2d) Node.js %-4s (Current)\n" "$idx" "$latest_major" >&2
        vmap[$idx]="$latest_major"
        ((idx++))
    fi

    local is_first=true
    for v in $lts_list; do
        if $is_first; then
            printf "  %2d) Node.js %-4s (LTS *)\n" "$idx" "$v" >&2
            is_first=false
        else
            printf "  %2d) Node.js %-4s (LTS)\n" "$idx" "$v" >&2
        fi
        vmap[$idx]="$v"
        ((idx++))
    done

    local mi=$idx
    printf "  %2d) Manual\n" "$mi" >&2
    echo "" >&2
    local dc
    [[ "$latest_major" != "$first_lts" ]] && dc=2 || dc=1
    echo -ne "  Choose [default:${dc}]: " >&2
    local vc
    read -r vc </dev/tty || vc=""
    vc=${vc:-$dc}

    if [[ "$vc" -eq "$mi" ]] 2>/dev/null; then
        echo -ne "  Major version: " >&2
        local mv
        read -r mv </dev/tty || mv=""
        echo "$(echo "${mv:-$NODE_MIN_VERSION}" | tr -d 'vV ')"
    else
        echo "${vmap[$vc]:-${vmap[$dc]:-$NODE_MIN_VERSION}}"
    fi
}

install_nodejs() {
    msg_step "Checking Node.js..."

    if has_cmd node; then
        local ver
        ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$ver" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v)"
            return 0
        fi
    fi

    echo ""
    echo "  1) NodeSource (recommended)"
    echo "  2) nvm"
    echo "  3) System package"
    echo "  4) Manual"
    echo ""
    echo -ne "${BOLD}Choose [1-4] (default: 1): ${NC}"
    local nc
    read -r nc </dev/tty || nc="1"
    nc=${nc:-1}

    local tv="$NODE_RECOMMENDED_VERSION"
    if [[ "$nc" -eq 1 || "$nc" -eq 2 ]]; then
        tv=$(pick_node_version)
        [[ -z "$tv" ]] && tv="$NODE_RECOMMENDED_VERSION"
    fi

    case "$nc" in
        1) _install_node_nodesource "$tv" ;;
        2) _install_node_nvm "$tv" ;;
        3) _install_node_native ;;
        4) msg_info "https://nodejs.org/en/download/"; return 1 ;;
    esac

    _refresh_node_path

    if has_cmd node; then
        local iv
        iv=$(node -v | sed 's/v//' | cut -d. -f1)
        [[ "$iv" -ge "$NODE_MIN_VERSION" ]] && { msg_ok "Node.js $(node -v)"; return 0; }
    fi
    msg_fail "Failed"
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
            has_cmd brew || { msg_fail "Need Homebrew"; return 1; }
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
    safe_run "install $version" nvm install "$version"
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
    msg_title "Version Info"
    is_openclaw_installed || { msg_fail "Not installed"; wait_and_return 2; return 0; }
    print_line
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw_cmd --version 2>/dev/null || echo 'unknown')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo 'not installed')"
    echo -e "  ${BOLD}npm${NC}         : v$(npm -v 2>/dev/null || echo 'not installed')"
    echo -e "  ${BOLD}Docker${NC}      : $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo 'not installed')"
    echo -e "  ${BOLD}Deploy${NC}      : $(_detect_deploy_mode)"
    echo -e "  ${BOLD}Script${NC}      : ${SCRIPT_VERSION}"
    print_line
    echo ""

    msg_info "Checking latest..."
    local latest current
    latest=$(get_openclaw_latest_version)
    current=$(openclaw_cmd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
    echo -e "  Current: ${current}  Latest: ${latest:-N/A}"

    if [[ -n "$latest" && "$latest" != "$current" ]]; then
        confirm "Upgrade?" && {
            if is_docker_mode; then
                docker pull "${DOCKER_IMAGE}:latest" && docker rm -f "$DOCKER_CONTAINER" && _docker_run "$OPENCLAW_PORT" "$DOCKER_DATA_DIR"
            else
                npm install -g openclaw@latest 2>&1 | tail -5 && msg_ok "Upgraded" || msg_fail "Failed"
            fi
        }
    else
        msg_ok "Already latest"
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
            msg_step "Starting Gateway..."

            if $docker_mode; then
                msg_info "Docker mode starting..."

                if ! docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
                    docker start "$DOCKER_CONTAINER" >/dev/null 2>&1
                    sleep 5
                fi

                local status
                status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")

                if [[ "$status" == "running" ]]; then
                    echo -ne "  Waiting for ready"
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
                        msg_ok "Container started"
                        show_dashboard_info
                    else
                        msg_warn "Port not responding, container logs:"
                        docker logs --tail 25 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
                    fi
                else
                    msg_fail "Container status: $status"
                    echo ""
                    echo -e "${YELLOW}${BOLD}Container logs:${NC}"
                    print_line
                    docker logs --tail 30 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
                    print_line
                    echo ""
                    echo -e "${CYAN}Troubleshoot:${NC}"
                    echo -e "  ${DIM}Config: ${DOCKER_DATA_DIR}/.openclaw/openclaw.json${NC}"
                    echo -e "  ${DIM}Menu [24] cleanup incompatible fields${NC}"
                    echo -e "  ${DIM}Menu [16] repair config${NC}"
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
                msg_warn "Port $OPENCLAW_PORT occupied by PID $port_pid, releasing..."
                kill -9 "$port_pid" 2>/dev/null || sudo kill -9 "$port_pid" 2>/dev/null || true
                sleep 2
            fi

            if ! has_cmd openclaw; then
                msg_fail "Host openclaw not installed"
                echo ""
                echo -e "  ${BOLD}A)${NC} Install npm version -> Menu [1]"
                echo -e "  ${BOLD}B)${NC} Use Docker -> Menu [2]"
                wait_and_return 5
                return 0
            fi

            if ! json_is_valid; then
                msg_fail "Config corrupted, please repair with menu [16]"
                wait_and_return 3
                return 0
            fi

            msg_step "Validating config..."
            local validate_out
            validate_out=$(openclaw config validate 2>&1)
            if echo "$validate_out" | grep -qiE "Invalid input|invalid config"; then
                msg_warn "Validation failed:"
                echo "$validate_out" | grep -iE "×|invalid|allowed" | head -8 | sed 's/^/  /'
                echo ""
                msg_step "Auto cleanup..."
                sanitize_config_for_schema | sed 's/^/  /'
                sleep 1
            else
                msg_ok "Config valid"
            fi

            mkdir -p "$OPENCLAW_LOG_DIR"
            local out_log="$OPENCLAW_LOG_DIR/gateway.out"
            > "$out_log"

            msg_info "Trying systemd start..."
            service_action start
            sleep 3

            if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                msg_ok "Started successfully"
                show_dashboard_info
                wait_and_return 3
                return 0
            fi

            msg_warn "systemd not responding, running background..."
            local openclaw_bin
            openclaw_bin=$(command -v openclaw)
            if [[ -z "$openclaw_bin" ]]; then
                msg_fail "Cannot find openclaw"
                wait_and_return 3
                return 0
            fi

            nohup "$openclaw_bin" gateway run > "$out_log" 2>&1 &
            local bg_pid=$!
            sleep 6

            if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                msg_ok "Background running (PID: $bg_pid)"
                show_dashboard_info
            else
                msg_fail "Gateway start failed"
                echo ""
                echo -e "${YELLOW}${BOLD}Error log:${NC}"
                print_line
                tail -25 "$out_log" 2>/dev/null | sed 's/^/  /' || echo "  (no log)"
                print_line
                echo ""
                echo -e "${CYAN}Fix:${NC}"
                echo -e "  ${BOLD}1)${NC} Menu [16] repair config"
                echo -e "  ${BOLD}2)${NC} Menu [24] cleanup fields"
                echo -e "  ${BOLD}3)${NC} Manual: ${YELLOW}openclaw gateway run${NC}"
            fi
            ;;
        stop)
            confirm "Confirm stop?" && {
                if $docker_mode; then
                    docker stop "$DOCKER_CONTAINER" 2>/dev/null && msg_ok "Container stopped" || msg_warn "Failed"
                else
                    if json_is_valid && has_cmd openclaw; then
                        service_action stop 2>/dev/null || true
                        openclaw gateway stop 2>/dev/null || true
                    fi
                    pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
                    sleep 1
                    msg_ok "Stopped"
                fi
            } || msg_info "Cancelled" ;;
        restart)
            msg_step "Restarting..."
            if $docker_mode; then
                docker restart "$DOCKER_CONTAINER" >/dev/null 2>&1
                sleep 5

                local st
                st=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")
                if [[ "$st" == "running" ]]; then
                    echo -ne "  Waiting for ready"
                    local i=0
                    while (( i < 20 )); do
                        sleep 1; echo -ne "."
                        curl -s --max-time 2 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null && break
                        ((i++))
                    done
                    echo ""
                    msg_ok "Restarted"
                    show_dashboard_info
                else
                    msg_fail "Restart failed, status: $st"
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
            msg_step "Status:"
            echo ""
            if $docker_mode; then
                echo -e "${CYAN}Docker container:${NC}"
                docker ps -a --filter "name=$DOCKER_CONTAINER" --format "  Name: {{.Names}}\n  Status: {{.Status}}\n  Ports: {{.Ports}}"
                echo ""
                echo -e "${CYAN}Container logs:${NC}"
                docker logs --tail 15 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
            else
                service_action status
                echo ""
                echo -e "${CYAN}Processes:${NC}"
                ps aux | grep -iE "openclaw" | grep -v grep | grep -v "openclaw-manager" | head -5 | sed 's/^/  /' || echo "  (none)"
            fi
            echo ""
            echo -e "${CYAN}Port ($OPENCLAW_PORT):${NC}"
            ss -lntp 2>/dev/null | grep ":$OPENCLAW_PORT" | sed 's/^/  /' || echo "  Not listening"

            load_config_from_file
            show_dashboard_info ;;
    esac
    wait_and_return 5
    return 0
}

diagnose_and_fix() {
    msg_title "${DOCTOR} Diagnose and Fix"
    detect_system
    local issues=0 fixed=0
    local cfg
    cfg=$(get_active_config_path)

    echo -e "${CYAN}${BOLD}Checking...${NC}"
    echo -e "${DIM}Mode: $(_detect_deploy_mode)  Config: $cfg${NC}"
    echo ""

    _chk() { echo -ne "  [${1}] ${2}...  "; }
    _pass() { echo -e "${GREEN}${OK} $*${NC}"; }
    _fail_msg() { echo -e "${RED}${FAIL} $*${NC}"; }

    _chk "1/10" "OpenClaw"
    if is_openclaw_installed; then
        _pass "$(openclaw_cmd --version 2>/dev/null)"
    else
        _fail_msg "Not installed"
        ((issues++))
    fi

    _chk "2/10" "Config exists"
    if [[ -f "$cfg" ]]; then
        _pass "Exists"
    else
        _fail_msg "Not exists"
        ((issues++))
        confirm "  Create?" && { _create_minimal_config; ((fixed++)); }
    fi

    _chk "3/10" "JSON valid"
    if [[ -f "$cfg" ]]; then
        if json_is_valid; then
            _pass "Valid"
        else
            _fail_msg "Corrupted!"
            ((issues++))
            confirm "  Repair?" && { backup_config; _create_minimal_config; ((fixed++)); }
        fi
    else
        echo -e "${DIM}Skip${NC}"
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
            _fail_msg "bind='$bind_v' invalid"
            ((issues++))
            confirm "  Fix?" && { sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        fi
    else
        echo -e "${DIM}Skip${NC}"
    fi

    _chk "5/10" "Illegal root fields"
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
            _pass "None"
        else
            _fail_msg "Exists: $bad_keys"
            ((issues++))
            confirm "  Cleanup?" && { sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        fi
    else
        echo -e "${DIM}Skip${NC}"
    fi

    _chk "6/10" "openclaw schema"
    if is_openclaw_installed && json_is_valid; then
        local schema_out
        schema_out=$(openclaw_cmd config validate 2>&1)
        if echo "$schema_out" | grep -qiE "Invalid input"; then
            _fail_msg "Failed"
            ((issues++))
            echo ""
            echo "$schema_out" | grep -iE "×|invalid|allowed" | head -5 | sed 's/^/    /'
            confirm "  Auto cleanup?" && { sanitize_config_for_schema | sed 's/^/    /'; ((fixed++)); }
        else
            _pass "Passed"
        fi
    else
        echo -e "${DIM}Skip${NC}"
    fi

    _chk "7/10" "Docker URL compatible"
    if is_docker_mode && [[ -f "$cfg" ]] && json_is_valid && has_cmd python3; then
        local lan_urls
        lan_urls=$(python3 -c "
import json, re
try:
    c = json.load(open('$cfg'))
    p = re.compile(r'^https?://(127\.|localhost|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)')
    bad = []
    for name, cfg in c.get('models', {}).get('providers', {}).items():
        url = cfg.get('baseUrl', '') if isinstance(cfg, dict) else ''
        if p.match(url):
            bad.append(name)
    print(','.join(bad))
except: print('')
" 2>/dev/null || echo "")
        if [[ -z "$lan_urls" ]]; then
            _pass "No conversion needed"
        else
            _fail_msg "LAN URL: $lan_urls (container cannot access)"
            ((issues++))
            confirm "  Convert to host.docker.internal?" && { convert_urls_for_docker_mode | sed 's/^/    /'; ((fixed++)); }
        fi
    else
        echo -e "${DIM}Skip${NC}"
    fi

    _chk "8/10" "Agent auth"
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
            _pass "Exists"
        else
            _fail_msg "Missing"
            ((issues++))
            confirm "  Fix (menu[23])?" && { fix_agent_auth_menu; ((fixed++)); }
        fi
    else
        echo -e "${DIM}Skip${NC}"
    fi

    _chk "9/10" "Gateway port"
    if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
        _pass "Responding"
    else
        echo -e "${YELLOW}${WARN} No response${NC}"
        ((issues++))
        confirm "  Start?" && { manage_service start >/dev/null; ((fixed++)); }
    fi

    _chk "10/10" "Disk"
    local da
    da=$(df "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999999")
    [[ "$da" -gt 1048576 ]] && _pass "$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')" || { _fail_msg "Low"; ((issues++)); }

    if is_openclaw_installed; then
        echo ""
        msg_step "openclaw doctor --fix..."
        openclaw_cmd doctor --fix 2>&1 | tail -15 | sed 's/^/    /' || true
    fi

    echo ""
    print_line
    echo -e "${BOLD}Result:${NC}  Issues ${RED}${issues}${NC}  Fixed ${GREEN}${fixed}${NC}"
    print_line

    wait_and_return 3
    return 0
}

view_logs() {
    msg_title "Logs"
    echo "  1) Live Gateway  2) systemd  3) File  4) Docker  5) Script  6) gateway.out  0) Return"
    echo ""
    echo -ne "${BOLD}Choose: ${NC}"
    local lc
    read -r lc </dev/tty || lc="0"

    case "$lc" in
        1)
            trap 'echo ""; msg_info "Exit"' INT
            if is_docker_mode; then
                docker logs -f "$DOCKER_CONTAINER" 2>&1 || true
            else
                openclaw_cmd gateway logs --follow 2>/dev/null \
                    || openclaw_cmd logs 2>/dev/null \
                    || tail -f "${OPENCLAW_LOG_DIR}/gateway.log" 2>/dev/null \
                    || msg_fail "Cannot get"
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
                echo -ne "${BOLD}File (Enter for latest): ${NC}"
                local lf; read -r lf </dev/tty || lf=""
                if [[ -n "$lf" ]]; then
                    less "${log_dir}/${lf}" 2>/dev/null
                else
                    local ll
                    ll=$(ls -t "${log_dir}"/*.log 2>/dev/null | head -1 || echo "")
                    [[ -n "$ll" ]] && less "$ll" || msg_warn "No log"
                fi
            fi ;;
        4)
            if docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
                trap 'echo ""; msg_info "Exit"' INT
                docker logs -f "$DOCKER_CONTAINER" 2>&1 || true
                trap - INT
            fi ;;
        5)
            [[ -f "$LOG_FILE" ]] && less "$LOG_FILE" || msg_warn "Not exists" ;;
        6)
            [[ -f "$OPENCLAW_LOG_DIR/gateway.out" ]] && less "$OPENCLAW_LOG_DIR/gateway.out" || msg_warn "Not exists" ;;
        0) return 0 ;;
    esac
    wait_and_return 2
    return 0
}

uninstall_openclaw() {
    msg_title "${TRASH} Uninstall"
    echo -e "${RED}${BOLD}Uninstall OpenClaw${NC}"
    echo ""
    confirm "Confirm?" || { wait_and_return 2; return 0; }
    detect_system

    docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER" && {
        docker stop "$DOCKER_CONTAINER" 2>/dev/null || true
        confirm "Delete container?" && docker rm -f "$DOCKER_CONTAINER" 2>/dev/null
        confirm "Delete image?" && {
            docker rmi "${DOCKER_IMAGE}:latest" 2>/dev/null || true
            docker rmi "${DOCKER_IMAGE_MIRROR}:latest" 2>/dev/null || true
        }
        confirm "Delete data dir (${DOCKER_DATA_DIR})?" && rm -rf "$DOCKER_DATA_DIR"
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
    confirm "Delete config dir ($OPENCLAW_CONFIG_DIR)?" && {
        rm -rf "$OPENCLAW_CONFIG_DIR"
        G_API_KEYS=()
        G_API_MODELS=()
        G_API_TYPES=()
        G_API_URLS=()
        G_DEFAULT_PROVIDER=""
    }

    msg_ok "Uninstalled"
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
    echo -e "        ${DIM}${SCRIPT_VERSION} | Docker+LAN+Agent One-Click Deploy${NC}"
    echo ""

    detect_system
    load_config_from_file 2>/dev/null || true

    local sc="${RED}" st="Not Installed"
    if is_openclaw_installed; then
        curl -s --max-time 2 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null \
            && { sc="${GREEN}"; st="Running"; } \
            || { sc="${YELLOW}"; st="Not Running"; }
    fi

    local cfg_status="${DIM}Not created${NC}"
    local cfg
    cfg=$(get_active_config_path)
    if [[ -f "$cfg" ]]; then
        json_is_valid && cfg_status="${GREEN}Valid${NC}" || cfg_status="${RED}${BOLD}Corrupted!${NC}"
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

    echo -e "  ${DIM}OS:${NC} ${OS^^}  ${DIM}|${NC}  ${DIM}GW:${NC} ${sc}${st}${NC}  ${DIM}|${NC}  ${DIM}Mode:${NC} ${mode_label}  ${DIM}|${NC}  ${DIM}Config:${NC} ${cfg_status}  ${DIM}|${NC}  ${DIM}bind:${NC} ${bind_v:-?}${mi}"
    print_line
}

main_menu() {
    while true; do
        show_banner
        echo -e "${WHITE}${BOLD}  Main Menu${NC}"
        echo ""
        echo -e "${BOLD}  -- Install --${NC}"
        echo -e "  ${BOLD}${GREEN}[1]${NC}  ${ROCKET} Local Install / Reinstall"
        echo -e "  ${BOLD}${GREEN}[2]${NC}  ${DOCKER} Docker Deploy"
        echo ""
        echo -e "${BOLD}  -- Config --${NC}"
        echo -e "  ${BOLD}${CYAN}[3]${NC}  ${KEY} Builtin Provider API Keys"
        echo -e "  ${BOLD}${CYAN}[4]${NC}  ${GEAR} Custom API ${GREEN}(One-Click)${NC}"
        echo -e "  ${BOLD}${CYAN}[5]${NC}  ${LOBSTER} LAN UI Access"
        echo -e "  ${BOLD}${CYAN}[6]${NC}  ${PLUGIN} Install Plugins"
        echo ""
        echo -e "${BOLD}  -- Service --${NC}"
        echo -e "  ${BOLD}${YELLOW}[7]${NC}  ${POWER} Start    ${BOLD}${YELLOW}[8]${NC} Restart    ${BOLD}${YELLOW}[9]${NC} Stop    ${BOLD}${YELLOW}[10]${NC} Status"
        echo ""
        echo -e "${BOLD}  -- Tools --${NC}"
        echo -e "  ${BOLD}${MAGENTA}[11]${NC} ${KEY} Gateway Token Manager"
        echo -e "  ${BOLD}${MAGENTA}[12]${NC} Dashboard URL"
        echo -e "  ${BOLD}${MAGENTA}[13]${NC} Version / Upgrade"
        echo -e "  ${BOLD}${MAGENTA}[14]${NC} Logs"
        echo -e "  ${BOLD}${MAGENTA}[15]${NC} ${GEAR} Quick Commands"
        echo -e "  ${BOLD}${MAGENTA}[16]${NC} Repair Config"
        echo -e "  ${BOLD}${MAGENTA}[17]${NC} Validate Config"
        echo -e "  ${BOLD}${MAGENTA}[18]${NC} ${DOCTOR} Diagnose and Fix"
        echo -e "  ${BOLD}${MAGENTA}[19]${NC} Command Reference"
        echo -e "  ${BOLD}${MAGENTA}[20]${NC} System Info"
        echo -e "  ${BOLD}${GREEN}[21]${NC} Setup Wizard"
        echo -e "  ${BOLD}${RED}[22]${NC} ${TRASH} Uninstall"
        echo -e "  ${BOLD}${YELLOW}[23]${NC} ${LINK} Fix Agent Auth"
        echo -e "  ${BOLD}${YELLOW}[24]${NC} Cleanup Incompatible Fields"
        echo -e "  ${BOLD}${YELLOW}[25]${NC} Convert URL (Docker Compatible)"
        echo -e "  ${BOLD}[0]${NC}  Exit"
        echo ""
        print_line
        echo -ne "  ${BOLD}Enter choice: ${NC}"
        local choice
        read -r choice </dev/tty || choice=""

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
            24) sanitize_config_for_schema | sed 's/^/  /'; msg_ok "Cleaned"; wait_and_return 3 ;;
            25)
                if is_docker_mode; then
                    convert_urls_for_docker_mode | sed 's/^/  /'
                    msg_ok "Converted, please restart Gateway"
                    confirm "Restart now?" && manage_service restart >/dev/null 2>&1
                else
                    msg_warn "Not Docker mode, no conversion needed"
                fi
                wait_and_return 3 ;;
            0)  echo ""; echo -e "${GREEN}${BOLD}Goodbye!${NC}"; echo ""; exit 0 ;;
            *)  msg_warn "Invalid: ${choice}"; sleep 1 ;;
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
