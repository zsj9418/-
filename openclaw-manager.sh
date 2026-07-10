#!/usr/bin/env bash
set -uo pipefail

# ─────────────────────────────────────────
#  全局颜色 & 图标
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
ROCKET="🚀"
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
SCRIPT_VERSION="v1.3.0"
NODE_MIN_VERSION=20
LOG_FILE="/tmp/openclaw_install_$(date +%Y%m%d_%H%M%S).log"

_NVM_LATEST=""
_NODE_LTS_VERSIONS=""
_NODE_LATEST_VERSION=""

# ─────────────────────────────────────────
#  全局配置存储
#  G_API_KEYS[provider]   = "api_key_value"
#  G_API_MODELS[provider]  = "model1,model2,model3"  (逗号分隔，第一个为默认)
#  G_DEFAULT_PROVIDER      = "优先使用的 provider"
# ─────────────────────────────────────────
declare -gA G_API_KEYS=()
declare -gA G_API_MODELS=()
declare -g  G_DEFAULT_PROVIDER=""

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

press_any_key() {
    echo ""
    read -rp "$(echo -e "${DIM}按 Enter 键返回主菜单...${NC}")" _ </dev/tty || true
}

confirm() {
    local prompt="${1:-确认操作}"
    local answer
    echo -ne "${YELLOW}${WARN} ${prompt} [y/N]: ${NC}"
    read -r answer </dev/tty || answer="n"
    [[ "$answer" =~ ^[Yy]$ ]]
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

has_cmd() { command -v "$1" &>/dev/null; }

safe_run() {
    local desc="$1"; shift
    if "$@" >> "$LOG_FILE" 2>&1; then
        msg_ok "$desc"
        return 0
    else
        msg_warn "$desc 失败 (详见 $LOG_FILE)"
        return 1
    fi
}

# ─────────────────────────────────────────
#  动态版本获取
# ─────────────────────────────────────────

get_nvm_latest_version() {
    if [[ -n "$_NVM_LATEST" ]]; then echo "$_NVM_LATEST"; return; fi
    local ver
    ver=$(curl -s --max-time 8 \
        "https://api.github.com/repos/nvm-sh/nvm/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | grep -o 'v[0-9.]*')
    if [[ -z "$ver" ]]; then
        ver=$(curl -s --max-time 8 \
            "https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/README.md" 2>/dev/null \
            | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
    fi
    _NVM_LATEST="${ver:-v0.40.1}"
    echo "$_NVM_LATEST"
}

get_node_lts_versions() {
    if [[ -n "$_NODE_LTS_VERSIONS" ]]; then echo "$_NODE_LTS_VERSIONS"; return; fi
    local versions
    versions=$(curl -s --max-time 8 "https://nodejs.org/dist/index.json" 2>/dev/null \
        | grep -o '"version":"v[0-9]*\.[0-9]*\.[0-9]*","[^}]*"lts":"[^f][^"]*"' \
        | grep -o '"version":"v[0-9]*' | grep -o '[0-9]*$' \
        | sort -rn | awk '!seen[$0]++' | head -5 | tr '\n' ' ')
    _NODE_LTS_VERSIONS="${versions:-22 20 18}"
    echo "$_NODE_LTS_VERSIONS"
}

get_node_latest_major() {
    if [[ -n "$_NODE_LATEST_VERSION" ]]; then echo "$_NODE_LATEST_VERSION"; return; fi
    local ver
    ver=$(curl -s --max-time 8 "https://nodejs.org/dist/index.json" 2>/dev/null \
        | grep -o '"version":"v[0-9]*' | head -1 | grep -o '[0-9]*$')
    _NODE_LATEST_VERSION="${ver:-23}"
    echo "$_NODE_LATEST_VERSION"
}

get_openclaw_latest_version() {
    curl -s --max-time 8 "https://registry.npmjs.org/openclaw/latest" 2>/dev/null \
        | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || echo ""
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
    echo -e "  ${BOLD}系统架构${NC}    : ${ARCH_LABEL}"
    echo -e "  ${BOLD}包管理器${NC}    : ${PKG_MANAGER}"
    echo -e "  ${BOLD}服务管理器${NC}  : ${SERVICE_MANAGER}"
    echo -e "  ${BOLD}主机名${NC}      : $(hostname)"
    echo -e "  ${BOLD}内存${NC}        : $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' \
                             || sysctl hw.memsize 2>/dev/null | awk '{printf "%.1f GB", $2/1073741824}' \
                             || echo '未知')"
    echo -e "  ${BOLD}CPU 核心${NC}    : $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '未知')"
    echo -e "  ${BOLD}磁盘可用${NC}    : $(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo '未知')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}npm${NC}         : $(npm -v 2>/dev/null | sed 's/^/v/' || echo '未安装')"
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw --version 2>/dev/null || echo '未安装')"
    if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
        echo -e "  ${BOLD}默认 Provider${NC}: ${GREEN}${G_DEFAULT_PROVIDER}${NC}"
        echo -e "  ${BOLD}已选模型${NC}    : ${G_API_MODELS[$G_DEFAULT_PROVIDER]:-未配置}"
    fi
    print_line
}

# ─────────────────────────────────────────
#  模型列表获取（已知 provider 的可选模型）
# ─────────────────────────────────────────

get_provider_models() {
    local provider="$1"
    if has_cmd openclaw; then
        local models
        models=$(openclaw models list --provider "$provider" --json 2>/dev/null \
                 | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | head -30)
        if [[ -n "$models" ]]; then echo "$models"; return; fi
    fi
    case "$provider" in
        anthropic)
            printf '%s\n' \
                "claude-opus-4-5" "claude-sonnet-4-5" "claude-haiku-3-5" \
                "claude-opus-4-0" "claude-sonnet-3-7" "claude-haiku-3-0" ;;
        openai)
            printf '%s\n' \
                "gpt-4o" "gpt-4o-mini" "gpt-4-turbo" "gpt-4" \
                "o1" "o1-mini" "o3-mini" ;;
        google)
            printf '%s\n' \
                "gemini-2.5-pro" "gemini-2.5-flash" \
                "gemini-2.0-flash-exp" "gemini-1.5-pro" \
                "gemini-1.5-flash" "gemini-1.5-flash-8b" ;;
        deepseek)
            printf '%s\n' \
                "deepseek-chat" "deepseek-reasoner" "deepseek-coder" ;;
        groq)
            printf '%s\n' \
                "llama-3.3-70b-versatile" "llama-3.1-8b-instant" \
                "mixtral-8x7b-32768" "gemma2-9b-it" ;;
        mistral)
            printf '%s\n' \
                "mistral-large-latest" "mistral-medium" \
                "mistral-small" "open-mistral-7b" ;;
    esac
}

# ─────────────────────────────────────────
#  多模型交互选择（标准 provider 用）
#
#  关键：所有 UI 输出走 >&2
#        所有 read 从 /dev/tty 读取
#        只有最终结果 echo 到 stdout
# ─────────────────────────────────────────

pick_models_interactive() {
    local provider="$1"
    local recommended="$2"

    local models=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && models+=("$line")
    done < <(get_provider_models "$provider")

    if [[ ${#models[@]} -eq 0 ]]; then
        echo -e "\n  ${CYAN}无法获取模型列表，请手动输入${NC}" >&2
        echo -ne "  模型名称 (多个用逗号分隔, 第一个为默认): " >&2
        local m
        read -r m </dev/tty || m=""
        echo "${m:-$recommended}"
        return
    fi

    echo "" >&2
    echo -e "  ${CYAN}${BOLD}可用模型 (${provider}):${NC}" >&2
    echo -e "  ${DIM}可选多个，第一个为默认${NC}" >&2
    echo "" >&2

    local i=1
    local rec_idx=1
    for m in "${models[@]}"; do
        local tag=""
        if [[ "$m" == "$recommended" ]]; then
            tag=" ${GREEN}★ 推荐${NC}"
            rec_idx=$i
        fi
        printf "    %2d) %s%b\n" "$i" "$m" "$tag" >&2
        ((i++))
    done
    local manual_idx=$i
    printf "    %2d) 手动输入\n" "$manual_idx" >&2
    echo "" >&2

    echo -e "  ${DIM}输入方式: 单个数字(2) / 多个(2,1,3) / 全选(a)${NC}" >&2
    echo "" >&2
    echo -ne "  请选择 [默认: ${rec_idx}]: " >&2
    local choice
    read -r choice </dev/tty || choice=""
    choice=${choice:-$rec_idx}

    local selected_models=()

    if [[ "$choice" == "a" || "$choice" == "all" || "$choice" == "A" ]]; then
        selected_models=("${models[@]}")
    elif [[ "$choice" == "$manual_idx" ]]; then
        echo -ne "  模型名称 (逗号分隔): " >&2
        local custom_input
        read -r custom_input </dev/tty || custom_input=""
        echo "${custom_input:-$recommended}"
        return
    else
        IFS=',' read -ra indices <<< "$choice"
        for idx in "${indices[@]}"; do
            idx=$(echo "$idx" | tr -d ' ')
            if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#models[@]} )); then
                selected_models+=("${models[$((idx - 1))]}")
            fi
        done
    fi

    if [[ ${#selected_models[@]} -eq 0 ]]; then
        selected_models=("$recommended")
    fi

    local result=""
    for m in "${selected_models[@]}"; do
        [[ -n "$result" ]] && result="${result},"
        result="${result}${m}"
    done
    echo "$result"
}

# ─────────────────────────────────────────
#  自定义 API 的模型交互管理
#  支持：手动输入 / 从已有列表增删 / 排序
# ─────────────────────────────────────────

pick_custom_models_interactive() {
    local existing_models="${1:-}"

    # 解析已有模型到数组
    local current=()
    if [[ -n "$existing_models" ]]; then
        IFS=',' read -ra current <<< "$existing_models"
    fi

    echo "" >&2
    echo -e "  ${CYAN}${BOLD}自定义 API 模型管理${NC}" >&2
    echo -e "  ${DIM}第一个模型将作为默认模型${NC}" >&2
    echo "" >&2

    if [[ ${#current[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}当前已配置 ${#current[@]} 个模型:${NC}" >&2
        local ci=1
        for m in "${current[@]}"; do
            if [[ $ci -eq 1 ]]; then
                echo -e "    ${ci}. ${GREEN}${BOLD}${m}${NC} ${DIM}(默认)${NC}" >&2
            else
                echo -e "    ${ci}. ${m}" >&2
            fi
            ((ci++))
        done
        echo "" >&2
    fi

    echo -e "  ${CYAN}操作:${NC}" >&2
    echo "    1) 重新输入全部模型（覆盖）" >&2
    echo "    2) 追加新模型" >&2
    echo "    3) 删除某个模型" >&2
    echo "    4) 调整顺序（设置默认模型）" >&2
    if [[ ${#current[@]} -gt 0 ]]; then
        echo "    0) 保持不变" >&2
    fi
    echo "" >&2
    echo -ne "  请选择: " >&2
    local op
    read -r op </dev/tty || op="0"

    case "$op" in
        1)
            echo "" >&2
            echo -e "  ${DIM}输入模型名称，逗号分隔，第一个为默认${NC}" >&2
            echo -e "  ${DIM}示例: openai/gpt-4o:free,anthropic/claude-3:free,meta/llama-3${NC}" >&2
            echo -ne "  模型列表: " >&2
            local new_list
            read -r new_list </dev/tty || new_list=""
            if [[ -n "$new_list" ]]; then
                echo "$new_list"
            else
                # 没输入就保留原来的
                local r=""
                for m in "${current[@]}"; do
                    [[ -n "$r" ]] && r="${r},"
                    r="${r}${m}"
                done
                echo "$r"
            fi
            ;;
        2)
            echo "" >&2
            echo -e "  ${DIM}输入要追加的模型名称（逗号分隔可批量）${NC}" >&2
            echo -ne "  追加模型: " >&2
            local append
            read -r append </dev/tty || append=""
            if [[ -n "$append" ]]; then
                IFS=',' read -ra new_arr <<< "$append"
                for m in "${new_arr[@]}"; do
                    m=$(echo "$m" | xargs)  # trim
                    [[ -n "$m" ]] && current+=("$m")
                done
            fi
            local r=""
            for m in "${current[@]}"; do
                [[ -n "$r" ]] && r="${r},"
                r="${r}${m}"
            done
            echo "$r"
            ;;
        3)
            if [[ ${#current[@]} -eq 0 ]]; then
                echo -e "  ${WARN} 没有模型可删除" >&2
                echo ""
                return
            fi
            echo "" >&2
            echo -e "  输入要删除的模型序号（逗号分隔可批量删除）:" >&2
            echo -ne "  删除序号: " >&2
            local del_idx
            read -r del_idx </dev/tty || del_idx=""
            if [[ -n "$del_idx" ]]; then
                IFS=',' read -ra del_arr <<< "$del_idx"
                local new_current=()
                for ci in "${!current[@]}"; do
                    local should_del=false
                    for di in "${del_arr[@]}"; do
                        di=$(echo "$di" | tr -d ' ')
                        if [[ "$((ci + 1))" == "$di" ]]; then
                            should_del=true
                            break
                        fi
                    done
                    $should_del || new_current+=("${current[$ci]}")
                done
                current=("${new_current[@]}")
            fi
            local r=""
            for m in "${current[@]}"; do
                [[ -n "$r" ]] && r="${r},"
                r="${r}${m}"
            done
            echo "$r"
            ;;
        4)
            if [[ ${#current[@]} -le 1 ]]; then
                echo -e "  ${DIM}只有一个模型，无需调整${NC}" >&2
                local r=""
                for m in "${current[@]}"; do
                    [[ -n "$r" ]] && r="${r},"
                    r="${r}${m}"
                done
                echo "$r"
                return
            fi
            echo "" >&2
            echo -e "  输入要设为默认（第一位）的模型序号:" >&2
            echo -ne "  序号: " >&2
            local new_first
            read -r new_first </dev/tty || new_first=""
            if [[ "$new_first" =~ ^[0-9]+$ ]] && (( new_first >= 1 && new_first <= ${#current[@]} )); then
                local target="${current[$((new_first - 1))]}"
                local reordered=("$target")
                for m in "${current[@]}"; do
                    [[ "$m" != "$target" ]] && reordered+=("$m")
                done
                current=("${reordered[@]}")
            fi
            local r=""
            for m in "${current[@]}"; do
                [[ -n "$r" ]] && r="${r},"
                r="${r}${m}"
            done
            echo "$r"
            ;;
        0|"")
            # 保持不变
            local r=""
            for m in "${current[@]}"; do
                [[ -n "$r" ]] && r="${r},"
                r="${r}${m}"
            done
            echo "$r"
            ;;
    esac
}

# ─────────────────────────────────────────
#  Node.js 版本选择（UI → stderr, 结果 → stdout）
# ─────────────────────────────────────────

pick_node_version() {
    echo -e "\n${CYAN}正在从 nodejs.org 获取可用版本...${NC}" >&2

    local lts_list
    lts_list=$(get_node_lts_versions)
    local latest_major
    latest_major=$(get_node_latest_major)

    echo -e "\n${CYAN}请选择要安装的 Node.js 版本:${NC}" >&2

    local idx=1
    declare -a vmap=()

    local first_lts
    first_lts=$(echo "$lts_list" | awk '{print $1}')

    if [[ "$latest_major" != "$first_lts" ]]; then
        printf "  %2d) Node.js %-4s (Current - 最新特性, 非 LTS)\n" "$idx" "$latest_major" >&2
        vmap[$idx]="$latest_major"
        ((idx++))
    fi

    local is_first=true
    for v in $lts_list; do
        if $is_first; then
            printf "  %2d) Node.js %-4s (LTS 最新稳定 ★ 推荐)\n" "$idx" "$v" >&2
            is_first=false
        else
            printf "  %2d) Node.js %-4s (LTS)\n" "$idx" "$v" >&2
        fi
        vmap[$idx]="$v"
        ((idx++))
    done

    local manual_idx=$idx
    printf "  %2d) 手动输入版本号\n" "$manual_idx" >&2
    echo "" >&2

    local default_choice
    if [[ "$latest_major" != "$first_lts" ]]; then
        default_choice=2
    else
        default_choice=1
    fi

    echo -ne "  ${BOLD}请选择 [1-${manual_idx}] (默认: ${default_choice}): ${NC}" >&2
    local ver_choice
    read -r ver_choice </dev/tty || ver_choice=""
    ver_choice=${ver_choice:-$default_choice}

    local selected=""
    if [[ "$ver_choice" -eq "$manual_idx" ]] 2>/dev/null; then
        echo -ne "  ${BOLD}请输入主版本号 (如 22, 20): ${NC}" >&2
        local mv
        read -r mv </dev/tty || mv=""
        selected=$(echo "${mv:-$NODE_MIN_VERSION}" | tr -d 'vV ')
    else
        selected="${vmap[$ver_choice]:-${vmap[$default_choice]:-$NODE_MIN_VERSION}}"
    fi

    echo "$selected"
}

# ─────────────────────────────────────────
#  Node.js 安装
# ─────────────────────────────────────────

install_nodejs() {
    msg_step "检测 Node.js..."

    if has_cmd node; then
        local ver
        ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$ver" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v) 满足要求 (v${NODE_MIN_VERSION}+)"
            return 0
        else
            msg_warn "当前 $(node -v) 低于要求 v${NODE_MIN_VERSION}+"
        fi
    else
        msg_warn "未检测到 Node.js"
    fi

    echo ""
    echo -e "${CYAN}选择安装方式:${NC}"
    echo "  1) NodeSource 官方源  (推荐 Linux)"
    echo "  2) nvm 版本管理器     (多版本切换)"
    echo "  3) 系统包管理器       (版本由系统决定)"
    echo "  4) 手动安装"
    echo ""
    local node_choice
    echo -ne "${BOLD}请选择 [1-4] (默认: 1): ${NC}"
    read -r node_choice </dev/tty || node_choice="1"
    node_choice=${node_choice:-1}

    local target_version="$NODE_MIN_VERSION"
    if [[ "$node_choice" -eq 1 || "$node_choice" -eq 2 ]]; then
        target_version=$(pick_node_version)
        [[ -z "$target_version" ]] && target_version="$NODE_MIN_VERSION"
        msg_info "目标版本: v${target_version}"
    fi

    case "$node_choice" in
        1) _install_node_nodesource "$target_version" ;;
        2) _install_node_nvm "$target_version" ;;
        3) _install_node_native ;;
        4)
            msg_info "请手动安装 Node.js v${NODE_MIN_VERSION}+"
            msg_info "下载: https://nodejs.org/en/download/"
            return 1
            ;;
        *) msg_warn "无效选项"; return 1 ;;
    esac

    _refresh_node_path

    if has_cmd node; then
        local iv
        iv=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$iv" -ge "$NODE_MIN_VERSION" ]]; then
            msg_ok "Node.js $(node -v) 安装成功！"
            log "Node.js $(node -v) installed"
            return 0
        fi
    fi

    msg_fail "Node.js 安装失败，请查看: $LOG_FILE"
    return 1
}

_install_node_nodesource() {
    local version="$1"
    msg_step "NodeSource 安装 Node.js v${version}..."
    case "$OS" in
        debian)
            safe_run "下载 NodeSource 脚本" \
                bash -c "curl -fsSL https://deb.nodesource.com/setup_${version}.x | sudo -E bash -"
            safe_run "apt 安装 nodejs" sudo apt-get install -y nodejs ;;
        rhel|fedora)
            safe_run "下载 NodeSource 脚本" \
                bash -c "curl -fsSL https://rpm.nodesource.com/setup_${version}.x | sudo bash -"
            safe_run "安装 nodejs" sudo "$PKG_MANAGER" install -y nodejs ;;
        arch)
            msg_info "Arch 使用 pacman（版本由仓库决定）"
            safe_run "安装 nodejs npm" sudo pacman -S --noconfirm nodejs npm ;;
        alpine)
            safe_run "安装 nodejs npm" sudo apk add nodejs npm ;;
        macos)
            has_cmd brew || { msg_fail "请先安装 Homebrew"; return 1; }
            safe_run "brew 安装 node@${version}" brew install "node@${version}"
            brew link --force --overwrite "node@${version}" 2>/dev/null || true ;;
        *) msg_fail "不支持当前系统"; return 1 ;;
    esac
}

_install_node_nvm() {
    local version="$1"
    msg_step "nvm 安装 Node.js v${version}..."

    local nvm_ver
    nvm_ver=$(get_nvm_latest_version)
    msg_info "nvm 版本: ${nvm_ver}"

    safe_run "安装 nvm ${nvm_ver}" \
        bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_ver}/install.sh | bash"

    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" || { msg_fail "nvm 加载失败"; return 1; }

    safe_run "nvm install ${version}" nvm install "$version"
    nvm use "$version" >> "$LOG_FILE" 2>&1 || true
    nvm alias default "$version" >> "$LOG_FILE" 2>&1 || true

    local shell_rc="$HOME/.bashrc"
    [[ "$SHELL" == *zsh* ]] && shell_rc="$HOME/.zshrc"
    if ! grep -q "NVM_DIR" "$shell_rc" 2>/dev/null; then
        {
            echo ''
            echo '# nvm'
            echo 'export NVM_DIR="$HOME/.nvm"'
            echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
            echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
        } >> "$shell_rc"
        msg_info "nvm 初始化已写入 $shell_rc"
    fi
}

_install_node_native() {
    msg_step "系统包管理器安装 Node.js..."
    msg_info "版本由系统仓库决定"
    case "$OS" in
        debian)   safe_run "apt update" sudo apt-get update -qq
                  safe_run "安装 nodejs" sudo apt-get install -y nodejs npm ;;
        rhel)     safe_run "安装 nodejs" sudo yum install -y nodejs npm ;;
        fedora)   safe_run "安装 nodejs" sudo dnf install -y nodejs npm ;;
        arch)     safe_run "安装 nodejs" sudo pacman -S --noconfirm nodejs npm ;;
        alpine)   safe_run "安装 nodejs" sudo apk add nodejs npm ;;
        macos)    has_cmd brew || { msg_fail "需要 Homebrew"; return 1; }
                  safe_run "安装 node" brew install node ;;
        *)        msg_fail "不支持"; return 1 ;;
    esac
}

_refresh_node_path() {
    local nvm_node_dir=""
    if [[ -d "$HOME/.nvm/versions/node" ]]; then
        nvm_node_dir=$(ls -d "$HOME/.nvm/versions/node/"v* 2>/dev/null | sort -V | tail -1)
    fi
    local paths=(
        "${nvm_node_dir:+${nvm_node_dir}/bin}"
        "$HOME/.local/bin"
        "/usr/local/bin"
    )
    for p in "${paths[@]}"; do
        [[ -n "$p" && -d "$p" ]] && export PATH="$p:$PATH"
    done
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
}

# ─────────────────────────────────────────
#  配置文件读写
# ─────────────────────────────────────────

load_config_from_file() {
    local config_file="$OPENCLAW_CONFIG_DIR/config.json"
    [[ ! -f "$config_file" ]] && return 0

    if has_cmd python3; then
        local eval_str
        eval_str=$(python3 - "$config_file" << 'PYEOF'
import json, sys

try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)

for provider, data in cfg.items():
    if provider == "defaultProvider":
        print(f'G_DEFAULT_PROVIDER="{data}"')
        continue
    if not isinstance(data, dict):
        continue
    key = data.get("apiKey", "")
    models_val = data.get("models", "")
    model_val = data.get("model", "")
    base_url = data.get("baseUrl", "")

    if provider == "custom":
        if base_url:
            print(f'G_API_KEYS[custom_url]="{base_url}"')
            print(f'G_API_KEYS[custom_key]="{key}"')
            print(f'G_API_MODELS[custom]="{models_val or model_val}"')
    else:
        if key:
            print(f'G_API_KEYS[{provider}]="{key}"')
        if models_val:
            print(f'G_API_MODELS[{provider}]="{models_val}"')
        elif model_val:
            print(f'G_API_MODELS[{provider}]="{model_val}"')
PYEOF
        ) 2>/dev/null || true
        [[ -n "${eval_str:-}" ]] && eval "$eval_str" 2>/dev/null || true
    fi
}

write_config_to_file() {
    local config_file="$OPENCLAW_CONFIG_DIR/config.json"
    mkdir -p "$OPENCLAW_CONFIG_DIR"

    if has_cmd python3; then
        local env_args=()
        for provider in "${!G_API_KEYS[@]}"; do
            local up
            up=$(echo "$provider" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
            env_args+=("OCKEY_${up}=${G_API_KEYS[$provider]}")
        done
        for provider in "${!G_API_MODELS[@]}"; do
            local up
            up=$(echo "$provider" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
            env_args+=("OCMODEL_${up}=${G_API_MODELS[$provider]}")
        done
        [[ -n "$G_DEFAULT_PROVIDER" ]] && env_args+=("OC_DEFAULT_PROVIDER=$G_DEFAULT_PROVIDER")

        env "${env_args[@]}" python3 - "$config_file" << 'PYEOF'
import json, sys, os

config_path = sys.argv[1]
os.makedirs(os.path.dirname(config_path), exist_ok=True)

try:
    with open(config_path) as f:
        config = json.load(f)
except Exception:
    config = {}

env = os.environ

for k, v in list(env.items()):
    if k.startswith("OCKEY_") and v:
        p = k[6:].lower()
        if p == "custom_url":
            config.setdefault("custom", {})["baseUrl"] = v
        elif p == "custom_key":
            config.setdefault("custom", {})["apiKey"] = v
        else:
            config.setdefault(p, {})["apiKey"] = v
    elif k.startswith("OCMODEL_") and v:
        p = k[8:].lower()
        target = "custom" if p == "custom" else p
        config.setdefault(target, {})["models"] = v
        config[target]["model"] = v.split(",")[0]

dp = env.get("OC_DEFAULT_PROVIDER", "")
if dp:
    config["defaultProvider"] = dp

with open(config_path, "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
PYEOF
        chmod 600 "$config_file"
        msg_ok "配置已写入 $config_file"
    else
        {
            echo "{"
            local comma=""
            for p in anthropic openai google deepseek groq mistral; do
                local key="${G_API_KEYS[$p]:-}"
                local mdls="${G_API_MODELS[$p]:-}"
                if [[ -n "$key" ]]; then
                    local first_model="${mdls%%,*}"
                    [[ -n "$comma" ]] && echo ","
                    echo "  \"${p}\": {"
                    echo "    \"apiKey\": \"${key}\","
                    echo "    \"model\": \"${first_model}\","
                    echo "    \"models\": \"${mdls}\""
                    echo -n "  }"
                    comma=","
                fi
            done
            if [[ -n "${G_API_KEYS[custom_url]:-}" ]]; then
                [[ -n "$comma" ]] && echo ","
                local cm="${G_API_MODELS[custom]:-}"
                echo "  \"custom\": {"
                echo "    \"baseUrl\": \"${G_API_KEYS[custom_url]}\","
                echo "    \"apiKey\": \"${G_API_KEYS[custom_key]:-none}\","
                echo "    \"model\": \"${cm%%,*}\","
                echo "    \"models\": \"${cm}\""
                echo -n "  }"
                comma=","
            fi
            if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
                [[ -n "$comma" ]] && echo ","
                echo -n "  \"defaultProvider\": \"${G_DEFAULT_PROVIDER}\""
            fi
            echo ""
            echo "}"
        } > "$config_file"
        chmod 600 "$config_file"
        msg_ok "配置已写入 $config_file (bash fallback)"
    fi
}

write_config_via_openclaw() {
    if ! has_cmd openclaw; then return 1; fi

    local any_ok=false
    _oc() { openclaw config set "$1" "$2" --silent 2>/dev/null && any_ok=true || true; }

    for p in anthropic openai google deepseek groq mistral; do
        [[ -n "${G_API_KEYS[$p]:-}" ]] && _oc "${p}.apiKey" "${G_API_KEYS[$p]}"
        if [[ -n "${G_API_MODELS[$p]:-}" ]]; then
            local first="${G_API_MODELS[$p]%%,*}"
            _oc "${p}.model"  "$first"
            _oc "${p}.models" "${G_API_MODELS[$p]}"
        fi
    done

    if [[ -n "${G_API_KEYS[custom_url]:-}" ]]; then
        _oc custom.baseUrl "${G_API_KEYS[custom_url]}"
        _oc custom.apiKey  "${G_API_KEYS[custom_key]:-none}"
        local cm="${G_API_MODELS[custom]:-}"
        _oc custom.model  "${cm%%,*}"
        _oc custom.models "$cm"
    fi

    [[ -n "$G_DEFAULT_PROVIDER" ]] && _oc defaultProvider "$G_DEFAULT_PROVIDER"

    $any_ok && return 0 || return 1
}

# ─────────────────────────────────────────
#  配置显示辅助
# ─────────────────────────────────────────

_display_selected_models() {
    local provider="$1"
    local models_str="$2"

    local first_model="${models_str%%,*}"
    local model_count
    model_count=$(echo "$models_str" | tr ',' '\n' | grep -c . || echo "0")

    msg_ok "${provider} 已配置:"
    echo -e "    默认模型: ${GREEN}${BOLD}${first_model}${NC}"
    if [[ "$model_count" -gt 1 ]]; then
        echo -e "    全部模型 (${model_count} 个):"
        local idx=1
        while IFS=',' read -ra arr; do
            for m in "${arr[@]}"; do
                m=$(echo "$m" | xargs)
                [[ -z "$m" ]] && continue
                if [[ "$idx" -eq 1 ]]; then
                    echo -e "      ${idx}. ${GREEN}${m}${NC} ${DIM}(默认)${NC}"
                else
                    echo -e "      ${idx}. ${m}"
                fi
                ((idx++))
            done
        done <<< "$models_str"
    fi
}

_show_config_summary() {
    print_line
    echo -e "${BOLD}配置摘要:${NC}"
    echo ""

    local total_models=0

    for p in anthropic openai google deepseek groq mistral; do
        if [[ -n "${G_API_KEYS[$p]:-}" ]]; then
            local tag=""
            [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && tag=" ${GREEN}${BOLD}[默认]${NC}"
            local models_str="${G_API_MODELS[$p]:-}"
            local first_m="${models_str%%,*}"
            local mc
            mc=$(echo "$models_str" | tr ',' '\n' | grep -c . 2>/dev/null || echo "0")
            ((total_models += mc))
            echo -e "  ${BOLD}${p}${NC}${tag}"
            echo -e "    Key: ${DIM}${G_API_KEYS[$p]:0:12}****${NC}"
            echo -e "    模型: ${CYAN}${first_m}${NC}${mc:+ (共 ${mc} 个)}"
        fi
    done

    if [[ -n "${G_API_KEYS[custom_url]:-}" ]]; then
        local tag=""
        [[ "$G_DEFAULT_PROVIDER" == "custom" ]] && tag=" ${GREEN}${BOLD}[默认]${NC}"
        local models_str="${G_API_MODELS[custom]:-}"
        local first_m="${models_str%%,*}"
        local mc
        mc=$(echo "$models_str" | tr ',' '\n' | grep -c . 2>/dev/null || echo "0")
        ((total_models += mc))
        echo -e "  ${BOLD}custom${NC}${tag}"
        echo -e "    URL: ${DIM}${G_API_KEYS[custom_url]}${NC}"
        echo -e "    模型: ${CYAN}${first_m}${NC}${mc:+ (共 ${mc} 个)}"
    fi

    echo ""
    echo -e "  ${BOLD}默认 Provider:${NC} ${GREEN}${BOLD}${G_DEFAULT_PROVIDER:-未设置}${NC}"
    echo -e "  ${BOLD}模型总数:${NC} ${total_models}"
    print_line
}

_select_default_provider() {
    echo -e "${CYAN}${BOLD}─── 设置默认 Provider ───${NC}"
    echo -e "${DIM}默认 Provider 将作为 OpenClaw 首选 AI 后端${NC}"
    echo ""

    local available=()
    local i=1

    for p in anthropic openai google deepseek groq mistral; do
        if [[ -n "${G_API_KEYS[$p]:-}" ]]; then
            local tag=""
            [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && tag=" ${GREEN}[当前]${NC}"
            local first_m="${G_API_MODELS[$p]:-}"
            first_m="${first_m%%,*}"
            echo -e "  ${BOLD}${i})${NC} ${p} → ${first_m}${tag}"
            available+=("$p")
            ((i++))
        fi
    done

    if [[ -n "${G_API_KEYS[custom_url]:-}" ]]; then
        local tag=""
        [[ "$G_DEFAULT_PROVIDER" == "custom" ]] && tag=" ${GREEN}[当前]${NC}"
        local first_m="${G_API_MODELS[custom]:-}"
        first_m="${first_m%%,*}"
        echo -e "  ${BOLD}${i})${NC} custom (${G_API_KEYS[custom_url]}) → ${first_m}${tag}"
        available+=("custom")
        ((i++))
    fi

    if [[ ${#available[@]} -eq 0 ]]; then
        msg_warn "未配置任何 Provider"
        return
    fi

    echo ""
    echo -ne "  请选择 [1-$((i-1))]: "
    local dp_choice
    read -r dp_choice </dev/tty || dp_choice=""

    if [[ -n "$dp_choice" ]] && [[ "$dp_choice" =~ ^[0-9]+$ ]] \
       && (( dp_choice >= 1 && dp_choice <= ${#available[@]} )); then
        G_DEFAULT_PROVIDER="${available[$((dp_choice - 1))]}"
        msg_ok "默认 Provider: ${GREEN}${BOLD}${G_DEFAULT_PROVIDER}${NC}"
    else
        msg_warn "无效选择"
    fi
}

_auto_select_default_provider() {
    local priority=("custom" "anthropic" "openai" "deepseek" "google" "groq" "mistral")
    for p in "${priority[@]}"; do
        if [[ "$p" == "custom" && -n "${G_API_KEYS[custom_url]:-}" ]]; then
            G_DEFAULT_PROVIDER="custom"
            msg_info "自动默认: ${BOLD}custom${NC}"
            return
        elif [[ "$p" != "custom" && -n "${G_API_KEYS[$p]:-}" ]]; then
            G_DEFAULT_PROVIDER="$p"
            msg_info "自动默认: ${BOLD}${p}${NC}"
            return
        fi
    done
}

# ─────────────────────────────────────────
#  API Key 配置主函数
# ─────────────────────────────────────────

configure_api_keys() {
    msg_title "🔑 配置第三方 LLM API 密钥"

    load_config_from_file

    local config_file="$OPENCLAW_CONFIG_DIR/config.json"
    mkdir -p "$OPENCLAW_CONFIG_DIR"

    # 显示已有配置
    if [[ ${#G_API_KEYS[@]} -gt 0 ]]; then
        echo -e "${CYAN}已有配置:${NC}"
        for p in anthropic openai google deepseek groq mistral; do
            if [[ -n "${G_API_KEYS[$p]:-}" ]]; then
                local masked="${G_API_KEYS[$p]:0:8}****"
                local dt=""
                [[ "$G_DEFAULT_PROVIDER" == "$p" ]] && dt=" ${GREEN}[默认]${NC}"
                local fm="${G_API_MODELS[$p]:-}"
                fm="${fm%%,*}"
                echo -e "  ${BOLD}${p}${NC}: ${masked} → ${fm}${dt}"
            fi
        done
        if [[ -n "${G_API_KEYS[custom_url]:-}" ]]; then
            local dt=""
            [[ "$G_DEFAULT_PROVIDER" == "custom" ]] && dt=" ${GREEN}[默认]${NC}"
            local fm="${G_API_MODELS[custom]:-}"
            fm="${fm%%,*}"
            echo -e "  ${BOLD}custom${NC}: ${G_API_KEYS[custom_url]} → ${fm}${dt}"
        fi
        echo ""
        echo -e "${DIM}输入新值覆盖，直接 Enter 保留原值${NC}"
        echo ""
    fi

    echo -e "${CYAN}提供商列表:${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} Anthropic Claude      ${DIM}https://console.anthropic.com/settings/keys${NC}"
    echo -e "  ${BOLD}2)${NC} OpenAI                 ${DIM}https://platform.openai.com/api-keys${NC}"
    echo -e "  ${BOLD}3)${NC} Google Gemini           ${DIM}https://aistudio.google.com/app/apikey${NC}"
    echo -e "  ${BOLD}4)${NC} DeepSeek               ${DIM}https://platform.deepseek.com/api_keys${NC}"
    echo -e "  ${BOLD}5)${NC} Groq                   ${DIM}https://console.groq.com/keys${NC}"
    echo -e "  ${BOLD}6)${NC} Mistral AI             ${DIM}https://console.mistral.ai/api-keys${NC}"
    echo -e "  ${BOLD}7)${NC} 自定义 OpenAI 兼容      ${DIM}Ollama / LM Studio / OpenRouter 等${NC}"
    echo -e "  ${BOLD}8)${NC} 设置/切换默认 Provider"
    echo -e "  ${BOLD}0)${NC} 完成并保存"
    echo ""

    while true; do
        echo -ne "${BOLD}请输入编号 (0 完成): ${NC}"
        read -r choice </dev/tty || choice="0"

        case "$choice" in
            0) break ;;
            1) _config_standard_provider "anthropic" "sk-ant-..." "claude-sonnet-4-5" ;;
            2) _config_standard_provider "openai"    "sk-..."     "gpt-4o" ;;
            3) _config_standard_provider "google"    ""           "gemini-2.5-flash" ;;
            4) _config_standard_provider "deepseek"  "sk-..."     "deepseek-chat" ;;
            5) _config_standard_provider "groq"      "gsk_..."    "llama-3.3-70b-versatile" ;;
            6) _config_standard_provider "mistral"   ""           "mistral-large-latest" ;;
            7) _config_custom_provider ;;
            8) echo ""; _select_default_provider; echo "" ;;
            *) msg_warn "无效选项 (0-8)" ;;
        esac
    done

    # 保存
    if [[ ${#G_API_KEYS[@]} -eq 0 ]]; then
        msg_warn "未配置任何 API Key"
        return 0
    fi

    msg_step "保存配置..."

    [[ -z "$G_DEFAULT_PROVIDER" ]] && _auto_select_default_provider

    if write_config_via_openclaw 2>/dev/null; then
        msg_ok "通过 openclaw config 写入"
    else
        write_config_to_file
    fi

    echo ""
    _show_config_summary
    log "API keys configured: ${!G_API_KEYS[*]} | default: ${G_DEFAULT_PROVIDER}"
    return 0
}

# 标准 provider 配置（有预置模型列表的）
_config_standard_provider() {
    local provider="$1"
    local key_hint="$2"
    local recommended_model="$3"

    echo ""
    echo -e "${CYAN}${BOLD}─── ${provider} ───${NC}"

    local existing_key="${G_API_KEYS[$provider]:-}"
    if [[ -n "$existing_key" ]]; then
        echo -e "  ${DIM}已有 Key: ${existing_key:0:8}****  模型: ${G_API_MODELS[$provider]:-}${NC}"
        echo -e "  ${DIM}直接 Enter 保留${NC}"
    fi

    echo -ne "  API Key"
    [[ -n "$key_hint" ]] && echo -ne " (${key_hint})"
    echo -ne ": "
    local new_key
    read -rs new_key </dev/tty; echo ""

    if [[ -z "$new_key" ]]; then
        if [[ -n "$existing_key" ]]; then
            msg_info "保留已有 Key"
            if confirm "  重新选择模型?"; then
                local sel_models
                sel_models=$(pick_models_interactive "$provider" "$recommended_model")
                G_API_MODELS["$provider"]="$sel_models"
                _display_selected_models "$provider" "$sel_models"
            fi
            echo ""
            return
        else
            msg_warn "Key 为空，跳过"
            echo ""
            return
        fi
    fi

    G_API_KEYS["$provider"]="$new_key"

    local sel_models
    sel_models=$(pick_models_interactive "$provider" "$recommended_model")
    G_API_MODELS["$provider"]="$sel_models"

    _display_selected_models "$provider" "$sel_models"

    if [[ -z "$G_DEFAULT_PROVIDER" ]]; then
        G_DEFAULT_PROVIDER="$provider"
        msg_info "已自动设为默认 Provider"
    fi

    echo ""
}

# 自定义 provider 配置（完整交互式）
_config_custom_provider() {
    echo ""
    echo -e "${CYAN}${BOLD}─── 自定义 OpenAI 兼容 API ───${NC}"
    echo -e "${DIM}适用于: Ollama / LM Studio / vLLM / OpenRouter / one-api 等${NC}"
    echo ""

    # URL
    local existing_url="${G_API_KEYS[custom_url]:-}"
    if [[ -n "$existing_url" ]]; then
        echo -e "  ${DIM}当前 URL: ${existing_url}${NC}"
        echo -e "  ${DIM}Enter 保留${NC}"
    fi
    echo -ne "  Base URL (例: http://localhost:11434/v1): "
    local custom_url
    read -r custom_url </dev/tty || custom_url=""
    [[ -z "$custom_url" && -n "$existing_url" ]] && custom_url="$existing_url"

    if [[ -z "$custom_url" ]]; then
        msg_warn "URL 为空，跳过"
        echo ""
        return
    fi

    # Key
    local existing_key="${G_API_KEYS[custom_key]:-}"
    if [[ -n "$existing_key" && "$existing_key" != "none" ]]; then
        echo -e "  ${DIM}当前 Key: ${existing_key:0:8}****${NC}"
    fi
    echo -ne "  API Key (无需认证填 none, Enter 保留): "
    local custom_key
    read -rs custom_key </dev/tty; echo ""
    [[ -z "$custom_key" ]] && custom_key="${existing_key:-none}"

    # 模型
    local existing_models="${G_API_MODELS[custom]:-}"
    local new_models
    new_models=$(pick_custom_models_interactive "$existing_models")

    if [[ -z "$new_models" ]]; then
        msg_warn "模型为空，跳过"
        echo ""
        return
    fi

    # 写入全局变量
    G_API_KEYS["custom_url"]="$custom_url"
    G_API_KEYS["custom_key"]="$custom_key"
    G_API_MODELS["custom"]="$new_models"

    local first_m="${new_models%%,*}"
    local mc
    mc=$(echo "$new_models" | tr ',' '\n' | grep -c . || echo "0")

    echo ""
    msg_ok "自定义 API 已配置:"
    echo -e "    URL:      ${custom_url}"
    echo -e "    Key:      ${DIM}${custom_key:0:8}${custom_key:+****}${NC}"
    echo -e "    默认模型: ${GREEN}${BOLD}${first_m}${NC}"
    if [[ "$mc" -gt 1 ]]; then
        echo -e "    模型总数: ${mc} 个"
        local idx=1
        while IFS=',' read -ra arr; do
            for m in "${arr[@]}"; do
                m=$(echo "$m" | xargs)
                [[ -z "$m" ]] && continue
                if [[ $idx -eq 1 ]]; then
                    echo -e "      ${idx}. ${GREEN}${m}${NC} ${DIM}(默认)${NC}"
                else
                    echo -e "      ${idx}. ${m}"
                fi
                ((idx++))
            done
        done <<< "$new_models"
    fi

    # 自动设为默认
    if [[ -z "$G_DEFAULT_PROVIDER" ]]; then
        G_DEFAULT_PROVIDER="custom"
        msg_info "已自动设为默认 Provider"
    elif [[ "$G_DEFAULT_PROVIDER" != "custom" ]]; then
        if confirm "  将自定义 API 设为默认 Provider?"; then
            G_DEFAULT_PROVIDER="custom"
            msg_ok "已设为默认"
        fi
    fi

    echo ""
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
            esac ;;
        openrc)
            case "$action" in
                start)   sudo rc-service openclaw start   2>/dev/null || true ;;
                stop)    sudo rc-service openclaw stop    2>/dev/null || true ;;
                restart) sudo rc-service openclaw restart 2>/dev/null || true ;;
                enable)  sudo rc-update add openclaw      2>/dev/null || true ;;
                status)  sudo rc-service openclaw status  2>/dev/null || true ;;
            esac ;;
        launchd)
            local plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
            case "$action" in
                start)   launchctl load   "$plist" 2>/dev/null || true ;;
                stop)    launchctl unload "$plist" 2>/dev/null || true ;;
                restart) launchctl unload "$plist" 2>/dev/null
                         launchctl load   "$plist" 2>/dev/null || true ;;
                enable)  launchctl load   "$plist" 2>/dev/null || true ;;
                status)  launchctl list 2>/dev/null | grep -i openclaw || echo "服务未运行" ;;
            esac ;;
        *)
            case "$action" in
                start)   openclaw gateway start >> "$LOG_FILE" 2>&1 & ;;
                stop)    openclaw gateway stop  >> "$LOG_FILE" 2>&1 || true ;;
                restart) openclaw gateway stop  >> "$LOG_FILE" 2>&1 || true; sleep 1
                         openclaw gateway start >> "$LOG_FILE" 2>&1 & ;;
                status)  openclaw gateway status 2>/dev/null || echo "状态未知" ;;
            esac ;;
    esac
    return 0
}

# ─────────────────────────────────────────
#  控制面板 URL
# ─────────────────────────────────────────

show_dashboard_info() {
    local local_ip
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' \
             || ipconfig getifaddr en0 2>/dev/null \
             || echo "127.0.0.1")
    local public_ip
    public_ip=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null \
             || curl -s --max-time 4 https://ifconfig.me 2>/dev/null \
             || echo "无法获取")

    # 加载配置以显示模型信息
    [[ -z "$G_DEFAULT_PROVIDER" ]] && load_config_from_file

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║            🎉 OpenClaw 控制面板访问信息                  ║${NC}"
    echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}本机:${NC}  ${CYAN}http://127.0.0.1:${OPENCLAW_PORT}${NC}                         ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}局域网:${NC} ${CYAN}http://${local_ip}:${OPENCLAW_PORT}${NC}                       ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}SSH 隧道:${NC}                                               ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${YELLOW}  ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} user@${public_ip}${NC}  ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
        local dm="${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
        dm="${dm%%,*}"
        echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}默认 AI:${NC} ${CYAN}${G_DEFAULT_PROVIDER}${NC} → ${dm}                    ${GREEN}${BOLD}║${NC}"
        echo -e "${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
    fi
    echo -e "${GREEN}${BOLD}║${NC}  ${RED}⚠️  请勿暴露端口到公网！用 SSH/VPN 访问${NC}                 ${GREEN}${BOLD}║${NC}"
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

    echo -e "${CYAN}当前环境:${NC} ${BOLD}${OS}${NC} | ${BOLD}${ARCH_LABEL}${NC}"
    echo ""

    if has_cmd openclaw; then
        local iv
        iv=$(openclaw --version 2>/dev/null || echo "未知")
        msg_warn "OpenClaw 已安装 ($iv)"
        if ! confirm "重新安装/升级?"; then
            return 0
        fi
    fi

    # Step 1
    msg_step "Step 1/5: 系统依赖..."
    case "$OS" in
        debian)
            safe_run "apt update" sudo apt-get update -qq
            safe_run "基础依赖" sudo apt-get install -y curl wget git build-essential ca-certificates gnupg ;;
        rhel|fedora)
            safe_run "更新缓存" bash -c "$UPDATE_CMD"
            safe_run "基础依赖" bash -c "$INSTALL_CMD curl wget git gcc gcc-c++ make" ;;
        arch)
            safe_run "pacman -Sy" sudo pacman -Sy --noconfirm
            safe_run "基础依赖" sudo pacman -S --noconfirm curl wget git base-devel ;;
        alpine)
            safe_run "apk update" sudo apk update
            safe_run "基础依赖" sudo apk add curl wget git build-base ;;
        macos)
            if ! has_cmd brew; then
                msg_step "安装 Homebrew..."
                safe_run "Homebrew" \
                    bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            fi
            safe_run "基础工具" brew install curl wget git ;;
    esac
    msg_ok "依赖完成"

    # Step 2
    msg_step "Step 2/5: Node.js..."
    install_nodejs || {
        msg_fail "Node.js 安装失败"
        press_any_key; return 1
    }

    # Step 3
    msg_step "Step 3/5: 安装 OpenClaw..."
    echo ""
    echo -e "${CYAN}安装方式:${NC}"
    echo "  1) 官方安装脚本 [推荐]"
    echo "  2) npm 全局安装"
    echo "  3) GitHub 源码"
    echo ""
    echo -ne "${BOLD}请选择 [1-3] (默认: 1): ${NC}"
    local ic
    read -r ic </dev/tty || ic="1"
    ic=${ic:-1}

    case "$ic" in
        1)
            msg_info "下载官方脚本..."
            if curl -fsSL https://openclaw.ai/install.sh | bash >> "$LOG_FILE" 2>&1; then
                msg_ok "官方脚本安装成功"
            else
                msg_warn "官方脚本失败，回退 npm..."
                npm install -g openclaw@latest >> "$LOG_FILE" 2>&1 || true
            fi ;;
        2)
            msg_info "npm install -g openclaw@latest..."
            npm install -g openclaw@latest 2>&1 | tee -a "$LOG_FILE" || true ;;
        3)
            echo -ne "${BOLD}GitHub 仓库 (默认: https://github.com/openclaw-ai/openclaw): ${NC}"
            local repo
            read -r repo </dev/tty || repo=""
            repo=${repo:-"https://github.com/openclaw-ai/openclaw"}
            local tmp="/tmp/openclaw_src_$$"
            git clone "$repo" "$tmp" >> "$LOG_FILE" 2>&1 || { msg_fail "clone 失败"; press_any_key; return 1; }
            pushd "$tmp" > /dev/null
            npm install >> "$LOG_FILE" 2>&1 || true
            npm run build >> "$LOG_FILE" 2>&1 || true
            npm install -g . >> "$LOG_FILE" 2>&1 || true
            popd > /dev/null
            rm -rf "$tmp" ;;
    esac

    _refresh_node_path

    if ! has_cmd openclaw; then
        msg_fail "安装失败，详见: $LOG_FILE"
        press_any_key; return 1
    fi
    msg_ok "OpenClaw $(openclaw --version 2>/dev/null) 安装成功！"

    # Step 4
    msg_step "Step 4/5: 配置 API 密钥..."
    echo ""
    if confirm "现在配置 AI API 密钥？(推荐)"; then
        configure_api_keys
    else
        msg_info "跳过，稍后菜单 [3] 配置"
    fi

    # Step 5
    msg_step "Step 5/5: 初始化 Gateway..."
    if openclaw onboard --install-daemon --non-interactive >> "$LOG_FILE" 2>&1; then
        msg_ok "Gateway 初始化成功"
    else
        msg_warn "非交互式初始化失败，直接启动..."
        openclaw gateway start >> "$LOG_FILE" 2>&1 & sleep 2
    fi

    service_action enable 2>/dev/null || true
    service_action start  2>/dev/null || true
    sleep 2

    if curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}/health" &>/dev/null \
       || openclaw gateway status 2>/dev/null | grep -qi "running"; then
        msg_ok "Gateway 已启动！"
    else
        msg_warn "Gateway 可能仍在启动中"
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
        press_any_key; return 0
    fi

    print_line
    echo -e "  ${BOLD}OpenClaw${NC}    : $(openclaw --version 2>/dev/null || echo '未知')"
    echo -e "  ${BOLD}Node.js${NC}     : $(node -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}npm${NC}         : v$(npm -v 2>/dev/null || echo '未安装')"
    echo -e "  ${BOLD}OS${NC}          : $(uname -srm)"
    echo -e "  ${BOLD}脚本${NC}        : ${SCRIPT_VERSION}"
    print_line
    echo ""

    msg_info "检查最新版本..."
    local latest
    latest=$(get_openclaw_latest_version)
    local current
    current=$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")

    echo -e "  ${BOLD}当前${NC}  : ${current}"
    echo -e "  ${BOLD}最新${NC}  : ${latest:-无法获取}"

    if [[ -n "$latest" && "$latest" != "$current" ]]; then
        echo ""
        msg_warn "发现新版本 $latest (当前: $current)"
        if confirm "立即升级?"; then
            msg_step "升级中..."
            if npm install -g openclaw@latest 2>&1 | tail -5; then
                msg_ok "升级完成: $(openclaw --version 2>/dev/null)"
            else
                msg_fail "升级失败"
            fi
        fi
    else
        echo ""
        msg_ok "已是最新版本"
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
            msg_step "启动 Gateway..."
            service_action start; sleep 2
            if openclaw gateway status 2>/dev/null | grep -qi "running" \
               || curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                msg_ok "Gateway 启动成功！"
                show_dashboard_info
            else
                msg_warn "可能仍在启动中，菜单 [10] 查看"
            fi ;;
        stop)
            if confirm "确认停止 Gateway?"; then
                msg_step "停止 Gateway..."
                service_action stop; sleep 1
                msg_ok "已停止"
            else
                msg_info "已取消"
            fi ;;
        restart)
            msg_step "重启 Gateway..."
            service_action restart; sleep 3
            msg_ok "已重启"
            show_dashboard_info ;;
        status)
            msg_step "运行状态:"
            echo ""
            service_action status
            load_config_from_file
            if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
                echo ""
                echo -e "  ${BOLD}默认 Provider:${NC} ${GREEN}${G_DEFAULT_PROVIDER}${NC}"
                local dm="${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
                echo -e "  ${BOLD}已选模型:${NC} ${dm}"
            fi
            show_dashboard_info ;;
    esac

    press_any_key
    return 0
}

# ─────────────────────────────────────────
#  模型管理（独立菜单）
# ─────────────────────────────────────────

manage_models() {
    msg_title "🤖 模型管理"

    load_config_from_file

    if [[ ${#G_API_KEYS[@]} -eq 0 ]]; then
        msg_warn "未配置任何 Provider"
        msg_info "请先菜单 [3] 配置 API 密钥"
        press_any_key; return 0
    fi

    _show_config_summary
    echo ""

    echo -e "${CYAN}操作:${NC}"
    echo "  1) 切换默认 Provider"
    echo "  2) 修改某个 Provider 的模型"
    echo "  3) 查看所有可用模型"
    echo "  0) 返回"
    echo ""
    echo -ne "${BOLD}请选择 [0-3]: ${NC}"
    local mc
    read -r mc </dev/tty || mc="0"

    case "$mc" in
        1)
            echo ""
            _select_default_provider
            if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
                write_config_via_openclaw 2>/dev/null || write_config_to_file
            fi ;;
        2)
            echo ""
            echo -e "${CYAN}选择 Provider:${NC}"
            local available=()
            local i=1
            for p in anthropic openai google deepseek groq mistral; do
                if [[ -n "${G_API_KEYS[$p]:-}" ]]; then
                    echo "  ${i}) ${p} → ${G_API_MODELS[$p]:-未设置}"
                    available+=("$p")
                    ((i++))
                fi
            done
            if [[ -n "${G_API_KEYS[custom_url]:-}" ]]; then
                echo "  ${i}) custom → ${G_API_MODELS[custom]:-未设置}"
                available+=("custom")
                ((i++))
            fi
            echo ""
            echo -ne "  请选择: "
            local pm
            read -r pm </dev/tty || pm=""
            if [[ -n "$pm" && "$pm" =~ ^[0-9]+$ ]] \
               && (( pm >= 1 && pm <= ${#available[@]} )); then
                local tp="${available[$((pm - 1))]}"
                local new_models
                if [[ "$tp" == "custom" ]]; then
                    new_models=$(pick_custom_models_interactive "${G_API_MODELS[custom]:-}")
                else
                    local rec="${G_API_MODELS[$tp]:-}"
                    rec="${rec%%,*}"
                    new_models=$(pick_models_interactive "$tp" "${rec:-}")
                fi
                if [[ -n "$new_models" ]]; then
                    G_API_MODELS["$tp"]="$new_models"
                    _display_selected_models "$tp" "$new_models"
                    write_config_via_openclaw 2>/dev/null || write_config_to_file
                fi
            fi ;;
        3)
            echo ""
            for p in anthropic openai google deepseek groq mistral; do
                if [[ -n "${G_API_KEYS[$p]:-}" ]]; then
                    echo -e "${CYAN}${BOLD}── ${p} ──${NC}"
                    get_provider_models "$p" | sed 's/^/  /'
                    echo ""
                fi
            done
            if [[ -n "${G_API_KEYS[custom_url]:-}" ]]; then
                echo -e "${CYAN}${BOLD}── custom ──${NC}"
                echo -e "  ${DIM}自定义 API 无预置列表，当前配置:${NC}"
                echo "  ${G_API_MODELS[custom]:-}" | tr ',' '\n' | sed 's/^/  /'
                echo ""
            fi ;;
        0) ;;
    esac

    press_any_key
    return 0
}

# ─────────────────────────────────────────
#  诊断与修复
# ─────────────────────────────────────────

diagnose_and_fix() {
    msg_title "${DOCTOR} 系统诊断与修复"
    detect_system

    local issues=0
    local fixed=0

    echo -e "${CYAN}${BOLD}全面检测中...${NC}"
    echo ""

    echo -ne "  [1/8] OpenClaw...           "
    if has_cmd openclaw; then
        echo -e "${GREEN}${OK} $(openclaw --version 2>/dev/null)${NC}"
    else
        echo -e "${RED}${FAIL} 未安装${NC}"
        ((issues++))
        if confirm "  立即安装?"; then
            install_openclaw && ((fixed++)) || true
        fi
    fi

    echo -ne "  [2/8] Node.js...            "
    if has_cmd node; then
        local nv
        nv=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$nv" -ge "$NODE_MIN_VERSION" ]]; then
            echo -e "${GREEN}${OK} $(node -v)${NC}"
        else
            echo -e "${RED}${FAIL} $(node -v) < v${NODE_MIN_VERSION}${NC}"
            ((issues++))
            if confirm "  升级?"; then install_nodejs && ((fixed++)) || true; fi
        fi
    else
        echo -e "${RED}${FAIL} 未安装${NC}"
        ((issues++))
        install_nodejs && ((fixed++)) || true
    fi

    echo -ne "  [3/8] 端口 ${OPENCLAW_PORT}...       "
    if curl -s --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
        echo -e "${GREEN}${OK} 正常${NC}"
    else
        echo -e "${YELLOW}${WARN} 无响应${NC}"
        ((issues++))
        if confirm "  启动 Gateway?"; then
            service_action start 2>/dev/null || { openclaw gateway start >> "$LOG_FILE" 2>&1 & true; }
            sleep 3
            if curl -s --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}" &>/dev/null; then
                msg_ok "  已启动"; ((fixed++))
            else
                msg_warn "  启动失败"
            fi
        fi
    fi

    echo -ne "  [4/8] 配置文件...           "
    if [[ -f "$OPENCLAW_CONFIG_DIR/config.json" ]]; then
        load_config_from_file
        if [[ ${#G_API_KEYS[@]} -gt 0 ]]; then
            echo -e "${GREEN}${OK} 存在 (${#G_API_KEYS[@]} 个 provider)${NC}"
        else
            echo -e "${YELLOW}${WARN} 文件存在但无 API Key${NC}"
            ((issues++))
        fi
    else
        echo -e "${YELLOW}${WARN} 不存在${NC}"
        ((issues++))
        msg_info "  菜单 [3] 配置"
    fi

    echo -ne "  [5/8] 自启动...             "
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if systemctl is-enabled "$OPENCLAW_SERVICE" &>/dev/null \
           || systemctl --user is-enabled "$OPENCLAW_SERVICE" &>/dev/null; then
            echo -e "${GREEN}${OK} 已启用${NC}"
        else
            echo -e "${YELLOW}${WARN} 未启用${NC}"
            ((issues++))
            if confirm "  设置?"; then
                service_action enable 2>/dev/null && { msg_ok "  已设置"; ((fixed++)); } || true
            fi
        fi
    else
        echo -e "${DIM}跳过 (非 systemd)${NC}"
    fi

    echo -ne "  [6/8] 磁盘...               "
    local da
    da=$(df "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999999")
    if [[ "$da" -gt 1048576 ]]; then
        echo -e "${GREEN}${OK} $(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')${NC}"
    else
        echo -e "${RED}${FAIL} 不足${NC}"
        ((issues++))
        if confirm "  清理日志?"; then
            rm -f "${OPENCLAW_LOG_DIR:?}"/*.log 2>/dev/null && { msg_ok "  已清理"; ((fixed++)); } || true
        fi
    fi

    echo -ne "  [7/8] 内存...               "
    local ma
    ma=$(grep -m1 MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "9999999")
    if [[ "$ma" -gt 512000 ]]; then
        echo -e "${GREEN}${OK} $(( ma / 1024 )) MB${NC}"
    else
        echo -e "${RED}${FAIL} $(( ma / 1024 )) MB${NC}"
        ((issues++))
        if confirm "  创建 2GB swap?"; then
            if [[ ! -f /swapfile ]]; then
                sudo fallocate -l 2G /swapfile >> "$LOG_FILE" 2>&1 \
                    && sudo chmod 600 /swapfile \
                    && sudo mkswap /swapfile >> "$LOG_FILE" 2>&1 \
                    && sudo swapon /swapfile \
                    && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >> "$LOG_FILE" \
                    && { msg_ok "  已创建"; ((fixed++)); } || msg_warn "  失败"
            else
                msg_info "  /swapfile 已存在"
            fi
        fi
    fi

    echo -ne "  [8/8] 外网...               "
    if curl -s --max-time 5 https://api.anthropic.com &>/dev/null \
       || curl -s --max-time 5 https://api.openai.com &>/dev/null \
       || curl -s --max-time 5 https://api.deepseek.com &>/dev/null; then
        echo -e "${GREEN}${OK} 正常${NC}"
    else
        echo -e "${YELLOW}${WARN} 异常${NC}"
        ((issues++))
        msg_warn "  检查防火墙/代理"
    fi

    if has_cmd openclaw; then
        echo ""
        msg_step "openclaw doctor..."
        openclaw doctor 2>&1 | sed 's/^/    /' || true
    fi

    echo ""
    print_line
    echo -e "${BOLD}结果:${NC}  问题 ${RED}${BOLD}${issues}${NC}  修复 ${GREEN}${BOLD}${fixed}${NC}"
    (( issues > fixed )) && echo -e "  待处理: ${YELLOW}${BOLD}$(( issues - fixed ))${NC}"
    echo -e "  日志: ${DIM}${LOG_FILE}${NC}"
    print_line

    press_any_key
    return 0
}

# ─────────────────────────────────────────
#  日志查看
# ─────────────────────────────────────────

view_logs() {
    msg_title "📋 日志查看"

    echo -e "${CYAN}日志类型:${NC}"
    echo "  1) 实时 Gateway 日志 (Ctrl+C 退出)"
    echo "  2) systemd journal"
    echo "  3) 应用日志文件"
    echo "  4) 本次脚本日志"
    echo "  0) 返回"
    echo ""
    echo -ne "${BOLD}请选择 [0-4]: ${NC}"
    local lc
    read -r lc </dev/tty || lc="0"

    case "$lc" in
        1)
            msg_info "Ctrl+C 退出"
            sleep 1
            trap 'echo ""; msg_info "已退出"' INT
            openclaw gateway logs --follow 2>/dev/null \
                || journalctl -u "$OPENCLAW_SERVICE" -f 2>/dev/null \
                || tail -f "${OPENCLAW_LOG_DIR}/gateway.log" 2>/dev/null \
                || msg_fail "无法获取" || true
            trap - INT ;;
        2)
            detect_system
            if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
                sudo journalctl -u "$OPENCLAW_SERVICE" -n 100 --no-pager 2>/dev/null \
                    || journalctl --user -u "$OPENCLAW_SERVICE" -n 100 --no-pager 2>/dev/null \
                    || msg_fail "不可用" || true
            else
                msg_warn "非 systemd"
            fi ;;
        3)
            if [[ -d "$OPENCLAW_LOG_DIR" ]]; then
                echo -e "${CYAN}文件:${NC}"
                ls -lh "$OPENCLAW_LOG_DIR" 2>/dev/null || echo "  (空)"
                echo ""
                echo -ne "${BOLD}文件名 (Enter 最新): ${NC}"
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
        4) [[ -f "$LOG_FILE" ]] && less "$LOG_FILE" || msg_warn "不存在" ;;
        0) return 0 ;;
        *) msg_warn "无效" ;;
    esac

    press_any_key
    return 0
}

# ─────────────────────────────────────────
#  卸载
# ─────────────────────────────────────────

uninstall_openclaw() {
    msg_title "${TRASH} 卸载 OpenClaw"

    echo -e "${RED}${BOLD}⚠️  此操作将卸载 OpenClaw${NC}"
    echo ""
    echo "  • 停止并禁用 Gateway"
    echo "  • 卸载 npm 包"
    echo "  • 可选删除配置/数据"
    echo ""

    if ! confirm "确认卸载?"; then
        msg_info "已取消"
        press_any_key; return 0
    fi

    detect_system

    msg_step "停止服务..."
    service_action stop 2>/dev/null || true; sleep 1

    msg_step "禁用自启..."
    case "$SERVICE_MANAGER" in
        systemd)
            sudo systemctl disable "$OPENCLAW_SERVICE" 2>/dev/null \
                || systemctl --user disable "$OPENCLAW_SERVICE" 2>/dev/null || true
            sudo rm -f "/etc/systemd/system/${OPENCLAW_SERVICE}.service" 2>/dev/null || true
            sudo systemctl daemon-reload 2>/dev/null || true ;;
        launchd)
            local plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
            launchctl unload "$plist" 2>/dev/null || true
            rm -f "$plist" 2>/dev/null || true ;;
        openrc)
            sudo rc-update del openclaw 2>/dev/null || true ;;
    esac
    msg_ok "服务已停止"

    msg_step "卸载 npm 包..."
    if npm uninstall -g openclaw >> "$LOG_FILE" 2>&1; then
        msg_ok "已卸载"
    else
        msg_warn "npm 卸载失败，手动清理..."
        local np
        np=$(npm prefix -g 2>/dev/null || echo "/usr/local")
        sudo rm -f  "${np}/bin/openclaw" 2>/dev/null || true
        sudo rm -rf "${np}/lib/node_modules/openclaw" 2>/dev/null || true
        msg_ok "清理完成"
    fi

    echo ""
    if confirm "删除配置和数据? ($OPENCLAW_CONFIG_DIR)"; then
        rm -rf "$OPENCLAW_CONFIG_DIR"
        G_API_KEYS=()
        G_API_MODELS=()
        G_DEFAULT_PROVIDER=""
        msg_ok "数据已删除"
    else
        msg_info "配置保留: $OPENCLAW_CONFIG_DIR"
    fi

    echo ""
    msg_ok "OpenClaw 已卸载"
    log "Uninstalled"
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
    echo -e "        ${DIM}一键管理 ${SCRIPT_VERSION} | 多系统 / 多模型 / 自定义优先${NC}"
    echo ""

    detect_system
    load_config_from_file

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

    local model_info=""
    if [[ -n "$G_DEFAULT_PROVIDER" ]]; then
        local dm="${G_API_MODELS[$G_DEFAULT_PROVIDER]:-}"
        dm="${dm%%,*}"
        [[ -n "$dm" ]] && model_info="  ${DIM}│${NC}  ${DIM}模型:${NC} ${CYAN}${dm}${NC}"
    fi

    echo -e "  ${DIM}系统:${NC} ${OS^^} ${ARCH_LABEL}  ${DIM}│${NC}  ${DIM}Gateway:${NC} ${status_color}${BOLD}${status_text}${NC}${model_info}"
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
        echo -e "  ${BOLD}${CYAN}[4]${NC}  📊 控制面板 URL"
        echo -e "  ${BOLD}${CYAN}[5]${NC}  📦 版本 / 升级"
        echo -e "  ${BOLD}${CYAN}[6]${NC}  📋 查看日志"
        echo -e "  ${BOLD}${CYAN}[7]${NC}  🤖 模型管理"
        echo -e "  ${BOLD}${YELLOW}[8]${NC}  🔄 重启 Gateway"
        echo -e "  ${BOLD}${YELLOW}[9]${NC}  ⏹  停止 Gateway"
        echo -e "  ${BOLD}${YELLOW}[10]${NC} 📈 运行状态"
        echo -e "  ${BOLD}${MAGENTA}[11]${NC} ${DOCTOR} 诊断修复"
        echo -e "  ${BOLD}${MAGENTA}[12]${NC} ℹ️  系统信息"
        echo -e "  ${BOLD}${RED}[13]${NC} ${TRASH} 卸载"
        echo -e "  ${BOLD}[0]${NC}  🚪 退出"
        echo ""
        print_line
        echo -ne "  ${BOLD}请输入: ${NC}"
        local choice
        read -r choice </dev/tty || choice="invalid"

        case "$choice" in
            1)  install_openclaw ;;
            2)  manage_service start ;;
            3)  configure_api_keys; press_any_key ;;
            4)  show_dashboard_info; press_any_key ;;
            5)  show_version ;;
            6)  view_logs ;;
            7)  manage_models ;;
            8)  manage_service restart ;;
            9)  manage_service stop ;;
            10) manage_service status ;;
            11) diagnose_and_fix ;;
            12) print_sysinfo; press_any_key ;;
            13) uninstall_openclaw ;;
            0)
                echo ""
                echo -e "${GREEN}${BOLD}再见！👋${NC}"
                echo ""
                exit 0
                ;;
            *)
                msg_warn "无效: ${choice} (0-13)"
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────
#  入口
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
    url)       load_config_from_file; show_dashboard_info ;;
    models)    detect_system; manage_models ;;
    config)    detect_system; configure_api_keys ;;
    *)         main_menu ;;
esac
