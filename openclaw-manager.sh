#!/usr/bin/env bash

set -euo pipefail

# ─────────────────────────────────────────
#  全局颜色 & 图标定义
# ─────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # 重置颜色

OK="✅"
FAIL="❌"
WARN="⚠️ "
INFO="ℹ️ "
ARROW="➜"
GEAR="⚙️ "
ROCKET="🚀"
LOCK="🔒"
TRASH="🗑️ "
DOCTOR="🩺"
POWER="⚡"

# ─────────────────────────────────────────
#  全局变量
# ─────────────────────────────────────────
OPENCLAW_PORT=18789
OPENCLAW_SERVICE="openclaw"
OPENCLAW_CONFIG_DIR="$HOME/.openclaw"
OPENCLAW_LOG_DIR="$OPENCLAW_CONFIG_DIR/logs"
SCRIPT_VERSION="v1.0.0"
NODE_MIN_VERSION=22
LOG_FILE="/tmp/openclaw_install_$(date +%Y%m%d_%H%M%S).log"

# ─────────────────────────────────────────
#  工具函数
# ─────────────────────────────────────────

# 打印分隔线
print_line() {
    echo -e "${DIM}$(printf '─%.0s' {1..60})${NC}"
}

# 打印带颜色的消息
msg_ok()    { echo -e "${GREEN}${OK}  $*${NC}"; }
msg_fail()  { echo -e "${RED}${FAIL}  $*${NC}"; }
msg_warn()  { echo -e "${YELLOW}${WARN} $*${NC}"; }
msg_info()  { echo -e "${CYAN}${INFO} $*${NC}"; }
msg_step()  { echo -e "\n${BLUE}${BOLD}${ARROW} $*${NC}"; }
msg_title() {
    echo ""
    echo -e "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}${BOLD}║$(printf '%*s' $(( (60 + ${#1}) / 2 )) "$1")$(printf '%*s' $(( (60 - ${#1}) / 2 )) "")║${NC}"
    echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 等待用户按任意键
press_any_key() {
    echo ""
    read -rp "$(echo -e "${DIM}按 Enter 键返回主菜单...${NC}")" _
}

# 确认操作（y/n）
confirm() {
    local prompt="${1:-确认操作}"
    local answer
    echo -ne "${YELLOW}${WARN} ${prompt} [y/N]: ${NC}"
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# 记录到日志文件
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# 命令是否存在
has_cmd() { command -v "$1" &>/dev/null; }

# ─────────────────────────────────────────
#  系统检测函数
# ─────────────────────────────────────────

detect_system() {
    # 操作系统
    OS=""
    PKG_MANAGER=""
    INSTALL_CMD=""
    UPDATE_CMD=""
    SERVICE_MANAGER=""

    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        SERVICE_MANAGER="launchd"
        if has_cmd brew; then
            PKG_MANAGER="brew"
            INSTALL_CMD="brew install"
            UPDATE_CMD="brew update"
        else
            PKG_MANAGER="none"
        fi
    elif [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop|kali|raspbian)
                OS="debian"
                PKG_MANAGER="apt"
                INSTALL_CMD="sudo apt-get install -y"
                UPDATE_CMD="sudo apt-get update -qq"
                ;;
            centos|rhel|rocky|almalinux|ol)
                OS="rhel"
                PKG_MANAGER="yum"
                INSTALL_CMD="sudo yum install -y"
                UPDATE_CMD="sudo yum update -y"
                ;;
            fedora)
                OS="fedora"
                PKG_MANAGER="dnf"
                INSTALL_CMD="sudo dnf install -y"
                UPDATE_CMD="sudo dnf update -y"
                ;;
            arch|manjaro|endeavouros)
                OS="arch"
                PKG_MANAGER="pacman"
                INSTALL_CMD="sudo pacman -S --noconfirm"
                UPDATE_CMD="sudo pacman -Sy"
                ;;
            alpine)
                OS="alpine"
                PKG_MANAGER="apk"
                INSTALL_CMD="sudo apk add"
                UPDATE_CMD="sudo apk update"
                ;;
            *)
                OS="unknown"
                PKG_MANAGER="unknown"
                ;;
        esac
        SERVICE_MANAGER="systemd"
        # Alpine 使用 OpenRC
        [[ "$OS" == "alpine" ]] && SERVICE_MANAGER="openrc"
    else
        OS="unknown"
    fi

    # 架构检测
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)    ARCH_LABEL="x86_64 (64位)"  ;;
        aarch64|arm64)   ARCH_LABEL="ARM64 (64位)"   ;;
        armv7l|armv6l)   ARCH_LABEL="ARMv7/v6 (32位)" ;;
        i386|i686)       ARCH_LABEL="x86 (32位)"     ;;
        *)               ARCH_LABEL="$ARCH (未知)"    ;;
    esac

    # 是否有 sudo 权限
    HAVE_SUDO=false
    if [[ "$OS" != "macos" ]]; then
        sudo -n true 2>/dev/null && HAVE_SUDO=true || HAVE_SUDO=true
    fi
}

# 打印系统信息摘要
print_sysinfo() {
    detect_system
    echo -e "${CYAN}${BOLD}系统信息摘要${NC}"
    print_line
    echo -e "  ${BOLD}操作系统${NC}    : $(echo "${OS}" | tr '[:lower:]' '[:upper:]') (${PRETTY_NAME:-$OS})"
    echo -e "  ${BOLD}系统架构${NC}    : ${ARCH_LABEL}"
    echo -e "  ${BOLD}包管理器${NC}    : ${PKG_MANAGER}"
    echo -e "  ${BOLD}服务管理器${NC}  : ${SERVICE_MANAGER}"
    echo -e "  ${BOLD}主机名${NC}      : $(hostname)"
    echo -e "  ${BOLD}内存${NC}        : $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || sysctl hw.memsize 2>/dev/null | awk '{printf "%.0f GB", $2/1073741824}' || echo '未知')"
    echo -e "  ${BOLD}CPU 核心${NC}    : $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '未知')"
    echo -e "  ${BOLD}磁盘可用${NC}    : $(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo '未知')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}npm${NC}         : $(npm -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw --version 2>/dev/null || echo '未安装')"
    print_line
}

# ─────────────────────────────────────────
#  Node.js 安装函数
# ─────────────────────────────────────────

install_nodejs() {
    msg_step "检测 Node.js 版本..."

    if has_cmd node; then
        local ver
        ver=$(node -e "process.exit(parseInt(process.version.slice(1)))" 2>/dev/null; node -v | sed 's/v//' | cut -d. -f1)
        ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$ver" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v) 已满足最低要求 (v${NODE_MIN_VERSION}+)"
            return 0
        else
            msg_warn "当前 Node.js 版本 $(node -v) 低于要求，需要 v${NODE_MIN_VERSION}+"
        fi
    else
        msg_warn "未检测到 Node.js，即将自动安装..."
    fi

    echo ""
    echo -e "${CYAN}请选择 Node.js 安装方式:${NC}"
    echo "  1) NodeSource 官方源 (推荐, 自动适配系统)"
    echo "  2) nvm 版本管理器    (灵活, 适合多版本需求)"
    echo "  3) Homebrew          (仅 macOS)"
    echo "  4) 手动安装          (高级用户)"
    echo ""
    read -rp "$(echo -e "${BOLD}请输入选项 [1-4] (默认: 1): ${NC}")" node_choice
    node_choice=${node_choice:-1}

    case "$node_choice" in
        1)
            msg_step "使用 NodeSource 安装 Node.js ${NODE_MIN_VERSION}..."
            case "$OS" in
                debian)
                    curl -fsSL https://deb.nodesource.com/setup_${NODE_MIN_VERSION}.x | sudo -E bash - >> "$LOG_FILE" 2>&1
                    sudo apt-get install -y nodejs >> "$LOG_FILE" 2>&1
                    ;;
                rhel|fedora)
                    curl -fsSL https://rpm.nodesource.com/setup_${NODE_MIN_VERSION}.x | sudo bash - >> "$LOG_FILE" 2>&1
                    sudo $PKG_MANAGER install -y nodejs >> "$LOG_FILE" 2>&1
                    ;;
                arch)
                    sudo pacman -S --noconfirm nodejs npm >> "$LOG_FILE" 2>&1
                    ;;
                alpine)
                    sudo apk add nodejs npm >> "$LOG_FILE" 2>&1
                    ;;
                macos)
                    brew install node@${NODE_MIN_VERSION} >> "$LOG_FILE" 2>&1
                    ;;
                *)
                    msg_fail "无法自动安装，请手动安装 Node.js ${NODE_MIN_VERSION}+"
                    return 1
                    ;;
            esac
            ;;
        2)
            msg_step "使用 nvm 安装..."
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash >> "$LOG_FILE" 2>&1
            export NVM_DIR="$HOME/.nvm"
            # shellcheck source=/dev/null
            [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
            nvm install $NODE_MIN_VERSION >> "$LOG_FILE" 2>&1
            nvm use $NODE_MIN_VERSION >> "$LOG_FILE" 2>&1
            nvm alias default $NODE_MIN_VERSION >> "$LOG_FILE" 2>&1
            ;;
        3)
            if [[ "$OS" != "macos" ]]; then
                msg_fail "Homebrew 仅适用于 macOS"
                return 1
            fi
            brew install node@${NODE_MIN_VERSION} >> "$LOG_FILE" 2>&1
            ;;
        4)
            echo ""
            msg_info "请手动安装 Node.js v${NODE_MIN_VERSION}+ 后重新运行此脚本"
            msg_info "下载地址: https://nodejs.org/en/download/"
            return 1
            ;;
    esac

    if has_cmd node && [[ $(node -v | sed 's/v//' | cut -d. -f1) -ge $NODE_MIN_VERSION ]]; then
        msg_ok "Node.js $(node -v) 安装成功!"
        log "Node.js $(node -v) installed"
    else
        msg_fail "Node.js 安装失败，请查看日志: $LOG_FILE"
        return 1
    fi
}

# ─────────────────────────────────────────
#  API Key 配置函数
# ─────────────────────────────────────────

configure_api_keys() {
    msg_title "🔑 配置第三方 LLM API 密钥"

    echo -e "${CYAN}支持以下 AI 服务提供商:${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} Anthropic Claude   (推荐, claude-3-5-sonnet 等)"
    echo -e "  ${BOLD}2)${NC} OpenAI             (GPT-4o, GPT-4 Turbo 等)"
    echo -e "  ${BOLD}3)${NC} Google Gemini      (Gemini 1.5 Pro 等)"
    echo -e "  ${BOLD}4)${NC} DeepSeek           (deepseek-chat, deepseek-coder)"
    echo -e "  ${BOLD}5)${NC} Groq               (Llama 3, Mixtral 高速推理)"
    echo -e "  ${BOLD}6)${NC} Mistral AI         (mistral-large 等)"
    echo -e "  ${BOLD}7)${NC} 自定义 OpenAI 兼容 API (本地模型/代理)"
    echo -e "  ${BOLD}0)${NC} 跳过 (稍后手动配置)"
    echo ""

    local config_file="$OPENCLAW_CONFIG_DIR/config.json"
    mkdir -p "$OPENCLAW_CONFIG_DIR"

    # 读取已有配置（如果存在）
    local existing_config="{}"
    [[ -f "$config_file" ]] && existing_config=$(cat "$config_file")

    declare -A api_keys
    declare -A api_models

    while true; do
        echo -ne "${BOLD}请输入要配置的提供商编号 (可多次输入, 输入 0 完成): ${NC}"
        read -r provider_choice

        case "$provider_choice" in
            0) break ;;

            1)
                echo ""
                echo -e "${CYAN}${BOLD}─── Anthropic Claude 配置 ───${NC}"
                echo -e "${DIM}获取地址: https://console.anthropic.com/settings/keys${NC}"
                echo ""
                echo -ne "  请输入 Anthropic API Key (sk-ant-...): "
                read -rs anthropic_key
                echo ""
                if [[ -n "$anthropic_key" ]]; then
                    echo ""
                    echo -e "  ${CYAN}选择默认模型:${NC}"
                    echo "    1) claude-opus-4-5       (最强, 较慢)"
                    echo "    2) claude-sonnet-4-5     (推荐均衡)"
                    echo "    3) claude-haiku-3-5      (最快, 经济)"
                    read -rp "  请输入 [1-3] (默认: 2): " m_choice
                    case "${m_choice:-2}" in
                        1) api_models["anthropic"]="claude-opus-4-5" ;;
                        3) api_models["anthropic"]="claude-haiku-3-5" ;;
                        *) api_models["anthropic"]="claude-sonnet-4-5" ;;
                    esac
                    api_keys["anthropic"]="$anthropic_key"
                    msg_ok "Anthropic API Key 已保存 (${api_models[anthropic]})"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            2)
                echo ""
                echo -e "${CYAN}${BOLD}─── OpenAI 配置 ───${NC}"
                echo -e "${DIM}获取地址: https://platform.openai.com/api-keys${NC}"
                echo ""
                echo -ne "  请输入 OpenAI API Key (sk-...): "
                read -rs openai_key
                echo ""
                if [[ -n "$openai_key" ]]; then
                    echo -e "  ${CYAN}选择默认模型:${NC}"
                    echo "    1) gpt-4o                (最强多模态)"
                    echo "    2) gpt-4-turbo           (高性能)"
                    echo "    3) gpt-4o-mini           (经济实惠)"
                    read -rp "  请输入 [1-3] (默认: 1): " m_choice
                    case "${m_choice:-1}" in
                        2) api_models["openai"]="gpt-4-turbo" ;;
                        3) api_models["openai"]="gpt-4o-mini" ;;
                        *) api_models["openai"]="gpt-4o" ;;
                    esac
                    api_keys["openai"]="$openai_key"
                    msg_ok "OpenAI API Key 已保存 (${api_models[openai]})"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            3)
                echo ""
                echo -e "${CYAN}${BOLD}─── Google Gemini 配置 ───${NC}"
                echo -e "${DIM}获取地址: https://aistudio.google.com/app/apikey${NC}"
                echo ""
                echo -ne "  请输入 Google API Key: "
                read -rs google_key
                echo ""
                if [[ -n "$google_key" ]]; then
                    echo -e "  ${CYAN}选择默认模型:${NC}"
                    echo "    1) gemini-1.5-pro        (最强)"
                    echo "    2) gemini-1.5-flash      (快速)"
                    echo "    3) gemini-2.0-flash-exp  (实验性)"
                    read -rp "  请输入 [1-3] (默认: 1): " m_choice
                    case "${m_choice:-1}" in
                        2) api_models["google"]="gemini-1.5-flash" ;;
                        3) api_models["google"]="gemini-2.0-flash-exp" ;;
                        *) api_models["google"]="gemini-1.5-pro" ;;
                    esac
                    api_keys["google"]="$google_key"
                    msg_ok "Google API Key 已保存 (${api_models[google]})"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            4)
                echo ""
                echo -e "${CYAN}${BOLD}─── DeepSeek 配置 ───${NC}"
                echo -e "${DIM}获取地址: https://platform.deepseek.com/api_keys${NC}"
                echo ""
                echo -ne "  请输入 DeepSeek API Key (sk-...): "
                read -rs deepseek_key
                echo ""
                if [[ -n "$deepseek_key" ]]; then
                    echo -e "  ${CYAN}选择默认模型:${NC}"
                    echo "    1) deepseek-chat         (通用对话)"
                    echo "    2) deepseek-coder        (代码专用)"
                    echo "    3) deepseek-reasoner     (推理增强)"
                    read -rp "  请输入 [1-3] (默认: 1): " m_choice
                    case "${m_choice:-1}" in
                        2) api_models["deepseek"]="deepseek-coder" ;;
                        3) api_models["deepseek"]="deepseek-reasoner" ;;
                        *) api_models["deepseek"]="deepseek-chat" ;;
                    esac
                    api_keys["deepseek"]="$deepseek_key"
                    msg_ok "DeepSeek API Key 已保存 (${api_models[deepseek]})"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            5)
                echo ""
                echo -e "${CYAN}${BOLD}─── Groq 配置 ───${NC}"
                echo -e "${DIM}获取地址: https://console.groq.com/keys${NC}"
                echo ""
                echo -ne "  请输入 Groq API Key (gsk_...): "
                read -rs groq_key
                echo ""
                if [[ -n "$groq_key" ]]; then
                    api_keys["groq"]="$groq_key"
                    api_models["groq"]="llama-3.3-70b-versatile"
                    msg_ok "Groq API Key 已保存 (llama-3.3-70b-versatile)"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            6)
                echo ""
                echo -e "${CYAN}${BOLD}─── Mistral AI 配置 ───${NC}"
                echo -e "${DIM}获取地址: https://console.mistral.ai/api-keys${NC}"
                echo ""
                echo -ne "  请输入 Mistral API Key: "
                read -rs mistral_key
                echo ""
                if [[ -n "$mistral_key" ]]; then
                    api_keys["mistral"]="$mistral_key"
                    api_models["mistral"]="mistral-large-latest"
                    msg_ok "Mistral API Key 已保存 (mistral-large-latest)"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            7)
                echo ""
                echo -e "${CYAN}${BOLD}─── 自定义 OpenAI 兼容 API 配置 ───${NC}"
                echo -e "${DIM}适用于: Ollama, LM Studio, vLLM, one-api 等代理${NC}"
                echo ""
                echo -ne "  请输入 API Base URL (例: http://localhost:11434/v1): "
                read -r custom_url
                echo -ne "  请输入 API Key (无需认证请输入 none): "
                read -rs custom_key
                echo ""
                echo -ne "  请输入模型名称 (例: llama3.2, qwen2.5): "
                read -r custom_model
                if [[ -n "$custom_url" && -n "$custom_model" ]]; then
                    api_keys["custom_url"]="$custom_url"
                    api_keys["custom_key"]="${custom_key:-none}"
                    api_models["custom"]="$custom_model"
                    msg_ok "自定义 API 已保存 ($custom_url | $custom_model)"
                else
                    msg_warn "URL 或模型名称为空，已跳过"
                fi
                ;;

            *)
                msg_warn "无效选项，请输入 0-7"
                ;;
        esac
        echo ""
    done

    # 写入配置
    if [[ ${#api_keys[@]} -gt 0 ]]; then
        msg_step "正在写入 API 配置到 $config_file ..."

        # 构造 JSON（使用 node 确保格式正确）
        local json_input=""
        for provider in "${!api_keys[@]}"; do
            if [[ "$provider" != "custom_url" && "$provider" != "custom_key" ]]; then
                json_input="${json_input}${provider}|${api_keys[$provider]}|${api_models[$provider]:-},"
            fi
        done

        # 如果有自定义 API
        if [[ -n "${api_keys[custom_url]:-}" ]]; then
            json_input="${json_input}custom|${api_keys[custom_key]}|${api_models[custom]}|${api_keys[custom_url]},"
        fi

        # 使用 Python 或 Node 生成 JSON
        if has_cmd python3; then
            python3 - <<PYEOF
import json, os

config_path = os.path.expanduser("${config_file}")
os.makedirs(os.path.dirname(config_path), exist_ok=True)

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
except:
    config = {}

providers = {}
PYEOF
        fi

        # 使用 openclaw 原生命令写入（优先）
        if has_cmd openclaw; then
            [[ -n "${api_keys[anthropic]:-}" ]]  && openclaw config set anthropic.apiKey "${api_keys[anthropic]}"   --silent 2>/dev/null || true
            [[ -n "${api_keys[anthropic]:-}" ]]  && openclaw config set anthropic.model  "${api_models[anthropic]}" --silent 2>/dev/null || true
            [[ -n "${api_keys[openai]:-}" ]]     && openclaw config set openai.apiKey   "${api_keys[openai]}"       --silent 2>/dev/null || true
            [[ -n "${api_keys[openai]:-}" ]]     && openclaw config set openai.model    "${api_models[openai]}"     --silent 2>/dev/null || true
            [[ -n "${api_keys[google]:-}" ]]     && openclaw config set google.apiKey   "${api_keys[google]}"       --silent 2>/dev/null || true
            [[ -n "${api_keys[google]:-}" ]]     && openclaw config set google.model    "${api_models[google]}"     --silent 2>/dev/null || true
            [[ -n "${api_keys[deepseek]:-}" ]]   && openclaw config set deepseek.apiKey "${api_keys[deepseek]}"     --silent 2>/dev/null || true
            [[ -n "${api_keys[deepseek]:-}" ]]   && openclaw config set deepseek.model  "${api_models[deepseek]}"   --silent 2>/dev/null || true
            [[ -n "${api_keys[groq]:-}" ]]       && openclaw config set groq.apiKey     "${api_keys[groq]}"         --silent 2>/dev/null || true
            [[ -n "${api_keys[mistral]:-}" ]]    && openclaw config set mistral.apiKey  "${api_keys[mistral]}"      --silent 2>/dev/null || true
            if [[ -n "${api_keys[custom_url]:-}" ]]; then
                openclaw config set custom.baseUrl "${api_keys[custom_url]}" --silent 2>/dev/null || true
                openclaw config set custom.apiKey  "${api_keys[custom_key]:-none}" --silent 2>/dev/null || true
                openclaw config set custom.model   "${api_models[custom]}"   --silent 2>/dev/null || true
            fi
            msg_ok "API 配置已通过 openclaw config 写入"
        else
            # 回退到直接写 JSON
            {
                echo "{"
                local first=true
                [[ -n "${api_keys[anthropic]:-}" ]] && {
                    $first || echo ","
                    echo "  \"anthropic\": { \"apiKey\": \"${api_keys[anthropic]}\", \"model\": \"${api_models[anthropic]:-claude-sonnet-4-5}\" }"
                    first=false
                }
                [[ -n "${api_keys[openai]:-}" ]] && {
                    $first || echo ","
                    echo "  \"openai\": { \"apiKey\": \"${api_keys[openai]}\", \"model\": \"${api_models[openai]:-gpt-4o}\" }"
                    first=false
                }
                echo "}"
            } > "$config_file"
            chmod 600 "$config_file"
            msg_ok "API 配置已写入 $config_file"
        fi
        log "API keys configured for: ${!api_keys[*]}"
    else
        msg_warn "未配置任何 API Key，稍后可通过菜单重新配置"
    fi
}

# ─────────────────────────────────────────
#  服务管理函数
# ─────────────────────────────────────────

service_action() {
    local action="$1" # start | stop | restart | enable | status
    detect_system

    case "$SERVICE_MANAGER" in
        systemd)
            case "$action" in
                start)   sudo systemctl start  "$OPENCLAW_SERVICE" 2>/dev/null \
                            || systemctl --user start  "$OPENCLAW_SERVICE" 2>/dev/null ;;
                stop)    sudo systemctl stop   "$OPENCLAW_SERVICE" 2>/dev/null \
                            || systemctl --user stop   "$OPENCLAW_SERVICE" 2>/dev/null ;;
                restart) sudo systemctl restart "$OPENCLAW_SERVICE" 2>/dev/null \
                            || systemctl --user restart "$OPENCLAW_SERVICE" 2>/dev/null ;;
                enable)  sudo systemctl enable --now "$OPENCLAW_SERVICE" 2>/dev/null \
                            || systemctl --user enable --now "$OPENCLAW_SERVICE" 2>/dev/null ;;
                status)  sudo systemctl status "$OPENCLAW_SERVICE" --no-pager 2>/dev/null \
                            || systemctl --user status "$OPENCLAW_SERVICE" --no-pager 2>/dev/null ;;
            esac
            ;;
        openrc)
            case "$action" in
                start)   sudo rc-service openclaw start ;;
                stop)    sudo rc-service openclaw stop  ;;
                restart) sudo rc-service openclaw restart ;;
                status)  sudo rc-service openclaw status ;;
            esac
            ;;
        launchd)
            # macOS
            local plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
            case "$action" in
                start)   launchctl load   "$plist" 2>/dev/null ;;
                stop)    launchctl unload "$plist" 2>/dev/null ;;
                restart) launchctl unload "$plist" 2>/dev/null; launchctl load "$plist" 2>/dev/null ;;
                status)  launchctl list | grep openclaw || echo "服务未运行" ;;
            esac
            ;;
        *)
            # 回退到直接命令
            case "$action" in
                start)   openclaw gateway start & ;;
                stop)    openclaw gateway stop    ;;
                restart) openclaw gateway stop; sleep 1; openclaw gateway start & ;;
                status)  openclaw gateway status  ;;
            esac
            ;;
    esac
}

# ─────────────────────────────────────────
#  获取控制面板 URL
# ─────────────────────────────────────────

get_dashboard_url() {
    local local_ip
    # 优先获取局域网 IP
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' \
             || ipconfig getifaddr en0 2>/dev/null \
             || ip route get 1 2>/dev/null | grep -oP 'src \K\S+' \
             || echo "127.0.0.1")

    echo "http://127.0.0.1:${OPENCLAW_PORT}"
}

show_dashboard_info() {
    local local_ip
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    local public_ip
    public_ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "无法获取")

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║               🎉 OpenClaw 控制面板访问信息               ║${NC}"
    echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}本机访问 (推荐):${NC}                                        ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${CYAN}  http://127.0.0.1:${OPENCLAW_PORT}${NC}                         ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}局域网访问:${NC}                                             ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${CYAN}  http://${local_ip}:${OPENCLAW_PORT}${NC}                    ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}远程服务器 SSH 隧道命令 (在本地运行):${NC}                  ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${YELLOW}  ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} user@${public_ip}${NC}    ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${DIM}  然后本地浏览器访问 http://127.0.0.1:${OPENCLAW_PORT}${NC}      ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}公网 IP:${NC}  ${public_ip}                              ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${RED}⚠️  请勿直接将端口 ${OPENCLAW_PORT} 暴露到公网！${NC}            ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${DIM}  请使用 SSH 隧道 或 Tailscale VPN 访问${NC}              ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ─────────────────────────────────────────
#  功能模块: 安装 OpenClaw
# ─────────────────────────────────────────

install_openclaw() {
    msg_title "${ROCKET} 安装 OpenClaw"
    detect_system

    echo -e "${CYAN}当前系统环境:${NC}"
    echo -e "  操作系统: ${BOLD}${OS}${NC} | 架构: ${BOLD}${ARCH_LABEL}${NC}"
    echo ""

    # 检查是否已安装
    if has_cmd openclaw; then
        local installed_ver
        installed_ver=$(openclaw --version 2>/dev/null || echo "未知")
        msg_warn "OpenClaw 已安装 (版本: $installed_ver)"
        if ! confirm "是否重新安装/升级?"; then
            return
        fi
    fi

    # Step 1: 安装系统依赖
    msg_step "Step 1/5: 安装系统基础依赖..."
    case "$OS" in
        debian)
            sudo apt-get update -qq >> "$LOG_FILE" 2>&1
            sudo apt-get install -y curl wget git build-essential ca-certificates gnupg >> "$LOG_FILE" 2>&1
            ;;
        rhel|fedora)
            $UPDATE_CMD >> "$LOG_FILE" 2>&1
            $INSTALL_CMD curl wget git gcc gcc-c++ make >> "$LOG_FILE" 2>&1
            ;;
        arch)
            sudo pacman -Sy --noconfirm curl wget git base-devel >> "$LOG_FILE" 2>&1
            ;;
        alpine)
            sudo apk update >> "$LOG_FILE" 2>&1
            sudo apk add curl wget git build-base >> "$LOG_FILE" 2>&1
            ;;
        macos)
            if ! has_cmd brew; then
                msg_step "安装 Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >> "$LOG_FILE" 2>&1
            fi
            brew install curl wget git >> "$LOG_FILE" 2>&1
            ;;
    esac
    msg_ok "基础依赖安装完成"

    # Step 2: 安装 Node.js
    msg_step "Step 2/5: 检查并安装 Node.js..."
    install_nodejs

    # Step 3: 安装 OpenClaw
    msg_step "Step 3/5: 安装 OpenClaw..."
    echo ""
    echo -e "${CYAN}选择安装方式:${NC}"
    echo "  1) 官方安装脚本 (openclaw.ai/install.sh) [推荐]"
    echo "  2) npm 全局安装 (npm install -g openclaw)"
    echo "  3) 从 GitHub 源码安装"
    echo ""
    read -rp "$(echo -e "${BOLD}请选择 [1-3] (默认: 1): ${NC}")" install_choice
    install_choice=${install_choice:-1}

    case "$install_choice" in
        1)
            msg_info "正在从官方源下载安装脚本..."
            if curl -fsSL https://openclaw.ai/install.sh | bash >> "$LOG_FILE" 2>&1; then
                msg_ok "OpenClaw 官方脚本安装成功"
            else
                msg_warn "官方脚本安装失败，尝试 npm 安装..."
                npm install -g openclaw@latest >> "$LOG_FILE" 2>&1
            fi
            ;;
        2)
            msg_info "通过 npm 安装 openclaw@latest..."
            npm install -g openclaw@latest 2>&1 | tee -a "$LOG_FILE"
            ;;
        3)
            echo -ne "${BOLD}请输入 GitHub 仓库地址 (默认: https://github.com/openclaw-ai/openclaw): ${NC}"
            read -r repo_url
            repo_url=${repo_url:-"https://github.com/openclaw-ai/openclaw"}
            git clone "$repo_url" /tmp/openclaw_src >> "$LOG_FILE" 2>&1
            cd /tmp/openclaw_src
            npm install >> "$LOG_FILE" 2>&1
            npm run build >> "$LOG_FILE" 2>&1
            npm install -g . >> "$LOG_FILE" 2>&1
            cd -
            ;;
    esac

    # 验证安装
    if has_cmd openclaw; then
        msg_ok "OpenClaw $(openclaw --version 2>/dev/null) 安装成功!"
    else
        # 尝试刷新 PATH
        export PATH="$PATH:$(npm root -g 2>/dev/null)/.bin:$HOME/.local/bin:/usr/local/bin"
        if has_cmd openclaw; then
            msg_ok "OpenClaw 安装成功 (已刷新 PATH)"
        else
            msg_fail "OpenClaw 安装可能失败，请检查日志: $LOG_FILE"
            press_any_key
            return 1
        fi
    fi

    # Step 4: 配置 API Key
    msg_step "Step 4/5: 配置第三方 LLM API 密钥..."
    echo ""
    if confirm "是否现在配置 AI API 密钥？(推荐)"; then
        configure_api_keys
    else
        msg_info "跳过 API 配置，可稍后通过菜单 [3] 重新配置"
    fi

    # Step 5: 初始化并启动服务
    msg_step "Step 5/5: 初始化 Gateway 并配置自启动..."
    echo ""

    # 运行 onboard
    msg_info "正在初始化 OpenClaw Gateway..."
    if openclaw onboard --install-daemon --non-interactive >> "$LOG_FILE" 2>&1; then
        msg_ok "Gateway 初始化成功 (systemd daemon 已安装)"
    else
        msg_warn "非交互式初始化失败，尝试手动初始化..."
        openclaw gateway start >> "$LOG_FILE" 2>&1 &
        sleep 2
    fi

    # 尝试启用系统服务
    service_action enable 2>/dev/null || true
    service_action start  2>/dev/null || true

    sleep 2

    # 验证 Gateway 是否启动
    if curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}/health" &>/dev/null \
       || openclaw gateway status 2>/dev/null | grep -qi "running"; then
        msg_ok "Gateway 已成功启动!"
    else
        msg_warn "Gateway 可能需要几秒钟才能完全启动，请稍候..."
    fi

    echo ""
    print_line
    echo -e "${GREEN}${BOLD}🎉 OpenClaw 安装完成!${NC}"
    print_line
    show_dashboard_info

    log "OpenClaw installation completed"
    press_any_key
}

# ─────────────────────────────────────────
#  功能模块: 查看版本信息
# ─────────────────────────────────────────

show_version() {
    msg_title "📦 版本信息"

    if ! has_cmd openclaw; then
        msg_fail "OpenClaw 未安装"
        press_any_key
        return
    fi

    print_line
    echo -e "  ${BOLD}OpenClaw CLI${NC}  : $(openclaw --version 2>/dev/null || echo '未知')"
    echo -e "  ${BOLD}Node.js${NC}       : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}npm${NC}           : v$(npm -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}操作系统${NC}      : $(uname -srm)"
    echo -e "  ${BOLD}脚本版本${NC}      : ${SCRIPT_VERSION}"
    print_line
    echo ""

    # 检查最新版本
    msg_info "正在检查最新版本..."
    local latest
    latest=$(curl -s --max-time 5 https://registry.npmjs.org/openclaw/latest 2>/dev/null \
             | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 \
             || echo "无法获取")

    local current
    current=$(openclaw --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo "0")

    echo -e "  ${BOLD}当前版本${NC}      : $current"
    echo -e "  ${BOLD}最新版本${NC}      : $latest"

    if [[ "$latest" != "无法获取" && "$latest" != "$current" ]]; then
        echo ""
        msg_warn "发现新版本 $latest，当前为 $current"
        if confirm "是否立即升级到最新版本?"; then
            msg_step "正在升级 OpenClaw..."
            npm install -g openclaw@latest 2>&1 | tail -5
            msg_ok "升级完成! 新版本: $(openclaw --version 2>/dev/null)"
        fi
    else
        echo ""
        msg_ok "当前已是最新版本"
    fi

    press_any_key
}

# ─────────────────────────────────────────
#  功能模块: 启动/重启/停止服务
# ─────────────────────────────────────────

manage_service() {
    local action="$1"
    detect_system

    case "$action" in
        start)
            msg_step "正在启动 OpenClaw Gateway..."
            service_action start
            sleep 2
            if openclaw gateway status 2>/dev/null | grep -qi "running" \
               || curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                msg_ok "Gateway 启动成功!"
                show_dashboard_info
            else
                msg_warn "Gateway 可能仍在启动中，请稍候 10 秒后检查状态"
            fi
            ;;
        stop)
            if confirm "确认停止 OpenClaw Gateway?"; then
                msg_step "正在停止 OpenClaw Gateway..."
                service_action stop
                sleep 1
                msg_ok "Gateway 已停止"
            fi
            ;;
        restart)
            msg_step "正在重启 OpenClaw Gateway..."
            service_action restart
            sleep 3
            msg_ok "Gateway 已重启"
            show_dashboard_info
            ;;
        status)
            msg_step "Gateway 运行状态:"
            echo ""
            service_action status
            echo ""
            show_dashboard_info
            ;;
    esac

    press_any_key
}

# ─────────────────────────────────────────
#  功能模块: 诊断与修复
# ─────────────────────────────────────────

diagnose_and_fix() {
    msg_title "${DOCTOR} 系统诊断与自动修复"
    detect_system

    local issues=0
    local fixed=0

    echo -e "${CYAN}${BOLD}开始全面诊断检测...${NC}"
    echo ""

    # 检查 1: OpenClaw 是否安装
    echo -ne "  检查 OpenClaw 安装状态...  "
    if has_cmd openclaw; then
        echo -e "${GREEN}${OK} 已安装 ($(openclaw --version 2>/dev/null))${NC}"
    else
        echo -e "${RED}${FAIL} 未安装${NC}"
        ((issues++))
        if confirm "  是否立即安装 OpenClaw?"; then
            install_openclaw
            ((fixed++))
        fi
    fi

    # 检查 2: Node.js 版本
    echo -ne "  检查 Node.js 版本...        "
    if has_cmd node; then
        local node_ver
        node_ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$node_ver" -ge "$NODE_MIN_VERSION" ]]; then
            echo -e "${GREEN}${OK} $(node -v) (满足 v${NODE_MIN_VERSION}+)${NC}"
        else
            echo -e "${RED}${FAIL} $(node -v) 低于最低要求 v${NODE_MIN_VERSION}${NC}"
            ((issues++))
            if confirm "  是否自动升级 Node.js?"; then
                install_nodejs
                ((fixed++))
            fi
        fi
    else
        echo -e "${RED}${FAIL} 未安装${NC}"
        ((issues++))
        install_nodejs && ((fixed++)) || true
    fi

    # 检查 3: Gateway 端口
    echo -ne "  检查端口 ${OPENCLAW_PORT} 状态...    "
    if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
        echo -e "${GREEN}${OK} 端口 ${OPENCLAW_PORT} 响应正常${NC}"
    else
        echo -e "${YELLOW}${WARN} 端口 ${OPENCLAW_PORT} 无响应 (Gateway 可能未运行)${NC}"
        ((issues++))
        if confirm "  是否尝试启动 Gateway?"; then
            service_action start 2>/dev/null || openclaw gateway start &
            sleep 3
            curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null \
                && msg_ok "Gateway 启动成功" && ((fixed++)) \
                || msg_warn "Gateway 启动失败，请检查日志"
        fi
    fi

    # 检查 4: 配置文件
    echo -ne "  检查配置文件...             "
    if [[ -f "$OPENCLAW_CONFIG_DIR/config.json" ]]; then
        echo -e "${GREEN}${OK} 配置文件存在${NC}"
    else
        echo -e "${YELLOW}${WARN} 配置文件不存在${NC}"
        ((issues++))
        msg_info "  提示: 请通过菜单 [3] 配置 API 密钥"
    fi

    # 检查 5: systemd 服务
    echo -ne "  检查 systemd 服务...        "
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if systemctl is-enabled "$OPENCLAW_SERVICE" &>/dev/null \
           || systemctl --user is-enabled "$OPENCLAW_SERVICE" &>/dev/null; then
            echo -e "${GREEN}${OK} 服务已启用 (开机自启)${NC}"
        else
            echo -e "${YELLOW}${WARN} 服务未设置开机自启${NC}"
            ((issues++))
            if confirm "  是否设置 OpenClaw 开机自启?"; then
                service_action enable 2>/dev/null && msg_ok "已设置开机自启" && ((fixed++)) || true
            fi
        fi
    else
        echo -e "${DIM}跳过 (非 systemd 系统)${NC}"
    fi

    # 检查 6: 磁盘空间
    echo -ne "  检查磁盘空间...             "
    local disk_avail
    disk_avail=$(df "$HOME" | awk 'NR==2{print $4}')
    if [[ "$disk_avail" -gt 1048576 ]]; then  # > 1GB
        echo -e "${GREEN}${OK} 可用空间充足 ($(df -h "$HOME" | awk 'NR==2{print $4}'))${NC}"
    else
        echo -e "${RED}${FAIL} 磁盘空间不足 ($(df -h "$HOME" | awk 'NR==2{print $4}'))${NC}"
        ((issues++))
        msg_warn "  建议清理日志文件: $OPENCLAW_LOG_DIR"
        if confirm "  是否清理 OpenClaw 日志文件?"; then
            rm -rf "${OPENCLAW_LOG_DIR:?}"/*.log 2>/dev/null && msg_ok "日志已清理" && ((fixed++)) || true
        fi
    fi

    # 检查 7: 内存
    echo -ne "  检查内存状态...             "
    local mem_avail
    mem_avail=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    if [[ "$mem_avail" -gt 512000 ]]; then  # > 512MB
        echo -e "${GREEN}${OK} 可用内存: $(awk "BEGIN {printf \"%.0f\", $mem_avail/1024}") MB${NC}"
    else
        echo -e "${RED}${FAIL} 可用内存不足 ($(awk "BEGIN {printf \"%.0f\", $mem_avail/1024}") MB)${NC}"
        ((issues++))
        msg_warn "  建议: 关闭其他进程释放内存，或扩大 swap"
        if confirm "  是否创建 2GB swap 文件以缓解内存压力?"; then
            if [[ ! -f /swapfile ]]; then
                sudo fallocate -l 2G /swapfile >> "$LOG_FILE" 2>&1
                sudo chmod 600 /swapfile
                sudo mkswap /swapfile >> "$LOG_FILE" 2>&1
                sudo swapon /swapfile
                echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >> "$LOG_FILE"
                msg_ok "2GB Swap 已创建并激活"
                ((fixed++))
            else
                msg_info "Swap 文件已存在"
            fi
        fi
    fi

    # 检查 8: 网络连通性
    echo -ne "  检查网络连通性...           "
    if curl -s --max-time 5 https://api.anthropic.com &>/dev/null \
       || curl -s --max-time 5 https://api.openai.com &>/dev/null; then
        echo -e "${GREEN}${OK} 外网连接正常${NC}"
    else
        echo -e "${YELLOW}${WARN} 无法连接 LLM API 端点${NC}"
        ((issues++))
        msg_warn "  请检查防火墙/代理设置，确保出站 HTTPS (443) 开放"
    fi

    # 运行 openclaw doctor（如果已安装）
    echo ""
    if has_cmd openclaw; then
        msg_step "运行 openclaw doctor 官方诊断..."
        openclaw doctor 2>&1 | sed 's/^/    /'
    fi

    # 汇总
    echo ""
    print_line
    echo -e "${BOLD}诊断结果汇总:${NC}"
    echo -e "  发现问题: ${RED}${BOLD}${issues}${NC} 个"
    echo -e "  已修复:   ${GREEN}${BOLD}${fixed}${NC} 个"
    if [[ $((issues - fixed)) -gt 0 ]]; then
        echo -e "  待处理:   ${YELLOW}${BOLD}$((issues - fixed))${NC} 个 (需手动处理)"
    fi
    echo -e "  详细日志: ${DIM}$LOG_FILE${NC}"
    print_line

    press_any_key
}

# ─────────────────────────────────────────
#  功能模块: 查看日志
# ─────────────────────────────────────────

view_logs() {
    msg_title "📋 日志查看"

    echo -e "${CYAN}选择日志类型:${NC}"
    echo "  1) 实时 Gateway 日志 (跟踪模式)"
    echo "  2) 系统服务日志 (systemd journal)"
    echo "  3) OpenClaw 应用日志文件"
    echo "  4) 本次安装脚本日志"
    echo "  0) 返回主菜单"
    echo ""
    read -rp "$(echo -e "${BOLD}请选择 [0-4]: ${NC}")" log_choice

    case "$log_choice" in
        1)
            msg_info "按 Ctrl+C 退出日志跟踪"
            sleep 1
            openclaw gateway logs --follow 2>/dev/null \
                || journalctl -u "$OPENCLAW_SERVICE" -f 2>/dev/null \
                || tail -f "${OPENCLAW_LOG_DIR}/gateway.log" 2>/dev/null \
                || msg_fail "无法获取实时日志"
            ;;
        2)
            detect_system
            if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
                sudo journalctl -u "$OPENCLAW_SERVICE" -n 100 --no-pager 2>/dev/null \
                    || journalctl --user -u "$OPENCLAW_SERVICE" -n 100 --no-pager 2>/dev/null \
                    || msg_fail "systemd 日志不可用"
            else
                msg_warn "当前系统不使用 systemd"
            fi
            ;;
        3)
            if [[ -d "$OPENCLAW_LOG_DIR" ]]; then
                echo -e "${CYAN}可用日志文件:${NC}"
                ls -lh "$OPENCLAW_LOG_DIR" 2>/dev/null
                echo ""
                read -rp "$(echo -e "${BOLD}输入文件名查看 (或 Enter 查看最新): ${NC}")" log_file
                if [[ -n "$log_file" ]]; then
                    less "${OPENCLAW_LOG_DIR}/${log_file}"
                else
                    local latest_log
                    latest_log=$(ls -t "${OPENCLAW_LOG_DIR}"/*.log 2>/dev/null | head -1)
                    [[ -n "$latest_log" ]] && less "$latest_log" || msg_warn "未找到日志文件"
                fi
            else
                msg_warn "日志目录不存在: $OPENCLAW_LOG_DIR"
            fi
            ;;
        4)
            if [[ -f "$LOG_FILE" ]]; then
                less "$LOG_FILE"
            else
                msg_warn "安装日志不存在: $LOG_FILE"
            fi
            ;;
        0) return ;;
    esac

    press_any_key
}

# ─────────────────────────────────────────
#  功能模块: 卸载 OpenClaw
# ─────────────────────────────────────────

uninstall_openclaw() {
    msg_title "${TRASH} 卸载 OpenClaw"

    echo -e "${RED}${BOLD}⚠️  警告: 此操作将卸载 OpenClaw 及相关组件${NC}"
    echo ""
    echo "  将要执行的操作:"
    echo "  • 停止并禁用 OpenClaw Gateway 服务"
    echo "  • 卸载 openclaw npm 包"
    echo "  • 可选: 删除配置文件和数据"
    echo ""

    if ! confirm "确认要卸载 OpenClaw 吗?"; then
        msg_info "已取消卸载"
        press_any_key
        return
    fi

    detect_system

    # 停止服务
    msg_step "停止 Gateway 服务..."
    service_action stop 2>/dev/null || true
    sleep 1

    # 禁用服务
    msg_step "禁用开机自启..."
    case "$SERVICE_MANAGER" in
        systemd)
            sudo systemctl disable "$OPENCLAW_SERVICE" 2>/dev/null \
                || systemctl --user disable "$OPENCLAW_SERVICE" 2>/dev/null || true
            sudo rm -f "/etc/systemd/system/${OPENCLAW_SERVICE}.service" 2>/dev/null || true
            sudo systemctl daemon-reload 2>/dev/null || true
            ;;
        launchd)
            local plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
            launchctl unload "$plist" 2>/dev/null || true
            rm -f "$plist" 2>/dev/null || true
            ;;
    esac
    msg_ok "服务已停止并禁用"

    # 卸载 npm 包
    msg_step "卸载 openclaw npm 包..."
    if npm uninstall -g openclaw >> "$LOG_FILE" 2>&1; then
        msg_ok "npm 包已卸载"
    else
        msg_warn "npm 卸载失败，尝试手动删除..."
        local npm_prefix
        npm_prefix=$(npm prefix -g 2>/dev/null || echo "/usr/local")
        sudo rm -f "${npm_prefix}/bin/openclaw" 2>/dev/null || true
        sudo rm -rf "${npm_prefix}/lib/node_modules/openclaw" 2>/dev/null || true
    fi

    # 询问是否删除数据
    echo ""
    if confirm "是否同时删除 OpenClaw 配置文件和数据? ($OPENCLAW_CONFIG_DIR)"; then
        rm -rf "$OPENCLAW_CONFIG_DIR"
        msg_ok "配置文件和数据已删除"
    else
        msg_info "配置文件已保留于: $OPENCLAW_CONFIG_DIR"
    fi

    echo ""
    msg_ok "OpenClaw 已成功卸载"
    log "OpenClaw uninstalled"
    press_any_key
}

# ─────────────────────────────────────────
#  主菜单 Banner
# ─────────────────────────────────────────

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
    echo -e "          ${DIM}一键交互式管理脚本 ${SCRIPT_VERSION} | 支持多系统/多架构${NC}"
    echo ""

    # 状态栏
    detect_system
    local status_color="${RED}"
    local status_text="未运行"
    if has_cmd openclaw; then
        if curl -s --max-time 2 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null \
           || openclaw gateway status 2>/dev/null | grep -qi "running"; then
            status_color="${GREEN}"
            status_text="运行中 ●"
        else
            status_color="${YELLOW}"
            status_text="已安装,未运行"
        fi
    fi

    echo -e "  ${DIM}系统:${NC} ${OS^^} ${ARCH_LABEL}   ${DIM}│${NC}   ${DIM}Gateway:${NC} ${status_color}${BOLD}${status_text}${NC}   ${DIM}│${NC}   ${DIM}端口:${NC} ${OPENCLAW_PORT}"
    print_line
}

# ─────────────────────────────────────────
#  主菜单
# ─────────────────────────────────────────

main_menu() {
    while true; do
        show_banner

        echo -e "${WHITE}${BOLD}  主菜单${NC}"
        echo ""
        echo -e "  ${BOLD}${GREEN}[1]${NC}  ${ROCKET} 安装 OpenClaw"
        echo -e "  ${BOLD}${GREEN}[2]${NC}  ${POWER} 启动 Gateway"
        echo -e "  ${BOLD}${GREEN}[3]${NC}  🔑 配置 API 密钥"
        echo -e "  ${BOLD}${CYAN}[4]${NC}  📊 查看控制面板 URL"
        echo -e "  ${BOLD}${CYAN}[5]${NC}  📦 查看/升级版本"
        echo -e "  ${BOLD}${CYAN}[6]${NC}  📋 查看日志"
        echo -e "  ${BOLD}${YELLOW}[7]${NC}  🔄 重启 Gateway"
        echo -e "  ${BOLD}${YELLOW}[8]${NC}  ⏹  停止 Gateway"
        echo -e "  ${BOLD}${YELLOW}[9]${NC}  📈 查看运行状态"
        echo -e "  ${BOLD}${MAGENTA}[10]${NC} ${DOCTOR} 诊断与修复"
        echo -e "  ${BOLD}${MAGENTA}[11]${NC} ℹ️  系统信息"
        echo -e "  ${BOLD}${RED}[12]${NC} ${TRASH} 卸载 OpenClaw"
        echo -e "  ${BOLD}[0]${NC}  🚪 退出脚本"
        echo ""
        print_line
        echo -ne "  ${BOLD}请输入选项编号: ${NC}"
        read -r choice

        case "$choice" in
            1)  install_openclaw ;;
            2)  manage_service start ;;
            3)  configure_api_keys; press_any_key ;;
            4)  show_dashboard_info; press_any_key ;;
            5)  show_version ;;
            6)  view_logs ;;
            7)  manage_service restart ;;
            8)  manage_service stop ;;
            9)  manage_service status ;;
            10) diagnose_and_fix ;;
            11) print_sysinfo; press_any_key ;;
            12) uninstall_openclaw ;;
            0)
                echo ""
                echo -e "${GREEN}${BOLD}感谢使用 OpenClaw 管理脚本，再见! 👋${NC}"
                echo ""
                exit 0
                ;;
            *)
                msg_warn "无效选项: $choice，请输入 0-12"
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────
#  入口: 支持命令行参数直接调用
# ─────────────────────────────────────────

case "${1:-}" in
    install)   detect_system; install_openclaw ;;
    start)     detect_system; manage_service start ;;
    stop)      detect_system; manage_service stop ;;
    restart)   detect_system; manage_service restart ;;
    status)    detect_system; manage_service status ;;
    version)   show_version ;;
    diagnose)  detect_system; diagnose_and_fix ;;
    uninstall) detect_system; uninstall_openclaw ;;
    url)       show_dashboard_info ;;
    *)         main_menu ;;
esac
