#!/bin/bash

set -euo pipefail

# ============================================================
# 全局配置
# ============================================================
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

NO_TTY=0

# ============================================================
# 日志系统
# ============================================================
_ensure_log_dir() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir" 2>/dev/null || true
}

_rotate_log() {
    [[ ! -f "$LOG_FILE" ]] && return 0
    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -ge "$LOG_MAX_SIZE" ]]; then
        for i in $(seq $((LOG_BACKUP_COUNT - 1)) -1 1); do
            [[ -f "${LOG_FILE}.$i" ]] && \
                mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"
        done
        mv "$LOG_FILE" "${LOG_FILE}.1"
        touch "$LOG_FILE"
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - 日志已轮转" \
            >> "$LOG_FILE"
    fi
}

log() {
    local level="$1" msg="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
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
    local safe_msg
    safe_msg=$(echo "$msg" | \
        sed 's/token=[^ ]*/token=***REDACTED***/gi' | \
        sed 's/secret=[^ ]*/secret=***REDACTED***/gi' | \
        sed 's/Bearer [^ ]*/Bearer ***REDACTED***/gi')
    echo "[$level] $timestamp - $safe_msg" >> "$LOG_FILE"
    _rotate_log
}

# ============================================================
# 目录初始化
# ============================================================
make_directories() {
    local dirs=(
        "$DATA_DIR/config" "$DATA_DIR/log"  "$DATA_DIR/db"
        "$DATA_DIR/repo"   "$DATA_DIR/raw"  "$DATA_DIR/scripts"
        "$DATA_DIR/jbot"   "$DATA_DIR/backup"
    )
    local failed=()
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" 2>/dev/null || failed+=("$dir")
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        log ERROR "目录创建失败: ${failed[*]}"
        return 1
    fi
    log INFO "必要目录已就绪"
}

# ============================================================
# 依赖检测
# ============================================================
check_dependencies() {
    if ! command -v docker &>/dev/null; then
        log ERROR "未安装 Docker！"; exit 1
    fi
    if ! docker info &>/dev/null; then
        log ERROR "Docker 守护进程未运行！"; exit 1
    fi
    if ! command -v jq &>/dev/null; then
        log WARN "未安装 jq，正在尝试安装..."
        local ok=0
        command -v apt-get &>/dev/null && \
            apt-get update -qq && apt-get install -y jq && ok=1
        [[ $ok -eq 0 ]] && command -v yum &>/dev/null && \
            yum install -y epel-release && yum install -y jq && ok=1
        [[ $ok -eq 0 ]] && command -v apk &>/dev/null && \
            apk add -q jq && ok=1
        [[ $ok -eq 0 ]] && command -v opkg &>/dev/null && \
            opkg update && opkg install jq && ok=1
        [[ $ok -eq 1 ]] && log INFO "jq 安装完成" || {
            log ERROR "无法自动安装 jq！"; exit 1
        }
    fi
    command -v curl &>/dev/null || {
        log ERROR "未安装 curl！"; exit 1
    }
    log INFO "依赖检测通过 ✅"
}

# ============================================================
# 磁盘检测
# ============================================================
check_disk_space() {
    local min_gb=3 warn_gb=5
    local target_dir="${1:-$DATA_DIR}"
    mkdir -p "$target_dir" 2>/dev/null || target_dir="$HOME"
    local avail_mb
    avail_mb=$(df -m "$target_dir" 2>/dev/null | awk 'NR==2{print $4}')
    [[ -z "$avail_mb" ]] || ! [[ "$avail_mb" =~ ^[0-9]+$ ]] && {
        log WARN "无法检测磁盘空间"; return 0
    }
    local avail_gb=$(( avail_mb / 1024 ))
    echo -e "\n${CYAN}${BOLD}════ 磁盘空间检测 ════${NC}" >&2
    printf "  当前可用 : %d GB (%d MB)\n" "$avail_gb" "$avail_mb" >&2
    printf "  最低需求 : %d GB | 推荐需求 : %d GB\n" \
        "$min_gb" "$warn_gb" >&2
    if (( avail_mb < min_gb * 1024 )); then
        echo -e "  状态 : ${RED}${BOLD}❌ 空间严重不足！${NC}" >&2
        log ERROR "磁盘空间不足 ${min_gb}GB（当前 ${avail_gb}GB）"
        read -rp "是否强制继续？风险自负 (y/N): " force
        [[ ! "${force:-N}" =~ ^[Yy]$ ]] && return 1
    elif (( avail_mb < warn_gb * 1024 )); then
        echo -e "  状态 : ${YELLOW}${BOLD}⚠️  空间偏低${NC}" >&2
        read -rp "空间偏低，是否继续？(Y/n): " cont
        [[ "${cont:-Y}" =~ ^[Nn]$ ]] && return 1
    else
        echo -e "  状态 : ${GREEN}${BOLD}✅ 空间充足${NC}" >&2
    fi
    echo "" >&2
}

# ============================================================
# 端口工具
# ============================================================
port_is_free() {
    local port=$1
    command -v ss &>/dev/null && \
        ss -tuln 2>/dev/null | grep -q ":${port}\b" && return 1
    command -v netstat &>/dev/null && \
        netstat -tuln 2>/dev/null | grep -q ":${port}\b" && return 1
    command -v lsof &>/dev/null && \
        lsof -i:"$port" 2>/dev/null | grep -q LISTEN && return 1
    return 0
}

prompt_port() {
    local prompt="$1" def="$2" input
    while true; do
        read -rp "$prompt [$def]: " input
        input=${input:-$def}
        if ! [[ "$input" =~ ^[0-9]+$ ]] || \
           [[ "$input" -lt 1 ]] || [[ "$input" -gt 65535 ]]; then
            log WARN "端口号必须在 1-65535 之间"; continue
        fi
        if port_is_free "$input"; then
            echo "$input"; return 0
        else
            log WARN "端口 $input 已被占用，请更换"
        fi
    done
}

prompt_container_name() {
    local prompt="$1" def="$2" input
    read -rp "$prompt [$def]: " input
    echo "${input:-$def}"
}

get_container_port() {
    local cname="$1"
    docker inspect \
        --format='{{(index (index .NetworkSettings.Ports "5700/tcp") 0).HostPort}}' \
        "$cname" 2>/dev/null || echo ""
}

# ============================================================
# ★★★ 容器管理（新增：启动/停止/重启/强制清理）★★★
# ============================================================

# 获取所有青龙相关容器（含已停止）
_get_ql_containers() {
    local filter="${1:-all}"  # all / running / stopped / created
    case "$filter" in
        running)
            docker ps --format "{{.Names}}" \
                2>/dev/null | grep -E "^${DEFAULT_CONTAINER_NAME}" \
                || true
            ;;
        stopped)
            docker ps -a --format "{{.Names}}\t{{.Status}}" \
                2>/dev/null | \
                awk -F'\t' '$2~/Exited|Created/{print $1}' | \
                grep -E "^${DEFAULT_CONTAINER_NAME}" || true
            ;;
        created)
            docker ps -a --format "{{.Names}}\t{{.Status}}" \
                2>/dev/null | \
                awk -F'\t' '$2~/Created/{print $1}' | \
                grep -E "^${DEFAULT_CONTAINER_NAME}" || true
            ;;
        *)
            docker ps -a --format "{{.Names}}" \
                2>/dev/null | grep -E "^${DEFAULT_CONTAINER_NAME}" \
                || true
            ;;
    esac
}

# 选择容器（支持多个）
_pick_container() {
    local prompt="${1:-请选择容器}" filter="${2:-all}"
    local containers
    mapfile -t containers < <(_get_ql_containers "$filter")

    if [[ ${#containers[@]} -eq 0 ]]; then
        log WARN "未找到符合条件的青龙容器"
        return 1
    fi

    if [[ ${#containers[@]} -eq 1 ]]; then
        echo "${containers[0]}"
        return 0
    fi

    echo -e "\n${YELLOW}$prompt：${NC}" >&2
    for i in "${!containers[@]}"; do
        local status
        status=$(docker inspect \
            --format='{{.State.Status}}' \
            "${containers[$i]}" 2>/dev/null || echo "未知")
        printf "  %d. %-20s [%s]\n" \
            $((i+1)) "${containers[$i]}" "$status" >&2
    done
    echo "  $((${#containers[@]}+1)). 所有容器" >&2

    local choice
    while true; do
        read -rp "请选择 [1-$((${#containers[@]}+1))]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if (( choice >= 1 && \
                  choice <= ${#containers[@]} )); then
                echo "${containers[$((choice-1))]}"
                return 0
            elif (( choice == ${#containers[@]}+1 )); then
                # 返回所有容器（换行分隔）
                printf '%s\n' "${containers[@]}"
                return 0
            fi
        fi
        log WARN "无效选择，请重试"
    done
}

# ── 启动容器 ──
start_container() {
    log STEP "启动青龙容器..."
    local name
    name=$(_pick_container "选择要启动的容器" "stopped") || return 1

    # 处理多选（换行分隔）
    local -a names
    mapfile -t names <<< "$name"

    for cname in "${names[@]}"; do
        [[ -z "$cname" ]] && continue

        # 检查是否是 Created 状态（之前启动失败留下的残骸）
        local status
        status=$(docker inspect \
            --format='{{.State.Status}}' \
            "$cname" 2>/dev/null || echo "")

        if [[ "$status" == "created" ]]; then
            log WARN "容器 $cname 处于 Created 状态（上次启动失败）"
            log WARN "需要先删除再重新创建，建议选择菜单 [1] 重新部署"
            read -rp "是否强制删除此残留容器并重新部署？(y/N): " del
            if [[ "${del:-N}" =~ ^[Yy]$ ]]; then
                docker rm -f "$cname" >/dev/null 2>&1 && \
                    log OK "已删除残留容器 $cname"
                log INFO "请重新选择菜单 [1] 部署容器"
            fi
            continue
        fi

        log INFO "正在启动 $cname ..."
        if docker start "$cname" >/dev/null 2>&1; then
            log OK "✅ $cname 启动成功"
            local port
            port=$(get_container_port "$cname")
            local host_ip
            host_ip=$(hostname -I 2>/dev/null | \
                awk '{print $1}' || echo "localhost")
            [[ -n "$port" ]] && \
                echo -e "  ${CYAN}面板: http://${host_ip}:${port}${NC}" >&2
        else
            log ERROR "❌ $cname 启动失败"
            echo -e "${YELLOW}查看详细错误：${NC}" >&2
            docker logs "$cname" 2>&1 | tail -10 >&2
            echo "" >&2
            echo -e "${YELLOW}如遇 /dev/pts/ptmx 错误，请选菜单 [D] 修复${NC}" >&2
        fi
    done
}

# ── 停止容器 ──
stop_container() {
    log STEP "停止青龙容器..."
    local name
    name=$(_pick_container "选择要停止的容器" "running") || return 1

    local -a names
    mapfile -t names <<< "$name"

    for cname in "${names[@]}"; do
        [[ -z "$cname" ]] && continue
        log INFO "正在停止 $cname ..."
        if docker stop "$cname" >/dev/null 2>&1; then
            log OK "✅ $cname 已停止"
        else
            log ERROR "❌ $cname 停止失败"
        fi
    done
}

# ── 重启容器 ──
restart_container() {
    log STEP "重启青龙容器..."
    local name
    name=$(_pick_container "选择要重启的容器" "running") || {
        # 没有运行中的，看看有没有已停止的
        log WARN "未找到运行中的容器，检查已停止容器..."
        name=$(_pick_container "选择要启动的容器" "stopped") || return 1
        local -a names
        mapfile -t names <<< "$name"
        for cname in "${names[@]}"; do
            [[ -z "$cname" ]] && continue
            docker start "$cname" >/dev/null 2>&1 && \
                log OK "✅ $cname 已启动" || \
                log ERROR "❌ $cname 启动失败"
        done
        return 0
    }

    local -a names
    mapfile -t names <<< "$name"

    for cname in "${names[@]}"; do
        [[ -z "$cname" ]] && continue
        log INFO "正在重启 $cname ..."
        if docker restart "$cname" >/dev/null 2>&1; then
            log OK "✅ $cname 重启成功"
            sleep 2
            local port
            port=$(get_container_port "$cname")
            local host_ip
            host_ip=$(hostname -I 2>/dev/null | \
                awk '{print $1}' || echo "localhost")
            [[ -n "$port" ]] && \
                echo -e "  ${CYAN}面板: http://${host_ip}:${port}${NC}" >&2
        else
            log ERROR "❌ $cname 重启失败"
        fi
    done
}

# ── 强制清理 Created 残留容器 ──
force_remove_created() {
    log STEP "清理 Created 状态残留容器..."

    local created_containers
    mapfile -t created_containers < <(
        docker ps -a --format "{{.Names}}\t{{.Status}}" \
            2>/dev/null | \
            awk -F'\t' '$2~/^Created/{print $1}' || true
    )

    if [[ ${#created_containers[@]} -eq 0 ]]; then
        log INFO "没有 Created 状态的残留容器"
        return 0
    fi

    echo -e "\n${YELLOW}发现以下 Created 残留容器：${NC}" >&2
    for c in "${created_containers[@]}"; do
        local image
        image=$(docker inspect \
            --format='{{.Config.Image}}' "$c" 2>/dev/null || echo "未知")
        printf "  - %-20s [%s]\n" "$c" "$image" >&2
    done

    read -rp "是否全部删除？(y/N): " confirm
    [[ ! "${confirm:-N}" =~ ^[Yy]$ ]] && {
        log INFO "已取消"; return 0
    }

    for c in "${created_containers[@]}"; do
        if docker rm -f "$c" >/dev/null 2>&1; then
            log OK "✅ 已删除: $c"
        else
            log ERROR "❌ 删除失败: $c"
        fi
    done
    log INFO "清理完成，可重新选择 [1] 部署容器"
}

# ── 查看容器日志 ──
view_container_logs() {
    local name
    name=$(_pick_container "选择要查看日志的容器" "all") || return 1

    # 只取第一个容器（日志不支持多选）
    local cname
    cname=$(echo "$name" | head -1)

    echo -e "\n${CYAN}── $cname 最近50行日志 ──${NC}" >&2
    echo -e "${YELLOW}（Ctrl+C 退出实时日志）${NC}\n" >&2
    docker logs --tail 50 -f "$cname" 2>&1
}

# ============================================================
# ★★★ devpts 检测与修复（v2 - 修复 mode=600 问题）★★★
# ============================================================
check_and_fix_devpts() {
    echo -e "\n${CYAN}${BOLD}════ /dev/pts 环境检测 ════${NC}" >&2

    # ── 检查1：devpts是否挂载 ──
    local devpts_mounted=0
    mount | grep -q "devpts on /dev/pts" && devpts_mounted=1

    # ── 检查2：ptmx设备节点 ──
    local ptmx_ok=0
    [[ -c /dev/pts/ptmx ]] || [[ -c /dev/ptmx ]] && ptmx_ok=1

    # ── 检查3：mode是否正确（关键！）──
    # mode=600 → 非root无法访问 → runc失败
    local mode_ok=0
    local current_mode=""
    current_mode=$(mount | grep "devpts on /dev/pts" | \
        grep -oP 'mode=\K[0-9]+' || echo "")

    # ptmxmode检查
    local ptmxmode=""
    ptmxmode=$(mount | grep "devpts on /dev/pts" | \
        grep -oP 'ptmxmode=\K[0-9]+' || echo "")

    # mode=620或mode=666均可接受，600不可接受
    if [[ "$current_mode" == "620" || \
          "$current_mode" == "666" || \
          "$current_mode" == "622" ]]; then
        mode_ok=1
    elif [[ -z "$current_mode" ]]; then
        # 无mode参数时检查实际权限
        local pts_perm
        pts_perm=$(stat -c "%a" /dev/pts 2>/dev/null || echo "")
        [[ "$pts_perm" =~ ^[67] ]] && mode_ok=1
    fi

    echo -e "  devpts挂载  : $(
        [[ $devpts_mounted -eq 1 ]] && \
        echo "${GREEN}✅ 已挂载${NC}" || \
        echo "${RED}❌ 未挂载${NC}")" >&2
    echo -e "  ptmx设备    : $(
        [[ $ptmx_ok -eq 1 ]] && \
        echo "${GREEN}✅ 存在${NC}" || \
        echo "${RED}❌ 不存在${NC}")" >&2
    echo -e "  挂载mode    : ${CYAN}${current_mode:-未知}${NC}$(
        [[ $mode_ok -eq 1 ]] && \
        echo " ${GREEN}✅ 正常${NC}" || \
        echo " ${RED}❌ 权限不足（需要620/666）${NC}")" >&2
    echo -e "  ptmxmode    : ${CYAN}${ptmxmode:-未设置}${NC}" >&2

    # ── 全部正常 ──
    if [[ $devpts_mounted -eq 1 && \
          $ptmx_ok -eq 1 && \
          $mode_ok -eq 1 ]]; then
        echo -e "  状态        : ${GREEN}${BOLD}✅ 完全正常${NC}" >&2
        echo "" >&2
        NO_TTY=0
        return 0
    fi

    # ── 需要修复 ──
    echo -e "  状态        : ${YELLOW}${BOLD}⚠️  需要修复${NC}" >&2

    # 特殊情况：mode=600 已挂载但权限错误
    if [[ $devpts_mounted -eq 1 && $mode_ok -eq 0 ]]; then
        log WARN "devpts 已挂载但 mode=$current_mode（权限不足）"
        log WARN "需要重新以正确参数挂载..."

        # 卸载后重新挂载
        if umount /dev/pts 2>/dev/null; then
            log INFO "已卸载旧 devpts"
        else
            log WARN "无法卸载（可能有进程占用），尝试 lazy umount..."
            umount -l /dev/pts 2>/dev/null || true
            sleep 1
        fi
    fi

    # ── 创建目录 ──
    [[ ! -d /dev/pts ]] && mkdir -p /dev/pts 2>/dev/null || true

    # ── 加载内核模块 ──
    for mod in pty devpts unix98_pty; do
        modprobe "$mod" 2>/dev/null || true
    done

    # OpenWrt专项
    if [[ -f /etc/openwrt_release ]] && ! modprobe pty 2>/dev/null; then
        log INFO "OpenWrt: 安装 kmod-pty..."
        opkg update &>/dev/null && \
            opkg install kmod-pty &>/dev/null && \
            modprobe pty 2>/dev/null || true
    fi

    # ── 重新挂载（按优先级尝试不同参数）──
    local mount_ok=0
    local mount_opts=(
        "gid=5,mode=620,ptmxmode=666"
        "gid=5,mode=620,ptmxmode=000"
        "gid=5,mode=620"
        "mode=620"
        "mode=666"
        ""
    )

    for opt in "${mount_opts[@]}"; do
        local cmd="mount -t devpts devpts /dev/pts"
        [[ -n "$opt" ]] && cmd="$cmd -o $opt"
        if eval "$cmd" 2>/dev/null; then
            mount_ok=1
            log OK "devpts 挂载成功（参数: ${opt:-默认}）"
            break
        fi
    done

    # ── 验证挂载结果 ──
    if [[ $mount_ok -eq 1 ]]; then
        # 验证ptmx可访问
        if [[ -c /dev/pts/ptmx ]] || [[ -c /dev/ptmx ]]; then
            log OK "ptmx 设备节点验证通过"

            # 显示新的挂载信息
            echo -e "\n${GREEN}修复后挂载状态：${NC}" >&2
            mount | grep "devpts on /dev/pts" | \
                sed 's/^/  /' >&2

            # 持久化
            _persist_devpts_mount
            NO_TTY=0
            echo "" >&2
            return 0
        fi
    fi

    # ── 挂载失败：尝试权限修正 ──
    log WARN "挂载失败，尝试直接修正权限..."
    if chmod 755 /dev/pts 2>/dev/null && \
       chmod 666 /dev/pts/ptmx 2>/dev/null; then
        log OK "权限修正完成"
        NO_TTY=0
        return 0
    fi

    # ── 最终降级：去掉-t参数 ──
    log WARN "所有修复方案失败，切换到无伪终端模式（-di）"
    echo -e "\n${YELLOW}${BOLD}── 降级方案 ──${NC}" >&2
    echo -e "  容器将以 ${CYAN}-di${NC} 启动（无伪终端）" >&2
    echo -e "  青龙 Web 面板功能不受影响 ✅" >&2
    echo "" >&2

    read -rp "是否以降级模式继续？(Y/n): " fallback
    if [[ ! "${fallback:-Y}" =~ ^[Nn]$ ]]; then
        NO_TTY=1
        log INFO "已启用降级模式（-di）"
        return 0
    fi

    log ERROR "用户取消部署"
    return 1
}

# ── 持久化 devpts 挂载 ──
_persist_devpts_mount() {
    local mount_cmd="mount -t devpts devpts /dev/pts \
-o gid=5,mode=620,ptmxmode=666 2>/dev/null || true"

    if [[ -f /etc/openwrt_release ]]; then
        grep -q "devpts" /etc/rc.local 2>/dev/null || {
            local rc="/etc/rc.local"
            if [[ -f "$rc" ]]; then
                sed -i "/^exit 0/i $mount_cmd" "$rc" 2>/dev/null || \
                    echo "$mount_cmd" >> "$rc"
            else
                printf '#!/bin/sh\n%s\nexit 0\n' \
                    "$mount_cmd" > "$rc"
                chmod +x "$rc"
            fi
            log INFO "OpenWrt: 已写入 /etc/rc.local"
        }
    elif command -v systemctl &>/dev/null && \
         [[ -d /etc/systemd/system ]]; then
        local unit="/etc/systemd/system/devpts-fix.service"
        [[ -f "$unit" ]] && return 0
        cat > "$unit" << UNIT
[Unit]
Description=Fix devpts mount for Docker
Before=docker.service
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/sh -c "umount /dev/pts 2>/dev/null; \
  mount -t devpts devpts /dev/pts \
  -o gid=5,mode=620,ptmxmode=666 2>/dev/null || \
  mount -t devpts devpts /dev/pts -o gid=5,mode=620"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload &>/dev/null
        systemctl enable devpts-fix.service &>/dev/null
        log INFO "systemd: 已创建 devpts-fix.service"
    elif [[ -f /etc/fstab ]]; then
        grep -q "devpts" /etc/fstab || {
            echo "devpts /dev/pts devpts gid=5,mode=620,ptmxmode=666 0 0" \
                >> /etc/fstab
            log INFO "已写入 /etc/fstab"
        }
    fi
}

# ── devpts 完整诊断 ──
diagnose_devpts() {
    echo -e "\n${CYAN}${BOLD}════════════════════════════════════════${NC}" >&2
    echo -e "${CYAN}${BOLD}   🔍 /dev/pts 环境完整诊断报告         ${NC}" >&2
    echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}" >&2

    echo -e "\n${YELLOW}── 系统信息 ──${NC}" >&2
    uname -a >&2
    grep -E "^(ID|NAME|VERSION)=" /etc/os-release 2>/dev/null | \
        sed 's/^/  /' >&2
    echo -e "  虚拟化: $(
        systemd-detect-virt 2>/dev/null || echo '未知')" >&2

    echo -e "\n${YELLOW}── 挂载状态 ──${NC}" >&2
    mount | grep -E "devpts|pts" | sed 's/^/  /' >&2 || \
        echo -e "  ${RED}无devpts挂载${NC}" >&2

    echo -e "\n${YELLOW}── 挂载参数分析 ──${NC}" >&2
    local current_mode ptmxmode
    current_mode=$(mount | grep "devpts on /dev/pts" | \
        grep -oP 'mode=\K[0-9]+' || echo "未设置")
    ptmxmode=$(mount | grep "devpts on /dev/pts" | \
        grep -oP 'ptmxmode=\K[0-9]+' || echo "未设置")
    echo -e "  mode     : $current_mode $(
        [[ "$current_mode" =~ ^(620|666|622)$ ]] && \
        echo "${GREEN}✅ 正常${NC}" || \
        echo "${RED}❌ 需要620或666${NC}")" >&2
    echo -e "  ptmxmode : $ptmxmode" >&2
    echo -e "  ${YELLOW}Docker runc 需要 mode=620/666 才能访问 ptmx${NC}" >&2

    echo -e "\n${YELLOW}── /dev/pts 目录 ──${NC}" >&2
    ls -la /dev/pts/ 2>/dev/null | sed 's/^/  /' >&2 || \
        echo -e "  ${RED}目录不存在${NC}" >&2

    echo -e "\n${YELLOW}── /dev/ptmx 状态 ──${NC}" >&2
    ls -la /dev/ptmx 2>/dev/null | sed 's/^/  /' >&2 || \
        echo -e "  ${RED}ptmx不存在${NC}" >&2

    echo -e "\n${YELLOW}── Docker 信息 ──${NC}" >&2
    docker info 2>/dev/null | \
        grep -E "Server Version|Storage Driver|Cgroup" | \
        sed 's/^/  /' >&2

    echo -e "\n${YELLOW}── Created状态容器（启动失败残留）──${NC}" >&2
    docker ps -a --format "{{.Names}}\t{{.Status}}\t{{.Image}}" \
        2>/dev/null | \
        awk -F'\t' '$2~/^Created/{
            printf "  %-20s %-12s %s\n", $1, $2, $3
        }' >&2 || echo "  无" >&2

    echo -e "\n${YELLOW}── 问题诊断 ──${NC}" >&2
    if mount | grep "devpts on /dev/pts" | grep -q "mode=600"; then
        echo -e "  ${RED}${BOLD}⚠️  检测到 mode=600！这是导致容器启动失败的原因！${NC}" >&2
        echo -e "  ${YELLOW}mode=600 导致 Docker runc 无法访问 /dev/pts/ptmx${NC}" >&2
        echo -e "  ${GREEN}修复方法：重新挂载 devpts（选 Y 自动修复）${NC}" >&2
    fi

    echo -e "\n${CYAN}${BOLD}════════════════════════════════════════${NC}\n" >&2

    echo -e "${YELLOW}选择操作：${NC}" >&2
    echo "  1. 自动修复 devpts（推荐）" >&2
    echo "  2. 清理 Created 残留容器" >&2
    echo "  3. 两项都做（修复后清理残留）" >&2
    echo "  4. 返回主菜单" >&2
    read -rp "请选择 [1-4，默认1]: " diag_choice

    case "${diag_choice:-1}" in
        1) check_and_fix_devpts ;;
        2) force_remove_created ;;
        3)
            check_and_fix_devpts
            force_remove_created
            log INFO "完成后请选菜单 [1] 重新部署容器"
            ;;
        4) return 0 ;;
        *) log WARN "无效选择" ;;
    esac
}

# ============================================================
# 凭证管理（加密存储）
# ============================================================
_get_machine_key() {
    local mid
    mid=$(cat /etc/machine-id 2>/dev/null || \
          cat /var/lib/dbus/machine-id 2>/dev/null || \
          hostname 2>/dev/null || echo "default_key")
    printf '%s%s' "$mid" "$mid" | \
        head -c 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

_save_creds() {
    local cname="$1" client_id="$2" client_secret="$3"
    mkdir -p "$CRED_DIR" && chmod 700 "$CRED_DIR"
    local key; key=$(_get_machine_key)
    local plaintext="${cname}|${client_id}|${client_secret}"
    if command -v openssl &>/dev/null; then
        local existing=""
        [[ -f "$CRED_CACHE_FILE" ]] && \
            existing=$(openssl enc -d -aes-256-cbc \
                -pbkdf2 -iter 100000 -pass "pass:${key}" \
                -in "$CRED_CACHE_FILE" 2>/dev/null || echo "")
        local new_content
        new_content=$(echo "$existing" | \
            grep -v "^${cname}|" 2>/dev/null || true)
        new_content="${new_content}${new_content:+$'\n'}${plaintext}"
        echo "$new_content" | openssl enc -aes-256-cbc \
            -pbkdf2 -iter 100000 -pass "pass:${key}" \
            -out "$CRED_CACHE_FILE" 2>/dev/null
        chmod 600 "$CRED_CACHE_FILE"
        log INFO "凭证已加密存储（AES-256-CBC）"
    else
        local pf="${CRED_CACHE_FILE%.enc}"
        grep -v "^${cname}|" "$pf" 2>/dev/null > "${pf}.tmp" || true
        echo "$plaintext" >> "${pf}.tmp"
        mv "${pf}.tmp" "$pf" && chmod 600 "$pf"
    fi
}

_load_cached_creds() {
    local cname="$1"
    local key; key=$(_get_machine_key)
    local content=""
    if [[ -f "$CRED_CACHE_FILE" ]] && \
       command -v openssl &>/dev/null; then
        content=$(openssl enc -d -aes-256-cbc \
            -pbkdf2 -iter 100000 -pass "pass:${key}" \
            -in "$CRED_CACHE_FILE" 2>/dev/null || echo "")
    elif [[ -f "${CRED_CACHE_FILE%.enc}" ]]; then
        content=$(cat "${CRED_CACHE_FILE%.enc}" 2>/dev/null || echo "")
    fi
    [[ -z "$content" ]] && echo "" && return 1
    local line
    line=$(echo "$content" | grep "^${cname}|" | tail -1)
    [[ -z "$line" ]] && echo "" && return 1
    echo "${line#*|}"
}

_parse_auth_json() {
    local cname="$1"
    local auth_json=""
    local paths=(
        "/ql/data/config/auth.json"
        "/ql/config/auth.json"
        "/data/config/auth.json"
        "/ql/db/auth.json"
    )
    for p in "${paths[@]}"; do
        auth_json=$(docker exec "$cname" \
            cat "$p" 2>/dev/null || echo "")
        [[ -n "$auth_json" ]] && break
    done
    [[ -z "$auth_json" ]] && echo "" && return 1

    local cid csec
    cid=$(echo "$auth_json" | \
        jq -r '.applications[0].client_id //
               .tokens[0].client_id //
               .client_id // empty' 2>/dev/null)
    csec=$(echo "$auth_json" | \
        jq -r '.applications[0].client_secret //
               .tokens[0].client_secret //
               .client_secret // empty' 2>/dev/null)
    [[ -n "$cid" && -n "$csec" ]] && \
        echo "${cid}|${csec}" && return 0
    echo "" && return 1
}

_show_openapi_guide() {
    local hp="${1:-5700}"
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    echo -e "\n${CYAN}${BOLD}════ Open API 创建指引 ════${NC}" >&2
    echo -e "  1. 访问: ${CYAN}http://${ip}:${hp}${NC}" >&2
    echo -e "  2. 系统设置 → 应用设置 → 添加应用" >&2
    echo -e "  3. 全权限勾选 → 提交" >&2
    echo -e "  4. 复制 Client ID 和 Client Secret" >&2
    echo "" >&2
}

_get_api_credentials() {
    local cname="$1" hp="${2:-5700}"

    # 策略1：缓存
    local creds
    creds=$(_load_cached_creds "$cname" 2>/dev/null || echo "")
    [[ -n "$creds" ]] && \
        log INFO "✅ 使用加密缓存凭证" && \
        echo "$creds" && return 0

    # 策略2：auth.json
    log INFO "尝试从 auth.json 读取..."
    creds=$(_parse_auth_json "$cname" 2>/dev/null || echo "")
    if [[ -n "$creds" ]]; then
        log OK "auth.json 读取成功"
        _save_creds "$cname" "${creds%%|*}" "${creds##*|}"
        echo "$creds" && return 0
    fi

    # 策略3：手动输入
    log WARN "无法自动获取，请手动输入"
    _show_openapi_guide "$hp"

    echo -e "${YELLOW}选择：${NC}" >&2
    echo "  1. 手动输入凭证" >&2
    echo "  2. 跳过 Open API" >&2
    read -rp "请选择 [1/2，默认2]: " ch

    case "${ch:-2}" in
        1)
            local cid csec
            while true; do
                read -rsp "  Client ID: " cid; echo "" >&2
                [[ -n "$cid" ]] && break
                echo -e "  ${RED}不能为空${NC}" >&2
            done
            while true; do
                read -rsp "  Client Secret: " csec; echo "" >&2
                [[ -n "$csec" ]] && break
                echo -e "  ${RED}不能为空${NC}" >&2
            done
            log INFO "验证凭证..."
            local tok
            tok=$(curl -s -m 10 -X POST \
                "http://localhost:${hp}/open/auth/token" \
                -H "Content-Type: application/json" \
                -d "$(jq -n \
                    --arg id "$cid" --arg s "$csec" \
                    '{"client_id":$id,"client_secret":$s}')" \
                2>/dev/null | \
                jq -r '.data.token // empty' 2>/dev/null)
            if [[ -n "$tok" ]]; then
                log OK "凭证验证成功"
                _save_creds "$cname" "$cid" "$csec"
                echo "${cid}|${csec}" && return 0
            else
                log ERROR "凭证验证失败！"
                echo "" && return 1
            fi
            ;;
        *)
            log WARN "跳过 Open API"
            echo "" && return 1
            ;;
    esac
}

_get_ql_token() {
    local cname="$1" hp="$2"
    local creds
    creds=$(_get_api_credentials "$cname" "$hp" 2>/dev/null || echo "")
    [[ -z "$creds" ]] && echo "" && return 1
    local cid="${creds%%|*}" csec="${creds##*|}"
    local tok
    tok=$(curl -s -m 10 -X POST \
        "http://localhost:${hp}/open/auth/token" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg id "$cid" --arg s "$csec" \
            '{"client_id":$id,"client_secret":$s}')" \
        2>/dev/null | \
        jq -r '.data.token // empty' 2>/dev/null)
    if [[ -n "$tok" ]]; then
        echo "$tok" && return 0
    else
        log WARN "Token获取失败，清除缓存..."
        clear_cred_cache_for "$cname"
        echo "" && return 1
    fi
}

clear_cred_cache_for() {
    local cname="$1"
    local key; key=$(_get_machine_key)
    if [[ -f "$CRED_CACHE_FILE" ]] && \
       command -v openssl &>/dev/null; then
        local content
        content=$(openssl enc -d -aes-256-cbc \
            -pbkdf2 -iter 100000 -pass "pass:${key}" \
            -in "$CRED_CACHE_FILE" 2>/dev/null || echo "")
        local new
        new=$(echo "$content" | \
            grep -v "^${cname}|" 2>/dev/null || true)
        if [[ -n "$new" ]]; then
            echo "$new" | openssl enc -aes-256-cbc \
                -pbkdf2 -iter 100000 -pass "pass:${key}" \
                -out "$CRED_CACHE_FILE" 2>/dev/null
        else
            rm -f "$CRED_CACHE_FILE"
        fi
    fi
}

clear_cred_cache() {
    rm -f "$CRED_CACHE_FILE" "${CRED_CACHE_FILE%.enc}"
    log OK "凭证缓存已清除"
}

# ============================================================
# API调用
# ============================================================
_api_install_dep() {
    local hp="$1" tok="$2" pkg="$3" type="${4:-linux}"
    local body
    body=$(jq -n --arg n "$pkg" --arg t "$type" \
        '{"names":[$n],"type":$t}')
    local resp
    resp=$(curl -s -m 60 -X POST \
        "http://localhost:${hp}/open/dependencies" \
        -H "Authorization: Bearer ${tok}" \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null)
    local code
    code=$(echo "$resp" | jq -r '.code // 0' 2>/dev/null)
    [[ "$code" == "200" ]]
}

_sys_install_pkg() {
    local cname="$1" pkg="$2" os="${3:-alpine}"
    if [[ "$os" == "alpine" ]]; then
        docker exec "$cname" \
            apk add --no-cache "$pkg" >/dev/null 2>&1
    else
        docker exec "$cname" \
            apt-get install -y -q "$pkg" >/dev/null 2>&1
    fi
}

# ============================================================
# 进度条
# ============================================================
_progress_bar() {
    local cur="$1" total="$2" label="${3:-}" w=30
    local filled=$(( cur * w / total )) empty=$(( w - filled ))
    local bar="" i
    for ((i=0;i<filled;i++)); do bar+="█"; done
    for ((i=0;i<empty;i++));  do bar+="░"; done
    printf "\r  ${CYAN}[%s]${NC} %3d/%d  %-25s" \
        "$bar" "$cur" "$total" "$label" >&2
}
_progress_done() { echo "" >&2; }

# ============================================================
# 并行安装
# ============================================================
_install_pkgs_parallel() {
    local cname="$1" itype="$2" hp="${3:-}" tok="${4:-}"
    shift 4
    local pkgs=("$@") total=${#pkgs[@]}
    local tmpdir; tmpdir=$(mktemp -d)
    local pids=() jcount=0

    for i in "${!pkgs[@]}"; do
        local pkg="${pkgs[$i]}" rf="$tmpdir/${i}.result"
        (
            local ok=0
            case "$itype" in
                npm)
                    for a in 1 2; do
                        docker exec "$cname" sh -c \
                            "cd /ql/scripts && \
                             pnpm add '$pkg' 2>/dev/null || \
                             npm install '$pkg' 2>/dev/null" \
                            >/dev/null 2>&1 && ok=1 && break
                        sleep 1
                    done ;;
                pip)
                    docker exec "$cname" \
                        pip3 install "$pkg" -q \
                        >/dev/null 2>&1 && ok=1 ;;
                linux-alpine)
                    [[ -n "$tok" && -n "$hp" ]] && \
                        _api_install_dep "$hp" "$tok" \
                            "$pkg" "linux" && ok=1
                    [[ $ok -eq 0 ]] && \
                        _sys_install_pkg "$cname" "$pkg" \
                            "alpine" && ok=1 ;;
                linux-debian)
                    [[ -n "$tok" && -n "$hp" ]] && \
                        _api_install_dep "$hp" "$tok" \
                            "$pkg" "linux" && ok=1
                    [[ $ok -eq 0 ]] && \
                        _sys_install_pkg "$cname" "$pkg" \
                            "debian" && ok=1 ;;
            esac
            echo "${pkg}|${ok}" > "$rf"
        ) &
        pids+=($!)
        jcount=$((jcount+1))
        local dc
        dc=$(ls "$tmpdir"/*.result 2>/dev/null | wc -l)
        _progress_bar "$dc" "$total" "$pkg"
        if [[ $jcount -ge $MAX_PARALLEL_JOBS ]]; then
            wait "${pids[0]}" 2>/dev/null || true
            pids=("${pids[@]:1}")
            jcount=$((jcount-1))
        fi
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    _progress_done

    local ok=0 fail=0 failed=()
    for i in "${!pkgs[@]}"; do
        local r; r=$(cat "$tmpdir/${i}.result" 2>/dev/null || \
            echo "${pkgs[$i]}|0")
        [[ "${r##*|}" == "1" ]] && ok=$((ok+1)) || {
            fail=$((fail+1)); failed+=("${r%%|*}")
        }
    done
    rm -rf "$tmpdir"
    echo "$ok|$fail|${failed[*]}"
}

# ============================================================
# 版本选择
# ============================================================
select_version() {
    local dver="${1:-latest}" sc="${2:-5}"
    echo -e "\n${CYAN}🔄 获取版本列表...${NC}" >&2
    local raw="" att
    for att in 1 2 3; do
        raw=$(curl -sf -m 15 \
            "https://hub.docker.com/v2/namespaces/whyour/repositories/qinglong/tags?page_size=50" \
            2>/dev/null | \
            jq -r '.results[].name' 2>/dev/null | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | \
            sort -rV | head -n "$sc" || echo "")
        [[ -n "$raw" ]] && break
        log WARN "第 $att 次获取失败，重试..." >&2; sleep 2
    done

    local versions=("$dver")
    if [[ -n "$raw" ]]; then
        while IFS= read -r v; do
            [[ "$v" != "$dver" ]] && versions+=("$v")
        done <<< "$raw"
        echo -e "${YELLOW}请选择版本：${NC}" >&2
        for i in "${!versions[@]}"; do
            [[ "${versions[$i]}" == "$dver" ]] && \
                echo -e "  $((i+1)). ${versions[$i]}  ${GREEN}← 默认${NC}" >&2 || \
                echo "  $((i+1)). ${versions[$i]}" >&2
        done
        local ch nv=${#versions[@]}
        while true; do
            read -rp "请输入编号 [默认 1]: " ch
            ch=${ch:-1}
            [[ "$ch" =~ ^[0-9]+$ ]] && \
            (( ch >= 1 && ch <= nv )) && \
                echo "${versions[$((ch-1))]}" && return 0
            log ERROR "无效选择，请输入 1~$nv" >&2
        done
    else
        log WARN "无法获取版本列表" >&2
        local mv
        read -rp "手动输入版本号 [默认: $dver]: " mv
        echo "${mv:-$dver}"
    fi
}

# ============================================================
# 全依赖一键补全
# ============================================================
install_all_deps() {
    check_disk_space || return 1
    local name="${1:-}"
    [[ -z "$name" ]] && \
        name=$(prompt_container_name \
            "请输入青龙容器名" "$DEFAULT_CONTAINER_NAME")

    if ! docker ps --format "{{.Names}}" | grep -qw "$name"; then
        log ERROR "容器 <$name> 不存在或未运行！"; return 1
    fi

    local hp; hp=$(get_container_port "$name")
    [[ -z "$hp" ]] && hp="$DEFAULT_PORT"

    echo -e "\n${CYAN}${BOLD}══ 青龙全依赖补全 v4.2 ══${NC}" >&2
    echo -e "  容器: $name | 端口: $hp" >&2

    # STEP 1：OS检测
    log STEP "[1/8] 检测容器系统..."
    local os="alpine"
    docker exec "$name" sh -c \
        "grep -qi 'debian\|ubuntu' /etc/os-release 2>/dev/null" && \
        os="debian" && log INFO "Debian 系" || \
        log INFO "Alpine 系"

    # STEP 2：API凭证
    log STEP "[2/8] 获取 Open API 凭证..."
    local ws=0
    while (( ws < 30 )); do
        local hc
        hc=$(curl -s -o /dev/null -w "%{http_code}" \
            -m 3 "http://localhost:${hp}" 2>/dev/null || echo "000")
        [[ "$hc" =~ ^[2-4] ]] && break
        log INFO "等待面板就绪... (${ws}s)"; sleep 5; ws=$((ws+5))
    done

    local tok="" avail=0
    tok=$(_get_ql_token "$name" "$hp" 2>/dev/null || echo "")
    [[ -n "$tok" ]] && avail=1 && log OK "Token 获取成功" || \
        log WARN "Open API 不可用，Linux依赖将系统直装"

    # STEP 3：编译环境
    log STEP "[3/8] 安装系统编译环境..."
    if [[ "$os" == "alpine" ]]; then
        docker exec "$name" apk add --no-cache \
            alpine-sdk autoconf automake libtool \
            build-base g++ gcc make \
            cairo-dev pango-dev giflib-dev \
            python3-dev py3-pip \
            jpeg-dev zlib-dev freetype-dev \
            libxml2-dev libxslt-dev \
            musl-dev libffi-dev openssl-dev \
            tzdata curl wget git ca-certificates \
            >/dev/null 2>&1 && log OK "Alpine编译环境就绪" || \
            log WARN "部分包安装失败"
    else
        docker exec "$name" apt-get install -y -q \
            build-essential gcc g++ make \
            libcairo2-dev libpango1.0-dev libgif-dev \
            python3-dev python3-pip \
            libjpeg-dev zlib1g-dev libffi-dev libssl-dev \
            libxml2-dev libxslt1-dev \
            tzdata curl wget git ca-certificates \
            >/dev/null 2>&1 && log OK "Debian编译环境就绪" || \
            log WARN "部分包安装失败"
    fi

    # STEP 4：pnpm源
    log STEP "[4/8] 修复 pnpm/npm 源..."
    docker exec "$name" sh -c "
        pnpm config set registry \
            https://registry.npmmirror.com 2>/dev/null
        npm config set registry \
            https://registry.npmmirror.com 2>/dev/null
        rm -f /ql/scripts/node_modules/.modules.yaml 2>/dev/null
    " >/dev/null 2>&1 && log OK "源已设为淘宝镜像" || \
        log WARN "源修复部分失败"

    # STEP 5：pip
    log STEP "[5/8] 修复 pip..."
    docker exec "$name" sh -c "
        python3 -m pip install \
            --upgrade pip setuptools wheel -q 2>/dev/null
        pip3 config set global.index-url \
            https://pypi.tuna.tsinghua.edu.cn/simple 2>/dev/null
        pip3 config set global.trusted-host \
            pypi.tuna.tsinghua.edu.cn 2>/dev/null
    " >/dev/null 2>&1 && log OK "pip已修复（清华源）" || \
        log WARN "pip修复部分失败"

    # STEP 6：NodeJS
    log STEP "[6/8] 安装 NodeJS 依赖（并行）..."
    local npkgs=(
        "axios" "axios@0.27.2" "request" "got" "node-fetch"
        "https-proxy-agent" "tunnel"
        "crypto-js" "ts-md5" "node-rsa" "js-base64"
        "date-fns" "moment"
        "json5" "qs" "form-data" "dotenv"
        "jsdom" "cheerio" "xmldom" "tough-cookie"
        "typescript" "tslib" "ts-node" "@types/node"
        "ws@7.4.3" "global-agent"
        "png-js" "sharp"
        "node-telegram-bot-api" "juejin-helper"
    )
    local nr; nr=$(_install_pkgs_parallel \
        "$name" "npm" "" "" "${npkgs[@]}")
    local on fn fln
    on=$(echo "$nr"|cut -d'|' -f1)
    fn=$(echo "$nr"|cut -d'|' -f2)
    fln=$(echo "$nr"|cut -d'|' -f3-)
    log OK "NodeJS: ✅$on ❌$fn / 共${#npkgs[@]}"
    [[ -n "$fln" ]] && log WARN "失败: $fln"

    # STEP 7：Python3
    log STEP "[7/8] 安装 Python3 依赖（并行）..."
    local ppkgs=(
        "requests" "httpx" "aiohttp"
        "pycryptodome" "rsa" "bs4" "lxml"
        "PyExecJS" "Pillow" "ping3" "jieba"
        "redis" "openai" "pytz" "pyyaml"
        "urllib3" "certifi"
    )
    local pr; pr=$(_install_pkgs_parallel \
        "$name" "pip" "" "" "${ppkgs[@]}")
    local op fp flp
    op=$(echo "$pr"|cut -d'|' -f1)
    fp=$(echo "$pr"|cut -d'|' -f2)
    flp=$(echo "$pr"|cut -d'|' -f3-)
    log OK "Python3: ✅$op ❌$fp / 共${#ppkgs[@]}"
    [[ -n "$flp" ]] && log WARN "失败: $flp"

    # STEP 8：Linux
    log STEP "[8/8] 安装 Linux 依赖..."
    local lpkgs=(
        "alpine-sdk" "autoconf" "automake" "libtool"
        "gcc" "g++" "make" "python3-dev"
        "libffi-dev" "openssl-dev" "jpeg-dev" "zlib-dev"
        "libxml2-dev" "libxslt-dev"
        "cairo-dev" "pango-dev" "giflib-dev"
        "curl" "wget" "git" "ca-certificates" "tzdata"
    )
    local lit="linux-alpine"
    [[ "$os" == "debian" ]] && lit="linux-debian"
    local lr
    if (( avail == 1 )); then
        echo -e "  ${GREEN}模式: Open API（面板可见）${NC}" >&2
        lr=$(_install_pkgs_parallel \
            "$name" "$lit" "$hp" "$tok" "${lpkgs[@]}")
    else
        echo -e "  ${YELLOW}模式: 系统直装${NC}" >&2
        lr=$(_install_pkgs_parallel \
            "$name" "$lit" "" "" "${lpkgs[@]}")
    fi
    local ol fl fll
    ol=$(echo "$lr"|cut -d'|' -f1)
    fl=$(echo "$lr"|cut -d'|' -f2)
    fll=$(echo "$lr"|cut -d'|' -f3-)
    log OK "Linux: ✅$ol ❌$fl / 共${#lpkgs[@]}"
    [[ -n "$fll" ]] && log WARN "失败（部分包已移除可忽略）: $fll"

    # canvas
    log INFO "尝试安装 canvas..."
    docker exec "$name" sh -c \
        "cd /ql/scripts && pnpm add canvas 2>/dev/null || \
         npm install canvas --build-from-source 2>/dev/null" \
        >/dev/null 2>&1 && \
        log OK "canvas 安装成功" || \
        log WARN "canvas 安装失败（非必需）"

    # 汇总
    echo -e "\n${CYAN}${BOLD}══ 安装汇总 ══${NC}" >&2
    printf "  NodeJS  : ${GREEN}%d${NC}✅ ${RED}%d${NC}❌ 共%d\n" \
        "$on" "$fn" "${#npkgs[@]}" >&2
    printf "  Python3 : ${GREEN}%d${NC}✅ ${RED}%d${NC}❌ 共%d\n" \
        "$op" "$fp" "${#ppkgs[@]}" >&2
    (( avail )) && \
    printf "  Linux   : ${GREEN}%d${NC}✅ ${RED}%d${NC}❌ 共%d ${GREEN}[面板可见]${NC}\n" \
        "$ol" "$fl" "${#lpkgs[@]}" >&2 || \
    printf "  Linux   : ${GREEN}%d${NC}✅ ${RED}%d${NC}❌ 共%d ${YELLOW}[系统直装]${NC}\n" \
        "$ol" "$fl" "${#lpkgs[@]}" >&2
    echo -e "${CYAN}${BOLD}══════════════${NC}\n" >&2

    read -rp "是否立即重启容器 $name？(Y/n): " rc
    if [[ ! "${rc:-Y}" =~ ^[Nn]$ ]]; then
        docker restart "$name" >/dev/null 2>&1 && sleep 3
        log OK "容器 $name 已重启"
        local ap; ap=$(get_container_port "$name")
        local ip; ip=$(hostname -I 2>/dev/null | \
            awk '{print $1}' || echo "localhost")
        [[ -n "$ap" ]] && \
            echo -e "${CYAN}面板: http://${ip}:${ap}${NC}" >&2
    fi
}

# ============================================================
# Cron管理
# ============================================================
manage_cron() {
    local name
    name=$(prompt_container_name \
        "请输入容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps --format "{{.Names}}" | grep -qw "$name" || {
        log ERROR "容器未运行！"; return 1
    }
    local hp; hp=$(get_container_port "$name")
    [[ -z "$hp" ]] && hp="$DEFAULT_PORT"
    local tok; tok=$(_get_ql_token "$name" "$hp") || {
        log ERROR "Token获取失败"; return 1
    }

    echo -e "\n${YELLOW}定时任务管理：${NC}"
    echo "  1. 列出所有任务"
    echo "  2. 运行指定任务"
    echo "  3. 停止指定任务"
    echo "  4. 启用/禁用任务"
    echo "  5. 添加任务"
    read -rp "请选择 [1-5]: " ch

    case "$ch" in
        1)
            curl -s -m 15 \
                "http://localhost:${hp}/open/crons" \
                -H "Authorization: Bearer ${tok}" | \
                jq -r '.data.data[] |
                    [.id,.name,.schedule,
                     (if .status==0 then "运行中"
                      elif .status==1 then "空闲"
                      else "已禁用" end)] | @tsv' \
                2>/dev/null | column -t -s $'\t'
            ;;
        2)
            read -rp "任务ID（逗号分隔）: " ids
            local j
            j=$(echo "$ids"|tr ','  '\n'| \
                grep -E '^[0-9]+$'|jq -s '.')
            curl -s -m 30 -X PUT \
                "http://localhost:${hp}/open/crons/run" \
                -H "Authorization: Bearer ${tok}" \
                -H "Content-Type: application/json" \
                -d "{\"ids\":${j}}" | \
                jq -r '.message // "完成"'
            ;;
        3)
            read -rp "任务ID: " id
            [[ ! "$id" =~ ^[0-9]+$ ]] && \
                log ERROR "ID必须是数字" && return 1
            curl -s -m 10 -X PUT \
                "http://localhost:${hp}/open/crons/stop" \
                -H "Authorization: Bearer ${tok}" \
                -H "Content-Type: application/json" \
                -d "{\"ids\":[$id]}" | \
                jq -r '.message // "完成"'
            ;;
        4)
            read -rp "任务ID: " id
            [[ ! "$id" =~ ^[0-9]+$ ]] && \
                log ERROR "ID必须是数字" && return 1
            read -rp "1=启用 2=禁用: " op
            local sv; [[ "$op" == "1" ]] && sv=0 || sv=1
            curl -s -m 10 -X PUT \
                "http://localhost:${hp}/open/crons/status" \
                -H "Authorization: Bearer ${tok}" \
                -H "Content-Type: application/json" \
                -d "{\"ids\":[$id],\"status\":$sv}" | \
                jq -r '.message // "完成"'
            ;;
        5)
            local cn cs cc
            read -rp "任务名称: " cn
            read -rp "Cron表达式: " cs
            read -rp "执行命令: " cc
            curl -s -m 10 -X POST \
                "http://localhost:${hp}/open/crons" \
                -H "Authorization: Bearer ${tok}" \
                -H "Content-Type: application/json" \
                -d "$(jq -n \
                    --arg n "$cn" --arg s "$cs" --arg c "$cc" \
                    '{"name":$n,"schedule":$s,"command":$c}')" | \
                jq -r '.message // "完成"'
            ;;
        *) log WARN "无效选择" ;;
    esac
}

# ============================================================
# Linux依赖注册
# ============================================================
register_linux_deps_to_panel() {
    local name
    name=$(prompt_container_name \
        "请输入容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps --format "{{.Names}}" | grep -qw "$name" || {
        log ERROR "容器未运行！"; return 1
    }
    local hp; hp=$(get_container_port "$name")
    [[ -z "$hp" ]] && hp="$DEFAULT_PORT"
    local tok; tok=$(_get_ql_token "$name" "$hp") || {
        log ERROR "Token获取失败！"; return 1
    }

    local lpkgs=(
        "alpine-sdk" "autoconf" "automake" "libtool"
        "gcc" "g++" "make" "python3-dev"
        "libffi-dev" "openssl-dev" "jpeg-dev" "zlib-dev"
        "libxml2-dev" "libxslt-dev" "cairo-dev"
        "pango-dev" "giflib-dev"
        "curl" "wget" "git" "ca-certificates" "tzdata"
    )
    local total=${#lpkgs[@]} ok=0 fail=0

    for i in "${!lpkgs[@]}"; do
        local pkg="${lpkgs[$i]}"
        _progress_bar $((i+1)) $total "$pkg"
        _api_install_dep "$hp" "$tok" "$pkg" "linux" && \
            ok=$((ok+1)) || fail=$((fail+1))
    done
    _progress_done
    log OK "注册完成: ✅$ok ❌$fail / 共$total"
}

# ============================================================
# 专项修复
# ============================================================
repair_deps() {
    local name
    name=$(prompt_container_name \
        "请输入要修复的容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps --format "{{.Names}}" | grep -qw "$name" || {
        log ERROR "容器未运行！"; return 1
    }

    echo -e "\n${YELLOW}修复模式：${NC}"
    echo "  1. 全量安装"
    echo "  2. 仅修复 pnpm 源"
    echo "  3. 仅修复 pip/Python3"
    echo "  4. 仅修复 canvas"
    echo "  5. Linux依赖重新注册到面板"
    echo "  6. 清除API凭证缓存"
    read -rp "请选择 [1-6，默认1]: " m

    case "${m:-1}" in
        1) install_all_deps "$name" ;;
        2)
            docker exec "$name" sh -c "
                pnpm config set registry \
                    https://registry.npmmirror.com 2>/dev/null
                npm config set registry \
                    https://registry.npmmirror.com 2>/dev/null
                rm -f /ql/scripts/node_modules/.modules.yaml \
                    2>/dev/null
            " && log OK "pnpm源修复完成" || log ERROR "修复失败"
            ;;
        3)
            docker exec "$name" sh -c "
                python3 -m pip install \
                    --upgrade pip setuptools wheel -q
                pip3 config set global.index-url \
                    https://pypi.tuna.tsinghua.edu.cn/simple
                pip3 install requests httpx pycryptodome rsa \
                    bs4 lxml PyExecJS Pillow pytz pyyaml -q
            " && log OK "Python3修复完成" || log ERROR "修复失败"
            ;;
        4)
            docker exec "$name" sh -c \
                "cat /etc/os-release" 2>/dev/null | \
                grep -qi "alpine" && \
                docker exec "$name" apk add --no-cache \
                    build-base cairo-dev pango-dev giflib-dev \
                    >/dev/null 2>&1 || \
                docker exec "$name" apt-get install -y \
                    build-essential libcairo2-dev \
                    libpango1.0-dev libgif-dev \
                    >/dev/null 2>&1
            docker exec "$name" sh -c \
                "cd /ql/scripts && \
                 npm install canvas --build-from-source 2>/dev/null" && \
                log OK "canvas修复完成" || log ERROR "canvas修复失败"
            ;;
        5) register_linux_deps_to_panel ;;
        6) clear_cred_cache ;;
        *) log ERROR "无效选择" ;;
    esac
}

# ============================================================
# 部署容器
# ============================================================
install_ql() {
    NO_TTY=0
    local name port image image_variant target_version

    name=$(prompt_container_name \
        "请输入容器名称" "$DEFAULT_CONTAINER_NAME")
    port=$(prompt_port "请输入 WebUI 端口" "$DEFAULT_PORT")

    if docker ps -a --format "{{.Names}}" | grep -qw "$name"; then
        log WARN "容器 $name 已存在！"

        # 检查是否是 Created 状态（启动失败残留）
        local st
        st=$(docker inspect \
            --format='{{.State.Status}}' "$name" 2>/dev/null || echo "")
        if [[ "$st" == "created" ]]; then
            log WARN "检测到 Created 状态残留（上次启动失败）"
            read -rp "是否删除残留并重新部署？(y/N): " del
            if [[ "${del:-N}" =~ ^[Yy]$ ]]; then
                docker rm -f "$name" >/dev/null 2>&1
                log OK "已删除残留容器，继续部署..."
            else
                return 0
            fi
        else
            return 0
        fi
    fi

    # ★ devpts检测修复
    check_and_fix_devpts || return 1

    echo -e "\n${YELLOW}请选择镜像类型：${NC}"
    echo "  1. alpine（默认轻量版）"
    echo "  2. debian（兼容性更好）"
    read -rp "请选择 [1/2，默认1]: " ic
    case "${ic:-1}" in
        2) image_variant="debian" ;;
        *) image_variant="" ;;
    esac

    target_version=$(select_version "$INSTALL_DEFAULT_VER" 5)
    if [[ -n "$image_variant" ]]; then
        image="${QL_IMAGE_BASE}:${image_variant}"
    else
        image="${QL_IMAGE_BASE}:${target_version}"
    fi

    log INFO "拉取镜像: $image ..."
    docker pull "$image" || { log ERROR "镜像拉取失败！"; return 1; }

    local rf="-dit"
    [[ "$NO_TTY" == "1" ]] && rf="-di" && \
        log WARN "降级模式启动（-di）"

    log INFO "启动容器 $name（端口 $port，参数 $rf）..."

    if docker run $rf \
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

        local ip
        ip=$(hostname -I 2>/dev/null | \
            awk '{print $1}' || echo "localhost")
        log OK "🎉 容器 $name 部署成功！"
        echo -e "\n${GREEN}${BOLD}── 下一步 ──${NC}" >&2
        echo -e "  访问: ${CYAN}http://${ip}:${port}${NC}" >&2
        echo -e "  初始化 → 应用设置 → 添加应用" >&2
        echo -e "  回到脚本选 ${GREEN}[7]${NC} 安装全依赖" >&2
    else
        log ERROR "容器启动失败！"
        echo -e "\n${YELLOW}── 错误日志 ──${NC}" >&2
        docker logs "$name" 2>&1 | tail -15 >&2
        echo "" >&2
        echo -e "${YELLOW}建议：选菜单 [D] 进行完整诊断和修复${NC}" >&2
        return 1
    fi
}

# ============================================================
# 容器列表
# ============================================================
list_containers() {
    echo -e "\n${CYAN}── 容器列表 ──${NC}"
    docker ps -a --format \
        "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"

    # 高亮 Created 状态警告
    local created_count
    created_count=$(docker ps -a --format "{{.Status}}" \
        2>/dev/null | grep -c "^Created" || echo 0)
    if [[ "$created_count" -gt 0 ]]; then
        echo -e "\n${RED}${BOLD}⚠️  发现 $created_count 个 Created 状态容器（启动失败残留）${NC}"
        echo -e "${YELLOW}建议选菜单 [D] → 选项2 清理残留，再选 [1] 重新部署${NC}"
    fi
    echo ""
}

# ============================================================
# 卸载容器
# ============================================================
uninstall_ql() {
    local name
    name=$(prompt_container_name \
        "请输入要卸载的容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps -a --format "{{.Names}}" | grep -qw "$name" || {
        log WARN "找不到容器 $name"; return
    }
    read -rp "确定停止并删除 $name？数据目录保留。(y/N): " ch
    if [[ "${ch:-N}" =~ ^[Yy]$ ]]; then
        docker stop "$name" >/dev/null 2>&1 || true
        docker rm -f "$name" >/dev/null 2>&1
        log OK "容器 $name 已删除"
    else
        log INFO "已取消"
    fi
}

# ============================================================
# 备份与恢复
# ============================================================
backup_ql() {
    local ts; ts=$(date +%Y%m%d%H%M%S)
    local bf="$DATA_DIR/backup/ql_backup_${ts}.tar.gz"
    log INFO "开始备份..."
    if tar -czf "$bf" -C "$DATA_DIR" \
        config log db repo raw scripts jbot 2>/dev/null; then
        sha256sum "$bf" > "${bf}.sha256" 2>/dev/null || true
        local sz; sz=$(du -sh "$bf" 2>/dev/null | awk '{print $1}')
        log OK "备份完成: $bf (${sz})"
    else
        log ERROR "备份失败！"; rm -f "$bf"; return 1
    fi
}

restore_ql() {
    local latest
    latest=$(ls -t "$DATA_DIR/backup"/ql_backup_*.tar.gz \
        2>/dev/null | head -n1)
    [[ ! -f "$latest" ]] && log WARN "找不到备份文件！" && return

    local csf="${latest}.sha256"
    if [[ -f "$csf" ]]; then
        sha256sum -c "$csf" &>/dev/null && log OK "校验通过" || {
            log ERROR "校验失败！文件可能损坏。"
            read -rp "强制恢复？(y/N): " f
            [[ ! "${f:-N}" =~ ^[Yy]$ ]] && return 1
        }
    fi

    read -rp "恢复: $(basename "$latest")？(y/N): " ch
    if [[ "${ch:-N}" =~ ^[Yy]$ ]]; then
        tar -xzf "$latest" -C "$DATA_DIR" 2>/dev/null && \
            log OK "恢复完成！请重启容器生效。" || \
            log ERROR "恢复失败！"
    fi
}

# ============================================================
# 无损升级
# ============================================================
upgrade_ql() {
    local name
    name=$(prompt_container_name \
        "请输入待升级的容器名" "$DEFAULT_CONTAINER_NAME")
    docker ps -a --format "{{.Names}}" | grep -qw "$name" || {
        log ERROR "容器 <$name> 不存在！"; return
    }

    local tv; tv=$(select_version "$DEFAULT_IMAGE_VER" 5)
    local image="${QL_IMAGE_BASE}:${tv}"

    log INFO "拉取镜像: $image ..."
    docker pull "$image" || { log ERROR "镜像拉取失败！"; return; }

    local ci; ci=$(docker inspect "$name")
    local nm rp
    nm=$(echo "$ci" | jq -r '.[0].HostConfig.NetworkMode')
    rp=$(echo "$ci" | jq -r '.[0].HostConfig.RestartPolicy.Name')

    local -a ra=("-dit" "--name" "$name" "--hostname" "$name")
    [[ -n "$rp" && "$rp" != "no" && "$rp" != "null" ]] && \
        ra+=("--restart" "$rp")
    [[ -n "$nm" && "$nm" != "default" && "$nm" != "null" ]] && \
        ra+=("--network" "$nm")

    if [[ "$nm" != "host" ]]; then
        local -a ports
        mapfile -t ports < <(
            echo "$ci" | jq -r \
                'if .[0].HostConfig.PortBindings
                 then .[0].HostConfig.PortBindings |
                      to_entries[] |
                      "-p",
                      "\(.value[0].HostPort):\(.key|split("/")[0])"
                 else empty end' 2>/dev/null
        )
        (( ${#ports[@]} > 0 )) && ra+=("${ports[@]}")
    fi

    local -a mounts envs
    mapfile -t mounts < <(
        echo "$ci" | jq -r \
            '.[0].Mounts[]? | "-v", "\(.Source):\(.Destination)"' \
            2>/dev/null
    )
    (( ${#mounts[@]} > 0 )) && ra+=("${mounts[@]}")

    mapfile -t envs < <(
        echo "$ci" | jq -r \
            '.[0].Config.Env[]? |
             select(test("^PATH=|^HOSTNAME=|^HOME=|^PWD=|^TERM=") | not) |
             "-e", .' 2>/dev/null
    )
    (( ${#envs[@]} > 0 )) && ra+=("${envs[@]}")

    log INFO "停止旧容器..."
    docker stop "$name" >/dev/null 2>&1
    docker rm "$name" >/dev/null 2>&1

    log INFO "重建容器..."
    if docker run "${ra[@]}" "$image" >/dev/null 2>&1; then
        log OK "🎉 无损升级完成 → $tv"
        local np; np=$(get_container_port "$name")
        local ip; ip=$(hostname -I 2>/dev/null | \
            awk '{print $1}' || echo "localhost")
        [[ -n "$np" ]] && \
            echo -e "${CYAN}面板: http://${ip}:${np}${NC}"
    else
        log ERROR "升级失败！执行 'docker logs $name' 查看原因"
    fi
}

# ============================================================
# 存储报告
# ============================================================
show_storage_report() {
    echo -e "\n${CYAN}${BOLD}════ 青龙存储占用分析 ════${NC}" >&2
    echo -e "\n${YELLOW}── Docker 镜像 ──${NC}" >&2
    docker images --format \
        "table {{.Repository}}:{{.Tag}}\t{{.Size}}" \
        2>/dev/null | grep -E "qinglong|REPO" || \
        echo "  无青龙镜像" >&2
    echo -e "\n${YELLOW}── 容器状态 ──${NC}" >&2
    docker ps -a --format \
        "table {{.Names}}\t{{.Image}}\t{{.Status}}" \
        2>/dev/null | grep -E "qinglong|NAMES" || \
        echo "  无青龙容器" >&2
    echo -e "\n${YELLOW}── 数据目录 ──${NC}" >&2
    [[ -d "$DATA_DIR" ]] && \
        du -sh "$DATA_DIR"/*/ 2>/dev/null | \
        sort -rh | awk '{printf "  %-10s  %s\n",$1,$2}' >&2 || \
        echo "  数据目录不存在" >&2
    echo -e "\n${YELLOW}── Docker 全局 ──${NC}" >&2
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
        echo -e "   ${GREEN}${BOLD}Q. ★ 全依赖一键补全（NodeJS+Python3+Linux）${NC}"
        echo -e "   ${YELLOW}W. 依赖专项修复${NC}"
        echo -e "   ${BLUE}E. Linux依赖注册到面板${NC}"
        echo -e "   ${CYAN}T. 定时任务管理（Cron）${NC}"
        echo -e "   ${RED}A. 清除API凭证缓存${NC}"
        echo -e "   ${BLUE}B. 存储占用分析${NC}"
        echo -e "   ${YELLOW}${BOLD}D. /dev/pts 诊断与修复${NC}"
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
            0)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *) log WARN "无效输入: '$op'" ;;
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
