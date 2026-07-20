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
LOBSTER="🦞"; DOCKER="🐳"; PLUGIN="🔌"

OPENCLAW_PORT=18789
OPENCLAW_SERVICE="openclaw"
OPENCLAW_SERVICE_CANDIDATES=("openclaw" "openclaw-gateway")
OPENCLAW_CONFIG_DIR="$HOME/.openclaw"
OPENCLAW_JSON="$OPENCLAW_CONFIG_DIR/openclaw.json"
OPENCLAW_LOG_DIR="$OPENCLAW_CONFIG_DIR/logs"
SCRIPT_VERSION="v1.0.1"
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

_NVM_LATEST=""
_NODE_LTS_VERSIONS=""
_NODE_LATEST_VERSION=""

# ============================================================
# 修复：使用正确的数据结构存储配置
# ============================================================
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

press_any_key() {
    local wait_time="${1:-0}"
    echo ""
    if [[ "$wait_time" -gt 0 ]]; then
        echo -ne "${DIM}${wait_time} 秒后自动返回...${NC}"
        sleep "$wait_time"
        echo ""
    else
        read -rp "$(echo -e "${DIM}按 Enter 返回主菜单...${NC}")" _ </dev/tty 2>/dev/null || true
    fi
}

# 快速返回（用于简单操作）
auto_return() {
    local delay="${1:-2}"
    echo ""
    echo -ne "${DIM}${delay} 秒后自动返回...${NC}"
    local i=0
    while (( i < delay )); do
        sleep 1
        ((i++))
    done
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

safe_run() {
    local desc="$1"; shift
    if "$@" >> "$LOG_FILE" 2>&1; then
        msg_ok "$desc"; return 0
    else
        msg_warn "$desc 失败 (详见 $LOG_FILE)"; return 1
    fi
}

is_openclaw_installed() {
    has_cmd openclaw || docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"
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
        # shellcheck source=/dev/null
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
        *)              ARCH_LABEL="$ARCH (未知)"     ;;
    esac
}

print_sysinfo() {
    detect_system
    echo -e "${CYAN}${BOLD}系统信息摘要${NC}"
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
    if [[ -n "${G_DEFAULT_PROVIDER:-}" ]]; then
        echo -e "  ${BOLD}默认 AI${NC}     : ${GREEN}${G_DEFAULT_PROVIDER}${NC} → ${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
    fi
    print_line
}

_detect_deploy_mode() {
    if has_cmd openclaw; then
        echo "本地安装 (npm)"
    elif docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        echo "Docker 容器"
    else
        echo "未部署"
    fi
}

# ============================================================
# 修复：正确的配置文件读取
# ============================================================
load_config_from_file() {
    local cfg="$OPENCLAW_JSON"
    [[ ! -f "$cfg" ]] && return 0
    
    if has_cmd python3; then
        local result
        result=$(python3 - "$cfg" << 'PYEOF' 2>/dev/null
import json
import sys

try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
except:
    sys.exit(0)

# 读取默认 Provider
dp = cfg.get("defaultProvider", "")
if not dp:
    # 尝试从 agents.defaults.model.primary 获取
    agents = cfg.get("agents", {})
    defaults = agents.get("defaults", {})
    model = defaults.get("model", {})
    primary = model.get("primary", "")
    if primary and "/" in primary:
        dp = primary.split("/")[0]

if dp:
    print(f'G_DEFAULT_PROVIDER="{dp}"')

# 读取内置 Provider 的 API Key
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

# 读取自定义 Provider
models_cfg = cfg.get("models", {})
providers = models_cfg.get("providers", {})

for name, p_cfg in providers.items():
    if not isinstance(p_cfg, dict):
        continue
    
    base_url = p_cfg.get("baseUrl", "")
    api_key = p_cfg.get("apiKey", "")
    api_type = p_cfg.get("api", "")
    
    # 获取模型列表
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

PYEOF
)
        [[ -n "${result:-}" ]] && eval "$result" 2>/dev/null || true
    fi
}

# ============================================================
# 修复：正确的配置文件写入（核心修复！）
# ============================================================
write_config_to_file() {
    local cfg="$OPENCLAW_JSON"
    mkdir -p "$OPENCLAW_CONFIG_DIR"
    
    if has_cmd python3; then
        # 使用 Python 安全地处理 JSON
        python3 - "$cfg" << PYEOF
import json
import sys
import os

cfg_path = sys.argv[1]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)

# 加载现有配置
try:
    with open(cfg_path, 'r') as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

# ============================================================
# 关键修复 1: 确保 gateway.mode 存在
# ============================================================
config.setdefault("gateway", {})
if not config["gateway"].get("mode"):
    config["gateway"]["mode"] = "local"
config["gateway"].setdefault("bind", "localhost")

# ============================================================
# 关键修复 2: 确保 models.mode = "merge"
# ============================================================
config.setdefault("models", {})
config["models"]["mode"] = "merge"
config["models"].setdefault("providers", {})

# 读取环境变量中的配置
env = os.environ

# 处理内置 Provider
for provider in ["anthropic", "openai", "google", "deepseek", "groq", "mistral"]:
    key_var = f"OCKEY_{provider.upper()}"
    model_var = f"OCMODEL_{provider.upper()}"
    
    key = env.get(key_var, "")
    models = env.get(model_var, "")
    
    if key:
        config.setdefault(provider, {})["apiKey"] = key
    if models:
        config.setdefault(provider, {})
        config[provider]["models"] = models
        config[provider]["model"] = models.split(",")[0]

# 处理自定义 Provider
custom_providers = {}
for k, v in env.items():
    if k.startswith("OCURL_") and v:
        name = k[6:].lower()
        custom_providers.setdefault(name, {})["baseUrl"] = v
    elif k.startswith("OCKEY_") and v and k[6:].lower() not in ["anthropic", "openai", "google", "deepseek", "groq", "mistral"]:
        name = k[6:].lower()
        custom_providers.setdefault(name, {})["apiKey"] = v
    elif k.startswith("OCTYPE_") and v:
        name = k[7:].lower()
        custom_providers.setdefault(name, {})["api"] = v
    elif k.startswith("OCMODEL_") and v and k[8:].lower() not in ["anthropic", "openai", "google", "deepseek", "groq", "mistral"]:
        name = k[8:].lower()
        custom_providers.setdefault(name, {})["models_str"] = v

for name, p_cfg in custom_providers.items():
    if not p_cfg.get("baseUrl"):
        continue
    
    provider_config = {
        "baseUrl": p_cfg["baseUrl"],
        "apiKey": p_cfg.get("apiKey", "none"),
        # ============================================================
        # 关键修复 3: 确保 api 字段存在
        # ============================================================
        "api": p_cfg.get("api", "openai-completions"),
        "models": []
    }
    
    # 构建模型列表
    models_str = p_cfg.get("models_str", "")
    if models_str:
        for model_id in models_str.split(","):
            model_id = model_id.strip()
            if model_id:
                provider_config["models"].append({
                    "id": model_id,
                    "name": model_id,
                    "reasoning": False,
                    "input": ["text"],
                    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                    "contextWindow": 128000,
                    "maxTokens": 8192
                })
    
    config["models"]["providers"][name] = provider_config

# ============================================================
# 关键修复 4: 设置默认模型
# ============================================================
default_provider = env.get("OC_DEFAULT", "")
if default_provider:
    config["defaultProvider"] = default_provider
    
    # 同时设置 agents.defaults.model.primary
    config.setdefault("agents", {})
    config["agents"].setdefault("defaults", {})
    config["agents"]["defaults"].setdefault("model", {})
    config["agents"]["defaults"].setdefault("maxConcurrent", 4)
    
    # 获取该 Provider 的第一个模型
    first_model = ""
    if default_provider in config["models"]["providers"]:
        models_list = config["models"]["providers"][default_provider].get("models", [])
        if models_list:
            first_model = models_list[0].get("id", "")
    elif default_provider in config:
        first_model = config[default_provider].get("model", "")
    
    if first_model:
        config["agents"]["defaults"]["model"]["primary"] = f"{default_provider}/{first_model}"

# 写入配置
with open(cfg_path, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

print("OK")
PYEOF
        msg_ok "配置已写入 $cfg"
    else
        # Bash 回退方案（确保关键字段存在）
        _write_config_bash_fallback
    fi
    
    chmod 600 "$cfg"
}

_write_config_bash_fallback() {
    local cfg="$OPENCLAW_JSON"
    local tmp_file="${cfg}.tmp.$$"
    
    # 如果配置文件存在且有效，尝试合并
    if [[ -f "$cfg" ]] && grep -q '"gateway"' "$cfg" 2>/dev/null; then
        # 简单追加/修复关键字段
        if ! grep -q '"mode"' "$cfg"; then
            sed -i 's/"gateway"\s*:\s*{/"gateway": { "mode": "local",/' "$cfg" 2>/dev/null || true
        fi
        return
    fi
    
    # 创建新配置
    cat > "$tmp_file" << 'EOF'
{
  "gateway": {
    "mode": "local",
    "bind": "localhost"
  },
  "models": {
    "mode": "merge",
    "providers": {}
  },
  "agents": {
    "defaults": {
      "maxConcurrent": 4,
      "model": {}
    }
  }
}
EOF
    mv "$tmp_file" "$cfg"
    msg_ok "基础配置已创建"
}

# ============================================================
# 修复：通过 openclaw CLI 写入配置
# ============================================================
write_config_via_openclaw() {
    is_openclaw_installed || return 1
    local any=false
    
    _oc() { 
        if openclaw_cmd config set "$1" "$2" 2>/dev/null; then
            any=true
        fi
    }
    
    # 关键修复：确保 gateway.mode 设置
    _oc "gateway.mode" "local"
    _oc "models.mode" "merge"
    
    # 内置 Provider
    for p in anthropic openai google deepseek groq mistral; do
        [[ -n "${G_API_KEYS[$p]:-}" ]] && _oc "${p}.apiKey" "${G_API_KEYS[$p]}"
        if [[ -n "${G_API_MODELS[$p]:-}" ]]; then
            _oc "${p}.model" "${G_API_MODELS[$p]%%,*}"
            _oc "${p}.models" "${G_API_MODELS[$p]}"
        fi
    done
    
    # 设置默认 Provider
    if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
        _oc "defaultProvider" "$G_DEFAULT_PROVIDER"
        
        # 设置默认模型
        local first_model="${G_API_MODELS[$G_DEFAULT_PROVIDER]%%,*}"
        if [[ -n "$first_model" ]]; then
            _oc "agents.defaults.model.primary" "${G_DEFAULT_PROVIDER}/${first_model}"
        fi
    fi
    
    $any && return 0 || return 1
}

# ============================================================
# 修复：配置自定义 API（核心功能修复！）
# ============================================================
configure_custom_api() {
    msg_title "🔧 配置自定义 API Provider"
    
    echo -e "${CYAN}${BOLD}━━━ 自定义 OpenAI 兼容 API 配置 ━━━${NC}"
    echo ""
    echo -e "${YELLOW}${WARN} 重要提示：${NC}"
    echo -e "  • 必须正确设置 ${BOLD}api${NC} 字段，否则会报 'undefined' 错误"
    echo -e "  • 必须设置 ${BOLD}models.mode${NC} 为 'merge'"
    echo -e "  • 必须设置 ${BOLD}默认模型${NC} 才能使用"
    echo ""
    
    # Provider 名称
    echo -ne "${CYAN}Provider 名称 (例如: deepseek, ollama, lmstudio, my-api): ${NC}"
    local provider_name
    read -r provider_name </dev/tty || provider_name=""
    provider_name=${provider_name:-custom}
    provider_name=$(echo "$provider_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    
    # Base URL
    echo ""
    echo -e "${DIM}常见 URL 示例:${NC}"
    echo -e "  ${DIM}• DeepSeek:   https://api.deepseek.com/v1${NC}"
    echo -e "  ${DIM}• Ollama:     http://127.0.0.1:11434 (注意：不加 /v1)${NC}"
    echo -e "  ${DIM}• LM Studio:  http://127.0.0.1:1234/v1${NC}"
    echo -e "  ${DIM}• vLLM:       http://127.0.0.1:8000/v1${NC}"
    echo ""
    echo -ne "${CYAN}API Base URL: ${NC}"
    local base_url
    read -r base_url </dev/tty || base_url=""
    
    if [[ -z "$base_url" ]]; then
        msg_warn "URL 不能为空，已取消"
        return 1
    fi
    
    # API Key
    echo ""
    echo -ne "${CYAN}API Key (本地服务输入 'local' 或 'none'): ${NC}"
    local api_key
    read -rs api_key </dev/tty || api_key=""
    echo ""
    api_key=${api_key:-local}
    
    # API 类型（关键！）
    echo ""
    echo -e "${CYAN}${BOLD}选择 API 类型（关键！）:${NC}"
    echo -e "  ${BOLD}1)${NC} openai-completions  ${DIM}(大多数 OpenAI 兼容 API: DeepSeek, LM Studio, vLLM 等)${NC}"
    echo -e "  ${BOLD}2)${NC} openai-responses    ${DIM}(OpenAI Responses API /v1/responses)${NC}"
    echo -e "  ${BOLD}3)${NC} ollama              ${DIM}(本地 Ollama，使用原生 API，不加 /v1)${NC}"
    echo -e "  ${BOLD}4)${NC} anthropic-messages  ${DIM}(Anthropic Claude 兼容 API)${NC}"
    echo ""
    echo -ne "${CYAN}选择 [1-4] (默认: 1): ${NC}"
    local api_choice
    read -r api_choice </dev/tty || api_choice="1"
    
    local api_type
    case "$api_choice" in
        2) api_type="openai-responses" ;;
        3) api_type="ollama" ;;
        4) api_type="anthropic-messages" ;;
        *) api_type="openai-completions" ;;
    esac
    
    # 模型 ID
    echo ""
    echo -e "${DIM}模型 ID 示例:${NC}"
    echo -e "  ${DIM}• DeepSeek: deepseek-chat, deepseek-reasoner${NC}"
    echo -e "  ${DIM}• Ollama:   qwen3:32b, llama3.1:8b${NC}"
    echo -e "  ${DIM}• 通用:     gpt-4o, claude-3-opus${NC}"
    echo ""
    echo -ne "${CYAN}模型 ID (多个用逗号分隔): ${NC}"
    local model_ids
    read -r model_ids </dev/tty || model_ids=""
    
    if [[ -z "$model_ids" ]]; then
        msg_warn "模型 ID 不能为空，已取消"
        return 1
    fi
    
    # 保存配置
    G_API_URLS["$provider_name"]="$base_url"
    G_API_KEYS["$provider_name"]="$api_key"
    G_API_TYPES["$provider_name"]="$api_type"
    G_API_MODELS["$provider_name"]="$model_ids"
    
    # 设置为默认 Provider
    echo ""
    if [[ -z "$G_DEFAULT_PROVIDER" ]] || confirm "设置 ${provider_name} 为默认 Provider?"; then
        G_DEFAULT_PROVIDER="$provider_name"
        msg_ok "已设置 ${provider_name} 为默认 Provider"
    fi
    
    # 写入配置文件
    echo ""
    msg_step "写入配置..."
    _write_custom_provider_config "$provider_name"
    
    # 显示配置摘要
    echo ""
    echo -e "${GREEN}${BOLD}✅ 自定义 API 配置完成${NC}"
    print_line
    echo -e "  ${BOLD}Provider:${NC}    $provider_name"
    echo -e "  ${BOLD}Base URL:${NC}    $base_url"
    echo -e "  ${BOLD}API Type:${NC}    ${CYAN}$api_type${NC}"
    echo -e "  ${BOLD}Models:${NC}      $model_ids"
    echo -e "  ${BOLD}默认模型:${NC}    ${provider_name}/${model_ids%%,*}"
    print_line
    
    return 0
}

_write_custom_provider_config() {
    local provider_name="$1"
    local cfg="$OPENCLAW_JSON"
    
    mkdir -p "$OPENCLAW_CONFIG_DIR"
    
    if has_cmd python3; then
        local base_url="${G_API_URLS[$provider_name]:-}"
        local api_key="${G_API_KEYS[$provider_name]:-local}"
        local api_type="${G_API_TYPES[$provider_name]:-openai-completions}"
        local models_str="${G_API_MODELS[$provider_name]:-}"
        local default_provider="${G_DEFAULT_PROVIDER:-}"
        
        python3 - "$cfg" "$provider_name" "$base_url" "$api_key" "$api_type" "$models_str" "$default_provider" << 'PYEOF'
import json
import sys
import os

cfg_path = sys.argv[1]
provider_name = sys.argv[2]
base_url = sys.argv[3]
api_key = sys.argv[4]
api_type = sys.argv[5]
models_str = sys.argv[6]
default_provider = sys.argv[7]

os.makedirs(os.path.dirname(cfg_path), exist_ok=True)

# 加载或创建配置
try:
    with open(cfg_path, 'r') as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

# 关键修复 1: gateway.mode
config.setdefault("gateway", {})
config["gateway"].setdefault("mode", "local")
config["gateway"].setdefault("bind", "localhost")

# 关键修复 2: models.mode = "merge"
config.setdefault("models", {})
config["models"]["mode"] = "merge"
config["models"].setdefault("providers", {})

# 构建模型列表
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

# 关键修复 3: 确保 api 字段存在
config["models"]["providers"][provider_name] = {
    "baseUrl": base_url,
    "apiKey": api_key,
    "api": api_type,  # 这是关键！
    "models": models_list
}

# 关键修复 4: 设置默认模型
if default_provider:
    config["defaultProvider"] = default_provider
    
    config.setdefault("agents", {})
    config["agents"].setdefault("defaults", {})
    config["agents"]["defaults"].setdefault("maxConcurrent", 4)
    config["agents"]["defaults"].setdefault("model", {})
    
    if models_list:
        first_model = models_list[0]["id"]
        config["agents"]["defaults"]["model"]["primary"] = f"{default_provider}/{first_model}"

# 写入
with open(cfg_path, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

print("配置写入成功")
PYEOF
        msg_ok "配置已写入"
    else
        # Bash 回退
        _write_custom_provider_bash "$provider_name"
    fi
    
    chmod 600 "$cfg"
}

_write_custom_provider_bash() {
    local provider_name="$1"
    local cfg="$OPENCLAW_JSON"
    local base_url="${G_API_URLS[$provider_name]:-}"
    local api_key="${G_API_KEYS[$provider_name]:-local}"
    local api_type="${G_API_TYPES[$provider_name]:-openai-completions}"
    local models_str="${G_API_MODELS[$provider_name]:-}"
    local first_model="${models_str%%,*}"
    
    # 构建模型 JSON 数组
    local models_json="["
    local first=true
    IFS=',' read -ra model_arr <<< "$models_str"
    for m in "${model_arr[@]}"; do
        m=$(echo "$m" | xargs)  # trim
        [[ -z "$m" ]] && continue
        $first || models_json+=","
        first=false
        models_json+="{\"id\":\"$m\",\"name\":\"$m\",\"reasoning\":false,\"input\":[\"text\"],\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0},\"contextWindow\":128000,\"maxTokens\":8192}"
    done
    models_json+="]"
    
    cat > "$cfg" << EOF
{
  "gateway": {
    "mode": "local",
    "bind": "localhost"
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
  },
  "agents": {
    "defaults": {
      "maxConcurrent": 4,
      "model": {
        "primary": "${provider_name}/${first_model}"
      }
    }
  },
  "defaultProvider": "${provider_name}"
}
EOF
    msg_ok "配置已创建 (Bash)"
}

# ============================================================
# 修复：验证配置（新增功能）
# ============================================================
validate_config() {
    local cfg="$OPENCLAW_JSON"
    local errors=0
    
    msg_step "验证配置文件..."
    
    if [[ ! -f "$cfg" ]]; then
        msg_fail "配置文件不存在: $cfg"
        echo -e "  ${DIM}运行: openclaw setup 或使用本脚本安装${NC}"
        return 1
    fi
    
    if has_cmd python3; then
        local result
        result=$(python3 - "$cfg" << 'PYEOF' 2>&1
import json
import sys

cfg_path = sys.argv[1]
errors = []
warnings = []

try:
    with open(cfg_path, 'r') as f:
        config = json.load(f)
except json.JSONDecodeError as e:
    print(f"FAIL:JSON 解析错误: {e}")
    sys.exit(1)
except Exception as e:
    print(f"FAIL:无法读取配置: {e}")
    sys.exit(1)

# 检查 gateway.mode（必须！）
gateway = config.get("gateway", {})
if not gateway.get("mode"):
    errors.append("gateway.mode 未设置 - Gateway 无法启动，会报 'Missing config'")
else:
    print(f"PASS:gateway.mode = {gateway['mode']}")

# 检查 models.mode
models = config.get("models", {})
if models.get("mode") != "merge":
    warnings.append(f"models.mode = '{models.get('mode', '未设置')}' - 建议设置为 'merge' 以启用自定义 Provider")
else:
    print("PASS:models.mode = merge")

# 检查自定义 providers
providers = models.get("providers", {})
if providers:
    for name, p_cfg in providers.items():
        if not isinstance(p_cfg, dict):
            continue
        
        # 检查 api 字段（关键！）
        if not p_cfg.get("api"):
            errors.append(f"Provider '{name}' 缺少 'api' 字段 - 会导致 'Unhandled API: undefined' 错误")
        else:
            print(f"PASS:Provider '{name}' api = {p_cfg['api']}")
        
        # 检查 baseUrl
        if not p_cfg.get("baseUrl"):
            errors.append(f"Provider '{name}' 缺少 'baseUrl'")
        
        # 检查 models
        model_list = p_cfg.get("models", [])
        if not model_list:
            warnings.append(f"Provider '{name}' 没有定义模型")
        else:
            print(f"PASS:Provider '{name}' 定义了 {len(model_list)} 个模型")

# 检查默认模型
agents = config.get("agents", {})
defaults = agents.get("defaults", {})
model = defaults.get("model", {})
primary = model.get("primary", "")

if primary:
    print(f"PASS:默认模型 = {primary}")
    if "/" not in primary:
        warnings.append(f"默认模型格式应为 'provider/model-id'，当前: {primary}")
else:
    warnings.append("未设置 agents.defaults.model.primary - 模型可能不会被使用")

# 输出结果
for w in warnings:
    print(f"WARN:{w}")

for e in errors:
    print(f"FAIL:{e}")

if errors:
    sys.exit(1)
PYEOF
)
        # 解析输出
        echo "$result" | while IFS= read -r line; do
            if [[ "$line" == PASS:* ]]; then
                msg_ok "${line#PASS:}"
            elif [[ "$line" == WARN:* ]]; then
                msg_warn "${line#WARN:}"
            elif [[ "$line" == FAIL:* ]]; then
                msg_fail "${line#FAIL:}"
                ((errors++))
            fi
        done
        
        if echo "$result" | grep -q "^FAIL:"; then
            echo ""
            msg_fail "配置存在错误，请修复后重试"
            return 1
        else
            echo ""
            msg_ok "配置验证通过"
            return 0
        fi
    else
        # 简单检查
        if grep -q '"mode"' "$cfg" && grep -q '"gateway"' "$cfg"; then
            msg_ok "基本检查通过（建议安装 python3 进行完整验证）"
            return 0
        else
            msg_fail "配置缺少必要字段"
            return 1
        fi
    fi
}

# ============================================================
# 修复：确保最小配置存在
# ============================================================
ensure_minimal_config() {
    local cfg="$OPENCLAW_JSON"
    
    mkdir -p "$OPENCLAW_CONFIG_DIR"
    
    # 如果配置不存在或无效，创建最小配置
    if [[ ! -f "$cfg" ]]; then
        msg_info "创建最小启动配置..."
        _create_minimal_config
        return
    fi
    
    # 检查关键字段
    if has_cmd python3; then
        python3 - "$cfg" << 'PYEOF'
import json
import sys

cfg_path = sys.argv[1]

try:
    with open(cfg_path, 'r') as f:
        config = json.load(f)
except:
    config = {}

modified = False

# 确保 gateway.mode 存在
if not config.get("gateway", {}).get("mode"):
    config.setdefault("gateway", {})["mode"] = "local"
    config["gateway"].setdefault("bind", "localhost")
    modified = True

# 确保 models.mode 存在
if config.get("models", {}).get("mode") != "merge":
    config.setdefault("models", {})["mode"] = "merge"
    config["models"].setdefault("providers", {})
    modified = True

if modified:
    with open(cfg_path, 'w') as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    print("FIXED")
else:
    print("OK")
PYEOF
        local result=$?
        if [[ $result -eq 0 ]]; then
            msg_ok "配置检查完成"
        fi
    else
        # 检查是否有 gateway.mode
        if ! grep -q '"mode"' "$cfg" 2>/dev/null; then
            msg_warn "配置可能缺少 gateway.mode，尝试修复..."
            _create_minimal_config
        fi
    fi
}

_create_minimal_config() {
    local cfg="$OPENCLAW_JSON"
    
    cat > "$cfg" << 'EOF'
{
  "gateway": {
    "mode": "local",
    "bind": "localhost"
  },
  "models": {
    "mode": "merge",
    "providers": {}
  },
  "agents": {
    "defaults": {
      "maxConcurrent": 4,
      "model": {}
    }
  }
}
EOF
    chmod 600 "$cfg"
    msg_ok "最小配置已创建"
}

# ============================================================
# 配置局域网访问
# ============================================================
configure_lan_access() {
    msg_title "${LOBSTER} 配置局域网访问"

    if ! is_openclaw_installed; then
        msg_fail "OpenClaw 未安装，请先安装"
        auto_return 2; return 0
    fi

    local cfg_file="$OPENCLAW_JSON"

    if has_cmd openclaw; then
        local real_cfg
        real_cfg=$(openclaw config file 2>/dev/null | tr -d '\n' || echo "")
        [[ -n "$real_cfg" && -f "$real_cfg" ]] && cfg_file="$real_cfg"
    fi

    echo -e "${CYAN}配置文件路径:${NC} ${DIM}${cfg_file}${NC}"
    echo ""

    echo -e "${CYAN}当前 gateway 配置:${NC}"
    if [[ -f "$cfg_file" ]] && has_cmd python3; then
        python3 - "$cfg_file" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    gw = cfg.get("gateway", {})
    print(f"  bind       : {gw.get('bind', '未设置')}")
    print(f"  mode       : {gw.get('mode', '未设置')}")
    print(f"  auth.mode  : {gw.get('auth', {}).get('mode', '未设置')}")
    ui = gw.get("controlUi", {})
    print(f"  controlUi  : {json.dumps(ui, ensure_ascii=False)}")
except Exception as e:
    print(f"  读取失败: {e}")
PYEOF
    else
        echo -e "  ${DIM}无法读取（文件不存在或无 python3）${NC}"
    fi

    echo ""
    print_line
    echo -e "${BOLD}将要执行的修改:${NC}"
    echo -e "  ${CYAN}gateway.mode${NC} → ${GREEN}\"local\"${NC}"
    echo -e "  ${CYAN}gateway.bind${NC} → ${GREEN}\"lan\"${NC}"
    echo -e "  ${CYAN}gateway.auth.token${NC} → ${GREEN}自动生成${NC}"
    echo -e "  ${CYAN}gateway.controlUi.allowInsecureAuth${NC} → ${GREEN}true${NC}"
    echo -e "  ${CYAN}gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback${NC} → ${GREEN}true${NC}"
    echo -e "  ${CYAN}gateway.controlUi.dangerouslyDisableDeviceAuth${NC} → ${GREEN}true${NC}"
    echo ""
    echo -e "${RED}${WARN} 安全提示: 启用局域网访问后请勿将端口暴露到公网！${NC}"
    echo ""

    if ! confirm "确认应用局域网配置?"; then
        msg_info "已取消"
        auto_return 2; return 0
    fi

    if [[ -f "$cfg_file" ]]; then
        local backup="${cfg_file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$cfg_file" "$backup"
        msg_ok "已备份到: $backup"
    fi

    mkdir -p "$(dirname "$cfg_file")"
    local gw_token=""
    if has_cmd python3; then
        local py_result
        py_result=$(python3 - "$cfg_file" << 'PYEOF'
import json, sys, os, secrets

cfg_path = sys.argv[1]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)

try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

gw = cfg.setdefault("gateway", {})
gw.setdefault("mode", "local")
gw["bind"] = "lan"

auth = gw.setdefault("auth", {})
if not auth.get("token"):
    auth["token"] = secrets.token_hex(24)
auth.setdefault("mode", "token")

gw.setdefault("controlUi", {}).update({
    "allowInsecureAuth": True,
    "dangerouslyAllowHostHeaderOriginFallback": True,
    "dangerouslyDisableDeviceAuth": True
})

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"TOKEN={auth['token']}")
PYEOF
)
        if [[ $? -eq 0 ]]; then
            gw_token=$(echo "$py_result" | grep '^TOKEN=' | cut -d= -f2)
            msg_ok "局域网配置已写入"
        else
            msg_fail "配置写入失败"
            auto_return 2; return 0
        fi
    else
        gw_token=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null | tr -d '\n' || date +%s%N)
        _write_lan_config_bash "$cfg_file" "$gw_token"
    fi

    echo ""
    msg_step "重启 Gateway..."
    if has_cmd openclaw; then
        openclaw gateway restart 2>&1 | tail -3 || true
    elif docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        docker exec "$DOCKER_CONTAINER" openclaw gateway restart 2>&1 | tail -3 || true
        docker restart "$DOCKER_CONTAINER" 2>/dev/null || true
    fi

    echo -ne "  等待服务就绪"
    local i=0
    while (( i < 10 )); do
        sleep 1; echo -ne "."
        if curl -s --max-time 2 "http://127.0.0.1:${OPENCLAW_PORT}/health" &>/dev/null; then
            break
        fi
        ((i++))
    done
    echo ""

    echo ""
    msg_step "验证局域网配置..."
    if has_cmd openclaw; then
        local status_out
        status_out=$(openclaw gateway status 2>/dev/null || echo "")
        echo "$status_out" | sed 's/^/  /'
        echo "$status_out" | grep -qi "lan\|0\.0\.0\.0" && { echo ""; msg_ok "局域网模式已生效！"; } || { echo ""; msg_warn "请手动确认: openclaw gateway status"; }
    fi

    local local_ip; local_ip=$(get_local_ip)
    local token_qs=""
    [[ -n "$gw_token" ]] && token_qs="?token=${gw_token}"
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║             ${LOBSTER} 局域网访问信息                          ║${NC}"
    echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}本机:${NC}    ${CYAN}http://127.0.0.1:${OPENCLAW_PORT}${NC}                      ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}局域网:${NC}  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${token_qs}${NC}"
    [[ -n "$gw_token" ]] && echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}Token:${NC}   ${YELLOW}${gw_token}${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${RED}⚠️  勿将端口暴露到公网！${NC}                              ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"

    log "LAN access configured"
    auto_return 3; return 0
}

_write_lan_config_bash() {
    local cfg_file="$1" token="$2"
    if [[ ! -f "$cfg_file" ]]; then
        cat > "$cfg_file" << EOF
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": { "mode": "token", "token": "${token}" },
    "controlUi": {
      "allowInsecureAuth": true,
      "dangerouslyAllowHostHeaderOriginFallback": true,
      "dangerouslyDisableDeviceAuth": true
    }
  },
  "models": {
    "mode": "merge",
    "providers": {}
  }
}
EOF
        msg_ok "配置文件已创建"
    else
        msg_warn "无 python3，请手动编辑 $cfg_file"
    fi
}

# ============================================================
# 插件安装
# ============================================================
install_plugins() {
    msg_title "${PLUGIN} 安装消息平台插件"

    if ! is_openclaw_installed; then
        msg_fail "OpenClaw 未安装，请先安装"
        auto_return 2; return 0
    fi

    echo -e "${CYAN}可用插件:${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} ${LOBSTER} 微信插件"
    echo -e "     ${DIM}包名: ${WECHAT_PLUGIN_PKG}${NC}"
    echo ""
    echo -e "  ${BOLD}2)${NC} ${LOBSTER} 飞书 / Lark 插件"
    echo -e "     ${DIM}包名: ${FEISHU_PLUGIN_PKG}${NC}"
    echo ""
    echo -e "  ${BOLD}3)${NC} 安装全部插件"
    echo -e "  ${BOLD}0)${NC} 返回"
    echo ""
    echo -ne "${BOLD}请选择 [0-3]: ${NC}"
    local choice
    read -r choice </dev/tty || choice="0"

    case "$choice" in
        1) _install_single_plugin "微信" "$WECHAT_PLUGIN_PKG" ;;
        2) _install_single_plugin "飞书" "$FEISHU_PLUGIN_PKG" ;;
        3)
            _install_single_plugin "微信" "$WECHAT_PLUGIN_PKG"
            _install_single_plugin "飞书" "$FEISHU_PLUGIN_PKG"
            ;;
        0) return 0 ;;
        *) msg_warn "无效选项" ;;
    esac

    auto_return 3; return 0
}

_install_single_plugin() {
    local name="$1" pkg="$2"
    echo ""
    msg_step "安装 ${name} 插件 (${pkg})..."
    echo -e "${DIM}执行: openclaw plugins install \"${pkg}\" --force${NC}"
    echo ""

    if openclaw_cmd plugins install "${pkg}" --force 2>&1 | tee -a "$LOG_FILE"; then
        echo ""
        msg_ok "${name} 插件安装成功！"
        echo ""
        echo -e "${CYAN}下一步:${NC}"
        echo -e "  ${DIM}openclaw channels login${NC}"
        echo -e "  ${DIM}openclaw channels status${NC}"
        echo -e "  ${DIM}openclaw gateway restart${NC}"
    else
        echo ""
        msg_fail "${name} 插件安装失败，详见: $LOG_FILE"
    fi
}

# ============================================================
# Docker 部署
# ============================================================
deploy_docker() {
    msg_title "${DOCKER} Docker 部署 OpenClaw"

    if ! has_cmd docker; then
        msg_warn "未检测到 Docker，正在安装..."
        _install_docker || { auto_return 3; return 0; }
    fi

    echo -e "${CYAN}Docker 版本:${NC} $(docker --version 2>/dev/null || echo '未知')"
    echo ""

    if docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        local container_status
        container_status=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null || echo "unknown")
        echo -e "${CYAN}已有容器 ${DOCKER_CONTAINER}:${NC} ${BOLD}${container_status}${NC}"
        echo ""
        echo -e "  ${BOLD}1)${NC} 启动容器"
        echo -e "  ${BOLD}2)${NC} 停止容器"
        echo -e "  ${BOLD}3)${NC} 重启容器"
        echo -e "  ${BOLD}4)${NC} 删除并重新部署"
        echo -e "  ${BOLD}5)${NC} 查看容器日志"
        echo -e "  ${BOLD}6)${NC} 进入容器 Shell"
        echo -e "  ${BOLD}0)${NC} 返回"
        echo ""
        echo -ne "${BOLD}请选择 [0-6]: ${NC}"
        local dc
        read -r dc </dev/tty || dc="0"

        case "$dc" in
            1) docker start "$DOCKER_CONTAINER" 2>&1 | tail -2 && msg_ok "容器已启动" || msg_fail "启动失败" ;;
            2) docker stop  "$DOCKER_CONTAINER" 2>&1 | tail -2 && msg_ok "容器已停止" || msg_fail "停止失败" ;;
            3) docker restart "$DOCKER_CONTAINER" 2>&1 | tail -2 && msg_ok "容器已重启" || msg_fail "重启失败" ;;
            4) confirm "确认删除并重新部署?" && { docker rm -f "$DOCKER_CONTAINER" 2>/dev/null || true; _docker_run; } ;;
            5) msg_info "按 Ctrl+C 退出"; trap 'echo ""; msg_info "退出"' INT; docker logs -f "$DOCKER_CONTAINER" 2>&1 || true; trap - INT ;;
            6) docker exec -it "$DOCKER_CONTAINER" /bin/sh 2>/dev/null || docker exec -it "$DOCKER_CONTAINER" /bin/bash 2>/dev/null || msg_fail "无法进入" ;;
            0) return 0 ;;
        esac
    else
        echo -e "${CYAN}配置 Docker 部署:${NC}"
        echo ""
        echo -ne "  端口映射 (默认: ${OPENCLAW_PORT}): "
        local port; read -r port </dev/tty || port=""; port=${port:-$OPENCLAW_PORT}
        echo -ne "  数据目录 (默认: ${DOCKER_DATA_DIR}): "
        local data_dir; read -r data_dir </dev/tty || data_dir=""; data_dir=${data_dir:-$DOCKER_DATA_DIR}
        local extra_opts=""
        confirm "  同时启用局域网访问模式?" && extra_opts="--lan"
        mkdir -p "$data_dir"
        _docker_run "$port" "$data_dir" "$extra_opts"
    fi

    auto_return 3; return 0
}

_docker_run() {
    local port="${1:-$OPENCLAW_PORT}"
    local data_dir="${2:-$DOCKER_DATA_DIR}"
    local extra="${3:-}"
    local image="$DOCKER_IMAGE"

    mkdir -p "${data_dir}/.openclaw" "${data_dir}/workspace"
    chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}" 2>/dev/null \
        || sudo chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}" 2>/dev/null || true

    msg_step "拉取最新镜像 (${image})..."
    if docker pull "${image}:latest" 2>&1 | tail -3; then
        msg_ok "镜像拉取成功"
    else
        msg_warn "GHCR 镜像拉取失败，尝试 Docker Hub (${DOCKER_IMAGE_MIRROR})..."
        if docker pull "${DOCKER_IMAGE_MIRROR}:latest" 2>&1 | tail -3; then
            image="$DOCKER_IMAGE_MIRROR"
            msg_ok "镜像拉取成功 (${DOCKER_IMAGE_MIRROR})"
        else
            msg_warn "镜像拉取失败，尝试使用本地缓存..."
        fi
    fi

    # 创建初始配置（关键修复！）
    local container_config="${data_dir}/.openclaw/openclaw.json"
    if [[ ! -f "$container_config" ]]; then
        msg_info "创建初始配置..."
        mkdir -p "${data_dir}/.openclaw"
        cat > "$container_config" << 'EOF'
{
  "gateway": {
    "mode": "local",
    "bind": "localhost"
  },
  "models": {
    "mode": "merge",
    "providers": {}
  }
}
EOF
        chmod 600 "$container_config"
    fi

    msg_step "启动容器..."
    local run_cmd=(
        docker run -d
        --name "$DOCKER_CONTAINER"
        --restart unless-stopped
        -p "${port}:18789"
        -v "${data_dir}/.openclaw:/home/node/.openclaw"
        -v "${data_dir}/workspace:/home/node/workspace"
        --add-host=host.docker.internal:host-gateway
        "${image}:latest"
    )

    if "${run_cmd[@]}" 2>&1 | tail -2; then
        msg_ok "容器 ${DOCKER_CONTAINER} 已启动"

        echo -ne "  等待服务就绪"
        local i=0
        while (( i < 20 )); do
            sleep 1; echo -ne "."
            if curl -s --max-time 2 "http://127.0.0.1:${port}/healthz" &>/dev/null \
               || curl -s --max-time 2 "http://127.0.0.1:${port}" &>/dev/null; then
                break
            fi
            ((i++))
        done
        echo ""

        if [[ "$extra" == "--lan" ]]; then
            msg_step "配置局域网访问..."
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.mode local >/dev/null 2>&1 || true
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.bind lan >/dev/null 2>&1 || true
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.controlUi.allowInsecureAuth true >/dev/null 2>&1 || true
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true >/dev/null 2>&1 || true
            docker exec "$DOCKER_CONTAINER" openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true >/dev/null 2>&1 || true
            docker restart "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
            msg_ok "局域网模式已启用"
        fi

        echo ""
        local local_ip; local_ip=$(get_local_ip)
        echo -e "${GREEN}${BOLD}Docker 部署完成！${NC}"
        echo -e "  ${BOLD}本机:${NC}   ${CYAN}http://127.0.0.1:${port}${NC}"
        echo -e "  ${BOLD}局域网:${NC} ${CYAN}http://${local_ip}:${port}${NC}"
        echo ""
        echo -e "  ${DIM}docker logs ${DOCKER_CONTAINER}${NC}"
        echo -e "  ${DIM}docker exec -it ${DOCKER_CONTAINER} openclaw setup${NC}"

        log "Docker deployed on port $port using ${image}"
    else
        msg_fail "容器启动失败: docker logs ${DOCKER_CONTAINER}"
    fi
}

_install_docker() {
    detect_system
    msg_step "安装 Docker..."
    case "$OS" in
        debian)
            safe_run "apt update"   sudo apt-get update -qq
            safe_run "安装依赖"     sudo apt-get install -y ca-certificates curl gnupg lsb-release
            safe_run "Docker 安装"  bash -c "curl -fsSL https://get.docker.com | sh"
            ;;
        rhel|fedora)
            safe_run "Docker 安装"  bash -c "curl -fsSL https://get.docker.com | sh" ;;
        arch)
            safe_run "安装 Docker"  sudo pacman -S --noconfirm docker ;;
        alpine)
            safe_run "安装 Docker"  sudo apk add docker ;;
        macos)
            msg_info "macOS 请手动安装 Docker Desktop: https://www.docker.com/products/docker-desktop"
            return 1 ;;
        *)
            safe_run "Docker 安装"  bash -c "curl -fsSL https://get.docker.com | sh" ;;
    esac
    case "$SERVICE_MANAGER" in
        systemd) sudo systemctl enable --now docker 2>/dev/null || true; sudo usermod -aG docker "$USER" 2>/dev/null || true ;;
        openrc)  sudo rc-update add docker 2>/dev/null || true; sudo service docker start 2>/dev/null || true ;;
    esac
    if has_cmd docker; then
        msg_ok "Docker 安装成功: $(docker --version)"
        msg_info "可能需要重新登录以使 docker 组权限生效"
        return 0
    else
        msg_fail "Docker 安装失败"; return 1
    fi
}

# ============================================================
# 命令速查
# ============================================================
show_command_reference() {
    msg_title "${LOBSTER} OpenClaw 命令速查"

    local use_docker=false
    docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER" && use_docker=true
    local prefix=""
    $use_docker && prefix="docker exec ${DOCKER_CONTAINER} "

    echo -e "${CYAN}${BOLD}🔧 安装与服务${NC}"; print_line
    _cmd_row "${prefix}openclaw setup"               "首次初始化配置（解决 Missing config）"
    _cmd_row "${prefix}openclaw onboard"             "引导向导"
    _cmd_row "${prefix}openclaw gateway start"       "启动 Gateway"
    _cmd_row "${prefix}openclaw gateway stop"        "停止 Gateway"
    _cmd_row "${prefix}openclaw gateway restart"     "重启 Gateway"
    _cmd_row "${prefix}openclaw gateway status"      "查看 Gateway 状态"
    echo ""

    echo -e "${CYAN}${BOLD}📊 状态与诊断${NC}"; print_line
    _cmd_row "${prefix}openclaw status"              "综合状态概览"
    _cmd_row "${prefix}openclaw health"              "Gateway 健康详情"
    _cmd_row "${prefix}openclaw doctor"              "诊断配置问题"
    _cmd_row "${prefix}openclaw doctor --fix"        "自动修复"
    _cmd_row "${prefix}openclaw logs"                "查看日志"
    echo ""

    echo -e "${CYAN}${BOLD}⚙️  配置管理${NC}"; print_line
    _cmd_row "${prefix}openclaw config get"              "读取配置"
    _cmd_row "${prefix}openclaw config set <path> <val>" "设置配置项"
    _cmd_row "${prefix}openclaw config validate"         "验证配置"
    _cmd_row "${prefix}openclaw config file"             "配置文件路径"
    echo ""

    echo -e "${CYAN}${BOLD}🧠 模型${NC}"; print_line
    _cmd_row "${prefix}openclaw models status"       "模型认证状态"
    _cmd_row "${prefix}openclaw models list"         "可用模型"
    echo ""

    echo -e "${RED}${BOLD}⚠️  常见问题修复${NC}"; print_line
    _cmd_row "openclaw config set gateway.mode local"              "修复 Missing config"
    _cmd_row "openclaw config set models.mode merge"               "启用自定义 Provider"
    _cmd_row "openclaw config set agents.defaults.model.primary X" "设置默认模型"
    echo ""

    auto_return 3; return 0
}

_cmd_row() {
    printf "  ${CYAN}%-52s${NC} ${DIM}%s${NC}\n" "$1" "$2"
}

# ============================================================
# 运行 setup 向导
# ============================================================
run_setup_wizard() {
    msg_title "🔧 OpenClaw 初始化向导 (setup)"

    if ! is_openclaw_installed; then
        msg_fail "OpenClaw 未安装，请先安装"
        auto_return 2; return 0
    fi

    echo -e "${CYAN}${BOLD}关于 openclaw setup${NC}"
    print_line
    echo ""
    echo -e "  ${BOLD}用途:${NC}   完成 Gateway 首次初始化配置"
    echo -e "  ${BOLD}必要性:${NC} Gateway 启动前必须完成，否则持续报:"
    echo -e "          ${RED}Missing config. Run \`openclaw setup\`${NC}"
    echo ""
    print_line
    echo ""

    # 确保最小配置存在
    ensure_minimal_config

    echo -e "${CYAN}当前配置状态:${NC}"
    if [[ -f "$OPENCLAW_JSON" ]] && has_cmd python3; then
        python3 - "$OPENCLAW_JSON" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
    gw = c.get("gateway", {})
    mode = gw.get('mode', '❌ 未设置')
    bind = gw.get('bind', '未设置')
    auth = gw.get("auth", {})
    token_status = '已设置' if auth.get('token') else '未设置'
    print(f"  gateway.mode  : {mode}")
    print(f"  gateway.bind  : {bind}")
    print(f"  gateway.auth  : mode={auth.get('mode','未设置')}  token={token_status}")
    
    models = c.get("models", {})
    print(f"  models.mode   : {models.get('mode', '未设置')}")
    
    providers = models.get("providers", {})
    if providers:
        print(f"  providers     : {', '.join(providers.keys())}")
    
    agents = c.get("agents", {})
    primary = agents.get("defaults", {}).get("model", {}).get("primary")
    if primary:
        print(f"  默认模型      : {primary}")
except Exception as e:
    print(f"  解析失败: {e}")
PYEOF
    else
        echo -e "  ${DIM}配置文件不存在 (${OPENCLAW_JSON})${NC}"
    fi
    echo ""

    echo -e "${YELLOW}${WARN} setup 是交互式向导，请按提示操作${NC}"
    echo ""

    if ! confirm "运行 openclaw setup?"; then
        msg_info "已取消"
        press_any_key; return 0
    fi

    echo ""
    print_line
    echo -e "${GREEN}${BOLD}开始 openclaw setup...${NC}"
    print_line
    echo ""

    if openclaw_cmd setup </dev/tty 2>&1; then
        echo ""
        msg_ok "setup 完成！"
        echo ""
        if confirm "重启 Gateway 使配置生效?"; then
            msg_step "重启 Gateway..."
            service_action restart 2>/dev/null || openclaw_cmd gateway restart 2>/dev/null || true
            sleep 3
            if curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                msg_ok "Gateway 已启动！"
                show_dashboard_info
            else
                msg_warn "Gateway 未响应，请查看: openclaw logs"
            fi
        fi
    else
        echo ""
        msg_warn "setup 退出（可能未完成）"
        echo ""
        echo -e "  ${CYAN}手动修复步骤:${NC}"
        echo -e "  ${DIM}  1. openclaw setup${NC}"
        echo -e "  ${DIM}  2. openclaw config set gateway.mode local${NC}"
        echo -e "  ${DIM}  3. openclaw gateway restart${NC}"
    fi

    auto_return 3; return 0
}

# ============================================================
# 快捷命令
# ============================================================
quick_commands() {
    msg_title "${GEAR} 快捷命令执行"

    if ! is_openclaw_installed; then
        msg_fail "OpenClaw 未安装"
        auto_return 2; return 0
    fi

    echo -e "${CYAN}常用操作:${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC}  openclaw setup           ${DIM}初始化向导（解决 Missing config）${NC}"
    echo -e "  ${BOLD}2)${NC}  openclaw status          ${DIM}综合状态${NC}"
    echo -e "  ${BOLD}3)${NC}  openclaw health          ${DIM}健康详情${NC}"
    echo -e "  ${BOLD}4)${NC}  openclaw doctor --fix    ${DIM}自动修复${NC}"
    echo -e "  ${BOLD}5)${NC}  openclaw logs            ${DIM}查看日志${NC}"
    echo -e "  ${BOLD}6)${NC}  openclaw models status   ${DIM}模型状态${NC}"
    echo -e "  ${BOLD}7)${NC}  openclaw models list     ${DIM}可用模型${NC}"
    echo -e "  ${BOLD}8)${NC}  openclaw config validate ${DIM}验证配置${NC}"
    echo -e "  ${BOLD}9)${NC}  验证本地配置             ${DIM}检查配置文件${NC}"
    echo -e "  ${BOLD}10)${NC} 配置自定义 API           ${DIM}添加自定义 Provider${NC}"
    echo -e "  ${BOLD}0)${NC}  返回"
    echo ""
    echo -ne "${BOLD}请选择: ${NC}"
    local qc
    read -r qc </dev/tty || qc="0"

    echo ""
    case "$qc" in
        1)  openclaw_cmd setup </dev/tty 2>&1 ;;
        2)  openclaw_cmd status ;;
        3)  openclaw_cmd health ;;
        4)  openclaw_cmd doctor --fix ;;
        5)  msg_info "Ctrl+C 退出"; trap 'echo ""; msg_info "退出"' INT; openclaw_cmd logs 2>&1 || true; trap - INT ;;
        6)  openclaw_cmd models status ;;
        7)  openclaw_cmd models list ;;
        8)  openclaw_cmd config validate ;;
        9)  validate_config ;;
        10) configure_custom_api ;;
        0)  return 0 ;;
        *)  msg_warn "无效选项" ;;
    esac

    auto_return 2; return 0
}

# ============================================================
# 模型管理
# ============================================================
get_provider_models() {
    local provider="$1"
    if is_openclaw_installed; then
        local models
        models=$(openclaw_cmd models list --provider "$provider" --json 2>/dev/null \
                 | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | head -30)
        if [[ -n "$models" ]]; then echo "$models"; return; fi
    fi
    case "$provider" in
        anthropic) printf '%s\n' "claude-opus-4-5" "claude-sonnet-4-5" "claude-haiku-3-5" "claude-sonnet-3-7" "claude-haiku-3-0" ;;
        openai)    printf '%s\n' "gpt-4o" "gpt-4o-mini" "gpt-4-turbo" "o1" "o1-mini" "o3-mini" ;;
        google)    printf '%s\n' "gemini-2.5-pro" "gemini-2.5-flash" "gemini-2.0-flash-exp" "gemini-1.5-pro" ;;
        deepseek)  printf '%s\n' "deepseek-chat" "deepseek-reasoner" "deepseek-coder" ;;
        groq)      printf '%s\n' "llama-3.3-70b-versatile" "llama-3.1-8b-instant" "mixtral-8x7b-32768" ;;
        mistral)   printf '%s\n' "mistral-large-latest" "mistral-medium" "mistral-small" ;;
    esac
}

# ============================================================
# 配置 API 密钥（内置 Provider）
# ============================================================
configure_api_keys() {
    msg_title "🔑 配置 LLM API 密钥"
    load_config_from_file
    mkdir -p "$OPENCLAW_CONFIG_DIR"

    [[ ${#G_API_KEYS[@]} -gt 0 ]] && {
        echo -e "${CYAN}已有配置:${NC}"
        for p in anthropic openai google deepseek groq mistral; do
            [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
            local dt=""; [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && dt=" ${GREEN}[默认]${NC}"
            echo -e "  ${BOLD}${p}${NC}: ${DIM}${G_API_KEYS[$p]:0:8}****${NC} → ${G_API_MODELS[$p]%%,*}${dt}"
        done
        # 显示自定义 Provider
        for p in "${!G_API_URLS[@]}"; do
            [[ -z "${G_API_URLS[$p]:-}" ]] && continue
            local dt=""; [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && dt=" ${GREEN}[默认]${NC}"
            echo -e "  ${BOLD}${p}${NC}: ${DIM}${G_API_URLS[$p]}${NC} → ${G_API_MODELS[$p]%%,*}${dt}"
        done
        echo ""; echo -e "${DIM}Enter 保留原值${NC}"; echo ""; }

    echo "  1) Anthropic   2) OpenAI   3) Google   4) DeepSeek"
    echo "  5) Groq        6) Mistral  7) 自定义 API  8) 设默认   0) 保存"; echo ""

    while true; do
        echo -ne "${BOLD}编号(0完成): ${NC}"; local c; read -r c </dev/tty || c="0"
        case "$c" in
            0) break ;;
            1) _cfg_builtin_provider anthropic "sk-ant-..." "claude-sonnet-4-5" ;;
            2) _cfg_builtin_provider openai "sk-..." "gpt-4o" ;;
            3) _cfg_builtin_provider google "" "gemini-2.5-flash" ;;
            4) _cfg_builtin_provider deepseek "sk-..." "deepseek-chat" ;;
            5) _cfg_builtin_provider groq "gsk_..." "llama-3.3-70b-versatile" ;;
            6) _cfg_builtin_provider mistral "" "mistral-large-latest" ;;
            7) configure_custom_api ;;
            8) echo ""; _select_default_provider; echo "" ;;
            *) msg_warn "0-8" ;;
        esac
    done

    if [[ ${#G_API_KEYS[@]} -eq 0 && ${#G_API_URLS[@]} -eq 0 ]]; then
        msg_warn "未配置任何 Provider"
        return 0
    fi

    msg_step "保存配置..."
    
    # 自动选择默认 Provider
    [[ -z "$G_DEFAULT_PROVIDER" ]] && _auto_select_default_provider
    
    # 确保最小配置存在
    ensure_minimal_config
    
    # 写入配置
    if is_openclaw_installed; then
        write_config_via_openclaw 2>/dev/null || write_config_to_file
    else
        write_config_to_file
    fi
    
    echo ""
    _show_config_summary
    
    # 验证配置
    echo ""
    validate_config
    
    return 0
}

_cfg_builtin_provider() {
    local p="$1" hint="$2" rec="$3"
    echo ""
    echo -e "${CYAN}${BOLD}─── ${p} ───${NC}"
    local ek="${G_API_KEYS[$p]:-}"
    [[ -n "$ek" ]] && echo -e "  ${DIM}已有: ${ek:0:8}**** → ${G_API_MODELS[$p]:-}${NC}"
    echo -ne "  Key${hint:+ ($hint)}: "
    local nk
    read -rs nk </dev/tty
    echo ""
    
    if [[ -z "$nk" ]]; then
        if [[ -n "$ek" ]]; then
            msg_info "保留原配置"
        else
            msg_warn "空，跳过"
        fi
        echo ""
        return
    fi
    
    G_API_KEYS["$p"]="$nk"
    
    # 选择模型
    echo -ne "  模型 (默认: $rec): "
    local sm
    read -r sm </dev/tty || sm=""
    sm=${sm:-$rec}
    G_API_MODELS["$p"]="$sm"
    
    msg_ok "${p}: ${sm}"
    
    [[ -z "$G_DEFAULT_PROVIDER" ]] && {
        G_DEFAULT_PROVIDER="$p"
        msg_info "自动设为默认: $p"
    }
    echo ""
}

_select_default_provider() {
    echo -e "${CYAN}设置默认 Provider:${NC}"
    local avail=() i=1
    
    # 内置 Provider
    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        local t=""; [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && t=" ${GREEN}[当前]${NC}"
        echo "  ${i}) ${p} → ${G_API_MODELS[$p]%%,*}${t}"
        avail+=("$p")
        ((i++))
    done
    
    # 自定义 Provider
    for p in "${!G_API_URLS[@]}"; do
        [[ -z "${G_API_URLS[$p]:-}" ]] && continue
        local t=""; [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && t=" ${GREEN}[当前]${NC}"
        echo "  ${i}) ${p} → ${G_API_MODELS[$p]%%,*}${t}"
        avail+=("$p")
        ((i++))
    done
    
    [[ ${#avail[@]} -eq 0 ]] && { msg_warn "无配置"; return; }
    
    echo ""
    echo -ne "  选择: "
    local dc
    read -r dc </dev/tty || dc=""
    
    if [[ "$dc" =~ ^[0-9]+$ ]] && (( dc >= 1 && dc <= ${#avail[@]} )); then
        G_DEFAULT_PROVIDER="${avail[$((dc-1))]}"
        msg_ok "默认: ${G_DEFAULT_PROVIDER}"
    else
        msg_warn "无效选择"
    fi
}

_auto_select_default_provider() {
    # 优先选择自定义 Provider
    for p in "${!G_API_URLS[@]}"; do
        if [[ -n "${G_API_URLS[$p]:-}" ]]; then
            G_DEFAULT_PROVIDER="$p"
            msg_info "自动默认: $p"
            return
        fi
    done
    
    # 然后选择内置 Provider
    for p in anthropic openai deepseek google groq mistral; do
        if [[ -n "${G_API_KEYS[$p]:-}" ]]; then
            G_DEFAULT_PROVIDER="$p"
            msg_info "自动默认: $p"
            return
        fi
    done
}

_show_config_summary() {
    print_line
    echo -e "${BOLD}配置摘要${NC}  默认→${GREEN}${BOLD}${G_DEFAULT_PROVIDER:-未设置}${NC}"
    echo ""
    
    # 内置 Provider
    for p in anthropic openai google deepseek groq mistral; do
        [[ -z "${G_API_KEYS[$p]:-}" ]] && continue
        local t=""; [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && t=" ${GREEN}[默认]${NC}"
        local ms="${G_API_MODELS[$p]:-}"
        echo -e "  ${BOLD}${p}${NC}${t}  ${DIM}${G_API_KEYS[$p]:0:10}****${NC} → ${CYAN}${ms%%,*}${NC}"
    done
    
    # 自定义 Provider
    for p in "${!G_API_URLS[@]}"; do
        [[ -z "${G_API_URLS[$p]:-}" ]] && continue
        local t=""; [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && t=" ${GREEN}[默认]${NC}"
        local ms="${G_API_MODELS[$p]:-}"
        local at="${G_API_TYPES[$p]:-openai-completions}"
        echo -e "  ${BOLD}${p}${NC}${t}  ${DIM}${G_API_URLS[$p]}${NC}"
        echo -e "    api: ${CYAN}${at}${NC} → ${CYAN}${ms%%,*}${NC}"
    done
    
    print_line
}

# ============================================================
# 服务管理
# ============================================================
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

    if ! has_cmd openclaw && docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        case "$action" in
            start)   docker start "$DOCKER_CONTAINER" 2>/dev/null || true ;;
            stop)    docker stop  "$DOCKER_CONTAINER" 2>/dev/null || true ;;
            restart) docker restart "$DOCKER_CONTAINER" 2>/dev/null || true ;;
            status)  docker inspect --format='Status: {{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null
                     docker logs --tail 10 "$DOCKER_CONTAINER" 2>/dev/null ;;
            enable)  msg_info "Docker 已设置 --restart unless-stopped" ;;
        esac
        return 0
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
                status)  openclaw gateway status 2>/dev/null || echo "状态未知" ;;
            esac ;;
    esac
    return 0
}

show_dashboard_info() {
    local local_ip
    local_ip=$(get_local_ip)
    local public_ip
    public_ip=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null \
             || curl -s --max-time 4 https://ifconfig.me 2>/dev/null || echo "无法获取")
    
    [[ -z "$G_DEFAULT_PROVIDER" ]] && load_config_from_file

    local bind_mode="localhost"
    if [[ -f "$OPENCLAW_JSON" ]] && has_cmd python3; then
        bind_mode=$(python3 -c "
import json
try:
    c=json.load(open('$OPENCLAW_JSON'))
    print(c.get('gateway',{}).get('bind','localhost'))
except: print('localhost')
" 2>/dev/null || echo "localhost")
    fi

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║            🎉 OpenClaw 访问信息                          ║${NC}"
    echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}本机:${NC}    ${CYAN}http://127.0.0.1:${OPENCLAW_PORT}${NC}                      ${GREEN}${BOLD}║${NC}"
    if [[ "$bind_mode" == "lan" ]]; then
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}局域网:${NC}  ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${NC} ${GREEN}(已启用)${NC}         ${GREEN}${BOLD}║${NC}"
    else
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}局域网:${NC}  ${DIM}http://${local_ip}:${OPENCLAW_PORT} (需配置LAN)${NC}      ${GREEN}${BOLD}║${NC}"
    fi
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}SSH隧道:${NC} ${YELLOW}ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} user@${public_ip}${NC}  ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}bind:${NC}    ${bind_mode}                                             ${GREEN}${BOLD}║${NC}"
    if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
        local dm="${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
        dm="${dm%%,*}"
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}默认AI:${NC}  ${CYAN}${G_DEFAULT_PROVIDER}${NC} → ${dm}                   ${GREEN}${BOLD}║${NC}"
    fi
    echo -e "${GREEN}${BOLD}║${NC}  ${RED}⚠️  勿将端口直接暴露公网！${NC}                              ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ============================================================
# 安装 OpenClaw
# ============================================================
install_openclaw() {
    msg_title "${ROCKET} 安装 OpenClaw"
    detect_system
    echo -e "${CYAN}环境:${NC} ${BOLD}${OS} ${ARCH_LABEL}${NC}"
    echo ""

    if has_cmd openclaw; then
        local iv
        iv=$(openclaw --version 2>/dev/null || echo "未知")
        msg_warn "已安装 ($iv)"
        confirm "重新安装/升级?" || { return 0; }
    fi

    msg_step "Step 1/5: 系统依赖..."
    case "$OS" in
        debian)
            safe_run "apt update" sudo apt-get update -qq
            safe_run "基础依赖" sudo apt-get install -y curl wget git build-essential ca-certificates gnupg ;;
        rhel|fedora)
            safe_run "更新" bash -c "$UPDATE_CMD"
            safe_run "基础依赖" bash -c "$INSTALL_CMD curl wget git gcc gcc-c++ make" ;;
        arch)
            safe_run "pacman" sudo pacman -Sy --noconfirm
            safe_run "基础依赖" sudo pacman -S --noconfirm curl wget git base-devel ;;
        alpine)
            safe_run "apk update" sudo apk update
            safe_run "基础依赖" sudo apk add curl wget git build-base python3 ;;
        macos)
            has_cmd brew || safe_run "Homebrew" bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            safe_run "基础工具" brew install curl wget git ;;
    esac
    msg_ok "依赖完成"

    msg_step "Step 2/5: Node.js..."
    install_nodejs || { msg_fail "Node.js 失败"; auto_return 3; return 1; }

    msg_step "Step 3/5: 安装 OpenClaw..."
    echo "  1) 官方脚本 [推荐]"
    echo "  2) npm"
    echo "  3) GitHub 源码 (pnpm)"
    echo ""
    echo -ne "${BOLD}选择 [1-3] (默认:1): ${NC}"
    local ic
    read -r ic </dev/tty || ic="1"
    ic=${ic:-1}

    case "$ic" in
        1)
            msg_info "下载官方脚本 (${OPENCLAW_INSTALL_URL})..."
            if curl -fsSL --proto '=https' --tlsv1.2 "$OPENCLAW_INSTALL_URL" | bash >> "$LOG_FILE" 2>&1; then
                msg_ok "官方脚本安装成功"
            else
                msg_warn "官方脚本失败，npm 回退..."
                npm install -g openclaw@latest >> "$LOG_FILE" 2>&1 || true
            fi ;;
        2)
            npm install -g openclaw@latest 2>&1 | tee -a "$LOG_FILE" || true ;;
        3)
            echo -ne "${BOLD}仓库 (默认: ${GITHUB_REPO}): ${NC}"
            local repo
            read -r repo </dev/tty || repo=""
            repo=${repo:-"$GITHUB_REPO"}
            local tmp="/tmp/oc_src_$$"
            git clone "$repo" "$tmp" >> "$LOG_FILE" 2>&1 || { msg_fail "clone失败"; auto_return 3; return 1; }
            pushd "$tmp" > /dev/null
            has_cmd pnpm || npm install -g pnpm >> "$LOG_FILE" 2>&1 || true
            pnpm install >> "$LOG_FILE" 2>&1 || true
            pnpm run build >> "$LOG_FILE" 2>&1 || true
            pnpm install -g . >> "$LOG_FILE" 2>&1 || true
            popd > /dev/null
            rm -rf "$tmp" ;;
    esac

    _refresh_node_path
    if ! has_cmd openclaw; then
        msg_fail "安装失败，详见: $LOG_FILE"
        auto_return 3
        return 1
    fi
    msg_ok "OpenClaw $(openclaw --version 2>/dev/null) 安装成功！"

    msg_step "Step 4/5: 配置..."
    
    # 关键修复：确保最小配置存在
    ensure_minimal_config
    
    # 询问配置 API
    if confirm "现在配置 API 密钥？(推荐)"; then
        configure_api_keys
    else
        msg_info "稍后菜单[3]配置"
    fi

    msg_step "Step 5/5: 初始化 Gateway..."

    echo ""
    echo -e "${CYAN}${BOLD}是否运行 openclaw setup 完成初始化?${NC}"
    echo -e "${DIM}setup 会引导你完成更多配置，但 Gateway 已可以启动${NC}"
    echo ""
    if confirm "运行 openclaw setup?"; then
        echo ""
        msg_info "运行 openclaw setup..."
        if openclaw setup </dev/tty; then
            msg_ok "setup 完成"
        else
            msg_warn "setup 未完成，但基本配置已存在"
        fi
    else
        msg_info "跳过 setup"
    fi

    msg_step "启动 Gateway..."
    service_action enable 2>/dev/null || true
    service_action start  2>/dev/null || true
    sleep 3

    if curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}/health" &>/dev/null \
       || curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
        msg_ok "Gateway 已启动！"
    elif openclaw gateway status 2>/dev/null | grep -qi "running"; then
        msg_ok "Gateway 运行中"
    else
        msg_warn "Gateway 未响应"
        echo -e "  ${DIM}查看日志: openclaw logs${NC}"
    fi

    echo ""
    print_line
    echo -e "${GREEN}${BOLD}🎉 安装完成！${NC}"
    print_line
    show_dashboard_info
    
    # 最终验证
    echo ""
    validate_config
    
    log "Installation completed"
    auto_return 3
    return 0
}

pick_node_version() {
    echo -e "\n${CYAN}获取 nodejs.org 版本列表...${NC}" >&2
    local lts_list
    lts_list=$(get_node_lts_versions)
    local latest_major
    latest_major=$(get_node_latest_major)
    local first_lts
    first_lts=$(echo "$lts_list" | awk '{print $1}')

    echo -e "\n${CYAN}选择 Node.js 版本 (最低 v${NODE_MIN_VERSION}+):${NC}" >&2
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
            printf "  %2d) Node.js %-4s (LTS ★ 推荐)\n" "$idx" "$v" >&2
            is_first=false
        else
            printf "  %2d) Node.js %-4s (LTS)\n" "$idx" "$v" >&2
        fi
        vmap[$idx]="$v"
        ((idx++))
    done

    local mi=$idx
    printf "  %2d) 手动输入\n" "$mi" >&2
    echo "" >&2
    local dc
    [[ "$latest_major" != "$first_lts" ]] && dc=2 || dc=1
    echo -ne "  选择 [默认:${dc}]: " >&2
    local vc
    read -r vc </dev/tty || vc=""
    vc=${vc:-$dc}

    if [[ "$vc" -eq "$mi" ]] 2>/dev/null; then
        echo -ne "  主版本号: " >&2
        local mv
        read -r mv </dev/tty || mv=""
        echo "$(echo "${mv:-$NODE_MIN_VERSION}" | tr -d 'vV ')"
    else
        echo "${vmap[$vc]:-${vmap[$dc]:-$NODE_MIN_VERSION}}"
    fi
}

install_nodejs() {
    msg_step "检测 Node.js..."

    if has_cmd node; then
        local ver
        ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$ver" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v) 满足要求"
            return 0
        fi
        msg_warn "$(node -v) 低于 v${NODE_MIN_VERSION}+"
    else
        msg_warn "未检测到 Node.js"
    fi

    echo ""
    echo "  1) NodeSource 官方源 (推荐)"
    echo "  2) nvm 版本管理器"
    echo "  3) 系统包管理器"
    echo "  4) 手动安装"
    echo ""
    echo -ne "${BOLD}选择 [1-4] (默认: 1): ${NC}"
    local nc
    read -r nc </dev/tty || nc="1"
    nc=${nc:-1}

    local tv="$NODE_RECOMMENDED_VERSION"
    if [[ "$nc" -eq 1 || "$nc" -eq 2 ]]; then
        tv=$(pick_node_version)
        [[ -z "$tv" ]] && tv="$NODE_RECOMMENDED_VERSION"
        msg_info "目标: v${tv}"
    fi

    case "$nc" in
        1) _install_node_nodesource "$tv" ;;
        2) _install_node_nvm "$tv" ;;
        3) _install_node_native ;;
        4) msg_info "下载: https://nodejs.org/en/download/"; return 1 ;;
        *) msg_warn "无效"; return 1 ;;
    esac

    _refresh_node_path

    if has_cmd node; then
        local iv
        iv=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$iv" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v) 安装成功！"
            log "Node.js $(node -v)"
            return 0
        fi
    fi
    msg_fail "安装失败，详见: $LOG_FILE"
    return 1
}

_install_node_nodesource() {
    local version="$1"
    msg_step "NodeSource v${version}..."
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
        *)
            msg_fail "不支持"
            return 1 ;;
    esac
}

_install_node_nvm() {
    local version="$1"
    local nvm_ver
    nvm_ver=$(get_nvm_latest_version)
    msg_step "nvm (${nvm_ver}) → Node.js v${version}..."
    safe_run "安装 nvm" bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_ver}/install.sh | bash"
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" || { msg_fail "nvm 加载失败"; return 1; }
    safe_run "nvm install $version" nvm install "$version"
    nvm use "$version" >> "$LOG_FILE" 2>&1 || true
    nvm alias default "$version" >> "$LOG_FILE" 2>&1 || true
    local src="$HOME/.bashrc"
    [[ "$SHELL" == *zsh* ]] && src="$HOME/.zshrc"
    grep -q "NVM_DIR" "$src" 2>/dev/null || {
        echo 'export NVM_DIR="$HOME/.nvm"'
        echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
    } >> "$src"
}

_install_node_native() {
    msg_step "系统包管理器..."
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
        *)
            msg_fail "不支持"
            return 1 ;;
    esac
}

_refresh_node_path() {
    local nd=""
    [[ -d "$HOME/.nvm/versions/node" ]] && nd=$(ls -d "$HOME/.nvm/versions/node/"v* 2>/dev/null | sort -V | tail -1)
    for p in "${nd:+${nd}/bin}" "$HOME/.local/bin" "/usr/local/bin"; do
        [[ -n "$p" && -d "$p" ]] && export PATH="$p:$PATH"
    done
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
}

# ============================================================
# 版本与升级
# ============================================================
show_version() {
    msg_title "📦 版本信息"
    is_openclaw_installed || { msg_fail "未安装"; auto_return 2; return 0; }
    print_line
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw_cmd --version 2>/dev/null || echo '未知')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}npm${NC}         : v$(npm -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}Docker${NC}      : $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo '未安装')"
    echo -e "  ${BOLD}部署方式${NC}    : $(_detect_deploy_mode)"
    echo -e "  ${BOLD}脚本版本${NC}    : ${SCRIPT_VERSION}"
    print_line
    echo ""

    msg_info "检查最新版本..."
    local latest
    latest=$(get_openclaw_latest_version)
    local current
    current=$(openclaw_cmd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
    echo -e "  ${BOLD}当前${NC}: ${current}  ${BOLD}最新${NC}: ${latest:-无法获取}"

    if [[ -n "$latest" && "$latest" != "$current" ]]; then
        echo ""
        msg_warn "发现新版本 $latest"
        confirm "立即升级?" && {
            if docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
                docker pull "${DOCKER_IMAGE}:latest" && docker rm -f "$DOCKER_CONTAINER" && _docker_run "$OPENCLAW_PORT" "$DOCKER_DATA_DIR"
            else
                npm install -g openclaw@latest 2>&1 | tail -5 && msg_ok "升级完成: $(openclaw --version 2>/dev/null)" || msg_fail "升级失败"
            fi
        }
    else
        echo ""
        msg_ok "已是最新版本"
    fi

    auto_return 3
    return 0
}

# ============================================================
# 服务管理
# ============================================================
manage_service() {
    local action="$1"
    detect_system
    
    case "$action" in
        start)
            msg_step "启动 Gateway..."
            # 确保配置存在
            ensure_minimal_config
            service_action start
            sleep 2
            if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                msg_ok "启动成功！"
                show_dashboard_info
            else
                msg_warn "未响应，检查配置: openclaw config validate"
            fi ;;
        stop)
            confirm "确认停止?" && {
                msg_step "停止..."
                service_action stop
                sleep 1
                msg_ok "已停止"
            } || msg_info "已取消" ;;
        restart)
            msg_step "重启..."
            service_action restart
            sleep 3
            msg_ok "已重启"
            show_dashboard_info ;;
        status)
            msg_step "状态:"
            echo ""
            service_action status
            load_config_from_file
            [[ -n "$G_DEFAULT_PROVIDER" ]] && {
                echo ""
                echo -e "  ${BOLD}默认AI:${NC} ${GREEN}${G_DEFAULT_PROVIDER}${NC} → ${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
            }
            show_dashboard_info ;;
    esac
    auto_return 3
    return 0
}

# ============================================================
# 诊断与修复
# ============================================================
diagnose_and_fix() {
    msg_title "${DOCTOR} 诊断与修复"
    detect_system
    local issues=0 fixed=0
    
    echo -e "${CYAN}${BOLD}检测中...${NC}"
    echo ""

    _chk() { echo -ne "  [${1}] ${2}...  "; }
    _pass() { echo -e "${GREEN}${OK} $*${NC}"; }
    _fail_msg() { echo -e "${RED}${FAIL} $*${NC}"; }

    _chk "1/10" "OpenClaw 安装"
    if is_openclaw_installed; then
        _pass "$(openclaw_cmd --version 2>/dev/null) ($(_detect_deploy_mode))"
    else
        _fail_msg "未安装"
        ((issues++))
        confirm "  立即安装?" && { install_openclaw && ((fixed++)) || true; }
    fi

    _chk "2/10" "Node.js"
    if has_cmd node; then
        local nv
        nv=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$nv" -ge "$NODE_MIN_VERSION" ]]; then
            _pass "$(node -v)"
        else
            _fail_msg "$(node -v) < v${NODE_MIN_VERSION}"
            ((issues++))
            confirm "  升级?" && { install_nodejs && ((fixed++)) || true; }
        fi
    else
        _fail_msg "未安装"
        ((issues++))
        install_nodejs && ((fixed++)) || true
    fi

    _chk "3/10" "配置文件"
    if [[ -f "$OPENCLAW_JSON" ]]; then
        _pass "$OPENCLAW_JSON"
    else
        _fail_msg "不存在"
        ((issues++))
        confirm "  创建最小配置?" && {
            ensure_minimal_config
            ((fixed++))
        }
    fi

    _chk "4/10" "gateway.mode"
    if [[ -f "$OPENCLAW_JSON" ]] && has_cmd python3; then
        local gw_mode
        gw_mode=$(python3 -c "
import json
try:
    c=json.load(open('$OPENCLAW_JSON'))
    print(c.get('gateway',{}).get('mode',''))
except: print('')
" 2>/dev/null || echo "")
        if [[ -n "$gw_mode" ]]; then
            _pass "gateway.mode=$gw_mode"
        else
            _fail_msg "未设置 → Gateway 将报 'Missing config'"
            ((issues++))
            if confirm "  设置 gateway.mode=local?"; then
                ensure_minimal_config
                ((fixed++))
                msg_ok "  已修复"
            fi
        fi
    else
        echo -e "${YELLOW}${WARN} 无法检查${NC}"
    fi

    _chk "5/10" "models.mode"
    if [[ -f "$OPENCLAW_JSON" ]] && has_cmd python3; then
        local models_mode
        models_mode=$(python3 -c "
import json
try:
    c=json.load(open('$OPENCLAW_JSON'))
    print(c.get('models',{}).get('mode',''))
except: print('')
" 2>/dev/null || echo "")
        if [[ "$models_mode" == "merge" ]]; then
            _pass "models.mode=merge"
        else
            _fail_msg "models.mode=${models_mode:-未设置} → 自定义 Provider 不工作"
            ((issues++))
            if confirm "  设置 models.mode=merge?"; then
                ensure_minimal_config
                ((fixed++))
                msg_ok "  已修复"
            fi
        fi
    else
        echo -e "${YELLOW}${WARN} 无法检查${NC}"
    fi

    _chk "6/10" "自定义 Provider api 字段"
    if [[ -f "$OPENCLAW_JSON" ]] && has_cmd python3; then
        local api_check
        api_check=$(python3 - "$OPENCLAW_JSON" << 'PYEOF' 2>/dev/null
import json
import sys

try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
except:
    sys.exit(0)

providers = c.get("models", {}).get("providers", {})
missing = []
for name, p in providers.items():
    if not p.get("api"):
        missing.append(name)

if missing:
    print("FAIL:" + ",".join(missing))
elif providers:
    print("PASS:" + str(len(providers)))
else:
    print("NONE")
PYEOF
)
        if [[ "$api_check" == PASS:* ]]; then
            _pass "${api_check#PASS:} 个 Provider"
        elif [[ "$api_check" == FAIL:* ]]; then
            _fail_msg "Provider 缺少 api 字段: ${api_check#FAIL:}"
            ((issues++))
            msg_warn "  请编辑 $OPENCLAW_JSON 添加 api 字段"
        else
            echo -e "${DIM}无自定义 Provider${NC}"
        fi
    else
        echo -e "${DIM}无法检查${NC}"
    fi

    _chk "7/10" "默认模型"
    if [[ -f "$OPENCLAW_JSON" ]] && has_cmd python3; then
        local primary
        primary=$(python3 -c "
import json
try:
    c=json.load(open('$OPENCLAW_JSON'))
    print(c.get('agents',{}).get('defaults',{}).get('model',{}).get('primary',''))
except: print('')
" 2>/dev/null || echo "")
        if [[ -n "$primary" ]]; then
            _pass "$primary"
        else
            echo -e "${YELLOW}${WARN} 未设置${NC}"
            ((issues++))
        fi
    else
        echo -e "${DIM}无法检查${NC}"
    fi

    _chk "8/10" "Gateway 端口"
    if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
        _pass "响应正常"
    else
        echo -e "${YELLOW}${WARN} 无响应${NC}"
        ((issues++))
        confirm "  启动 Gateway?" && {
            service_action start 2>/dev/null || { openclaw_cmd gateway start >> "$LOG_FILE" 2>&1 & true; }
            sleep 3
            curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null && {
                msg_ok "  已启动"
                ((fixed++))
            } || msg_warn "  启动失败"
        }
    fi

    _chk "9/10" "磁盘空间"
    local da
    da=$(df "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999999")
    if [[ "$da" -gt 1048576 ]]; then
        _pass "$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
    else
        _fail_msg "不足"
        ((issues++))
    fi

    _chk "10/10" "网络连接"
    if curl -s --max-time 5 https://api.anthropic.com &>/dev/null \
       || curl -s --max-time 5 https://api.openai.com &>/dev/null; then
        _pass "正常"
    else
        echo -e "${YELLOW}${WARN} 异常${NC}"
        ((issues++))
        msg_warn "  检查防火墙/代理"
    fi

    # 运行 openclaw doctor
    if is_openclaw_installed; then
        echo ""
        msg_step "运行 openclaw doctor --fix..."
        openclaw_cmd doctor --fix 2>&1 | sed 's/^/    /' || true
    fi

    echo ""
    print_line
    echo -e "${BOLD}结果:${NC}  问题 ${RED}${BOLD}${issues}${NC}  修复 ${GREEN}${BOLD}${fixed}${NC}"
    (( issues > fixed )) && echo -e "  待处理: ${YELLOW}$(( issues - fixed ))${NC}"
    echo -e "  日志: ${DIM}${LOG_FILE}${NC}"
    print_line
    
    auto_return 3
    return 0
}

# ============================================================
# 查看日志
# ============================================================
view_logs() {
    msg_title "📋 日志"
    echo "  1) 实时 Gateway  2) systemd  3) 应用文件  4) Docker  5) 脚本日志  0) 返回"
    echo ""
    echo -ne "${BOLD}选择 [0-5]: ${NC}"
    local lc
    read -r lc </dev/tty || lc="0"

    case "$lc" in
        1)
            msg_info "Ctrl+C 退出"
            sleep 1
            trap 'echo ""; msg_info "退出"' INT
            openclaw_cmd gateway logs --follow 2>/dev/null \
                || openclaw_cmd logs 2>/dev/null \
                || journalctl -u "$OPENCLAW_SERVICE" -f 2>/dev/null \
                || tail -f "${OPENCLAW_LOG_DIR}/gateway.log" 2>/dev/null \
                || msg_fail "无法获取" || true
            trap - INT ;;
        2)
            detect_system
            if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
                local svc found=false
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    if sudo journalctl -u "$svc" -n 100 --no-pager 2>/dev/null \
                       || journalctl --user -u "$svc" -n 100 --no-pager 2>/dev/null; then
                        found=true
                        break
                    fi
                done
                $found || msg_fail "不可用"
            else
                msg_warn "非 systemd"
            fi ;;
        3)
            if [[ -d "$OPENCLAW_LOG_DIR" ]]; then
                ls -lh "$OPENCLAW_LOG_DIR" 2>/dev/null || echo "(空)"
                echo -ne "${BOLD}文件名 (Enter最新): ${NC}"
                local lf
                read -r lf </dev/tty || lf=""
                if [[ -n "$lf" ]]; then
                    less "${OPENCLAW_LOG_DIR}/${lf}" 2>/dev/null || msg_warn "不存在"
                else
                    local ll
                    ll=$(ls -t "${OPENCLAW_LOG_DIR}"/*.log 2>/dev/null | head -1 || echo "")
                    [[ -n "$ll" ]] && less "$ll" || msg_warn "无日志"
                fi
            else
                msg_warn "目录不存在"
            fi ;;
        4)
            if has_cmd docker && docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
                trap 'echo ""; msg_info "退出"' INT
                docker logs -f "$DOCKER_CONTAINER" 2>&1 || true
                trap - INT
            else
                msg_warn "无 Docker 容器"
            fi ;;
        5)
            [[ -f "$LOG_FILE" ]] && less "$LOG_FILE" || msg_warn "不存在" ;;
        0)
            return 0 ;;
        *)
            msg_warn "无效" ;;
    esac
    auto_return 2
    return 0
}

# ============================================================
# 卸载
# ============================================================
uninstall_openclaw() {
    msg_title "${TRASH} 卸载 OpenClaw"
    echo -e "${RED}${BOLD}⚠️  此操作将卸载 OpenClaw${NC}"
    echo ""
    echo "  • 停止并禁用 Gateway / 容器"
    echo "  • 卸载 npm 包或删除 Docker 容器"
    echo "  • 可选: 删除配置/数据"
    echo ""
    confirm "确认卸载?" || { msg_info "已取消"; auto_return 2; return 0; }
    detect_system

    docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER" && {
        msg_step "Docker 容器..."
        docker stop "$DOCKER_CONTAINER" 2>/dev/null || true
        confirm "删除容器?" && { docker rm -f "$DOCKER_CONTAINER" 2>/dev/null && msg_ok "容器已删除"; }
        confirm "删除镜像?" && {
            docker rmi "${DOCKER_IMAGE}:latest" 2>/dev/null || true
            docker rmi "${DOCKER_IMAGE_MIRROR}:latest" 2>/dev/null || true
            msg_ok "镜像已删除"
        }
    }

    if has_cmd openclaw; then
        msg_step "停止服务..."
        openclaw gateway uninstall >> "$LOG_FILE" 2>&1 || true
        service_action stop 2>/dev/null || true
        sleep 1
        
        msg_step "禁用自启..."
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
                rm -f "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist" \
                      "$HOME/Library/LaunchAgents/com.openclaw.gateway.plist" 2>/dev/null || true ;;
            openrc)
                local svc
                for svc in "${OPENCLAW_SERVICE_CANDIDATES[@]}"; do
                    sudo rc-update del "$svc" 2>/dev/null || true
                done ;;
        esac
        
        msg_step "卸载 npm..."
        npm uninstall -g openclaw >> "$LOG_FILE" 2>&1 && msg_ok "已卸载" || {
            msg_warn "npm 失败，手动清理..."
            local np
            np=$(npm prefix -g 2>/dev/null || echo "/usr/local")
            sudo rm -f "${np}/bin/openclaw" 2>/dev/null || true
            sudo rm -rf "${np}/lib/node_modules/openclaw" 2>/dev/null || true
            msg_ok "清理完成"
        }
    fi

    echo ""
    confirm "删除配置和数据? ($OPENCLAW_CONFIG_DIR)" && {
        rm -rf "$OPENCLAW_CONFIG_DIR"
        G_API_KEYS=()
        G_API_MODELS=()
        G_API_TYPES=()
        G_API_URLS=()
        G_DEFAULT_PROVIDER=""
        msg_ok "数据已删除"
    } || msg_info "配置保留: $OPENCLAW_CONFIG_DIR"

    echo ""
    msg_ok "OpenClaw 已卸载"
    log "Uninstalled"
    auto_return 3
    return 0
}

# ============================================================
# 主菜单
# ============================================================
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
    echo -e "        ${DIM}修复版 ${SCRIPT_VERSION} | 解决部署和自定义 API 配置问题${NC}"
    echo ""

    detect_system
    load_config_from_file 2>/dev/null || true

    local sc="${RED}" st="未安装"
    if is_openclaw_installed; then
        curl -s --max-time 2 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null \
            && { sc="${GREEN}"; st="运行中 ●"; } \
            || { sc="${YELLOW}"; st="已安装，未运行"; }
    fi

    local mi=""
    if [[ -n "${G_DEFAULT_PROVIDER:-}" ]]; then
        local dm="${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
        dm="${dm%%,*}"
        [[ -n "$dm" ]] && mi="  ${DIM}|${NC} ${CYAN}${G_DEFAULT_PROVIDER}${NC}:${dm}"
    fi

    echo -e "  ${DIM}系统:${NC} ${OS^^} ${ARCH_LABEL}  ${DIM}|${NC}  ${DIM}GW:${NC} ${sc}${BOLD}${st}${NC}  ${DIM}|${NC}  ${DIM}部署:${NC} $(_detect_deploy_mode)${mi}"
    print_line
}

main_menu() {
    while true; do
        show_banner
        echo -e "${WHITE}${BOLD}  主菜单${NC}"
        echo ""
        echo -e "${BOLD}  ── 安装部署 ──${NC}"
        echo -e "  ${BOLD}${GREEN}[1]${NC}  ${ROCKET} 本地安装 / 重装"
        echo -e "  ${BOLD}${GREEN}[2]${NC}  ${DOCKER} Docker 部署"
        echo ""
        echo -e "${BOLD}  ── 配置管理 ──${NC}"
        echo -e "  ${BOLD}${CYAN}[3]${NC}  🔑 配置 API 密钥"
        echo -e "  ${BOLD}${CYAN}[4]${NC}  🔧 配置自定义 API (重要!)"
        echo -e "  ${BOLD}${CYAN}[5]${NC}  ${LOBSTER} 局域网访问配置"
        echo -e "  ${BOLD}${CYAN}[6]${NC}  ${PLUGIN} 安装插件 (微信/飞书)"
        echo ""
        echo -e "${BOLD}  ── 服务控制 ──${NC}"
        echo -e "  ${BOLD}${YELLOW}[7]${NC}  ${POWER} 启动 Gateway"
        echo -e "  ${BOLD}${YELLOW}[8]${NC}  🔄 重启 Gateway"
        echo -e "  ${BOLD}${YELLOW}[9]${NC}  ⏹  停止 Gateway"
        echo -e "  ${BOLD}${YELLOW}[10]${NC} 📈 运行状态"
        echo ""
        echo -e "${BOLD}  ── 信息与工具 ──${NC}"
        echo -e "  ${BOLD}${MAGENTA}[11]${NC} 📊 控制面板 URL"
        echo -e "  ${BOLD}${MAGENTA}[12]${NC} 📦 版本 / 升级"
        echo -e "  ${BOLD}${MAGENTA}[13]${NC} 📋 查看日志"
        echo -e "  ${BOLD}${MAGENTA}[14]${NC} ${GEAR} 快捷命令执行"
        echo -e "  ${BOLD}${MAGENTA}[15]${NC} 📖 命令速查手册"
        echo -e "  ${BOLD}${MAGENTA}[16]${NC} ${DOCTOR} 诊断修复"
        echo -e "  ${BOLD}${MAGENTA}[17]${NC} ✅ 验证配置"
        echo -e "  ${BOLD}${MAGENTA}[18]${NC} ℹ️  系统信息"
        echo -e "  ${BOLD}${RED}[19]${NC} ${TRASH} 卸载"
        echo -e "  ${BOLD}${GREEN}[20]${NC} 🔧 运行 setup 初始化向导"
        echo -e "  ${BOLD}[0]${NC}  🚪 退出"
        echo ""
        print_line
        echo -ne "  ${BOLD}请输入: ${NC}"
        local choice
        read -r choice </dev/tty || choice=""

        case "$choice" in
            1)  install_openclaw ;;
            2)  deploy_docker ;;
            3)  configure_api_keys; auto_return 2 ;;
            4)  configure_custom_api; auto_return 2 ;;
            5)  configure_lan_access ;;
            6)  install_plugins ;;
            7)  manage_service start ;;
            8)  manage_service restart ;;
            9)  manage_service stop ;;
            10) manage_service status ;;
            11) show_dashboard_info; auto_return 3 ;;
            12) show_version ;;
            13) view_logs ;;
            14) quick_commands ;;
            15) show_command_reference ;;
            16) diagnose_and_fix ;;
            17) validate_config; auto_return 2 ;;
            18) print_sysinfo; auto_return 3 ;;
            19) uninstall_openclaw ;;
            20) run_setup_wizard ;;
            0)  echo ""; echo -e "${GREEN}${BOLD}再见！👋${NC}"; echo ""; exit 0 ;;
            *)  msg_warn "无效: ${choice} (0-20)"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 入口
# ============================================================
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
    ref|help)   show_command_reference ;;
    cmds)       detect_system; quick_commands ;;
    *)          main_menu ;;
esac
