#!/bin/bash

set -euo pipefail

readonly SCRIPT_VERSION="1.2"
readonly BASE_DIR="${HOME}/qinglong"
readonly DATA_DIR="$BASE_DIR"
readonly QL_IMAGE_BASE="whyour/qinglong"
readonly DEFAULT_IMAGE_VER="latest"
readonly INSTALL_DEFAULT_VER="2.20.2"
readonly DEFAULT_CONTAINER_NAME="qinglong"
readonly DEFAULT_PORT=5700
readonly LOG_FILE="$DATA_DIR/ql_script.log"
readonly LOG_MAX_SIZE=1048576
readonly LOG_BACKUP_COUNT=3
readonly CRED_DIR="$DATA_DIR/config"
readonly CRED_CACHE_FILE="$CRED_DIR/.ql_api_creds.enc"
readonly MAX_PARALLEL_JOBS=5
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ============================================================
# 日志
# ============================================================
_ensure_log_dir() {
    local d; d=$(dirname "$LOG_FILE")
    [[ ! -d "$d" ]] && mkdir -p "$d" 2>/dev/null || true
}

_rotate_log() {
    [[ ! -f "$LOG_FILE" ]] && return 0
    local sz; sz=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$sz" -ge "$LOG_MAX_SIZE" ]]; then
        local i
        for ((i=LOG_BACKUP_COUNT-1; i>=1; i--)); do
            [[ -f "${LOG_FILE}.$i" ]] && mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"
        done
        mv "$LOG_FILE" "${LOG_FILE}.1"
        touch "$LOG_FILE"
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - 日志已轮转" >> "$LOG_FILE"
    fi
}

log() {
    local level="$1" msg="$2"
    local ts; ts=$(date "+%Y-%m-%d %H:%M:%S")
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]  $msg${NC}" >&2 ;;
        WARN)  echo -e "${YELLOW}[WARN]  $msg${NC}" >&2 ;;
        ERROR) echo -e "${RED}[ERROR] $msg${NC}" >&2 ;;
        STEP)  echo -e "${CYAN}${BOLD}[STEP]  $msg${NC}" >&2 ;;
        OK)    echo -e "${GREEN}${BOLD}[✓ OK]  $msg${NC}" >&2 ;;
        TIP)   echo -e "${BLUE}${BOLD}[TIP]   $msg${NC}" >&2 ;;
        *)     echo -e "[LOG]   $msg" >&2 ;;
    esac
    _ensure_log_dir
    local safe; safe=$(echo "$msg" | sed \
        -e 's/token=[^ ]*/token=***/gi' \
        -e 's/secret=[^ ]*/secret=***/gi' \
        -e 's/Bearer [^ ]*/Bearer ***/gi')
    echo "[$level] $ts - $safe" >> "$LOG_FILE"
    _rotate_log
}

# ============================================================
# 初始化
# ============================================================
make_directories() {
    local d fail=()
    for d in config log db repo raw scripts jbot backup; do
        mkdir -p "$DATA_DIR/$d" 2>/dev/null || fail+=("$d")
    done
    [[ ${#fail[@]} -gt 0 ]] && { log ERROR "目录创建失败: ${fail[*]}"; return 1; }
    log INFO "必要目录已就绪"
}

check_dependencies() {
    command -v docker &>/dev/null || { log ERROR "未安装 Docker！"; exit 1; }
    docker info &>/dev/null || { log ERROR "Docker 守护进程未运行！"; exit 1; }
    if ! command -v jq &>/dev/null; then
        log WARN "未安装 jq，正在尝试安装..."
        local ok=0
        command -v apt-get &>/dev/null && apt-get update -qq && apt-get install -y jq 2>/dev/null && ok=1
        [[ $ok -eq 0 ]] && command -v yum &>/dev/null && yum install -y epel-release 2>/dev/null; yum install -y jq 2>/dev/null && ok=1
        [[ $ok -eq 0 ]] && command -v apk &>/dev/null && apk add -q jq 2>/dev/null && ok=1
        [[ $ok -eq 0 ]] && command -v opkg &>/dev/null && opkg update 2>/dev/null && opkg install jq 2>/dev/null && ok=1
        [[ $ok -eq 1 ]] && log INFO "jq 安装完成" || { log ERROR "jq 安装失败！"; exit 1; }
    fi
    command -v curl &>/dev/null || { log ERROR "未安装 curl！"; exit 1; }
    log INFO "依赖检测通过 ✅"
}

# ============================================================
# 磁盘
# ============================================================
check_disk_space() {
    local min_gb=3 warn_gb=5 dir="${1:-$DATA_DIR}"
    mkdir -p "$dir" 2>/dev/null || dir="$HOME"
    local mb; mb=$(df -m "$dir" 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -z "$mb" ]] || ! [[ "$mb" =~ ^[0-9]+$ ]]; then
        log WARN "无法检测磁盘空间"; return 0
    fi
    local gb=$((mb/1024))
    echo -e "\n${CYAN}${BOLD}════ 磁盘空间检测 ════${NC}" >&2
    printf "  可用: %dGB (%dMB) | 最低: %dGB | 推荐: %dGB\n" "$gb" "$mb" "$min_gb" "$warn_gb" >&2
    if ((mb < min_gb*1024)); then
        echo -e "  ${RED}${BOLD}❌ 空间严重不足！${NC}" >&2
        read -rp "强制继续？(y/N): " f; [[ ! "${f:-N}" =~ ^[Yy]$ ]] && return 1
    elif ((mb < warn_gb*1024)); then
        echo -e "  ${YELLOW}${BOLD}⚠️  空间偏低${NC}" >&2
        read -rp "继续？(Y/n): " f; [[ "${f:-Y}" =~ ^[Nn]$ ]] && return 1
    else
        echo -e "  ${GREEN}${BOLD}✅ 空间充足${NC}" >&2
    fi
    echo "" >&2
}

# ============================================================
# 端口 / 容器名
# ============================================================
port_is_free() {
    local p=$1
    command -v ss &>/dev/null && ss -tuln 2>/dev/null | grep -q ":${p}\b" && return 1
    command -v netstat &>/dev/null && netstat -tuln 2>/dev/null | grep -q ":${p}\b" && return 1
    return 0
}

prompt_port() {
    local prompt="$1" def="$2" input
    while true; do
        read -rp "$prompt [$def]: " input; input=${input:-$def}
        [[ "$input" =~ ^[0-9]+$ ]] && ((input>=1 && input<=65535)) || { log WARN "端口1-65535"; continue; }
        port_is_free "$input" && { echo "$input"; return; } || log WARN "端口 $input 被占用"
    done
}

prompt_container_name() {
    local prompt="$1" def="$2" input
    read -rp "$prompt [$def]: " input; echo "${input:-$def}"
}

get_container_port() {
    docker inspect --format='{{(index (index .NetworkSettings.Ports "5700/tcp") 0).HostPort}}' "$1" 2>/dev/null || echo ""
}

get_host_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
}

# ============================================================
# 容器选择器
# ============================================================
_get_ql_containers() {
    local filter="${1:-all}"
    case "$filter" in
        running) docker ps --format "{{.Names}}" 2>/dev/null | grep -E "^${DEFAULT_CONTAINER_NAME}" || true ;;
        stopped) docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null | awk -F'\t' '$2~/Exited|Created/{print $1}' | grep -E "^${DEFAULT_CONTAINER_NAME}" || true ;;
        created) docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null | awk -F'\t' '$2~/Created/{print $1}' | grep -E "^${DEFAULT_CONTAINER_NAME}" || true ;;
        *)       docker ps -a --format "{{.Names}}" 2>/dev/null | grep -E "^${DEFAULT_CONTAINER_NAME}" || true ;;
    esac
}

_pick_container() {
    local prompt="${1:-选择容器}" filter="${2:-all}"
    local -a containers
    mapfile -t containers < <(_get_ql_containers "$filter")
    [[ ${#containers[@]} -eq 0 ]] && { log WARN "未找到符合条件的青龙容器"; return 1; }
    if [[ ${#containers[@]} -eq 1 ]]; then echo "${containers[0]}"; return 0; fi
    echo -e "\n${YELLOW}$prompt：${NC}" >&2
    local i
    for i in "${!containers[@]}"; do
        local st; st=$(docker inspect --format='{{.State.Status}}' "${containers[$i]}" 2>/dev/null || echo "未知")
        printf "  %d. %-20s [%s]\n" $((i+1)) "${containers[$i]}" "$st" >&2
    done
    echo "  $((${#containers[@]}+1)). 所有容器" >&2
    local ch
    while true; do
        read -rp "请选择 [1-$((${#containers[@]}+1))]: " ch
        [[ "$ch" =~ ^[0-9]+$ ]] || { log WARN "请输入数字"; continue; }
        if ((ch>=1 && ch<=${#containers[@]})); then echo "${containers[$((ch-1))]}"; return 0
        elif ((ch==${#containers[@]}+1)); then printf '%s\n' "${containers[@]}"; return 0; fi
        log WARN "无效选择"
    done
}

# ============================================================
# 容器管理：启动 / 停止 / 重启 / 日志 / 清理
# ============================================================
start_container() {
    log STEP "启动青龙容器..."
    local name; name=$(_pick_container "选择要启动的容器" "stopped") || return 1
    local -a names; mapfile -t names <<< "$name"
    local c
    for c in "${names[@]}"; do
        [[ -z "$c" ]] && continue
        local st; st=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "")
        if [[ "$st" == "created" ]]; then
            log WARN "$c 处于 Created 状态（上次启动失败的残留）"
            read -rp "是否删除残留并重新部署？(y/N): " d
            [[ "${d:-N}" =~ ^[Yy]$ ]] && docker rm -f "$c" >/dev/null 2>&1 && log OK "已删除残留 $c，请选菜单[1]重新部署"
            continue
        fi
        log INFO "启动 $c ..."
        if docker start "$c" >/dev/null 2>&1; then
            log OK "✅ $c 启动成功"
            local p; p=$(get_container_port "$c")
            [[ -n "$p" ]] && echo -e "  ${CYAN}面板: http://$(get_host_ip):$p${NC}" >&2
        else
            log ERROR "❌ $c 启动失败"
            docker logs "$c" 2>&1 | tail -10 >&2
        fi
    done
}

stop_container() {
    log STEP "停止青龙容器..."
    local name; name=$(_pick_container "选择要停止的容器" "running") || return 1
    local -a names; mapfile -t names <<< "$name"
    local c; for c in "${names[@]}"; do
        [[ -z "$c" ]] && continue
        docker stop "$c" >/dev/null 2>&1 && log OK "✅ $c 已停止" || log ERROR "❌ $c 停止失败"
    done
}

restart_container() {
    log STEP "重启青龙容器..."
    local name; name=$(_pick_container "选择要重启的容器" "running") || {
        log WARN "没有运行中的容器，尝试启动已停止的..."
        start_container; return $?
    }
    local -a names; mapfile -t names <<< "$name"
    local c; for c in "${names[@]}"; do
        [[ -z "$c" ]] && continue
        docker restart "$c" >/dev/null 2>&1 && {
            log OK "✅ $c 重启成功"; sleep 2
            local p; p=$(get_container_port "$c")
            [[ -n "$p" ]] && echo -e "  ${CYAN}面板: http://$(get_host_ip):$p${NC}" >&2
        } || log ERROR "❌ $c 重启失败"
    done
}

view_container_logs() {
    local name; name=$(_pick_container "选择容器" "all") || return 1
    local c; c=$(echo "$name" | head -1)
    echo -e "\n${CYAN}── $c 最近50行日志（Ctrl+C退出）──${NC}" >&2
    docker logs --tail 50 -f "$c" 2>&1
}

force_remove_created() {
    log STEP "清理 Created 状态残留容器..."
    local -a cc
    mapfile -t cc < <(docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null | awk -F'\t' '$2~/^Created/{print $1}')
    if [[ ${#cc[@]} -eq 0 ]]; then log INFO "没有 Created 残留容器"; return 0; fi
    echo -e "${YELLOW}发现残留：${NC}" >&2
    local c; for c in "${cc[@]}"; do echo "  - $c" >&2; done
    read -rp "全部删除？(y/N): " cf; [[ ! "${cf:-N}" =~ ^[Yy]$ ]] && return 0
    for c in "${cc[@]}"; do docker rm -f "$c" >/dev/null 2>&1 && log OK "已删除 $c" || log ERROR "删除失败 $c"; done
}

# ============================================================
# devpts 诊断（仅提示，不强制修复）
# ============================================================
diagnose_devpts() {
    echo -e "\n${CYAN}${BOLD}════ /dev/pts 环境诊断 ════${NC}" >&2
    echo -e "\n${YELLOW}── 系统信息 ──${NC}" >&2
    uname -a >&2
    grep -E "^(ID|NAME|VERSION)=" /etc/os-release 2>/dev/null | sed 's/^/  /' >&2
    echo -e "\n${YELLOW}── 挂载状态 ──${NC}" >&2
    mount | grep -E "devpts|pts" | sed 's/^/  /' >&2 || echo -e "  ${RED}无devpts挂载${NC}" >&2
    echo -e "\n${YELLOW}── /dev/pts 目录 ──${NC}" >&2
    ls -la /dev/pts/ 2>/dev/null | sed 's/^/  /' >&2 || echo -e "  ${RED}目录不存在${NC}" >&2
    echo -e "\n${YELLOW}── 容器内 /dev/pts 测试 ──${NC}" >&2
    echo -n "  " >&2
    docker run --rm alpine ls /dev/pts/ 2>&1 | tr '\n' ' ' >&2
    echo "" >&2
    local has_ptmx=0
    docker run --rm alpine ls /dev/pts/ 2>/dev/null | grep -q "ptmx" && has_ptmx=1

    echo -e "\n${YELLOW}── 诊断结论 ──${NC}" >&2
    if [[ $has_ptmx -eq 1 ]]; then
        echo -e "  ${GREEN}${BOLD}✅ 容器内 ptmx 可用，支持 -dit 启动${NC}" >&2
    else
        echo -e "  ${RED}${BOLD}❌ 容器内 ptmx 不可用（定制内核常见）${NC}" >&2
        echo -e "  ${YELLOW}本脚本已自动使用 -d 启动，不影响任何功能${NC}" >&2
        echo -e "  ${YELLOW}青龙面板 Web 功能完全正常 ✅${NC}" >&2
        echo -e "  ${YELLOW}仅 docker exec -it 交互式shell可能受限 ⚠️${NC}" >&2
    fi

    echo -e "\n${YELLOW}── Created 残留容器 ──${NC}" >&2
    local created
    created=$(docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null | awk -F'\t' '$2~/^Created/{print $1}')
    if [[ -n "$created" ]]; then
        echo "$created" | sed 's/^/  ⚠️  /' >&2
        read -rp "是否清理残留容器？(y/N): " cf
        [[ "${cf:-N}" =~ ^[Yy]$ ]] && force_remove_created
    else
        echo "  无残留 ✅" >&2
    fi
    echo -e "${CYAN}${BOLD}═══════════════════════════${NC}\n" >&2
}

# ============================================================
# 凭证管理（加密存储）
# ============================================================
_get_machine_key() {
    local mid; mid=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null || hostname 2>/dev/null || echo "default")
    printf '%s%s' "$mid" "$mid" | head -c 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

_save_creds() {
    local cn="$1" cid="$2" csec="$3"
    mkdir -p "$CRED_DIR" && chmod 700 "$CRED_DIR"
    local key; key=$(_get_machine_key)
    local pt="${cn}|${cid}|${csec}"
    if command -v openssl &>/dev/null; then
        local ex=""
        [[ -f "$CRED_CACHE_FILE" ]] && ex=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass "pass:${key}" -in "$CRED_CACHE_FILE" 2>/dev/null || echo "")
        local nw; nw=$(echo "$ex" | grep -v "^${cn}|" 2>/dev/null || true)
        nw="${nw}${nw:+$'\n'}${pt}"
        echo "$nw" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -pass "pass:${key}" -out "$CRED_CACHE_FILE" 2>/dev/null
        chmod 600 "$CRED_CACHE_FILE"
    else
        local pf="${CRED_CACHE_FILE%.enc}"
        grep -v "^${cn}|" "$pf" 2>/dev/null > "${pf}.tmp" || true
        echo "$pt" >> "${pf}.tmp"; mv "${pf}.tmp" "$pf"; chmod 600 "$pf"
    fi
}

_load_cached_creds() {
    local cn="$1" key; key=$(_get_machine_key)
    local content=""
    if [[ -f "$CRED_CACHE_FILE" ]] && command -v openssl &>/dev/null; then
        content=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass "pass:${key}" -in "$CRED_CACHE_FILE" 2>/dev/null || echo "")
    elif [[ -f "${CRED_CACHE_FILE%.enc}" ]]; then
        content=$(cat "${CRED_CACHE_FILE%.enc}" 2>/dev/null || echo "")
    fi
    [[ -z "$content" ]] && echo "" && return 1
    local line; line=$(echo "$content" | grep "^${cn}|" | tail -1)
    [[ -z "$line" ]] && echo "" && return 1
    echo "${line#*|}"
}

_parse_auth_json() {
    local cn="$1" aj="" p
    for p in /ql/data/config/auth.json /ql/config/auth.json /data/config/auth.json /ql/db/auth.json; do
        aj=$(docker exec "$cn" cat "$p" 2>/dev/null || echo "")
        [[ -n "$aj" ]] && break
    done
    [[ -z "$aj" ]] && echo "" && return 1
    local cid csec
    cid=$(echo "$aj" | jq -r '.applications[0].client_id // .tokens[0].client_id // .client_id // empty' 2>/dev/null)
    csec=$(echo "$aj" | jq -r '.applications[0].client_secret // .tokens[0].client_secret // .client_secret // empty' 2>/dev/null)
    [[ -n "$cid" && -n "$csec" ]] && echo "${cid}|${csec}" && return 0
    echo "" && return 1
}

_show_openapi_guide() {
    local hp="${1:-5700}"
    echo -e "\n${CYAN}${BOLD}════ Open API 创建指引 ════${NC}" >&2
    echo -e "  1. 访问: ${CYAN}http://$(get_host_ip):${hp}${NC}" >&2
    echo -e "  2. 系统设置 → 应用设置 → 添加应用" >&2
    echo -e "  3. 全权限勾选 → 提交" >&2
    echo -e "  4. 复制 Client ID 和 Client Secret\n" >&2
}

_get_api_credentials() {
    local cn="$1" hp="${2:-5700}" creds
    creds=$(_load_cached_creds "$cn" 2>/dev/null || echo "")
    [[ -n "$creds" ]] && log INFO "✅ 使用加密缓存凭证" && echo "$creds" && return 0
    log INFO "尝试从 auth.json 读取..."
    creds=$(_parse_auth_json "$cn" 2>/dev/null || echo "")
    if [[ -n "$creds" ]]; then
        log OK "auth.json 读取成功"
        _save_creds "$cn" "${creds%%|*}" "${creds##*|}"
        echo "$creds" && return 0
    fi
    log WARN "无法自动获取，请手动输入"
    _show_openapi_guide "$hp"
    echo -e "${YELLOW}选择：${NC}" >&2
    echo "  1. 手动输入凭证" >&2
    echo "  2. 跳过 Open API" >&2
    read -rp "请选择 [1/2，默认2]: " ch
    case "${ch:-2}" in
        1)
            local cid csec
            while true; do read -rsp "  Client ID: " cid; echo >&2; [[ -n "$cid" ]] && break; echo -e "  ${RED}不能为空${NC}" >&2; done
            while true; do read -rsp "  Client Secret: " csec; echo >&2; [[ -n "$csec" ]] && break; echo -e "  ${RED}不能为空${NC}" >&2; done
            log INFO "验证凭证..."
            local tok
            tok=$(curl -s -m 10 -X POST "http://localhost:${hp}/open/auth/token" \
                -H "Content-Type: application/json" \
                -d "$(jq -n --arg id "$cid" --arg s "$csec" '{"client_id":$id,"client_secret":$s}')" \
                2>/dev/null | jq -r '.data.token // empty' 2>/dev/null)
            if [[ -n "$tok" ]]; then
                log OK "凭证验证成功"
                _save_creds "$cn" "$cid" "$csec"
                echo "${cid}|${csec}" && return 0
            else
                log ERROR "凭证验证失败！"; echo "" && return 1
            fi ;;
        *) log WARN "跳过 Open API"; echo "" && return 1 ;;
    esac
}

_get_ql_token() {
    local cn="$1" hp="$2" creds
    creds=$(_get_api_credentials "$cn" "$hp" 2>/dev/null || echo "")
    [[ -z "$creds" ]] && echo "" && return 1
    local cid="${creds%%|*}" csec="${creds##*|}"
    local tok
    tok=$(curl -s -m 10 -X POST "http://localhost:${hp}/open/auth/token" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg id "$cid" --arg s "$csec" '{"client_id":$id,"client_secret":$s}')" \
        2>/dev/null | jq -r '.data.token // empty' 2>/dev/null)
    [[ -n "$tok" ]] && echo "$tok" && return 0
    log WARN "Token获取失败，清除缓存"
    _clear_cred_for "$cn"; echo "" && return 1
}

_clear_cred_for() {
    local cn="$1" key; key=$(_get_machine_key)
    if [[ -f "$CRED_CACHE_FILE" ]] && command -v openssl &>/dev/null; then
        local c; c=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass "pass:${key}" -in "$CRED_CACHE_FILE" 2>/dev/null || echo "")
        local nw; nw=$(echo "$c" | grep -v "^${cn}|" 2>/dev/null || true)
        if [[ -n "$nw" ]]; then echo "$nw" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -pass "pass:${key}" -out "$CRED_CACHE_FILE" 2>/dev/null
        else rm -f "$CRED_CACHE_FILE"; fi
    fi
}

clear_cred_cache() {
    rm -f "$CRED_CACHE_FILE" "${CRED_CACHE_FILE%.enc}" 2>/dev/null
    log OK "凭证缓存已清除"
}

# ============================================================
# API / 系统安装
# ============================================================
_api_install_dep() {
    local hp="$1" tok="$2" pkg="$3" tp="${4:-linux}"
    local body; body=$(jq -n --arg n "$pkg" --arg t "$tp" '{"names":[$n],"type":$t}')
    local resp; resp=$(curl -s -m 60 -X POST "http://localhost:${hp}/open/dependencies" \
        -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" -d "$body" 2>/dev/null)
    local code; code=$(echo "$resp" | jq -r '.code // 0' 2>/dev/null)
    [[ "$code" == "200" ]]
}

_sys_install_pkg() {
    local cn="$1" pkg="$2" os="${3:-alpine}"
    if [[ "$os" == "alpine" ]]; then docker exec "$cn" apk add --no-cache "$pkg" >/dev/null 2>&1
    else docker exec "$cn" apt-get install -y -q "$pkg" >/dev/null 2>&1; fi
}

# ============================================================
# 进度条
# ============================================================
_progress_bar() {
    local cur="$1" total="$2" label="${3:-}" w=30
    local filled=$((cur*w/total)) empty=$((w-filled)) bar="" i
    for ((i=0;i<filled;i++)); do bar+="█"; done
    for ((i=0;i<empty;i++)); do bar+="░"; done
    printf "\r  ${CYAN}[%s]${NC} %3d/%d  %-25s" "$bar" "$cur" "$total" "$label" >&2
}
_progress_done() { echo "" >&2; }

# ============================================================
# 并行安装
# ============================================================
_install_pkgs_parallel() {
    local cn="$1" itype="$2" hp="${3:-}" tok="${4:-}"
    shift 4; local pkgs=("$@") total=${#pkgs[@]}
    local tmpdir; tmpdir=$(mktemp -d)
    local pids=() jc=0 i
    for i in "${!pkgs[@]}"; do
        local pkg="${pkgs[$i]}" rf="$tmpdir/${i}.result"
        (
            local ok=0
            case "$itype" in
                npm) for a in 1 2; do docker exec "$cn" sh -c "cd /ql/scripts && pnpm add '$pkg' 2>/dev/null || npm install '$pkg' 2>/dev/null" >/dev/null 2>&1 && ok=1 && break; sleep 1; done ;;
                pip) docker exec "$cn" pip3 install "$pkg" -q >/dev/null 2>&1 && ok=1 ;;
                linux-alpine)
                    [[ -n "$tok" && -n "$hp" ]] && _api_install_dep "$hp" "$tok" "$pkg" "linux" && ok=1
                    [[ $ok -eq 0 ]] && _sys_install_pkg "$cn" "$pkg" "alpine" && ok=1 ;;
                linux-debian)
                    [[ -n "$tok" && -n "$hp" ]] && _api_install_dep "$hp" "$tok" "$pkg" "linux" && ok=1
                    [[ $ok -eq 0 ]] && _sys_install_pkg "$cn" "$pkg" "debian" && ok=1 ;;
            esac
            echo "${pkg}|${ok}" > "$rf"
        ) &
        pids+=($!); jc=$((jc+1))
        local dc; dc=$(find "$tmpdir" -name "*.result" 2>/dev/null | wc -l)
        _progress_bar "$dc" "$total" "$pkg"
        if [[ $jc -ge $MAX_PARALLEL_JOBS ]]; then wait "${pids[0]}" 2>/dev/null || true; pids=("${pids[@]:1}"); jc=$((jc-1)); fi
    done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    _progress_done
    local ok=0 fail=0 failed=()
    for i in "${!pkgs[@]}"; do
        local r; r=$(cat "$tmpdir/${i}.result" 2>/dev/null || echo "${pkgs[$i]}|0")
        [[ "${r##*|}" == "1" ]] && ok=$((ok+1)) || { fail=$((fail+1)); failed+=("${r%%|*}"); }
    done
    rm -rf "$tmpdir"
    echo "$ok|$fail|${failed[*]}"
}

# ============================================================
# 版本选择
# ============================================================
select_version() {
    local dv="${1:-latest}" sc="${2:-5}"
    echo -e "\n${CYAN}🔄 获取版本列表...${NC}" >&2
    local raw="" att
    for att in 1 2 3; do
        raw=$(curl -sf -m 15 "https://hub.docker.com/v2/namespaces/whyour/repositories/qinglong/tags?page_size=50" 2>/dev/null | jq -r '.results[].name' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV | head -n "$sc" || echo "")
        [[ -n "$raw" ]] && break; log WARN "第$att次获取失败..." >&2; sleep 2
    done
    local versions=("$dv")
    if [[ -n "$raw" ]]; then
        while IFS= read -r v; do [[ "$v" != "$dv" ]] && versions+=("$v"); done <<< "$raw"
        echo -e "${YELLOW}请选择版本：${NC}" >&2
        local i; for i in "${!versions[@]}"; do
            [[ "${versions[$i]}" == "$dv" ]] && echo -e "  $((i+1)). ${versions[$i]}  ${GREEN}← 默认${NC}" >&2 || echo "  $((i+1)). ${versions[$i]}" >&2
        done
        local ch nv=${#versions[@]}
        while true; do read -rp "编号 [默认1]: " ch; ch=${ch:-1}
            [[ "$ch" =~ ^[0-9]+$ ]] && ((ch>=1 && ch<=nv)) && echo "${versions[$((ch-1))]}" && return 0
            log ERROR "输入 1~$nv" >&2
        done
    else
        log WARN "无法获取版本列表" >&2
        local mv; read -rp "手动输入版本 [默认$dv]: " mv; echo "${mv:-$dv}"
    fi
}

# ============================================================
# 全依赖一键补全
# ============================================================
install_all_deps() {
    check_disk_space || return 1
    local name="${1:-}"
    [[ -z "$name" ]] && name=$(prompt_container_name "请输入青龙容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps --format "{{.Names}}" | grep -qw "$name" || { log ERROR "容器 <$name> 未运行！"; return 1; }
    local hp; hp=$(get_container_port "$name"); [[ -z "$hp" ]] && hp="$DEFAULT_PORT"

    echo -e "\n${CYAN}${BOLD}══ 青龙全依赖补全 v1.2 ══${NC}" >&2
    echo -e "  容器: $name | 端口: $hp" >&2

    # STEP 1
    log STEP "[1/8] 检测容器系统..."
    local os="alpine"
    docker exec "$name" sh -c "grep -qi 'debian\|ubuntu' /etc/os-release 2>/dev/null" && os="debian" && log INFO "Debian系" || log INFO "Alpine系"

    # STEP 2
    log STEP "[2/8] 获取 Open API 凭证..."
    local ws=0
    while ((ws<30)); do
        local hc; hc=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "http://localhost:${hp}" 2>/dev/null || echo "000")
        [[ "$hc" =~ ^[2-4] ]] && break; log INFO "等待面板就绪(${ws}s)..."; sleep 5; ws=$((ws+5))
    done
    local tok="" avail=0
    tok=$(_get_ql_token "$name" "$hp" 2>/dev/null || echo "")
    [[ -n "$tok" ]] && avail=1 && log OK "Token获取成功" || log WARN "Open API不可用，Linux依赖将系统直装"

    # STEP 3
    log STEP "[3/8] 安装系统编译环境..."
    if [[ "$os" == "alpine" ]]; then
        docker exec "$name" apk add --no-cache alpine-sdk autoconf automake libtool build-base g++ gcc make cairo-dev pango-dev giflib-dev python3-dev py3-pip jpeg-dev zlib-dev freetype-dev libxml2-dev libxslt-dev musl-dev libffi-dev openssl-dev tzdata curl wget git ca-certificates >/dev/null 2>&1 && log OK "Alpine编译环境就绪" || log WARN "部分包安装失败"
    else
        docker exec "$name" apt-get update -qq >/dev/null 2>&1
        docker exec "$name" apt-get install -y -q build-essential gcc g++ make libcairo2-dev libpango1.0-dev libgif-dev python3-dev python3-pip libjpeg-dev zlib1g-dev libffi-dev libssl-dev libxml2-dev libxslt1-dev tzdata curl wget git ca-certificates >/dev/null 2>&1 && log OK "Debian编译环境就绪" || log WARN "部分包安装失败"
    fi

    # STEP 4
    log STEP "[4/8] 修复 pnpm/npm 源..."
    docker exec "$name" sh -c "pnpm config set registry https://registry.npmmirror.com 2>/dev/null; npm config set registry https://registry.npmmirror.com 2>/dev/null; rm -f /ql/scripts/node_modules/.modules.yaml 2>/dev/null" >/dev/null 2>&1 && log OK "源已设为淘宝镜像" || log WARN "源修复部分失败"

    # STEP 5
    log STEP "[5/8] 修复 pip..."
    docker exec "$name" sh -c "python3 -m pip install --upgrade pip setuptools wheel -q 2>/dev/null; pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple 2>/dev/null; pip3 config set global.trusted-host pypi.tuna.tsinghua.edu.cn 2>/dev/null" >/dev/null 2>&1 && log OK "pip已修复（清华源）" || log WARN "pip修复部分失败"

    # STEP 6
    log STEP "[6/8] 安装 NodeJS 依赖（并行）..."
    local npkgs=("axios" "axios@0.27.2" "request" "got" "node-fetch" "https-proxy-agent" "tunnel" "crypto-js" "ts-md5" "node-rsa" "js-base64" "date-fns" "moment" "json5" "qs" "form-data" "dotenv" "jsdom" "cheerio" "xmldom" "tough-cookie" "typescript" "tslib" "ts-node" "@types/node" "ws@7.4.3" "global-agent" "png-js" "sharp" "node-telegram-bot-api" "juejin-helper")
    local nr; nr=$(_install_pkgs_parallel "$name" "npm" "" "" "${npkgs[@]}")
    local on fn fln; on=$(echo "$nr"|cut -d'|' -f1); fn=$(echo "$nr"|cut -d'|' -f2); fln=$(echo "$nr"|cut -d'|' -f3-)
    log OK "NodeJS: ✅$on ❌$fn / 共${#npkgs[@]}"
    [[ -n "$fln" ]] && log WARN "失败: $fln"

    # STEP 7
    log STEP "[7/8] 安装 Python3 依赖（并行）..."
    local ppkgs=("requests" "httpx" "aiohttp" "pycryptodome" "rsa" "bs4" "lxml" "PyExecJS" "Pillow" "ping3" "jieba" "redis" "openai" "pytz" "pyyaml" "urllib3" "certifi")
    local pr; pr=$(_install_pkgs_parallel "$name" "pip" "" "" "${ppkgs[@]}")
    local op fp flp; op=$(echo "$pr"|cut -d'|' -f1); fp=$(echo "$pr"|cut -d'|' -f2); flp=$(echo "$pr"|cut -d'|' -f3-)
    log OK "Python3: ✅$op ❌$fp / 共${#ppkgs[@]}"
    [[ -n "$flp" ]] && log WARN "失败: $flp"

    # STEP 8
    log STEP "[8/8] 安装 Linux 依赖..."
    local lpkgs=("alpine-sdk" "autoconf" "automake" "libtool" "gcc" "g++" "make" "python3-dev" "libffi-dev" "openssl-dev" "jpeg-dev" "zlib-dev" "libxml2-dev" "libxslt-dev" "cairo-dev" "pango-dev" "giflib-dev" "curl" "wget" "git" "ca-certificates" "tzdata")
    local lit="linux-alpine"; [[ "$os" == "debian" ]] && lit="linux-debian"
    local lr
    if ((avail==1)); then
        echo -e "  ${GREEN}模式: Open API（面板可见）${NC}" >&2
        lr=$(_install_pkgs_parallel "$name" "$lit" "$hp" "$tok" "${lpkgs[@]}")
    else
        echo -e "  ${YELLOW}模式: 系统直装${NC}" >&2
        lr=$(_install_pkgs_parallel "$name" "$lit" "" "" "${lpkgs[@]}")
    fi
    local ol fl fll; ol=$(echo "$lr"|cut -d'|' -f1); fl=$(echo "$lr"|cut -d'|' -f2); fll=$(echo "$lr"|cut -d'|' -f3-)
    log OK "Linux: ✅$ol ❌$fl / 共${#lpkgs[@]}"
    [[ -n "$fll" ]] && log WARN "失败: $fll"

    # canvas
    log INFO "尝试安装 canvas..."
    docker exec "$name" sh -c "cd /ql/scripts && pnpm add canvas 2>/dev/null || npm install canvas --build-from-source 2>/dev/null" >/dev/null 2>&1 && log OK "canvas 成功" || log WARN "canvas 失败（非必需）"

    # 汇总
    echo -e "\n${CYAN}${BOLD}══ 安装汇总 ══${NC}" >&2
    printf "  NodeJS  : ${GREEN}%d${NC}✅ ${RED}%d${NC}❌ 共%d\n" "$on" "$fn" "${#npkgs[@]}" >&2
    printf "  Python3 : ${GREEN}%d${NC}✅ ${RED}%d${NC}❌ 共%d\n" "$op" "$fp" "${#ppkgs[@]}" >&2
    ((avail)) && printf "  Linux   : ${GREEN}%d${NC}✅ ${RED}%d${NC}❌ 共%d ${GREEN}[面板可见]${NC}\n" "$ol" "$fl" "${#lpkgs[@]}" >&2 \
              || printf "  Linux   : ${GREEN}%d${NC}✅ ${RED}%d${NC}❌ 共%d ${YELLOW}[系统直装]${NC}\n" "$ol" "$fl" "${#lpkgs[@]}" >&2
    echo -e "${CYAN}${BOLD}══════════════${NC}\n" >&2

    read -rp "是否重启容器 $name？(Y/n): " rc
    if [[ ! "${rc:-Y}" =~ ^[Nn]$ ]]; then
        docker restart "$name" >/dev/null 2>&1 && sleep 3 && log OK "$name 已重启"
        local ap; ap=$(get_container_port "$name")
        [[ -n "$ap" ]] && echo -e "${CYAN}面板: http://$(get_host_ip):$ap${NC}" >&2
    fi
}

# ============================================================
# Cron管理
# ============================================================
manage_cron() {
    local name; name=$(prompt_container_name "容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps --format "{{.Names}}" | grep -qw "$name" || { log ERROR "容器未运行！"; return 1; }
    local hp; hp=$(get_container_port "$name"); [[ -z "$hp" ]] && hp="$DEFAULT_PORT"
    local tok; tok=$(_get_ql_token "$name" "$hp") || { log ERROR "Token获取失败"; return 1; }
    echo -e "\n${YELLOW}定时任务管理：${NC}"
    echo "  1. 列出任务  2. 运行  3. 停止  4. 启用/禁用  5. 添加"
    read -rp "选择 [1-5]: " ch
    case "$ch" in
        1) curl -s -m 15 "http://localhost:${hp}/open/crons" -H "Authorization: Bearer ${tok}" | jq -r '.data.data[] | [.id,.name,.schedule,(if .status==0 then "运行中" elif .status==1 then "空闲" else "已禁用" end)] | @tsv' 2>/dev/null | column -t -s $'\t' ;;
        2) read -rp "任务ID(逗号分隔): " ids; local j; j=$(echo "$ids"|tr ',' '\n'|grep -E '^[0-9]+$'|jq -s '.'); curl -s -m 30 -X PUT "http://localhost:${hp}/open/crons/run" -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" -d "{\"ids\":${j}}" | jq -r '.message // "完成"' ;;
        3) read -rp "任务ID: " id; [[ "$id" =~ ^[0-9]+$ ]] || { log ERROR "数字！"; return 1; }; curl -s -m 10 -X PUT "http://localhost:${hp}/open/crons/stop" -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" -d "{\"ids\":[$id]}" | jq -r '.message // "完成"' ;;
        4) read -rp "任务ID: " id; [[ "$id" =~ ^[0-9]+$ ]] || { log ERROR "数字！"; return 1; }; read -rp "1=启用 2=禁用: " op; local sv; [[ "$op" == "1" ]] && sv=0 || sv=1; curl -s -m 10 -X PUT "http://localhost:${hp}/open/crons/status" -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" -d "{\"ids\":[$id],\"status\":$sv}" | jq -r '.message // "完成"' ;;
        5) local cn cs cc; read -rp "名称: " cn; read -rp "Cron: " cs; read -rp "命令: " cc; curl -s -m 10 -X POST "http://localhost:${hp}/open/crons" -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" -d "$(jq -n --arg n "$cn" --arg s "$cs" --arg c "$cc" '{"name":$n,"schedule":$s,"command":$c}')" | jq -r '.message // "完成"' ;;
        *) log WARN "无效" ;;
    esac
}

# ============================================================
# Linux依赖注册
# ============================================================
register_linux_deps_to_panel() {
    local name; name=$(prompt_container_name "容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps --format "{{.Names}}" | grep -qw "$name" || { log ERROR "容器未运行！"; return 1; }
    local hp; hp=$(get_container_port "$name"); [[ -z "$hp" ]] && hp="$DEFAULT_PORT"
    local tok; tok=$(_get_ql_token "$name" "$hp") || { log ERROR "Token失败！"; return 1; }
    local lpkgs=("alpine-sdk" "autoconf" "automake" "libtool" "gcc" "g++" "make" "python3-dev" "libffi-dev" "openssl-dev" "jpeg-dev" "zlib-dev" "libxml2-dev" "libxslt-dev" "cairo-dev" "pango-dev" "giflib-dev" "curl" "wget" "git" "ca-certificates" "tzdata")
    local total=${#lpkgs[@]} ok=0 fail=0 i
    for i in "${!lpkgs[@]}"; do
        _progress_bar $((i+1)) $total "${lpkgs[$i]}"
        _api_install_dep "$hp" "$tok" "${lpkgs[$i]}" "linux" && ok=$((ok+1)) || fail=$((fail+1))
    done
    _progress_done
    log OK "注册完成: ✅$ok ❌$fail / 共$total"
}

# ============================================================
# 专项修复
# ============================================================
repair_deps() {
    local name; name=$(prompt_container_name "容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps --format "{{.Names}}" | grep -qw "$name" || { log ERROR "容器未运行！"; return 1; }
    echo -e "\n${YELLOW}修复模式：${NC}"
    echo "  1. 全量  2. pnpm源  3. pip/Python3  4. canvas  5. Linux注册  6. 清除凭证"
    read -rp "选择 [1-6，默认1]: " m
    case "${m:-1}" in
        1) install_all_deps "$name" ;;
        2) docker exec "$name" sh -c "pnpm config set registry https://registry.npmmirror.com 2>/dev/null; npm config set registry https://registry.npmmirror.com 2>/dev/null; rm -f /ql/scripts/node_modules/.modules.yaml 2>/dev/null" && log OK "pnpm源修复完成" || log ERROR "失败" ;;
        3) docker exec "$name" sh -c "python3 -m pip install --upgrade pip setuptools wheel -q; pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple; pip3 install requests httpx pycryptodome rsa bs4 lxml PyExecJS Pillow pytz pyyaml -q" && log OK "Python3修复完成" || log ERROR "失败" ;;
        4) docker exec "$name" sh -c "cat /etc/os-release" 2>/dev/null | grep -qi "alpine" && docker exec "$name" apk add --no-cache build-base cairo-dev pango-dev giflib-dev >/dev/null 2>&1 || docker exec "$name" apt-get install -y build-essential libcairo2-dev libpango1.0-dev libgif-dev >/dev/null 2>&1; docker exec "$name" sh -c "cd /ql/scripts && npm install canvas --build-from-source 2>/dev/null" && log OK "canvas修复完成" || log ERROR "canvas失败" ;;
        5) register_linux_deps_to_panel ;;
        6) clear_cred_cache ;;
        *) log ERROR "无效" ;;
    esac
}

# ============================================================
# 部署容器（★ 使用 -d 启动，不用 -dit）
# ============================================================
install_ql() {
    local name port image image_variant target_version

    name=$(prompt_container_name "容器名称" "$DEFAULT_CONTAINER_NAME")
    port=$(prompt_port "WebUI 端口" "$DEFAULT_PORT")

    if docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
        local st; st=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "")
        if [[ "$st" == "created" ]]; then
            log WARN "检测到 Created 状态残留（上次启动失败）"
            read -rp "删除残留重新部署？(y/N): " d
            [[ "${d:-N}" =~ ^[Yy]$ ]] && docker rm -f "$name" >/dev/null 2>&1 && log OK "已清理" || return 0
        else
            log WARN "容器 $name 已存在！"; return 0
        fi
    fi

    echo -e "\n${YELLOW}镜像类型：${NC}"
    echo "  1. alpine（轻量）  2. debian（兼容好）"
    read -rp "选择 [1/2，默认1]: " ic
    case "${ic:-1}" in 2) image_variant="debian" ;; *) image_variant="" ;; esac

    target_version=$(select_version "$INSTALL_DEFAULT_VER" 5)
    [[ -n "$image_variant" ]] && image="${QL_IMAGE_BASE}:${image_variant}" || image="${QL_IMAGE_BASE}:${target_version}"

    log INFO "拉取镜像: $image ..."
    docker pull "$image" || { log ERROR "镜像拉取失败！"; return 1; }

    log INFO "启动容器 $name（端口 $port，-d 模式）..."

    if docker run -d \
        -v "$DATA_DIR/config:/ql/config" \
        -v "$DATA_DIR/log:/ql/log" \
        -v "$DATA_DIR/db:/ql/db" \
        -v "$DATA_DIR/repo:/ql/repo" \
        -v "$DATA_DIR/raw:/ql/raw" \
        -v "$DATA_DIR/scripts:/ql/scripts" \
        -v "$DATA_DIR/jbot:/ql/jbot" \
        -p "${port}:5700" \
        --name "$name" \
        --hostname "$name" \
        --restart unless-stopped \
        "$image"; then

        log OK "🎉 容器 $name 部署成功！"
        echo -e "\n${GREEN}${BOLD}── 下一步 ──${NC}" >&2
        echo -e "  访问: ${CYAN}http://$(get_host_ip):${port}${NC}" >&2
        echo -e "  初始化 → 应用设置 → 添加应用 → 选菜单[Q]装依赖" >&2
    else
        log ERROR "容器启动失败！"
        docker logs "$name" 2>&1 | tail -15 >&2
        echo -e "\n${YELLOW}建议：选菜单 [D] 诊断环境${NC}" >&2
        return 1
    fi
}

# ============================================================
# 容器列表
# ============================================================
list_containers() {
    echo -e "\n${CYAN}── 容器列表 ──${NC}"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"

    # 修复：created_count 安全取值
    local created_count=0
    created_count=$(docker ps -a --format "{{.Status}}" 2>/dev/null | grep -c "^Created" || true)
    # 确保是纯数字
    created_count=$(echo "$created_count" | tr -dc '0-9')
    created_count=${created_count:-0}

    if [[ "$created_count" -gt 0 ]] 2>/dev/null; then
        echo -e "\n${RED}${BOLD}⚠️  发现 $created_count 个 Created 残留容器（启动失败）${NC}"
        echo -e "${YELLOW}建议选菜单 [D] 清理残留后重新部署${NC}"
    fi
    echo ""
}

# ============================================================
# 卸载
# ============================================================
uninstall_ql() {
    local name; name=$(prompt_container_name "容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps -a --format "{{.Names}}" | grep -qw "$name" || { log WARN "找不到 $name"; return; }
    read -rp "确定停止并删除 $name？数据保留。(y/N): " ch
    [[ "${ch:-N}" =~ ^[Yy]$ ]] && { docker stop "$name" >/dev/null 2>&1 || true; docker rm -f "$name" >/dev/null 2>&1; log OK "$name 已删除"; } || log INFO "已取消"
}

# ============================================================
# 备份 / 恢复
# ============================================================
backup_ql() {
    local ts; ts=$(date +%Y%m%d%H%M%S)
    local bf="$DATA_DIR/backup/ql_backup_${ts}.tar.gz"
    log INFO "开始备份..."
    tar -czf "$bf" -C "$DATA_DIR" config log db repo raw scripts jbot 2>/dev/null && {
        sha256sum "$bf" > "${bf}.sha256" 2>/dev/null || true
        local sz; sz=$(du -sh "$bf" 2>/dev/null | awk '{print $1}')
        log OK "备份完成: $bf ($sz)"
    } || { log ERROR "备份失败！"; rm -f "$bf"; return 1; }
}

restore_ql() {
    local latest; latest=$(ls -t "$DATA_DIR/backup"/ql_backup_*.tar.gz 2>/dev/null | head -n1)
    [[ ! -f "$latest" ]] && { log WARN "找不到备份文件！"; return; }
    [[ -f "${latest}.sha256" ]] && { sha256sum -c "${latest}.sha256" &>/dev/null && log OK "校验通过" || { log ERROR "校验失败！"; read -rp "强制恢复？(y/N): " f; [[ ! "${f:-N}" =~ ^[Yy]$ ]] && return 1; }; }
    read -rp "恢复 $(basename "$latest")？(y/N): " ch
    [[ "${ch:-N}" =~ ^[Yy]$ ]] && { tar -xzf "$latest" -C "$DATA_DIR" 2>/dev/null && log OK "恢复完成！请重启容器。" || log ERROR "恢复失败！"; }
}

# ============================================================
# 无损升级（★ 使用 -d 启动）
# ============================================================
upgrade_ql() {
    local name; name=$(prompt_container_name "待升级容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps -a --format "{{.Names}}" | grep -qw "$name" || { log ERROR "容器不存在！"; return; }

    local tv; tv=$(select_version "$DEFAULT_IMAGE_VER" 5)
    local image="${QL_IMAGE_BASE}:${tv}"
    log INFO "拉取镜像: $image ..."
    docker pull "$image" || { log ERROR "拉取失败！"; return; }

    local ci; ci=$(docker inspect "$name")
    local nm rp
    nm=$(echo "$ci" | jq -r '.[0].HostConfig.NetworkMode')
    rp=$(echo "$ci" | jq -r '.[0].HostConfig.RestartPolicy.Name')

    # ★ 使用 -d 而非 -dit
    local -a ra=("-d" "--name" "$name" "--hostname" "$name")
    [[ -n "$rp" && "$rp" != "no" && "$rp" != "null" ]] && ra+=("--restart" "$rp")
    [[ -n "$nm" && "$nm" != "default" && "$nm" != "null" ]] && ra+=("--network" "$nm")

    if [[ "$nm" != "host" ]]; then
        local -a ports; mapfile -t ports < <(echo "$ci" | jq -r 'if .[0].HostConfig.PortBindings then .[0].HostConfig.PortBindings | to_entries[] | "-p", "\(.value[0].HostPort):\(.key|split("/")[0])" else empty end' 2>/dev/null)
        ((${#ports[@]}>0)) && ra+=("${ports[@]}")
    fi

    local -a mounts; mapfile -t mounts < <(echo "$ci" | jq -r '.[0].Mounts[]? | "-v", "\(.Source):\(.Destination)"' 2>/dev/null)
    ((${#mounts[@]}>0)) && ra+=("${mounts[@]}")

    local -a envs; mapfile -t envs < <(echo "$ci" | jq -r '.[0].Config.Env[]? | select(test("^PATH=|^HOSTNAME=|^HOME=|^PWD=|^TERM=") | not) | "-e", .' 2>/dev/null)
    ((${#envs[@]}>0)) && ra+=("${envs[@]}")

    log INFO "停止旧容器..."
    docker stop "$name" >/dev/null 2>&1; docker rm "$name" >/dev/null 2>&1

    log INFO "重建容器..."
    if docker run "${ra[@]}" "$image" >/dev/null 2>&1; then
        log OK "🎉 无损升级完成 → $tv"
        local np; np=$(get_container_port "$name")
        [[ -n "$np" ]] && echo -e "${CYAN}面板: http://$(get_host_ip):$np${NC}"
    else
        log ERROR "升级失败！docker logs $name 查看原因"
    fi
}

# ============================================================
# 存储报告
# ============================================================
show_storage_report() {
    echo -e "\n${CYAN}${BOLD}════ 存储占用 ════${NC}" >&2
    echo -e "${YELLOW}── Docker镜像 ──${NC}" >&2
    docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" 2>/dev/null | grep -E "qinglong|REPO" || echo "  无" >&2
    echo -e "${YELLOW}── 容器 ──${NC}" >&2
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null | grep -E "qinglong|NAMES" || echo "  无" >&2
    echo -e "${YELLOW}── 数据目录 ──${NC}" >&2
    [[ -d "$DATA_DIR" ]] && du -sh "$DATA_DIR"/*/ 2>/dev/null | sort -rh | awk '{printf "  %-10s %s\n",$1,$2}' >&2 || echo "  不存在" >&2
    echo -e "${YELLOW}── Docker全局 ──${NC}" >&2
    docker system df 2>/dev/null || echo "  无法获取" >&2
    echo "" >&2
}

# ============================================================
# 主菜单
# ============================================================
show_menu() {
    while true; do
        echo -e "\n${CYAN}${BOLD}════════════════════════════════════════${NC}"
        echo -e "${CYAN}${BOLD}   青龙面板 Docker 管家 v${SCRIPT_VERSION}           ${NC}"
        echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}"
        echo "   1. 部署 QingLong 容器"
        echo -e "   2. 无损升级面板 ${YELLOW}[保留全部配置]${NC}"
        echo "   3. 查看容器列表"
        echo -e "   ${GREEN}4. 启动容器${NC}"
        echo -e "   ${YELLOW}5. 停止容器${NC}"
        echo -e "   ${CYAN}6. 重启容器${NC}"
        echo "   7. 卸载容器"
        echo "   8. 查看容器日志"
        echo "   9. 一键数据备份"
        echo "   R. 一键数据恢复"
        echo -e "   ${GREEN}${BOLD}Q. ★ 全依赖一键补全${NC}"
        echo -e "   ${YELLOW}W. 依赖专项修复${NC}"
        echo -e "   ${BLUE}E. Linux依赖注册到面板${NC}"
        echo -e "   ${CYAN}T. 定时任务管理${NC}"
        echo -e "   ${RED}A. 清除API凭证缓存${NC}"
        echo -e "   ${BLUE}B. 存储占用分析${NC}"
        echo -e "   ${YELLOW}D. /dev/pts 环境诊断${NC}"
        echo "   0. 退出"
        echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}"

        read -rp "请输入选项: " op
        case "$op" in
            1) install_ql ;;
            2) upgrade_ql ;;
            3) list_containers ;;
            4) start_container ;;
            5) stop_container ;;
            6) restart_container ;;
            7) uninstall_ql ;;
            8) view_container_logs ;;
            9) backup_ql ;;
            [Rr]) restore_ql ;;
            [Qq]) install_all_deps ;;
            [Ww]) repair_deps ;;
            [Ee]) register_linux_deps_to_panel ;;
            [Tt]) manage_cron ;;
            [Aa]) clear_cred_cache ;;
            [Bb]) show_storage_report ;;
            [Dd]) diagnose_devpts ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) log WARN "无效输入" ;;
        esac
    done
}

# ============================================================
# 主入口
# ============================================================
main() {
    _ensure_log_dir 2>/dev/null || true
    log INFO "=== 青龙管理脚本 v${SCRIPT_VERSION} 启动 ==="
    check_dependencies
    make_directories
    show_menu
}

main "$@"
