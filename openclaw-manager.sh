#!/usr/bin/env bash

set -uo pipefail

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
NC='\033[0m'

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
SCRIPT_VERSION="v1.1.0"
NODE_MIN_VERSION=20
LOG_FILE="/tmp/openclaw_install_$(date +%Y%m%d_%H%M%S).log"

# 动态版本缓存（运行时获取）
_NVM_LATEST=""
_NODE_LTS_VERSIONS=""
_NODE_LATEST_VERSION=""

# ─────────────────────────────────────────
#  工具函数
# ─────────────────────────────────────────

print_line() {
    echo -e "${DIM}$(printf '─%.0s' {1..60})${NC}"
}

msg_ok()    { echo -e "${GREEN}${OK}  $*${NC}"; }
msg_fail()  { echo -e "${RED}${FAIL}  $*${NC}"; }
msg_warn()  { echo -e "${YELLOW}${WARN} $*${NC}"; }
msg_info()  { echo -e "${CYAN}${INFO} $*${NC}"; }
msg_step()  { echo -e "\n${BLUE}${BOLD}${ARROW} $*${NC}"; }
msg_title() {
    echo ""
    echo -e "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    # 居中标题（纯 ASCII 安全计算）
    local title="$1"
    local width=58
    local tlen=${#title}
    local lpad=$(( (width - tlen) / 2 ))
    local rpad=$(( width - tlen - lpad ))
    printf "${MAGENTA}${BOLD}║%${lpad}s%s%${rpad}s║${NC}\n" "" "$title" ""
    echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 按 Enter 返回，所有子菜单结束时调用
press_any_key() {
    echo ""
    read -rp "$(echo -e "${DIM}按 Enter 键返回主菜单...${NC}")" _ || true
}

# 确认操作（y/N）
confirm() {
    local prompt="${1:-确认操作}"
    local answer
    echo -ne "${YELLOW}${WARN} ${prompt} [y/N]: ${NC}"
    read -r answer || answer="n"
    [[ "$answer" =~ ^[Yy]$ ]]
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

has_cmd() { command -v "$1" &>/dev/null; }

# 安全执行：失败只打印警告，不退出脚本
safe_run() {
    local desc="$1"; shift
    if "$@" >> "$LOG_FILE" 2>&1; then
        msg_ok "$desc 成功"
        return 0
    else
        msg_warn "$desc 失败，详见日志: $LOG_FILE"
        return 1
    fi
}

# ─────────────────────────────────────────
#  动态版本获取函数
# ─────────────────────────────────────────

# 获取 nvm 最新稳定版本号（如 v0.40.1）
get_nvm_latest_version() {
    if [[ -n "$_NVM_LATEST" ]]; then
        echo "$_NVM_LATEST"
        return
    fi
    local ver
    # 从 GitHub releases API 获取
    ver=$(curl -s --max-time 8 \
        "https://api.github.com/repos/nvm-sh/nvm/releases/latest" \
        2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' \
        | head -1 \
        | grep -o 'v[0-9.]*')

    # fallback：从官网 README 解析（更稳定）
    if [[ -z "$ver" ]]; then
        ver=$(curl -s --max-time 8 \
            "https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/README.md" \
            2>/dev/null \
            | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' \
            | head -1)
    fi

    _NVM_LATEST="${ver:-v0.39.7}"   # 最终 fallback
    echo "$_NVM_LATEST"
}

# 获取 NodeSource 支持的最新 LTS 大版本列表
# 返回形如 "22 20 18" 的字符串（降序）
get_node_lts_versions() {
    if [[ -n "$_NODE_LTS_VERSIONS" ]]; then
        echo "$_NODE_LTS_VERSIONS"
        return
    fi
    local versions
    # 从 nodejs.org releases.json 获取 LTS 列表
    versions=$(curl -s --max-time 8 \
        "https://nodejs.org/dist/index.json" \
        2>/dev/null \
        | grep -o '"version":"v[0-9]*\.[0-9]*\.[0-9]*","[^}]*"lts":"[^f][^"]*"' \
        | grep -o '"version":"v[0-9]*' \
        | grep -o '[0-9]*$' \
        | sort -rn \
        | awk '!seen[$0]++' \
        | head -5 \
        | tr '\n' ' ')

    if [[ -z "$versions" ]]; then
        versions="22 20 18"   # fallback
    fi
    _NODE_LTS_VERSIONS="$versions"
    echo "$_NODE_LTS_VERSIONS"
}

# 获取 Node.js 当前 Current（最新）大版本号
get_node_latest_major() {
    if [[ -n "$_NODE_LATEST_VERSION" ]]; then
        echo "$_NODE_LATEST_VERSION"
        return
    fi
    local ver
    ver=$(curl -s --max-time 8 \
        "https://nodejs.org/dist/index.json" \
        2>/dev/null \
        | grep -o '"version":"v[0-9]*' \
        | head -1 \
        | grep -o '[0-9]*$')
    _NODE_LATEST_VERSION="${ver:-22}"
    echo "$_NODE_LATEST_VERSION"
}

# 获取指定 provider 在 npm 上的最新 openclaw 版本
get_openclaw_latest_version() {
    curl -s --max-time 8 \
        "https://registry.npmjs.org/openclaw/latest" \
        2>/dev/null \
        | grep -o '"version":"[^"]*"' \
        | head -1 \
        | cut -d'"' -f4 \
        || echo ""
}

# ─────────────────────────────────────────
#  系统检测
# ─────────────────────────────────────────

detect_system() {
    OS=""
    PKG_MANAGER=""
    INSTALL_CMD=""
    UPDATE_CMD=""
    SERVICE_MANAGER=""
    PRETTY_NAME=""

    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        SERVICE_MANAGER="launchd"
        PRETTY_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
        if has_cmd brew; then
            PKG_MANAGER="brew"
            INSTALL_CMD="brew install"
            UPDATE_CMD="brew update"
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
                INSTALL_CMD="sudo apt-get install -y"
                UPDATE_CMD="sudo apt-get update -qq"
                ;;
            centos|rhel|rocky|almalinux|ol)
                OS="rhel"; PKG_MANAGER="yum"
                INSTALL_CMD="sudo yum install -y"
                UPDATE_CMD="sudo yum update -y"
                ;;
            fedora)
                OS="fedora"; PKG_MANAGER="dnf"
                INSTALL_CMD="sudo dnf install -y"
                UPDATE_CMD="sudo dnf update -y"
                ;;
            arch|manjaro|endeavouros)
                OS="arch"; PKG_MANAGER="pacman"
                INSTALL_CMD="sudo pacman -S --noconfirm"
                UPDATE_CMD="sudo pacman -Sy"
                ;;
            alpine)
                OS="alpine"; PKG_MANAGER="apk"
                INSTALL_CMD="sudo apk add"
                UPDATE_CMD="sudo apk update"
                ;;
            *)
                OS="unknown"; PKG_MANAGER="unknown"
                ;;
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

    HAVE_SUDO=false
    if [[ "$OS" != "macos" ]]; then
        sudo -n true 2>/dev/null && HAVE_SUDO=true || HAVE_SUDO=true
    fi
}

print_sysinfo() {
    detect_system
    echo -e "${CYAN}${BOLD}系统信息摘要${NC}"
    print_line
    echo -e "  ${BOLD}操作系统${NC}    : $(echo "${OS}" | tr '[:lower:]' '[:upper:]') (${PRETTY_NAME})"
    echo -e "  ${BOLD}系统架构${NC}    : ${ARCH_LABEL}"
    echo -e "  ${BOLD}包管理器${NC}    : ${PKG_MANAGER}"
    echo -e "  ${BOLD}服务管理器${NC}  : ${SERVICE_MANAGER}"
    echo -e "  ${BOLD}主机名${NC}      : $(hostname)"
    echo -e "  ${BOLD}内存${NC}        : $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' \
                             || sysctl hw.memsize 2>/dev/null \
                                | awk '{printf "%.1f GB", $2/1073741824}' \
                             || echo '未知')"
    echo -e "  ${BOLD}CPU 核心${NC}    : $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '未知')"
    echo -e "  ${BOLD}磁盘可用${NC}    : $(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo '未知')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}npm${NC}         : $(npm -v 2>/dev/null | sed 's/^/v/' || echo '未安装')"
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw --version 2>/dev/null || echo '未安装')"
    print_line
}

# ─────────────────────────────────────────
#  Node.js 安装
# ─────────────────────────────────────────

# 让用户选择想要安装的 Node.js 版本
pick_node_version() {
    echo ""
    msg_info "正在从 nodejs.org 获取可用 LTS 版本..."
    local lts_list
    lts_list=$(get_node_lts_versions)    # 例："22 20 18"
    local latest_major
    latest_major=$(get_node_latest_major) # 例："23"

    echo ""
    echo -e "${CYAN}请选择要安装的 Node.js 版本:${NC}"

    # 动态构建选项
    local idx=1
    declare -a version_map=()

    # Current（最新非 LTS）
    if [[ "$latest_major" != "$(echo "$lts_list" | awk '{print $1}')" ]]; then
        echo "  ${idx}) Node.js ${latest_major} (Current - 最新特性，非 LTS)"
        version_map[$idx]="$latest_major"
        ((idx++))
    fi

    # LTS 列表
    for v in $lts_list; do
        local label="LTS"
        [[ $idx -eq $(( [[ "$v" == "$(echo "$lts_list" | awk '{print $1}')" ]] && echo 1 || echo 99 )) ]] \
            && label="LTS (最新稳定，推荐)"
        if [[ $idx -eq $(( ${#version_map[@]} + 1 )) ]] && [[ -z "${version_map[1]:-}" || "${version_map[1]}" != "$latest_major" ]]; then
            label="LTS (最新稳定，推荐)"
        fi
        echo "  ${idx}) Node.js ${v} (${label})"
        version_map[$idx]="$v"
        ((idx++))
    done

    echo "  ${idx}) 手动输入版本号"
    local manual_idx=$idx

    echo ""
    local default_choice=2
    [[ -z "${version_map[2]:-}" ]] && default_choice=1
    read -rp "$(echo -e "${BOLD}请选择 [1-${idx}] (默认: ${default_choice}): ${NC}")" ver_choice
    ver_choice=${ver_choice:-$default_choice}

    local selected_version=""
    if [[ "$ver_choice" -eq "$manual_idx" ]] 2>/dev/null; then
        read -rp "$(echo -e "${BOLD}请输入 Node.js 主版本号 (如 22, 20, 18): ${NC}")" selected_version
        selected_version=$(echo "$selected_version" | tr -d 'vV ')
    else
        selected_version="${version_map[$ver_choice]:-${version_map[$default_choice]}}"
    fi

    echo "$selected_version"
}

install_nodejs() {
    msg_step "检测 Node.js 版本..."

    if has_cmd node; then
        local ver
        ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$ver" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v) 已满足最低要求 (v${NODE_MIN_VERSION}+)"
            return 0
        else
            msg_warn "当前 Node.js 版本 $(node -v) 低于要求 v${NODE_MIN_VERSION}+，需要升级"
        fi
    else
        msg_warn "未检测到 Node.js，即将安装..."
    fi

    echo ""
    echo -e "${CYAN}请选择 Node.js 安装方式:${NC}"
    echo "  1) NodeSource 官方源  (推荐 Linux，系统级安装)"
    echo "  2) nvm 版本管理器     (灵活，支持多版本切换)"
    echo "  3) 包管理器原生安装   (apt/yum/brew，版本由系统决定)"
    echo "  4) 手动安装           (自行下载，高级用户)"
    echo ""
    read -rp "$(echo -e "${BOLD}请输入选项 [1-4] (默认: 1): ${NC}")" node_choice
    node_choice=${node_choice:-1}

    # 选择目标版本（nvm 和 NodeSource 时需要）
    local target_version="$NODE_MIN_VERSION"
    if [[ "$node_choice" -eq 1 || "$node_choice" -eq 2 ]]; then
        target_version=$(pick_node_version)
        if [[ -z "$target_version" ]]; then
            msg_warn "未选择版本，使用默认 v${NODE_MIN_VERSION}"
            target_version="$NODE_MIN_VERSION"
        fi
        msg_info "目标 Node.js 版本: v${target_version}"
    fi

    case "$node_choice" in
        1) _install_nodejs_nodesource "$target_version" ;;
        2) _install_nodejs_nvm        "$target_version" ;;
        3) _install_nodejs_native ;;
        4)
            echo ""
            msg_info "请手动下载安装 Node.js v${NODE_MIN_VERSION}+"
            msg_info "下载地址: https://nodejs.org/en/download/"
            return 1
            ;;
        *)
            msg_warn "无效选项，跳过 Node.js 安装"
            return 1
            ;;
    esac

    # 刷新 PATH（nvm 场景）
    _refresh_node_path

    if has_cmd node; then
        local installed_ver
        installed_ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$installed_ver" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v) 安装成功！"
            log "Node.js $(node -v) installed"
            return 0
        fi
    fi

    msg_fail "Node.js 安装失败或版本不满足要求，请查看日志: $LOG_FILE"
    return 1
}

_install_nodejs_nodesource() {
    local version="$1"
    msg_step "使用 NodeSource 安装 Node.js v${version}..."
    case "$OS" in
        debian)
            safe_run "下载 NodeSource 安装脚本" \
                bash -c "curl -fsSL https://deb.nodesource.com/setup_${version}.x | sudo -E bash -"
            safe_run "安装 nodejs 包" sudo apt-get install -y nodejs
            ;;
        rhel|fedora)
            safe_run "下载 NodeSource 安装脚本" \
                bash -c "curl -fsSL https://rpm.nodesource.com/setup_${version}.x | sudo bash -"
            safe_run "安装 nodejs 包" sudo "$PKG_MANAGER" install -y nodejs
            ;;
        arch)
            # Arch 通过 pacman 安装（版本由仓库决定，忽略 target_version）
            msg_info "Arch Linux 使用 pacman 安装 nodejs（版本由官方仓库决定）"
            safe_run "安装 nodejs npm" sudo pacman -S --noconfirm nodejs npm
            ;;
        alpine)
            safe_run "安装 nodejs npm" sudo apk add nodejs npm
            ;;
        macos)
            has_cmd brew || { msg_fail "请先安装 Homebrew"; return 1; }
            safe_run "安装 node@${version}" brew install "node@${version}"
            brew link --force --overwrite "node@${version}" 2>/dev/null || true
            ;;
        *)
            msg_fail "不支持当前系统的 NodeSource 安装，请选择 nvm 方式"
            return 1
            ;;
    esac
}

_install_nodejs_nvm() {
    local version="$1"
    msg_step "使用 nvm 安装 Node.js v${version}..."

    # 获取 nvm 最新版本
    msg_info "正在获取 nvm 最新版本..."
    local nvm_ver
    nvm_ver=$(get_nvm_latest_version)
    msg_info "nvm 版本: ${nvm_ver}"

    # 安装/更新 nvm
    if [[ ! -d "$HOME/.nvm" ]]; then
        safe_run "安装 nvm ${nvm_ver}" \
            bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_ver}/install.sh | bash"
    else
        msg_info "nvm 已存在，尝试更新到 ${nvm_ver}..."
        safe_run "更新 nvm ${nvm_ver}" \
            bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_ver}/install.sh | bash"
    fi

    # 激活 nvm
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" || {
        msg_fail "nvm 加载失败"
        return 1
    }

    # 安装目标版本：支持 "lts/*" 或具体大版本号
    local nvm_target="$version"
    safe_run "nvm install ${nvm_target}" nvm install "$nvm_target"
    nvm use "$nvm_target" >> "$LOG_FILE" 2>&1 || true
    nvm alias default "$nvm_target" >> "$LOG_FILE" 2>&1 || true

    # 写入 shell 配置文件（持久化）
    local shell_rc="$HOME/.bashrc"
    [[ -n "${ZSH_VERSION:-}" || "$SHELL" == *zsh* ]] && shell_rc="$HOME/.zshrc"
    if ! grep -q "NVM_DIR" "$shell_rc" 2>/dev/null; then
        {
            echo ''
            echo '# nvm - Node Version Manager'
            echo 'export NVM_DIR="$HOME/.nvm"'
            echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
            echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
        } >> "$shell_rc"
        msg_info "已将 nvm 初始化代码写入 $shell_rc"
    fi
}

_install_nodejs_native() {
    msg_step "使用系统包管理器安装 Node.js..."
    msg_info "注意：版本由系统仓库决定，可能不是最新版本"
    case "$OS" in
        debian)
            safe_run "更新 apt 缓存" sudo apt-get update -qq
            safe_run "安装 nodejs npm" sudo apt-get install -y nodejs npm
            ;;
        rhel)
            safe_run "安装 nodejs npm" sudo yum install -y nodejs npm
            ;;
        fedora)
            safe_run "安装 nodejs npm" sudo dnf install -y nodejs npm
            ;;
        arch)
            safe_run "安装 nodejs npm" sudo pacman -S --noconfirm nodejs npm
            ;;
        alpine)
            safe_run "安装 nodejs npm" sudo apk add nodejs npm
            ;;
        macos)
            has_cmd brew || { msg_fail "请先安装 Homebrew"; return 1; }
            safe_run "brew 安装 node" brew install node
            ;;
        *)
            msg_fail "不支持当前系统，请手动安装 Node.js"
            return 1
            ;;
    esac
}

_refresh_node_path() {
    # 尝试各种可能路径
    local paths=(
        "$HOME/.nvm/versions/node/$(ls "$HOME/.nvm/versions/node/" 2>/dev/null | sort -V | tail -1)/bin"
        "$HOME/.local/bin"
        "/usr/local/bin"
        "/usr/bin"
        "$(npm prefix -g 2>/dev/null)/bin"
    )
    for p in "${paths[@]}"; do
        [[ -d "$p" ]] && export PATH="$p:$PATH"
    done
    # 重新 source nvm（如果存在）
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
}

# ─────────────────────────────────────────
#  模型列表动态获取
# ─────────────────────────────────────────

# 从 npm registry 或 openclaw 内置获取支持模型列表（有回退）
get_provider_models() {
    local provider="$1"
    # 优先问 openclaw 自己（如果已安装）
    if has_cmd openclaw; then
        local models
        models=$(openclaw models list --provider "$provider" --json 2>/dev/null \
                 | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | head -20)
        [[ -n "$models" ]] && { echo "$models"; return; }
    fi
    # 静态回退列表（保持更新友好的注释说明）
    case "$provider" in
        anthropic)
            # 见 https://docs.anthropic.com/en/docs/about-claude/models
            printf '%s\n' \
                "claude-opus-4-5" \
                "claude-sonnet-4-5" \
                "claude-haiku-3-5" \
                "claude-opus-4-0" \
                "claude-sonnet-3-7" \
                "claude-haiku-3-0"
            ;;
        openai)
            # 见 https://platform.openai.com/docs/models
            printf '%s\n' \
                "gpt-4o" \
                "gpt-4o-mini" \
                "gpt-4-turbo" \
                "gpt-4" \
                "o1" \
                "o1-mini" \
                "o3-mini"
            ;;
        google)
            printf '%s\n' \
                "gemini-2.0-flash-exp" \
                "gemini-1.5-pro" \
                "gemini-1.5-flash" \
                "gemini-1.5-flash-8b"
            ;;
        deepseek)
            printf '%s\n' \
                "deepseek-chat" \
                "deepseek-reasoner" \
                "deepseek-coder"
            ;;
        groq)
            printf '%s\n' \
                "llama-3.3-70b-versatile" \
                "llama-3.1-8b-instant" \
                "mixtral-8x7b-32768" \
                "gemma2-9b-it"
            ;;
        mistral)
            printf '%s\n' \
                "mistral-large-latest" \
                "mistral-medium" \
                "mistral-small" \
                "open-mistral-7b"
            ;;
    esac
}

# 交互式模型选择，返回选定的模型名
pick_model_interactive() {
    local provider="$1"
    local default_model="$2"

    # 获取模型列表
    local models
    mapfile -t models < <(get_provider_models "$provider")

    if [[ ${#models[@]} -eq 0 ]]; then
        # 无法获取列表，直接手动输入
        echo ""
        echo -ne "  ${CYAN}请手动输入模型名称 (默认: ${default_model}): ${NC}"
        local m; read -r m
        echo "${m:-$default_model}"
        return
    fi

    echo ""
    echo -e "  ${CYAN}选择默认模型 (从 ${provider} 当前支持列表获取):${NC}"
    local i=1
    for m in "${models[@]}"; do
        local tag=""
        [[ "$m" == "$default_model" ]] && tag=" ${GREEN}[推荐]${NC}"
        printf "    %2d) %s%b\n" "$i" "$m" "$tag"
        ((i++))
    done
    echo "    $i) 手动输入模型名称"
    local manual_idx=$i
    echo ""

    # 找到推荐模型的默认序号
    local default_idx=1
    for j in "${!models[@]}"; do
        if [[ "${models[$j]}" == "$default_model" ]]; then
            default_idx=$((j + 1))
            break
        fi
    done

    read -rp "  请选择 [1-${manual_idx}] (默认: ${default_idx}): " m_choice
    m_choice=${m_choice:-$default_idx}

    if [[ "$m_choice" -eq "$manual_idx" ]] 2>/dev/null; then
        echo -ne "  请输入模型名称: "
        local custom_model; read -r custom_model
        echo "${custom_model:-$default_model}"
    elif [[ "$m_choice" -ge 1 && "$m_choice" -le ${#models[@]} ]] 2>/dev/null; then
        echo "${models[$((m_choice - 1))]}"
    else
        echo "$default_model"
    fi
}

# ─────────────────────────────────────────
#  API Key 配置
# ─────────────────────────────────────────

configure_api_keys() {
    msg_title "🔑 配置第三方 LLM API 密钥"

    echo -e "${CYAN}支持以下 AI 服务提供商:${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} Anthropic Claude   (claude-opus/sonnet/haiku 系列)"
    echo -e "  ${BOLD}2)${NC} OpenAI             (GPT-4o, o1, o3 系列)"
    echo -e "  ${BOLD}3)${NC} Google Gemini      (Gemini 2.0/1.5 系列)"
    echo -e "  ${BOLD}4)${NC} DeepSeek           (deepseek-chat/reasoner/coder)"
    echo -e "  ${BOLD}5)${NC} Groq               (Llama/Mixtral 高速推理)"
    echo -e "  ${BOLD}6)${NC} Mistral AI         (mistral-large/medium/small)"
    echo -e "  ${BOLD}7)${NC} 自定义 OpenAI 兼容 API (本地模型/代理)"
    echo -e "  ${BOLD}0)${NC} 完成配置并保存"
    echo ""

    local config_file="$OPENCLAW_CONFIG_DIR/config.json"
    mkdir -p "$OPENCLAW_CONFIG_DIR"

    declare -A api_keys
    declare -A api_models

    while true; do
        echo -ne "${BOLD}请输入要配置的提供商编号 (0 完成): ${NC}"
        read -r provider_choice || provider_choice="0"

        case "$provider_choice" in
            0) break ;;

            1)
                echo ""
                echo -e "${CYAN}${BOLD}─── Anthropic Claude ───${NC}"
                echo -e "${DIM}API Key 获取: https://console.anthropic.com/settings/keys${NC}"
                echo -e "${DIM}模型文档: https://docs.anthropic.com/en/docs/about-claude/models${NC}"
                echo ""
                echo -ne "  请输入 Anthropic API Key (sk-ant-...): "
                read -rs anthropic_key; echo ""
                if [[ -n "$anthropic_key" ]]; then
                    local sel_model
                    sel_model=$(pick_model_interactive "anthropic" "claude-sonnet-4-5")
                    api_keys["anthropic"]="$anthropic_key"
                    api_models["anthropic"]="$sel_model"
                    msg_ok "Anthropic 已配置 → ${api_models[anthropic]}"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            2)
                echo ""
                echo -e "${CYAN}${BOLD}─── OpenAI ───${NC}"
                echo -e "${DIM}API Key 获取: https://platform.openai.com/api-keys${NC}"
                echo -e "${DIM}模型文档: https://platform.openai.com/docs/models${NC}"
                echo ""
                echo -ne "  请输入 OpenAI API Key (sk-...): "
                read -rs openai_key; echo ""
                if [[ -n "$openai_key" ]]; then
                    local sel_model
                    sel_model=$(pick_model_interactive "openai" "gpt-4o")
                    api_keys["openai"]="$openai_key"
                    api_models["openai"]="$sel_model"
                    msg_ok "OpenAI 已配置 → ${api_models[openai]}"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            3)
                echo ""
                echo -e "${CYAN}${BOLD}─── Google Gemini ───${NC}"
                echo -e "${DIM}API Key 获取: https://aistudio.google.com/app/apikey${NC}"
                echo ""
                echo -ne "  请输入 Google API Key: "
                read -rs google_key; echo ""
                if [[ -n "$google_key" ]]; then
                    local sel_model
                    sel_model=$(pick_model_interactive "google" "gemini-2.0-flash-exp")
                    api_keys["google"]="$google_key"
                    api_models["google"]="$sel_model"
                    msg_ok "Google 已配置 → ${api_models[google]}"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            4)
                echo ""
                echo -e "${CYAN}${BOLD}─── DeepSeek ───${NC}"
                echo -e "${DIM}API Key 获取: https://platform.deepseek.com/api_keys${NC}"
                echo ""
                echo -ne "  请输入 DeepSeek API Key (sk-...): "
                read -rs deepseek_key; echo ""
                if [[ -n "$deepseek_key" ]]; then
                    local sel_model
                    sel_model=$(pick_model_interactive "deepseek" "deepseek-chat")
                    api_keys["deepseek"]="$deepseek_key"
                    api_models["deepseek"]="$sel_model"
                    msg_ok "DeepSeek 已配置 → ${api_models[deepseek]}"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            5)
                echo ""
                echo -e "${CYAN}${BOLD}─── Groq ───${NC}"
                echo -e "${DIM}API Key 获取: https://console.groq.com/keys${NC}"
                echo ""
                echo -ne "  请输入 Groq API Key (gsk_...): "
                read -rs groq_key; echo ""
                if [[ -n "$groq_key" ]]; then
                    local sel_model
                    sel_model=$(pick_model_interactive "groq" "llama-3.3-70b-versatile")
                    api_keys["groq"]="$groq_key"
                    api_models["groq"]="$sel_model"
                    msg_ok "Groq 已配置 → ${api_models[groq]}"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            6)
                echo ""
                echo -e "${CYAN}${BOLD}─── Mistral AI ───${NC}"
                echo -e "${DIM}API Key 获取: https://console.mistral.ai/api-keys${NC}"
                echo ""
                echo -ne "  请输入 Mistral API Key: "
                read -rs mistral_key; echo ""
                if [[ -n "$mistral_key" ]]; then
                    local sel_model
                    sel_model=$(pick_model_interactive "mistral" "mistral-large-latest")
                    api_keys["mistral"]="$mistral_key"
                    api_models["mistral"]="$sel_model"
                    msg_ok "Mistral 已配置 → ${api_models[mistral]}"
                else
                    msg_warn "API Key 为空，已跳过"
                fi
                ;;

            7)
                echo ""
                echo -e "${CYAN}${BOLD}─── 自定义 OpenAI 兼容 API ───${NC}"
                echo -e "${DIM}适用于: Ollama、LM Studio、vLLM、one-api 等${NC}"
                echo ""
                echo -ne "  请输入 API Base URL (例: http://localhost:11434/v1): "
                read -r custom_url
                echo -ne "  请输入 API Key (无需认证请输入 none): "
                read -rs custom_key; echo ""
                echo -ne "  请输入模型名称 (例: llama3.2, qwen2.5): "
                read -r custom_model
                if [[ -n "$custom_url" && -n "$custom_model" ]]; then
                    api_keys["custom_url"]="$custom_url"
                    api_keys["custom_key"]="${custom_key:-none}"
                    api_models["custom"]="$custom_model"
                    msg_ok "自定义 API 已配置 → $custom_url | $custom_model"
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

    # ── 写入配置 ──
    if [[ ${#api_keys[@]} -gt 0 ]]; then
        msg_step "正在写入 API 配置..."

        if has_cmd openclaw; then
            # 优先通过 openclaw 原生命令写入
            [[ -n "${api_keys[anthropic]:-}"  ]] && openclaw config set anthropic.apiKey  "${api_keys[anthropic]}"   --silent 2>/dev/null || true
            [[ -n "${api_keys[anthropic]:-}"  ]] && openclaw config set anthropic.model   "${api_models[anthropic]:-}" --silent 2>/dev/null || true
            [[ -n "${api_keys[openai]:-}"     ]] && openclaw config set openai.apiKey     "${api_keys[openai]}"       --silent 2>/dev/null || true
            [[ -n "${api_keys[openai]:-}"     ]] && openclaw config set openai.model      "${api_models[openai]:-}"   --silent 2>/dev/null || true
            [[ -n "${api_keys[google]:-}"     ]] && openclaw config set google.apiKey     "${api_keys[google]}"       --silent 2>/dev/null || true
            [[ -n "${api_keys[google]:-}"     ]] && openclaw config set google.model      "${api_models[google]:-}"   --silent 2>/dev/null || true
            [[ -n "${api_keys[deepseek]:-}"   ]] && openclaw config set deepseek.apiKey   "${api_keys[deepseek]}"     --silent 2>/dev/null || true
            [[ -n "${api_keys[deepseek]:-}"   ]] && openclaw config set deepseek.model    "${api_models[deepseek]:-}" --silent 2>/dev/null || true
            [[ -n "${api_keys[groq]:-}"       ]] && openclaw config set groq.apiKey       "${api_keys[groq]}"         --silent 2>/dev/null || true
            [[ -n "${api_keys[groq]:-}"       ]] && openclaw config set groq.model        "${api_models[groq]:-}"     --silent 2>/dev/null || true
            [[ -n "${api_keys[mistral]:-}"    ]] && openclaw config set mistral.apiKey    "${api_keys[mistral]}"      --silent 2>/dev/null || true
            [[ -n "${api_keys[mistral]:-}"    ]] && openclaw config set mistral.model     "${api_models[mistral]:-}"  --silent 2>/dev/null || true
            if [[ -n "${api_keys[custom_url]:-}" ]]; then
                openclaw config set custom.baseUrl "${api_keys[custom_url]}"          --silent 2>/dev/null || true
                openclaw config set custom.apiKey  "${api_keys[custom_key]:-none}"    --silent 2>/dev/null || true
                openclaw config set custom.model   "${api_models[custom]:-}"          --silent 2>/dev/null || true
            fi
            msg_ok "API 配置已通过 openclaw config 写入"
        else
            # 回退：直接生成 JSON 文件（使用 Python3 确保格式正确）
            _write_config_json api_keys api_models "$config_file"
        fi
        log "API keys configured for: ${!api_keys[*]}"
    else
        msg_warn "未配置任何 API Key"
    fi
}

# 用 Python3 或纯 bash heredoc 写 JSON
_write_config_json() {
    # nameref 在 bash 4.3+，此处改用全局变量传递
    local config_file="$3"

    if has_cmd python3; then
        python3 - "$config_file" <<'PYEOF'
import json, sys, os

config_path = sys.argv[1]
os.makedirs(os.path.dirname(config_path), exist_ok=True)

try:
    with open(config_path) as f:
        config = json.load(f)
except Exception:
    config = {}

# 从环境变量读取（由外层 bash export）
import os as _os
providers = ['anthropic','openai','google','deepseek','groq','mistral']
for p in providers:
    key = _os.environ.get(f'API_KEY_{p.upper()}', '')
    model = _os.environ.get(f'API_MODEL_{p.upper()}', '')
    if key:
        config.setdefault(p, {})['apiKey'] = key
    if model:
        config.setdefault(p, {})['model'] = model

custom_url = _os.environ.get('API_KEY_CUSTOM_URL', '')
if custom_url:
    config['custom'] = {
        'baseUrl': custom_url,
        'apiKey':  _os.environ.get('API_KEY_CUSTOM_KEY', 'none'),
        'model':   _os.environ.get('API_MODEL_CUSTOM', ''),
    }

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print(f"Config written to {config_path}")
PYEOF
    else
        # 纯 bash：简单拼接（仅作最终回退）
        {
            echo "{"
            local comma=""
            for p in anthropic openai google deepseek groq mistral; do
                local k="api_keys[$p]"
                local m="api_models[$p]"
                if [[ -n "${!k:-}" ]]; then
                    echo "${comma}  \"${p}\": {\"apiKey\": \"${!k}\", \"model\": \"${!m:-}\"}"
                    comma=","
                fi
            done
            if [[ -n "${api_keys[custom_url]:-}" ]]; then
                echo "${comma}  \"custom\": {\"baseUrl\": \"${api_keys[custom_url]}\", \"apiKey\": \"${api_keys[custom_key]:-none}\", \"model\": \"${api_models[custom]:-}\"}"
            fi
            echo "}"
        } > "$config_file"
    fi

    chmod 600 "$config_file"
    msg_ok "API 配置已写入 $config_file"
}

# ─────────────────────────────────────────
#  服务管理
# ─────────────────────────────────────────

service_action() {
    local action="$1"
    detect_system

    case "$SERVICE_MANAGER" in
        systemd)
            case "$action" in
                start)   sudo systemctl start   "$OPENCLAW_SERVICE" 2>/dev/null \
                             || systemctl --user start   "$OPENCLAW_SERVICE" 2>/dev/null || true ;;
                stop)    sudo systemctl stop    "$OPENCLAW_SERVICE" 2>/dev/null \
                             || systemctl --user stop    "$OPENCLAW_SERVICE" 2>/dev/null || true ;;
                restart) sudo systemctl restart "$OPENCLAW_SERVICE" 2>/dev/null \
                             || systemctl --user restart "$OPENCLAW_SERVICE" 2>/dev/null || true ;;
                enable)  sudo systemctl enable --now "$OPENCLAW_SERVICE" 2>/dev/null \
                             || systemctl --user enable --now "$OPENCLAW_SERVICE" 2>/dev/null || true ;;
                status)  sudo systemctl status  "$OPENCLAW_SERVICE" --no-pager 2>/dev/null \
                             || systemctl --user status  "$OPENCLAW_SERVICE" --no-pager 2>/dev/null || true ;;
            esac
            ;;
        openrc)
            case "$action" in
                start)   sudo rc-service openclaw start   2>/dev/null || true ;;
                stop)    sudo rc-service openclaw stop    2>/dev/null || true ;;
                restart) sudo rc-service openclaw restart 2>/dev/null || true ;;
                enable)  sudo rc-update add openclaw      2>/dev/null || true ;;
                status)  sudo rc-service openclaw status  2>/dev/null || true ;;
            esac
            ;;
        launchd)
            local plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
            case "$action" in
                start)   launchctl load   "$plist" 2>/dev/null || true ;;
                stop)    launchctl unload "$plist" 2>/dev/null || true ;;
                restart) launchctl unload "$plist" 2>/dev/null || true
                         launchctl load   "$plist" 2>/dev/null || true ;;
                enable)  launchctl load   "$plist" 2>/dev/null || true ;;
                status)  launchctl list 2>/dev/null | grep -i openclaw || echo "服务未运行" ;;
            esac
            ;;
        *)
            case "$action" in
                start)   openclaw gateway start >> "$LOG_FILE" 2>&1 & ;;
                stop)    openclaw gateway stop  >> "$LOG_FILE" 2>&1 || true ;;
                restart) openclaw gateway stop  >> "$LOG_FILE" 2>&1 || true
                         sleep 1
                         openclaw gateway start >> "$LOG_FILE" 2>&1 & ;;
                status)  openclaw gateway status 2>/dev/null || echo "状态未知" ;;
            esac
            ;;
    esac
    return 0   # 确保不因服务命令失败而传播错误
}

# ─────────────────────────────────────────
#  控制面板 URL 信息
# ─────────────────────────────────────────

show_dashboard_info() {
    local local_ip
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' \
             || ipconfig getifaddr en0 2>/dev/null \
             || ip route get 1 2>/dev/null | grep -oP 'src \K\S+' \
             || echo "127.0.0.1")
    local public_ip
    public_ip=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null \
             || curl -s --max-time 4 https://ifconfig.me 2>/dev/null \
             || echo "无法获取")

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║            🎉 OpenClaw 控制面板访问信息                  ║${NC}"
    echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}本机访问 (推荐):${NC}                                        ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${CYAN}  http://127.0.0.1:${OPENCLAW_PORT}${NC}                         ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}局域网访问:${NC}                                             ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${CYAN}  http://${local_ip}:${OPENCLAW_PORT}${NC}                       ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}远程 SSH 隧道 (在本地终端运行):${NC}                         ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${YELLOW}  ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} user@${public_ip}${NC}  ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${DIM}  之后本地浏览器访问 http://127.0.0.1:${OPENCLAW_PORT}${NC}   ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}公网 IP:${NC}  ${public_ip}                              ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${RED}⚠️  请勿直接将端口 ${OPENCLAW_PORT} 暴露到公网！${NC}           ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${DIM}  使用 SSH 隧道 / Tailscale / Nginx 反代 访问${NC}       ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ─────────────────────────────────────────
#  安装 OpenClaw
# ─────────────────────────────────────────

install_openclaw() {
    msg_title "${ROCKET} 安装 OpenClaw"
    detect_system

    echo -e "${CYAN}当前系统环境:${NC}"
    echo -e "  操作系统: ${BOLD}${OS}${NC} | 架构: ${BOLD}${ARCH_LABEL}${NC}"
    echo ""

    if has_cmd openclaw; then
        local installed_ver
        installed_ver=$(openclaw --version 2>/dev/null || echo "未知")
        msg_warn "OpenClaw 已安装 (版本: $installed_ver)"
        if ! confirm "是否重新安装/升级?"; then
            return 0   # return 而非 exit
        fi
    fi

    # ── Step 1: 系统依赖 ──
    msg_step "Step 1/5: 安装系统基础依赖..."
    case "$OS" in
        debian)
            safe_run "apt update"            sudo apt-get update -qq
            safe_run "安装基础依赖"          sudo apt-get install -y curl wget git build-essential ca-certificates gnupg
            ;;
        rhel|fedora)
            safe_run "更新包缓存"            bash -c "$UPDATE_CMD"
            safe_run "安装基础依赖"          bash -c "$INSTALL_CMD curl wget git gcc gcc-c++ make"
            ;;
        arch)
            safe_run "更新 pacman"           sudo pacman -Sy --noconfirm
            safe_run "安装基础依赖"          sudo pacman -S --noconfirm curl wget git base-devel
            ;;
        alpine)
            safe_run "apk update"            sudo apk update
            safe_run "安装基础依赖"          sudo apk add curl wget git build-base
            ;;
        macos)
            if ! has_cmd brew; then
                msg_step "安装 Homebrew..."
                safe_run "安装 Homebrew" \
                    bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            fi
            safe_run "安装基础工具"          brew install curl wget git
            ;;
    esac
    msg_ok "基础依赖安装完成"

    # ── Step 2: Node.js ──
    msg_step "Step 2/5: 检查并安装 Node.js..."
    install_nodejs || {
        msg_fail "Node.js 安装失败，终止安装 OpenClaw"
        press_any_key
        return 1
    }

    # ── Step 3: 安装 OpenClaw ──
    msg_step "Step 3/5: 安装 OpenClaw..."
    echo ""
    echo -e "${CYAN}选择安装方式:${NC}"
    echo "  1) 官方安装脚本 (openclaw.ai/install.sh)  [推荐]"
    echo "  2) npm 全局安装 (npm install -g openclaw)"
    echo "  3) 从 GitHub 源码编译安装"
    echo ""
    read -rp "$(echo -e "${BOLD}请选择 [1-3] (默认: 1): ${NC}")" install_choice
    install_choice=${install_choice:-1}

    local install_ok=false
    case "$install_choice" in
        1)
            msg_info "正在从官方源下载安装脚本..."
            if curl -fsSL https://openclaw.ai/install.sh | bash >> "$LOG_FILE" 2>&1; then
                install_ok=true
                msg_ok "官方脚本安装成功"
            else
                msg_warn "官方脚本失败，回退到 npm 安装..."
                if npm install -g openclaw@latest >> "$LOG_FILE" 2>&1; then
                    install_ok=true
                fi
            fi
            ;;
        2)
            msg_info "通过 npm 安装 openclaw@latest..."
            if npm install -g openclaw@latest 2>&1 | tee -a "$LOG_FILE"; then
                install_ok=true
            fi
            ;;
        3)
            echo -ne "${BOLD}GitHub 仓库地址 (默认: https://github.com/openclaw-ai/openclaw): ${NC}"
            read -r repo_url
            repo_url=${repo_url:-"https://github.com/openclaw-ai/openclaw"}
            local tmp_src="/tmp/openclaw_src_$$"
            if git clone "$repo_url" "$tmp_src" >> "$LOG_FILE" 2>&1; then
                pushd "$tmp_src" > /dev/null
                npm install   >> "$LOG_FILE" 2>&1 || true
                npm run build >> "$LOG_FILE" 2>&1 || true
                npm install -g . >> "$LOG_FILE" 2>&1 && install_ok=true
                popd > /dev/null
                rm -rf "$tmp_src"
            fi
            ;;
    esac

    _refresh_node_path

    if ! has_cmd openclaw; then
        msg_fail "OpenClaw 安装失败，请检查日志: $LOG_FILE"
        press_any_key
        return 1
    fi
    msg_ok "OpenClaw $(openclaw --version 2>/dev/null) 安装成功！"

    # ── Step 4: API Key ──
    msg_step "Step 4/5: 配置第三方 LLM API 密钥..."
    echo ""
    if confirm "是否现在配置 AI API 密钥？(推荐)"; then
        configure_api_keys
    else
        msg_info "跳过，可稍后通过主菜单 [3] 重新配置"
    fi

    # ── Step 5: 初始化服务 ──
    msg_step "Step 5/5: 初始化 Gateway 并配置自启动..."
    msg_info "正在初始化 OpenClaw Gateway..."
    if openclaw onboard --install-daemon --non-interactive >> "$LOG_FILE" 2>&1; then
        msg_ok "Gateway 初始化成功"
    else
        msg_warn "非交互式初始化失败，尝试直接启动..."
        openclaw gateway start >> "$LOG_FILE" 2>&1 & sleep 2
    fi

    service_action enable 2>/dev/null || true
    service_action start  2>/dev/null || true
    sleep 2

    if curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}/health" &>/dev/null \
       || openclaw gateway status 2>/dev/null | grep -qi "running"; then
        msg_ok "Gateway 已成功启动！"
    else
        msg_warn "Gateway 可能仍在启动中，请稍等或通过菜单 [9] 查看状态"
    fi

    echo ""
    print_line
    echo -e "${GREEN}${BOLD}🎉 OpenClaw 安装完成！${NC}"
    print_line
    show_dashboard_info

    log "OpenClaw installation completed"
    press_any_key
    return 0
}

# ─────────────────────────────────────────
#  版本查看 / 升级
# ─────────────────────────────────────────

show_version() {
    msg_title "📦 版本信息"

    if ! has_cmd openclaw; then
        msg_fail "OpenClaw 未安装"
        press_any_key
        return 0
    fi

    print_line
    echo -e "  ${BOLD}OpenClaw CLI${NC}  : $(openclaw --version 2>/dev/null || echo '未知')"
    echo -e "  ${BOLD}Node.js${NC}       : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}npm${NC}           : v$(npm -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}操作系统${NC}      : $(uname -srm)"
    echo -e "  ${BOLD}脚本版本${NC}      : ${SCRIPT_VERSION}"
    print_line
    echo ""

    msg_info "正在检查最新版本（从 npm registry）..."
    local latest
    latest=$(get_openclaw_latest_version)
    local current
    current=$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")

    echo -e "  ${BOLD}当前版本${NC}      : ${current}"
    echo -e "  ${BOLD}npm 最新版本${NC}  : ${latest:-无法获取}"

    if [[ -n "$latest" && "$latest" != "$current" ]]; then
        echo ""
        msg_warn "发现新版本 $latest（当前: $current）"
        if confirm "是否立即升级到最新版本?"; then
            msg_step "正在升级 OpenClaw..."
            if npm install -g openclaw@latest 2>&1 | tail -5; then
                msg_ok "升级完成！新版本: $(openclaw --version 2>/dev/null)"
            else
                msg_fail "升级失败，请查看日志: $LOG_FILE"
            fi
        fi
    else
        echo ""
        msg_ok "当前已是最新版本"
    fi

    press_any_key
    return 0
}

# ─────────────────────────────────────────
#  服务管理入口
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
                msg_ok "Gateway 启动成功！"
                show_dashboard_info
            else
                msg_warn "Gateway 可能仍在启动中，请 10 秒后通过菜单 [9] 查看状态"
            fi
            ;;
        stop)
            if confirm "确认停止 OpenClaw Gateway?"; then
                msg_step "正在停止 OpenClaw Gateway..."
                service_action stop
                sleep 1
                msg_ok "Gateway 已停止"
            else
                msg_info "已取消"
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
    return 0
}

# ─────────────────────────────────────────
#  诊断与修复
# ─────────────────────────────────────────

diagnose_and_fix() {
    msg_title "${DOCTOR} 系统诊断与自动修复"
    detect_system

    local issues=0
    local fixed=0

    echo -e "${CYAN}${BOLD}开始全面诊断检测...${NC}"
    echo ""

    # 1. OpenClaw 安装
    echo -ne "  [1/8] 检查 OpenClaw 安装...        "
    if has_cmd openclaw; then
        echo -e "${GREEN}${OK} 已安装 ($(openclaw --version 2>/dev/null))${NC}"
    else
        echo -e "${RED}${FAIL} 未安装${NC}"
        ((issues++))
        if confirm "  是否立即安装 OpenClaw?"; then
            install_openclaw && ((fixed++)) || true
        fi
    fi

    # 2. Node.js 版本
    echo -ne "  [2/8] 检查 Node.js 版本...         "
    if has_cmd node; then
        local nv
        nv=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$nv" -ge "$NODE_MIN_VERSION" ]]; then
            echo -e "${GREEN}${OK} $(node -v)（满足 v${NODE_MIN_VERSION}+）${NC}"
        else
            echo -e "${RED}${FAIL} $(node -v) 低于最低要求 v${NODE_MIN_VERSION}${NC}"
            ((issues++))
            if confirm "  是否自动升级 Node.js?"; then
                install_nodejs && ((fixed++)) || true
            fi
        fi
    else
        echo -e "${RED}${FAIL} 未安装${NC}"
        ((issues++))
        install_nodejs && ((fixed++)) || true
    fi

    # 3. Gateway 端口
    echo -ne "  [3/8] 检查端口 ${OPENCLAW_PORT} 响应...    "
    if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
        echo -e "${GREEN}${OK} 端口响应正常${NC}"
    else
        echo -e "${YELLOW}${WARN} 无响应（Gateway 可能未运行）${NC}"
        ((issues++))
        if confirm "  是否尝试启动 Gateway?"; then
            service_action start 2>/dev/null || openclaw gateway start >> "$LOG_FILE" 2>&1 & true
            sleep 3
            if curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                msg_ok "  Gateway 启动成功"
                ((fixed++))
            else
                msg_warn "  Gateway 启动失败，请查看日志"
            fi
        fi
    fi

    # 4. 配置文件
    echo -ne "  [4/8] 检查配置文件...               "
    if [[ -f "$OPENCLAW_CONFIG_DIR/config.json" ]]; then
        echo -e "${GREEN}${OK} 配置文件存在${NC}"
    else
        echo -e "${YELLOW}${WARN} 不存在${NC}"
        ((issues++))
        msg_info "  提示: 通过主菜单 [3] 配置 API 密钥"
    fi

    # 5. systemd 服务
    echo -ne "  [5/8] 检查自启动服务...             "
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if systemctl is-enabled "$OPENCLAW_SERVICE" &>/dev/null \
           || systemctl --user is-enabled "$OPENCLAW_SERVICE" &>/dev/null; then
            echo -e "${GREEN}${OK} 已设置开机自启${NC}"
        else
            echo -e "${YELLOW}${WARN} 未设置开机自启${NC}"
            ((issues++))
            if confirm "  是否设置开机自启?"; then
                service_action enable 2>/dev/null && msg_ok "  已设置" && ((fixed++)) || true
            fi
        fi
    else
        echo -e "${DIM}跳过（非 systemd）${NC}"
    fi

    # 6. 磁盘空间
    echo -ne "  [6/8] 检查磁盘空间...               "
    local disk_avail
    disk_avail=$(df "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
    if [[ "$disk_avail" -gt 1048576 ]]; then
        echo -e "${GREEN}${OK} 可用 $(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')${NC}"
    else
        echo -e "${RED}${FAIL} 磁盘空间不足 ($(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}'))${NC}"
        ((issues++))
        if confirm "  是否清理 OpenClaw 日志?"; then
            rm -f "${OPENCLAW_LOG_DIR:?}"/*.log 2>/dev/null && msg_ok "  日志已清理" && ((fixed++)) || true
        fi
    fi

    # 7. 内存
    echo -ne "  [7/8] 检查可用内存...               "
    local mem_avail
    mem_avail=$(grep -m1 MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "9999999")
    if [[ "$mem_avail" -gt 512000 ]]; then
        echo -e "${GREEN}${OK} 可用 $(( mem_avail / 1024 )) MB${NC}"
    else
        echo -e "${RED}${FAIL} 仅剩 $(( mem_avail / 1024 )) MB${NC}"
        ((issues++))
        msg_warn "  建议关闭其他进程，或扩大 swap"
        if confirm "  是否创建 2GB swap 文件?"; then
            if [[ ! -f /swapfile ]]; then
                sudo fallocate -l 2G /swapfile >> "$LOG_FILE" 2>&1 \
                    && sudo chmod 600 /swapfile \
                    && sudo mkswap /swapfile >> "$LOG_FILE" 2>&1 \
                    && sudo swapon /swapfile \
                    && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >> "$LOG_FILE" \
                    && msg_ok "  2GB Swap 已创建" \
                    && ((fixed++)) || msg_warn "  Swap 创建失败"
            else
                msg_info "  /swapfile 已存在"
            fi
        fi
    fi

    # 8. 网络连通性
    echo -ne "  [8/8] 检查外网连通性...             "
    if curl -s --max-time 5 https://api.anthropic.com &>/dev/null \
       || curl -s --max-time 5 https://api.openai.com &>/dev/null \
       || curl -s --max-time 5 https://api.deepseek.com &>/dev/null; then
        echo -e "${GREEN}${OK} 外网连接正常${NC}"
    else
        echo -e "${YELLOW}${WARN} 无法访问 LLM API 端点${NC}"
        ((issues++))
        msg_warn "  请检查防火墙/代理，确保出站 HTTPS (443) 开放"
    fi

    # openclaw doctor
    echo ""
    if has_cmd openclaw; then
        msg_step "运行 openclaw doctor 官方诊断..."
        openclaw doctor 2>&1 | sed 's/^/    /' || true
    fi

    # 汇总
    echo ""
    print_line
    echo -e "${BOLD}诊断结果:${NC}"
    echo -e "  发现问题: ${RED}${BOLD}${issues}${NC} 个   已自动修复: ${GREEN}${BOLD}${fixed}${NC} 个"
    if (( issues > fixed )); then
        echo -e "  待手动处理: ${YELLOW}${BOLD}$(( issues - fixed ))${NC} 个"
    fi
    echo -e "  详细日志: ${DIM}${LOG_FILE}${NC}"
    print_line

    press_any_key
    return 0
}

# ─────────────────────────────────────────
#  日志查看
# ─────────────────────────────────────────

view_logs() {
    msg_title "📋 日志查看"

    echo -e "${CYAN}选择日志类型:${NC}"
    echo "  1) 实时 Gateway 日志 (Ctrl+C 退出)"
    echo "  2) 系统服务日志 (systemd journal)"
    echo "  3) OpenClaw 应用日志文件"
    echo "  4) 本次脚本安装日志"
    echo "  0) 返回主菜单"
    echo ""
    read -rp "$(echo -e "${BOLD}请选择 [0-4]: ${NC}")" log_choice || log_choice="0"

    case "$log_choice" in
        1)
            msg_info "按 Ctrl+C 退出日志跟踪，之后自动返回主菜单"
            sleep 1
            # 捕获 Ctrl+C，防止退出整个脚本
            trap 'echo ""; msg_info "已退出日志跟踪"' INT
            openclaw gateway logs --follow 2>/dev/null \
                || journalctl -u "$OPENCLAW_SERVICE" -f 2>/dev/null \
                || tail -f "${OPENCLAW_LOG_DIR}/gateway.log" 2>/dev/null \
                || msg_fail "无法获取实时日志" || true
            trap - INT   # 恢复默认
            ;;
        2)
            detect_system
            if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
                sudo journalctl -u "$OPENCLAW_SERVICE" -n 100 --no-pager 2>/dev/null \
                    || journalctl --user -u "$OPENCLAW_SERVICE" -n 100 --no-pager 2>/dev/null \
                    || msg_fail "systemd 日志不可用" || true
            else
                msg_warn "当前系统不使用 systemd"
            fi
            ;;
        3)
            if [[ -d "$OPENCLAW_LOG_DIR" ]]; then
                echo -e "${CYAN}可用日志文件:${NC}"
                ls -lh "$OPENCLAW_LOG_DIR" 2>/dev/null || echo "  (空)"
                echo ""
                read -rp "$(echo -e "${BOLD}输入文件名查看 (Enter 查看最新): ${NC}")" log_file || true
                if [[ -n "${log_file:-}" ]]; then
                    less "${OPENCLAW_LOG_DIR}/${log_file}" 2>/dev/null || msg_warn "文件不存在"
                else
                    local latest_log
                    latest_log=$(ls -t "${OPENCLAW_LOG_DIR}"/*.log 2>/dev/null | head -1 || echo "")
                    [[ -n "$latest_log" ]] && less "$latest_log" || msg_warn "未找到日志文件"
                fi
            else
                msg_warn "日志目录不存在: $OPENCLAW_LOG_DIR"
            fi
            ;;
        4)
            [[ -f "$LOG_FILE" ]] && less "$LOG_FILE" || msg_warn "安装日志不存在: $LOG_FILE"
            ;;
        0) return 0 ;;
        *) msg_warn "无效选项" ;;
    esac

    press_any_key
    return 0
}

# ─────────────────────────────────────────
#  卸载
# ─────────────────────────────────────────

uninstall_openclaw() {
    msg_title "${TRASH} 卸载 OpenClaw"

    echo -e "${RED}${BOLD}⚠️  此操作将卸载 OpenClaw 及相关组件${NC}"
    echo ""
    echo "  将执行的操作:"
    echo "  • 停止并禁用 Gateway 服务"
    echo "  • 卸载 openclaw npm 包"
    echo "  • 可选: 删除配置文件和数据"
    echo ""

    if ! confirm "确认卸载 OpenClaw?"; then
        msg_info "已取消卸载"
        press_any_key
        return 0
    fi

    detect_system

    msg_step "停止 Gateway..."
    service_action stop 2>/dev/null || true
    sleep 1

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
        openrc)
            sudo rc-update del openclaw 2>/dev/null || true
            ;;
    esac
    msg_ok "服务已停止并禁用"

    msg_step "卸载 npm 包..."
    if npm uninstall -g openclaw >> "$LOG_FILE" 2>&1; then
        msg_ok "npm 包已卸载"
    else
        msg_warn "npm 卸载失败，尝试手动清理..."
        local npm_prefix
        npm_prefix=$(npm prefix -g 2>/dev/null || echo "/usr/local")
        sudo rm -f  "${npm_prefix}/bin/openclaw"            2>/dev/null || true
        sudo rm -rf "${npm_prefix}/lib/node_modules/openclaw" 2>/dev/null || true
        msg_ok "手动清理完成"
    fi

    echo ""
    if confirm "是否同时删除配置文件和数据? ($OPENCLAW_CONFIG_DIR)"; then
        rm -rf "$OPENCLAW_CONFIG_DIR"
        msg_ok "配置文件和数据已删除"
    else
        msg_info "配置文件已保留: $OPENCLAW_CONFIG_DIR"
    fi

    echo ""
    msg_ok "OpenClaw 已成功卸载"
    log "OpenClaw uninstalled"
    press_any_key
    return 0
}

# ─────────────────────────────────────────
#  Banner & 主菜单
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
    echo -e "        ${DIM}一键交互式管理脚本 ${SCRIPT_VERSION} | 支持多系统 / 多架构${NC}"
    echo ""

    # 状态栏（detect_system 已在调用处执行）
    local status_color="${RED}"
    local status_text="未安装"
    if has_cmd openclaw; then
        if curl -s --max-time 2 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null \
           || openclaw gateway status 2>/dev/null | grep -qi "running"; then
            status_color="${GREEN}"
            status_text="运行中 ●"
        else
            status_color="${YELLOW}"
            status_text="已安装，未运行"
        fi
    fi

    detect_system
    echo -e "  ${DIM}系统:${NC} ${OS^^} ${ARCH_LABEL}  ${DIM}│${NC}  ${DIM}Gateway:${NC} ${status_color}${BOLD}${status_text}${NC}  ${DIM}│${NC}  ${DIM}端口:${NC} ${OPENCLAW_PORT}"
    print_line
}

main_menu() {
    while true; do
        show_banner

        echo -e "${WHITE}${BOLD}  主菜单${NC}"
        echo ""
        echo -e "  ${BOLD}${GREEN}[1]${NC}  ${ROCKET} 安装 / 重装 OpenClaw"
        echo -e "  ${BOLD}${GREEN}[2]${NC}  ${POWER} 启动 Gateway"
        echo -e "  ${BOLD}${GREEN}[3]${NC}  🔑 配置 API 密钥"
        echo -e "  ${BOLD}${CYAN}[4]${NC}  📊 查看控制面板 URL"
        echo -e "  ${BOLD}${CYAN}[5]${NC}  📦 查看 / 升级版本"
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
        read -r choice || choice="invalid"

        case "$choice" in
            1)  install_openclaw    ;;
            2)  manage_service start   ;;
            3)  configure_api_keys; press_any_key ;;
            4)  show_dashboard_info;  press_any_key ;;
            5)  show_version        ;;
            6)  view_logs           ;;
            7)  manage_service restart ;;
            8)  manage_service stop    ;;
            9)  manage_service status  ;;
            10) diagnose_and_fix    ;;
            11) print_sysinfo; press_any_key ;;
            12) uninstall_openclaw  ;;
            0)
                echo ""
                echo -e "${GREEN}${BOLD}感谢使用 OpenClaw 管理脚本，再见！👋${NC}"
                echo ""
                exit 0
                ;;
            *)
                msg_warn "无效选项: ${choice}，请输入 0-12"
                sleep 1
                ;;
        esac
        # ↑ 所有子功能执行完后自动回到 while true 循环顶部（show_banner + 菜单）
    done
}

# ─────────────────────────────────────────
#  入口
# ─────────────────────────────────────────

case "${1:-}" in
    install)   detect_system; install_openclaw   ;;
    start)     detect_system; manage_service start   ;;
    stop)      detect_system; manage_service stop    ;;
    restart)   detect_system; manage_service restart ;;
    status)    detect_system; manage_service status  ;;
    version)   show_version  ;;
    diagnose)  detect_system; diagnose_and_fix   ;;
    uninstall) detect_system; uninstall_openclaw ;;
    url)       show_dashboard_info ;;
    *)         main_menu ;;
esac
