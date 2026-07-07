#!/bin/bash
# 磁盘性能测试脚本 v2.0
# 修复：输入验证/iostat解析/临时文件清理/设备类型检测

set -euo pipefail

# ============================================================
# 全局配置
# ============================================================
readonly SCRIPT_VERSION="2.0"
readonly LOG_FILE="/tmp/disk_benchmark_$(date +%Y%m%d_%H%M%S).log"
readonly MIN_FREE_KB=$((1024 * 1024))   # 1GB
readonly DD_SIZE_MB=1024
TEMP_FILES=()                            # 全局临时文件追踪

# ============================================================
# 清理函数（trap保障）
# ============================================================
cleanup() {
    local exit_code=$?
    for f in "${TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f" && echo "已清理临时文件: $f"
    done
    [[ $exit_code -ne 0 ]] && echo "脚本异常退出，代码: $exit_code"
}
trap cleanup EXIT INT TERM

# ============================================================
# 日志函数
# ============================================================
log() {
    local level=$1; shift
    local msg="[$(date '+%H:%M:%S')] [$level] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}
info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@" >&2; }

# ============================================================
# 权限检查
# ============================================================
check_privilege() {
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
    elif sudo -v &>/dev/null 2>&1; then
        SUDO="sudo"
    else
        error "需要root或sudo权限！"
        exit 1
    fi
}

# ============================================================
# 依赖检测与安装（新增 fedora/opensuse/alpine）
# ============================================================
declare -A TOOL_TO_PKG=(
    [hdparm]="hdparm"
    [dd]="coreutils"
    [iostat]="sysstat"
    [lsblk]="util-linux"
    [awk]="gawk"
    [smartctl]="smartmontools"
    [fio]="fio"
)

install_dependencies() {
    local missing_tools=()
    local missing_pkgs=()
    
    for tool in "${!TOOL_TO_PKG[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
            local pkg="${TOOL_TO_PKG[$tool]}"
            # 去重
            [[ ! " ${missing_pkgs[*]} " =~ " $pkg " ]] && \
                missing_pkgs+=("$pkg")
        fi
    done
    
    [[ ${#missing_tools[@]} -eq 0 ]] && return 0
    
    warn "缺失工具: ${missing_tools[*]}"
    info "尝试自动安装: ${missing_pkgs[*]}"
    
    if [[ ! -f /etc/os-release ]]; then
        error "无法检测系统类型，请手动安装: ${missing_pkgs[*]}"
        exit 1
    fi
    
    # shellcheck source=/dev/null
    source /etc/os-release
    
    case "$ID" in
        ubuntu|debian|linuxmint)
            $SUDO apt-get update -qq
            $SUDO apt-get install -y "${missing_pkgs[@]}"
            ;;
        centos|rhel|rocky|almalinux)
            $SUDO yum install -y "${missing_pkgs[@]}"
            ;;
        fedora)
            $SUDO dnf install -y "${missing_pkgs[@]}"
            ;;
        arch|manjaro)
            $SUDO pacman -Sy --noconfirm "${missing_pkgs[@]}"
            ;;
        opensuse*|sles)
            $SUDO zypper install -y "${missing_pkgs[@]}"
            ;;
        alpine)
            $SUDO apk add "${missing_pkgs[@]}"
            ;;
        *)
            warn "不支持的发行版 '$ID'，请手动安装: ${missing_pkgs[*]}"
            ;;
    esac
}

# ============================================================
# 设备类型检测
# ============================================================
detect_disk_type() {
    local disk=$1
    local transport rota
    transport=$(lsblk -d -n -o TRAN "/dev/$disk" 2>/dev/null | tr -d ' ')
    rota=$(cat "/sys/block/$disk/queue/rotational" 2>/dev/null || echo "1")
    
    case "$transport" in
        nvme)  echo "NVMe SSD" ;;
        usb)   echo "USB存储" ;;
        sata|ata)
            [[ "$rota" == "0" ]] && echo "SATA SSD" || echo "SATA HDD"
            ;;
        *)
            [[ "$rota" == "0" ]] && echo "SSD" || echo "HDD"
            ;;
    esac
}

# ============================================================
# 用户输入（带验证）
# ============================================================
select_disks() {
    local disks=("$@")
    local total=${#disks[@]}
    
    echo ""
    echo "════════════════════════════════════"
    echo "  检测到以下磁盘设备"
    echo "════════════════════════════════════"
    
    for i in "${!disks[@]}"; do
        local disk="${disks[$i]}"
        local dtype size model
        dtype=$(detect_disk_type "$disk")
        size=$(lsblk -d -n -o SIZE "/dev/$disk" 2>/dev/null | tr -d ' ')
        model=$(lsblk -d -n -o MODEL "/dev/$disk" 2>/dev/null | sed 's/[[:space:]]*$//')
        printf "  %d. /dev/%-8s  %-10s  %-8s  %s\n" \
            $((i+1)) "$disk" "$dtype" "$size" "${model:-未知型号}"
    done
    
    echo "  $((total+1)). 测试所有磁盘"
    echo "  $((total+2)). 退出"
    echo "════════════════════════════════════"
    
    local choice
    while true; do
        read -rp "请选择 [1-$((total+2))]: " choice
        
        # 验证为纯数字
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            warn "请输入数字！"
            continue
        fi
        
        if [[ "$choice" -eq $((total+2)) ]]; then
            info "用户选择退出"
            exit 0
        elif [[ "$choice" -eq $((total+1)) ]]; then
            SELECTED_DISKS=("${disks[@]}")
            break
        elif [[ "$choice" -ge 1 && "$choice" -le "$total" ]]; then
            SELECTED_DISKS=("${disks[$((choice-1))]}")
            break
        else
            warn "无效选项，请重新输入！"
        fi
    done
}

# ============================================================
# hdparm 测试（带设备类型检查）
# ============================================================
run_hdparm() {
    local disk=$1
    local device="/dev/$disk"
    local dtype
    dtype=$(detect_disk_type "$disk")
    
    # NVMe 设备 hdparm 意义不大
    if [[ "$dtype" == "NVMe SSD" ]]; then
        echo "cached=N/A(NVMe) buffered=N/A(NVMe)"
        return
    fi
    
    local result
    result=$($SUDO hdparm -tT "$device" 2>/dev/null) || {
        echo "cached=失败 buffered=失败"
        return
    }
    
    local cached buffered
    cached=$(echo "$result"  | awk '/Timing cached/   {print $5}')
    buffered=$(echo "$result" | awk '/Timing buffered/ {print $5}')
    echo "cached=${cached:-未知} buffered=${buffered:-未知}"
}

# ============================================================
# dd 写入测试（修复单位解析）
# ============================================================
run_dd_write() {
    local test_file=$1
    local result speed
    
    info "正在进行 ${DD_SIZE_MB}MB 顺序写入测试..."
    
    # 同时捕获stderr（dd输出到stderr）
    result=$(dd if=/dev/zero of="$test_file" \
        bs=1M count="$DD_SIZE_MB" \
        oflag=direct 2>&1) || {
        warn "dd测试失败"
        echo "失败"
        return
    }
    
    sync
    
    # 兼容 MB/s 和 MiB/s 两种格式
    speed=$(echo "$result" | \
        grep -oP '[\d.]+ [MGk]i?B/s' | tail -1)
    
    # 统一转换为 MB/s
    if echo "$speed" | grep -q "MiB/s"; then
        local num
        num=$(echo "$speed" | grep -oP '[\d.]+')
        # MiB → MB: 乘以 1.048576
        speed=$(awk "BEGIN {printf \"%.1f MB/s\", $num * 1.048576}")
    fi
    
    echo "${speed:-未知}"
}

# ============================================================
# iostat 解析（按列名定位，兼容多版本）
# ============================================================
run_iostat() {
    local disk=$1
    
    # 获取带列头的输出
    local raw_output
    raw_output=$(iostat -d -x "$disk" 1 3 2>/dev/null) || {
        echo "read=未检测 write=未检测"
        return
    }
    
    # 提取列头行和最后数据行
    local header data_line
    header=$(echo "$raw_output" | grep -E "^Device|^Device:")
    data_line=$(echo "$raw_output" | \
        awk -v dev="$disk" '$1==dev {line=$0} END{print line}')
    
    if [[ -z "$data_line" ]]; then
        echo "read=未检测 write=未检测"
        return
    fi
    
    # 按列名查找 rMB/s 和 wMB/s 的列位置
    local rmb_col wmb_col
    rmb_col=$(echo "$header" | \
        awk '{for(i=1;i<=NF;i++) if($i=="rMB/s"||$i=="rkB/s") print i; exit}')
    wmb_col=$(echo "$header" | \
        awk '{for(i=1;i<=NF;i++) if($i=="wMB/s"||$i=="wkB/s") print i; exit}')
    
    local rmb wmb
    if [[ -n "$rmb_col" && -n "$wmb_col" ]]; then
        rmb=$(echo "$data_line" | awk -v c="$rmb_col" '{print $c}')
        wmb=$(echo "$data_line" | awk -v c="$wmb_col" '{print $c}')
        
        # 若单位是kB/s，转为MB/s
        if echo "$header" | grep -q "rkB/s"; then
            rmb=$(awk "BEGIN {printf \"%.2f\", $rmb/1024}")
            wmb=$(awk "BEGIN {printf \"%.2f\", $wmb/1024}")
        fi
    else
        rmb="未检测"
        wmb="未检测"
    fi
    
    echo "read=${rmb:-未检测} write=${wmb:-未检测}"
}

# ============================================================
# SMART 健康检测
# ============================================================
run_smart() {
    local device=$1
    
    if ! command -v smartctl &>/dev/null; then
        echo "health=未安装smartmontools"
        return
    fi
    
    local health
    health=$($SUDO smartctl -H "$device" 2>/dev/null | \
        awk '/overall-health/ {print $NF}')
    
    # 关键坏扇区警告
    local bad_sectors
    bad_sectors=$($SUDO smartctl -A "$device" 2>/dev/null | \
        awk '/Reallocated_Sector_Ct|Current_Pending_Sector/ {
            if($10+0 > 0) print $2"="$10
        }')
    
    local result="health=${health:-未知}"
    [[ -n "$bad_sectors" ]] && result+=" ⚠️ 坏扇区: $bad_sectors"
    echo "$result"
}

# ============================================================
# 获取测试目录
# ============================================================
get_test_dir() {
    local disk=$1
    local device="/dev/$disk"
    
    # 查找挂载点
    local mountpoint
    mountpoint=$(lsblk -n -o MOUNTPOINT "$device" 2>/dev/null | \
        grep -v '^$' | head -n1)
    
    if [[ -z "$mountpoint" ]]; then
        warn "$device 未挂载，使用 /tmp 进行测试（仅参考）"
        mountpoint="/tmp"
    fi
    
    # 检查空间
    local avail_kb
    avail_kb=$(df --output=avail -k "$mountpoint" 2>/dev/null | tail -1)
    
    if [[ "${avail_kb:-0}" -lt "$MIN_FREE_KB" ]]; then
        warn "$mountpoint 可用空间不足 1GB（当前: ${avail_kb}KB），跳过写入测试"
        echo "NOSPACE"
        return
    fi
    
    echo "$mountpoint"
}

# ============================================================
# 性能评级（简单参考）
# ============================================================
rate_speed() {
    local speed_str=$1   # 如 "245.3 MB/s"
    local type=$2        # "read" or "write"
    
    local speed
    speed=$(echo "$speed_str" | grep -oP '[\d.]+' | head -1)
    
    if [[ -z "$speed" ]]; then echo "❓"; return; fi
    
    # HDD参考标准
    local excellent good
    if [[ "$type" == "read" ]]; then
        excellent=150; good=80
    else
        excellent=100; good=60
    fi
    
    if awk "BEGIN {exit !($speed >= $excellent)}"; then
        echo "🟢优秀"
    elif awk "BEGIN {exit !($speed >= $good)}"; then
        echo "🟡良好"
    else
        echo "🔴较差"
    fi
}

# ============================================================
# 主测试流程
# ============================================================
test_disk() {
    local disk=$1
    local device="/dev/$disk"
    local dtype
    dtype=$(detect_disk_type "$disk")
    
    info "════ 开始测试: $device ($dtype) ════"
    
    # 1. hdparm 读取测试
    info "→ 执行 hdparm 读取测试..."
    local hdparm_out
    hdparm_out=$(run_hdparm "$disk")
    local cached buffered
    cached=$(echo "$hdparm_out"  | grep -oP 'cached=\K\S+')
    buffered=$(echo "$hdparm_out" | grep -oP 'buffered=\K\S+')
    
    # 2. SMART 健康
    info "→ 执行 SMART 健康检测..."
    local smart_out
    smart_out=$(run_smart "$device")
    
    # 3. 获取测试目录
    local test_dir
    test_dir=$(get_test_dir "$disk")
    
    # 4. dd 写入测试
    local dd_speed="跳过"
    if [[ "$test_dir" != "NOSPACE" ]]; then
        local test_file
        test_file=$(mktemp "${test_dir}/diskbench_${disk}_XXXX")
        TEMP_FILES+=("$test_file")  # 注册到全局清理列表
        
        dd_speed=$(run_dd_write "$test_file")
        rm -f "$test_file"
        # 从追踪列表中移除（已删除）
        TEMP_FILES=("${TEMP_FILES[@]/$test_file}")
    fi
    
    # 5. iostat IO监控
    info "→ 执行 iostat 监控（约3秒）..."
    local iostat_out
    iostat_out=$(run_iostat "$disk")
    local io_read io_write
    io_read=$(echo "$iostat_out"  | grep -oP 'read=\K\S+')
    io_write=$(echo "$iostat_out" | grep -oP 'write=\K\S+')
    
    # 评级
    local read_rating write_rating
    read_rating=$(rate_speed "$buffered MB/s" "read")
    write_rating=$(rate_speed "$dd_speed" "write")
    
    # 格式化结果
    RESULTS[$disk]=$(cat <<EOF

┌─────────────────────────────────────────┐
│  磁盘: /dev/$disk  ($dtype)
├─────────────────────────────────────────┤
│  健康状态
│    $smart_out
├─────────────────────────────────────────┤
│  顺序读取 (hdparm)
│    缓存读取:   ${cached} MB/s
│    缓冲读取:   ${buffered} MB/s  $read_rating
├─────────────────────────────────────────┤
│  顺序写入 (dd, ${DD_SIZE_MB}MB, direct)
│    写入速度:   ${dd_speed}  $write_rating
├─────────────────────────────────────────┤
│  实时 I/O (iostat)
│    读取:  ${io_read} MB/s
│    写入:  ${io_write} MB/s
└─────────────────────────────────────────┘
EOF
)
    
    info "════ $device 测试完成 ════"
}

# ============================================================
# 汇总报告
# ============================================================
print_summary() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        📊 磁盘性能测试汇总报告            ║"
    echo "║  测试时间: $(date '+%Y-%m-%d %H:%M:%S')    ║"
    echo "╚══════════════════════════════════════════╝"
    
    for disk in "${SELECTED_DISKS[@]}"; do
        echo "${RESULTS[$disk]}"
    done
    
    echo ""
    echo "✅ 所有测试完成！日志已保存: $LOG_FILE"
    echo ""
    echo "📌 评级参考（HDD基准）："
    echo "   读取: 🟢>150MB/s  🟡80-150MB/s  🔴<80MB/s"
    echo "   写入: 🟢>100MB/s  🟡60-100MB/s  🔴<60MB/s"
    echo "   SSD/NVMe 性能远高于上述标准，建议使用 fio 深度测试"
}

# ============================================================
# 主入口
# ============================================================
main() {
    echo "════════════════════════════════════════"
    echo "  磁盘性能测试工具 v${SCRIPT_VERSION}"
    echo "════════════════════════════════════════"
    
    check_privilege
    install_dependencies
    
    # 发现磁盘
    mapfile -t DISKS < <(lsblk -d -n -o NAME,TYPE | \
        awk '$2=="disk"{print $1}')
    
    if [[ ${#DISKS[@]} -eq 0 ]]; then
        error "未发现任何磁盘设备！"
        exit 1
    fi
    
    # 用户选择
    declare -g -a SELECTED_DISKS
    select_disks "${DISKS[@]}"
    
    # 执行测试
    declare -g -A RESULTS
    for disk in "${SELECTED_DISKS[@]}"; do
        test_disk "$disk"
    done
    
    # 输出报告
    print_summary
}

main "$@"
