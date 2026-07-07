#!/bin/bash
set -uo pipefail

# ============================================================
# 全局配置
# ============================================================
SCRIPT_VERSION="2.0"
SCRIPT_DIR="$HOME/one-click-scripts"
LOG_FILE="$SCRIPT_DIR/installer.log"
LOG_MAX_SIZE=1048576
RETRY_COUNT=3
CUSTOM_MENU_FILE="$SCRIPT_DIR/custom_menu.conf"
FIRST_RUN_FLAG="$SCRIPT_DIR/.initialized"

PROXY_PREFIXES=(
    "https://un.ax18.ggff.net/"
    "https://cdn.yyds9527.nyc.mn/"
)

# ============================================================
# 菜单数据
# ============================================================
declare -A DEFAULT_SCRIPTS=(
    ["1"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker.sh"
    ["2"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_tools.sh"
    ["3"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/clean-system.sh"
    ["4"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/device_info.sh"
    ["5"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup_cronjob.sh"
    ["6"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/singbox-manager.sh"
    ["7"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_singbox_docker.sh"
    ["8"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-sing-box-mihomo.sh"
    ["9"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup-dae.sh"
    ["10"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/dae_manager.sh"
    ["11"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup_tun.sh"
    ["12"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-subc.sh"
    ["13"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/sub-store-deploy.sh"
    ["14"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/set-dns.sh"
    ["15"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_mosdns.sh"
    ["16"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-adg.sh"
    ["17"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/cloudflared-deploy.sh"
    ["18"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-caddy.sh"
    ["19"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker_ddns_go.sh"
    ["20"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/ipwg.sh"
    ["21"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/deploy_containers.sh"
    ["22"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-alist.sh"
    ["23"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-nexterm.sh"
    ["24"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-rustdesk.sh"
    ["25"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker_lucky.sh"
    ["26"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/ql.sh"
    ["27"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-nezha.sh"
    ["28"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_siyuan.sh"
    ["29"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/docker_sunpanel.sh"
    ["30"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/casaos_installer.sh"
    ["31"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-openapi.sh"
    ["32"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-deploy_frigate.sh"
    ["33"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/Shinobi.sh"
    ["34"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/disk_repair_tool.sh"
    ["35"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/auto_disk_mounter.sh"
    ["36"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/disk_speed_test.sh"
    ["37"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/pve-zfsswap.sh"
    ["38"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/wifi-hotspot.sh"
    ["39"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/4G-UFI_sim.sh"
    ["40"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/manage_openwrt.sh"
    ["41"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/netconfig.sh"
    ["42"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/openwrt_mac.sh"
    ["43"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/argon_beauty.sh"
    ["44"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/pve_smart_migration.sh"
    ["45"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/uninstall_histb.sh"
)

DEFAULT_OPTIONS=(
    "1. 安装 Docker"
    "2. 安装常用工具"
    "3. 清理系统垃圾"
    "4. 获取设备信息"
    "5. 配置定时任务"
    "6. 管理 Sing-box"
    "7. 部署 Docker 版 Sing-box"
    "8. 安装裸核 Sing-box 和 Mihomo"
    "9. 配置 dae"
    "10. 管理 dae"
    "11. 开启 tun 模式"
    "12. 安装 Subconverter"
    "13. 部署 Sub-Store"
    "14. 设置 DNS"
    "15. 安装 MosDNS"
    "16. 安装 AdGuard Home"
    "17. 安装 cloudflared"
    "18. 开启 Caddy 反代功能"
    "19. 安装 Docker 版 ddns-go"
    "20. 设备网关设置"
    "21. SSH 工具 & 测速容器"
    "22. 安装 Alist"
    "23. 安装 NexTerm"
    "24. Docker 部署 RustDesk"
    "25. 安装 Docker 版 Lucky"
    "26. 安装 Docker 版青龙面板"
    "27. 哪吒探针部署"
    "28. 安装思源笔记"
    "29. 安装 Sun-Panel"
    "30. CasaOS 部署"
    "31. 安装 OpenAPI"
    "32. 部署 Frigate 监控"
    "33. 部署 Shinobi 监控"
    "34. 硬盘修复 / 格式化工具"
    "35. 自动挂载外置硬盘"
    "36. 硬盘测速"
    "37. 设置虚拟内存"
    "38. 设置 WiFi 热点"
    "39. 4G-UFI 切卡管理"
    "40. 安装 Docker 版 OpenWrt"
    "41. OpenWrt 网口配置"
    "42. OpenWrt 固定 MAC"
    "43. OpenWrt UI 界面美化"
    "44. PVE 智能存储迁移"
    "45. 海纳思内置卸载"
    "98. 快捷键管理"
)

# 运行时菜单状态
declare -A SCRIPTS=()
declare -A CUSTOM_SCRIPT_NAMES=()
OPTIONS=()

# ============================================================
# 基础工具函数
# ============================================================

is_root()    { [ "$(id -u)" -eq 0 ]; }
is_openwrt() { [[ -f /etc/openwrt_release ]]; }

get_real_path() {
    local path="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$path" 2>/dev/null || echo "$path"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$path" 2>/dev/null || echo "$path"
    else
        echo "$path"
    fi
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ============================================================
# 系统环境检测
# ============================================================

OS=""
PKG_MANAGER=""

detect_os_pkg() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="${ID:-unknown}"
    fi
    if command -v opkg >/dev/null 2>&1; then
        PKG_MANAGER="opkg"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    else
        PKG_MANAGER=""
    fi
}

# ============================================================
# 依赖安装
# ============================================================

NEEDED_CMDS=(wget curl tar)
MISSING_CMDS=()

check_and_install_deps() {
    MISSING_CMDS=()
    for cmd in "${NEEDED_CMDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || MISSING_CMDS+=("$cmd")
    done

    if is_openwrt; then
        command -v nano >/dev/null 2>&1 || MISSING_CMDS+=(nano)
    fi

    [[ ${#MISSING_CMDS[@]} -eq 0 ]] && return 0

    detect_os_pkg
    echo "缺少以下依赖：${MISSING_CMDS[*]}"

    if [ -z "$PKG_MANAGER" ]; then
        echo "无法自动检测包管理器，请手动安装：${MISSING_CMDS[*]}"
        return 1
    fi

    echo "正在使用 $PKG_MANAGER 安装依赖..."

    if ! is_root && [[ "$PKG_MANAGER" != "opkg" ]]; then
        echo "需要 root 权限，请使用 sudo 运行本脚本"
        return 1
    fi

    case "$PKG_MANAGER" in
        apt-get) apt-get update -qq && apt-get install -y "${MISSING_CMDS[@]}" || return 1 ;;
        yum)     yum install -y "${MISSING_CMDS[@]}" || return 1 ;;
        dnf)     dnf install -y "${MISSING_CMDS[@]}" || return 1 ;;
        opkg)    opkg update && opkg install "${MISSING_CMDS[@]}" || return 1 ;;
        *)
            echo "未知包管理器：$PKG_MANAGER，请手动安装：${MISSING_CMDS[*]}"
            return 1
            ;;
    esac
    echo "依赖安装完成"
}

# ============================================================
# 初始化目录
# ============================================================

init_dirs() {
    local dirs=("$SCRIPT_DIR" "$SCRIPT_DIR/core_scripts" "$SCRIPT_DIR/user_scripts")
    for d in "${dirs[@]}"; do
        mkdir -p "$d" || { echo "无法创建目录：$d"; return 1; }
    done
    touch "$LOG_FILE" "$CUSTOM_MENU_FILE" 2>/dev/null || {
        echo "无法创建必要文件"
        return 1
    }
}

# ============================================================
# 网络检测 & 脚本下载
# ============================================================

DIRECT_OK=0

check_network() {
    if curl -fsSL --max-time 5 "https://raw.githubusercontent.com" >/dev/null 2>&1; then
        DIRECT_OK=1
        return 0
    else
        DIRECT_OK=0
        return 1
    fi
}

download_script() {
    local choice="$1"
    local url="${DEFAULT_SCRIPTS[$choice]:-}"

    if [[ -z "$url" ]]; then
        echo "此选项没有对应的脚本 URL" >&2
        return 1
    fi

    local script_name="${choice}-$(basename "$url")"
    local script_path="$SCRIPT_DIR/core_scripts/$script_name"

    # 缓存命中（24小时内）
    if [[ -f "$script_path" ]]; then
        if ! find "$script_path" -mmin +1440 2>/dev/null | grep -q .; then
            echo "使用本地缓存: $script_path" >&2
            echo "$script_path"
            return 0
        fi
        echo "缓存已过期，重新下载..." >&2
        rm -f "$script_path"
    fi

    # 网络检测（只做一次）
    if [[ "$DIRECT_OK" -eq 0 ]]; then
        echo -n "检测网络连通性... " >&2
        if check_network; then
            echo "直连可用" >&2
        else
            echo "直连不可用，将使用代理" >&2
        fi
    fi

    # 组装候选 URL
    local urls_to_try=()
    [[ "$DIRECT_OK" -eq 1 ]] && urls_to_try+=("$url")
    if [[ "$url" == https://raw.githubusercontent.com/* ]]; then
        for proxy in "${PROXY_PREFIXES[@]}"; do
            urls_to_try+=("${proxy}${url}")
        done
    fi
    [[ ${#urls_to_try[@]} -eq 0 ]] && urls_to_try+=("$url")

    # 逐一尝试下载
    local attempt=0
    for try_url in "${urls_to_try[@]}"; do
        for ((i=1; i<=RETRY_COUNT; i++)); do
            attempt=$((attempt + 1))
            echo "下载尝试 $attempt/$((${#urls_to_try[@]} * RETRY_COUNT)): $try_url" >&2

            if curl -fsSL --connect-timeout 10 --max-time 60 \
                    "$try_url" -o "$script_path" 2>/dev/null; then
                if [[ -s "$script_path" ]]; then
                    chmod +x "$script_path"
                    echo "下载成功 ✅" >&2
                    log "下载成功: $script_path (来源: $try_url)"
                    echo "$script_path"
                    return 0
                else
                    echo "下载文件为空，删除并重试..." >&2
                    rm -f "$script_path"
                fi
            else
                echo "curl 失败，重试 ($i/$RETRY_COUNT)..." >&2
                rm -f "$script_path" 2>/dev/null
            fi

            [[ $i -lt $RETRY_COUNT ]] && sleep 2
        done
    done

    echo "❌ 所有下载均失败，URL: $url" >&2
    log "下载失败: choice=$choice url=$url"
    return 1
}

# ============================================================
# 脚本执行
# ============================================================

run_script() {
    local script_path="$1"
    if [[ ! -f "$script_path" ]]; then
        echo "脚本文件不存在：$script_path"
        log "运行失败，文件不存在: $script_path"
        return 1
    fi

    chmod +x "$script_path"
    log "开始运行: $script_path"

    bash "$script_path" 2>&1 | tee -a "$LOG_FILE"
    local script_exit="${PIPESTATUS[0]}"

    if [[ "$script_exit" -eq 0 ]]; then
        echo ""
        echo "✅ 脚本运行成功"
        log "运行成功: $script_path"
    else
        echo ""
        echo "❌ 脚本运行失败（退出码: $script_exit），请查看日志"
        log "运行失败（退出码: $script_exit）: $script_path"
    fi
    return "$script_exit"
}

# ============================================================
# 日志管理
# ============================================================

manage_logs() {
    [[ -f "$LOG_FILE" ]] || return 0

    local log_size=0
    if command -v stat >/dev/null 2>&1; then
        log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    else
        log_size=$(ls -l "$LOG_FILE" 2>/dev/null | awk '{print $5}' || echo 0)
    fi
    log_size=${log_size:-0}

    if [[ "$log_size" -ge "$LOG_MAX_SIZE" ]]; then
        local keep_size=$((LOG_MAX_SIZE / 2))
        tail -c "$keep_size" "$LOG_FILE" > "${LOG_FILE}.tmp" && \
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "日志已轮转，原大小: ${log_size} 字节"
    fi
}

# ============================================================
# 快捷键管理
# ============================================================

# 首次运行自动创建快捷键 'a'
add_script_shortcut() {
    [[ -f "$FIRST_RUN_FLAG" ]] && return 0

    local cur_path
    cur_path="$(get_real_path "$0")"
    local symlink_name="a"

    local symlink_dirs=()
    if is_openwrt; then
        symlink_dirs=("/usr/bin" "/bin" "$HOME/.local/bin")
    else
        symlink_dirs=("/usr/local/bin" "/usr/bin" "/bin" "$HOME/.local/bin")
    fi

    local chosen_dir=""
    for d in "${symlink_dirs[@]}"; do
        mkdir -p "$d" 2>/dev/null || continue
        if [[ -w "$d" ]] || is_root; then
            chosen_dir="$d"
            break
        fi
    done

    if [[ -z "$chosen_dir" ]]; then
        echo "没有可写目录，跳过快捷键设置"
        touch "$FIRST_RUN_FLAG"
        return 0
    fi

    local link="${chosen_dir}/${symlink_name}"

    if [[ -L "$link" ]]; then
        local existing_target
        existing_target="$(readlink -f "$link" 2>/dev/null)"
        if [[ "$existing_target" == "$cur_path" ]]; then
            echo "快捷键 '$symlink_name' 已存在，可直接输入 '$symlink_name' 启动本脚本"
            touch "$FIRST_RUN_FLAG"
            return 0
        fi
    fi

    echo ""
    echo -ne "是否创建快捷键 '$symlink_name' 到 $chosen_dir？（回车=是，n=跳过）: "
    read -r ans
    case "${ans:-y}" in
        n|N|no|NO)
            echo "已跳过快捷键设置"
            touch "$FIRST_RUN_FLAG"
            return 0
            ;;
    esac

    if ln -sf "$cur_path" "$link" 2>/dev/null && chmod +x "$cur_path"; then
        echo "快捷键 '$symlink_name' 创建成功，后续直接输入 '$symlink_name' 即可启动"
    else
        echo "快捷键创建失败（可能权限不足），可手动执行："
        echo "  ln -sf '$cur_path' '$link'"
    fi

    touch "$FIRST_RUN_FLAG"
}

# 探测可写的快捷键目录
get_symlink_dir() {
    local dirs=()
    if is_openwrt; then
        dirs=("/usr/bin" "/bin" "$HOME/.local/bin")
    else
        dirs=("/usr/local/bin" "/usr/bin" "/bin" "$HOME/.local/bin")
    fi
    for d in "${dirs[@]}"; do
        mkdir -p "$d" 2>/dev/null || continue
        if [[ -w "$d" ]] || is_root; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

# 快捷键管理主菜单
manage_symlink() {
    local current_script
    current_script="$(get_real_path "$0")"
    while true; do
        clear
        echo "========================================"
        echo "           快捷键管理"
        echo "========================================"
        echo "1. 管理当前脚本快捷键"
        echo "2. 绑定指定脚本到快捷键"
        echo "0. 返回主菜单"
        echo "----------------------------------------"
        read -rp "请输入选项编号: " choice

        case "$choice" in
            1) manage_current_script_symlink "$current_script" ;;
            2) bind_script_to_shortcut ;;
            0) break ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

# 管理当前脚本快捷键（增/删）
manage_current_script_symlink() {
    local current_script="$1"
    local symlink_dir
    symlink_dir="$(get_symlink_dir)" || {
        echo "未找到可写目录"
        read -rp "按回车键返回..."
        return 1
    }

    while true; do
        clear
        echo "========================================"
        echo "    管理当前脚本快捷键"
        echo "========================================"
        echo "当前脚本: $current_script"
        echo "快捷键目录: $symlink_dir"
        echo ""
        echo "当前已创建的快捷键："
        local found=0
        while IFS= read -r -d $'\0' link; do
            local target
            target="$(readlink -f "$link" 2>/dev/null)" || continue
            if [[ "$target" == "$current_script" ]]; then
                echo "  $(basename "$link") -> $target"
                found=1
            fi
        done < <(find "$symlink_dir" -maxdepth 1 -type l -print0 2>/dev/null)
        [[ $found -eq 0 ]] && echo "  （暂无）"

        echo ""
        echo "1. 创建新快捷键"
        echo "2. 删除快捷键"
        echo "0. 返回上级"
        read -rp "请输入选项编号: " choice

        case "$choice" in
            1)
                read -rp "请输入快捷键名称（仅字母数字）: " shortcut
                if [[ ! "$shortcut" =~ ^[a-zA-Z0-9]+$ ]]; then
                    echo "快捷键只能含字母和数字"; sleep 1; continue
                fi
                local link="$symlink_dir/$shortcut"
                if [[ -e "$link" ]]; then
                    echo "快捷键已存在，请换一个名称"; sleep 1; continue
                fi
                if ln -sf "$current_script" "$link" 2>/dev/null; then
                    echo "✅ 快捷键 '$shortcut' 创建成功"
                else
                    sudo ln -sf "$current_script" "$link" 2>/dev/null && \
                        echo "✅ 快捷键 '$shortcut' 创建成功（使用了 sudo）" || \
                        echo "❌ 创建失败，请检查权限"
                fi
                read -rp "按回车键继续..."
                ;;
            2)
                read -rp "请输入要删除的快捷键名称: " shortcut
                local link="$symlink_dir/$shortcut"
                if [[ ! -L "$link" ]]; then
                    echo "快捷键不存在"; sleep 1; continue
                fi
                local target
                target="$(readlink -f "$link" 2>/dev/null)"
                if [[ "$target" != "$current_script" ]]; then
                    echo "该快捷键不指向当前脚本，拒绝删除"; sleep 1; continue
                fi
                rm -f "$link" 2>/dev/null || sudo rm -f "$link" 2>/dev/null
                echo "已删除快捷键 '$shortcut'"
                read -rp "按回车键继续..."
                ;;
            0) break ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

# 绑定任意脚本到快捷键
bind_script_to_shortcut() {
    while true; do
        clear
        echo "========================================"
        echo "    绑定指定脚本到快捷键"
        echo "========================================"
        read -rp "请输入脚本的完整路径（0=返回）: " script_path
        [[ "$script_path" == "0" ]] && break

        script_path="$(get_real_path "$script_path")"
        if [[ ! -f "$script_path" ]]; then
            echo "文件不存在: $script_path"; sleep 1; continue
        fi

        local first_line
        first_line=$(head -1 "$script_path" 2>/dev/null)
        if [[ ! "$first_line" =~ ^#! ]]; then
            echo "警告：文件没有 shebang，可能不是有效脚本"
            read -rp "仍然继续？[y/N]: " ans
            [[ "${ans:-n}" != [yY] ]] && continue
        fi

        read -rp "请输入快捷键名称（仅字母数字）: " shortcut
        if [[ ! "$shortcut" =~ ^[a-zA-Z0-9]+$ ]]; then
            echo "快捷键只能含字母和数字"; sleep 1; continue
        fi

        local symlink_dir
        symlink_dir="$(get_symlink_dir)" || { echo "未找到可写目录"; sleep 1; continue; }

        local link="$symlink_dir/$shortcut"
        if [[ -e "$link" ]]; then
            echo "快捷键 '$shortcut' 已存在"; sleep 1; continue
        fi

        if ln -sf "$script_path" "$link" && chmod +x "$script_path"; then
            echo "✅ 成功: $link -> $script_path"
        else
            echo "❌ 创建失败，可尝试手动执行："
            echo "   ln -sf '$script_path' '$link'"
        fi

        read -rp "按回车键继续..."
        break
    done
}

# ============================================================
# 菜单逻辑
# ============================================================

get_next_custom_menu_id() {
    local max_id=0
    for opt in "${DEFAULT_OPTIONS[@]}"; do
        local num="${opt%%.*}"
        [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -gt "$max_id" ]] && max_id="$num"
    done
    while IFS='|' read -r id _rest; do
        [[ "$id" =~ ^[0-9]+$ ]] && [[ "$id" -gt "$max_id" ]] && max_id="$id"
    done < <(grep -v '^#' "$CUSTOM_MENU_FILE" 2>/dev/null | grep -v '^$')
    echo $((max_id + 1))
}

load_menu() {
    OPTIONS=()
    SCRIPTS=()
    CUSTOM_SCRIPT_NAMES=()
    declare -A seen_ids=()

    for opt in "${DEFAULT_OPTIONS[@]}"; do
        local num="${opt%%.*}"
        [[ -n "${seen_ids[$num]+_}" ]] && continue
        seen_ids["$num"]=1
        OPTIONS+=("$opt")
        if [[ -v DEFAULT_SCRIPTS["$num"] ]]; then
            SCRIPTS["$num"]="${DEFAULT_SCRIPTS[$num]}"
            CUSTOM_SCRIPT_NAMES["$num"]="$(basename "${DEFAULT_SCRIPTS[$num]}")"
        else
            SCRIPTS["$num"]=""
        fi
    done

    while IFS='|' read -r id name url script_name; do
        [[ -z "$id" || "$id" == \#* ]] && continue
        [[ -n "${seen_ids[$id]+_}" ]] && continue
        seen_ids["$id"]=1
        OPTIONS+=("${id}. ${name}")
        SCRIPTS["$id"]="$url"
        CUSTOM_SCRIPT_NAMES["$id"]="$script_name"
    done < <(grep -v '^#' "$CUSTOM_MENU_FILE" 2>/dev/null | grep -v '^$')

    IFS=$'\n' OPTIONS=($(
        for opt in "${OPTIONS[@]}"; do echo "$opt"; done | sort -t. -k1 -n
    ))
    unset IFS

    [[ -z "${seen_ids[99]+_}" ]] && OPTIONS+=("99. 管理自定义菜单") && SCRIPTS["99"]=""
    [[ -z "${seen_ids[0]+_}" ]]  && OPTIONS+=("0. 退出")            && SCRIPTS["0"]=""
}

manage_custom_menu() {
    while true; do
        clear
        echo "========================================"
        echo "          自定义菜单管理"
        echo "========================================"
        echo "当前自定义菜单选项："
        local count=0
        while IFS='|' read -r id name url script_name; do
            [[ -z "$id" || "$id" == \#* ]] && continue
            echo "  $id. $name  [$url]"
            count=$((count + 1))
        done < <(grep -v '^#' "$CUSTOM_MENU_FILE" 2>/dev/null | grep -v '^$')
        [[ $count -eq 0 ]] && echo "  （暂无自定义菜单项）"

        echo "----------------------------------------"
        echo "1. 添加菜单选项"
        echo "2. 删除菜单选项"
        echo "0. 返回主菜单"
        echo "----------------------------------------"
        read -rp "请输入选项编号: " choice
        case "$choice" in
            1)
                local next_id
                next_id="$(get_next_custom_menu_id)"
                read -rp "请输入菜单名称: " name
                [[ -z "$name" ]] && echo "名称不能为空" && sleep 1 && continue

                read -rp "请输入脚本 URL 或本地路径: " url
                [[ -z "$url" ]] && echo "URL不能为空" && sleep 1 && continue

                name="${name//|/／}"

                local script_name
                script_name="$(echo "$name" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]').sh"
                [[ -z "$script_name" || "$script_name" == ".sh" ]] && \
                    script_name="custom_${next_id}.sh"

                echo "${next_id}|${name}|${url}|${script_name}" >> "$CUSTOM_MENU_FILE"
                echo "✅ 已添加菜单项 $next_id: $name"
                ;;
            2)
                read -rp "请输入要删除的菜单项编号: " id
                if grep -q "^${id}|" "$CUSTOM_MENU_FILE"; then
                    sed -i "/^${id}|/d" "$CUSTOM_MENU_FILE"
                    echo "✅ 已删除菜单项 $id"
                else
                    echo "未找到编号 $id 的菜单项"
                fi
                ;;
            0) break ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
        read -rp "按回车键继续..."
    done
}

print_menu() {
    clear
    echo "========================================"
    echo "       🚀 一键脚本管理平台 v${SCRIPT_VERSION} 🚀"
    echo "========================================"
    echo "请输入选项编号并按回车键执行："
    echo "----------------------------------------"
    for opt in "${OPTIONS[@]}"; do
        echo "  $opt"
    done
    echo "----------------------------------------"
}

# ============================================================
# 主函数
# ============================================================

main() {
    init_dirs              || exit 1
    check_and_install_deps || exit 1
    add_script_shortcut

    while true; do
        load_menu
        print_menu
        read -rp "请输入选项编号: " choice

        case "$choice" in
            0)
                echo "再见！"
                exit 0
                ;;
            98)
                manage_symlink
                ;;
            99)
                manage_custom_menu
                ;;
            ''|*[!0-9]*)
                echo "请输入有效数字"
                sleep 1
                continue
                ;;
            *)
                if [[ -v SCRIPTS["$choice"] ]]; then
                    local url="${SCRIPTS[$choice]}"
                    if [[ -z "$url" ]]; then
                        echo "该选项是内部功能，请重新选择"
                        sleep 1
                        continue
                    fi

                    manage_logs

                    local script_path
                    script_path="$(download_script "$choice")"
                    local dl_ret=$?

                    if [[ $dl_ret -eq 0 && -f "$script_path" ]]; then
                        run_script "$script_path"
                    else
                        echo ""
                        echo "❌ 下载失败，请检查以上错误信息或网络状态"
                        log "下载失败: choice=$choice"
                    fi

                    echo ""
                    read -rp "按回车键返回主菜单..."
                else
                    echo "无效选项：$choice"
                    sleep 1
                fi
                ;;
        esac
    done
}

main
