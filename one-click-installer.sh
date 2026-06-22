#!/bin/bash
# set -euo pipefail  # ❌ 与交互式菜单冲突，改为手动检查
set -uo pipefail     # ✅ 保留 -u 和 pipefail，去掉 -e

# ============================================================
# 全局配置
# ============================================================
SCRIPT_VERSION="2.0"
SCRIPT_DIR="$HOME/one-click-scripts"
LOG_FILE="$SCRIPT_DIR/installer.log"
LOG_MAX_SIZE=1048576
RETRY_COUNT=3
CUSTOM_MENU_FILE="$SCRIPT_DIR/custom_menu.conf"
FIRST_RUN_FLAG="$SCRIPT_DIR/.initialized"  # ✅ 新增：首次运行标记

# 代理列表（用户可自行修改）
PROXY_PREFIXES=(
    "https://un.ax18.ggff.net/"
    "https://cdn.yyds9527.nyc.mn/"
)

# ============================================================
# 工具函数
# ============================================================
is_root() { [ "$(id -u)" -eq 0 ]; }

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
# 依赖检测（修复：仅在需要时运行，避免误触 set -e）
# ============================================================
NEEDED_CMDS=(wget curl tar)
MISSING_CMDS=()
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

    # ✅ 修复：统一 root 判断逻辑
    if ! is_root && [[ "$PKG_MANAGER" != "opkg" ]]; then
        echo "需要 root 权限，请使用 sudo 运行本脚本"
        return 1
    fi

    case "$PKG_MANAGER" in
        apt-get)
            apt-get update -qq && apt-get install -y "${MISSING_CMDS[@]}" || return 1
            ;;
        yum)
            yum install -y "${MISSING_CMDS[@]}" || return 1
            ;;
        dnf)
            dnf install -y "${MISSING_CMDS[@]}" || return 1
            ;;
        opkg)
            opkg update && opkg install "${MISSING_CMDS[@]}" || return 1
            ;;
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
# 快捷键（✅ 修复：仅首次运行时设置，不是每次启动都弹）
# ============================================================
add_script_shortcut() {
    # 首次运行标记检查
    if [[ -f "$FIRST_RUN_FLAG" ]]; then
        return 0  # 已初始化过，跳过
    fi

    local cur_path
    cur_path="$(get_real_path "$0")"

    # 快捷键固定为 'a'
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
        touch "$FIRST_RUN_FLAG"  # 标记已处理，不再重复弹提示
        return 0
    fi

    local link="${chosen_dir}/${symlink_name}"

    # 已存在且指向正确
    if [[ -L "$link" ]]; then
        local existing_target
        existing_target="$(readlink -f "$link" 2>/dev/null)"
        if [[ "$existing_target" == "$cur_path" ]]; then
            echo "快捷键 '$symlink_name' 已存在，可直接输入 '$symlink_name' 启动本脚本"
            touch "$FIRST_RUN_FLAG"
            return 0
        fi
    fi

    # 询问用户
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

    # 创建软链
    if ln -sf "$cur_path" "$link" 2>/dev/null && chmod +x "$cur_path"; then
        echo "快捷键 '$symlink_name' 创建成功，后续直接输入 '$symlink_name' 即可启动"
    else
        echo "快捷键创建失败（可能权限不足），可手动执行："
        echo "  ln -sf '$cur_path' '$link'"
    fi

    touch "$FIRST_RUN_FLAG"  # 标记已完成初始化
}

# ============================================================
# 日志管理（✅ 修复：log_size 空值保护）
# ============================================================
manage_logs() {
    [[ -f "$LOG_FILE" ]] || return 0

    local log_size=0
    if command -v stat >/dev/null 2>&1; then
        log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    else
        log_size=$(ls -l "$LOG_FILE" 2>/dev/null | awk '{print $5}' || echo 0)
    fi
    log_size=${log_size:-0}  # ✅ 空值保护

    if [[ "$log_size" -ge "$LOG_MAX_SIZE" ]]; then
        local keep_size=$((LOG_MAX_SIZE / 2))
        tail -c "$keep_size" "$LOG_FILE" > "${LOG_FILE}.tmp" && \
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "日志已轮转，原大小: ${log_size} 字节"
    fi
}

# ============================================================
# 网络检测（✅ 修复：实际在下载前调用）
# ============================================================
DIRECT_OK=0  # 全局缓存网络检测结果

check_network() {
    if curl -fsSL --max-time 5 "https://raw.githubusercontent.com" >/dev/null 2>&1; then
        DIRECT_OK=1
        return 0
    else
        DIRECT_OK=0
        return 1
    fi
}

# ============================================================
# 下载脚本（✅ 修复：逻辑清晰化 + 文件完整性校验）
# ============================================================
download_script() {
    local choice="$1"
    local url="${DEFAULT_SCRIPTS[$choice]:-}"

    if [[ -z "$url" ]]; then
        echo "此选项没有对应的脚本 URL" >&2
        return 1
    fi

    local script_name
    script_name="${choice}-$(basename "$url")"
    local script_path="$SCRIPT_DIR/core_scripts/$script_name"

    # 已存在则检查是否需要更新（24小时内不重复下载）
    if [[ -f "$script_path" ]]; then
        local file_age
        file_age=$(( $(date +%s) - $(stat -c%Y "$script_path" 2>/dev/null || echo 0) ))
        if [[ "$file_age" -lt 86400 ]]; then
            log "脚本缓存有效（${file_age}秒前下载）: $script_path"
            echo "$script_path"
            return 0
        else
            echo "脚本缓存已过期（超过24小时），重新下载..."
            rm -f "$script_path"
        fi
    fi

    # 网络检测（首次）
    if [[ "$DIRECT_OK" -eq 0 ]]; then
        echo -n "检测网络连通性... "
        if check_network; then
            echo "直连可用"
        else
            echo "直连不可用，将使用代理"
        fi
    fi

    # ✅ 重组下载 URL 列表（直连 + 多代理）
    local urls_to_try=()
    if [[ "$DIRECT_OK" -eq 1 ]]; then
        urls_to_try+=("$url")
    fi
    if [[ "$url" == https://raw.githubusercontent.com/* ]]; then
        for proxy in "${PROXY_PREFIXES[@]}"; do
            urls_to_try+=("${proxy}${url}")
        done
    fi

    # 按优先级尝试下载
    local attempt=0
    for try_url in "${urls_to_try[@]}"; do
        for ((i=1; i<=RETRY_COUNT; i++)); do
            attempt=$((attempt + 1))
            echo "下载尝试 $attempt: $try_url" >&2
            if curl -fsSL --max-time 30 "$try_url" -o "$script_path" 2>/dev/null; then
                # ✅ 完整性校验：检查文件非空且有 shebang
                if [[ -s "$script_path" ]]; then
                    local first_line
                    first_line=$(head -1 "$script_path" 2>/dev/null)
                    if [[ "$first_line" =~ ^#! ]]; then
                        chmod +x "$script_path"
                        log "下载成功: $script_path (来源: $try_url)"
                        echo "$script_path"
                        return 0
                    else
                        echo "文件内容异常（无 shebang），放弃此 URL" >&2
                        rm -f "$script_path"
                    fi
                else
                    echo "下载文件为空，重试..." >&2
                    rm -f "$script_path"
                fi
            fi
            [[ $i -lt $RETRY_COUNT ]] && sleep 2
        done
    done

    echo "所有 URL 均下载失败，请检查网络或 URL：$url" >&2
    log "下载失败: $url"
    return 1
}

# ============================================================
# 运行脚本（✅ 修复：正确捕获脚本退出码，不被 tee 覆盖）
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

    # ✅ 使用 PIPESTATUS 捕获实际脚本退出码，不是 tee 的退出码
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
# 快捷键管理（完整保留原有功能，略去重复代码）
# ============================================================
get_symlink_dir() {
    # ✅ 提取为独立函数，避免在 manage_current_script_symlink
    #    和 bind_script_to_shortcut 中重复相同的目录探测逻辑
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

        # ✅ 校验是否为可执行脚本
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
# 菜单管理（✅ 修复：去重逻辑改用关联数组）
# ============================================================
declare -A DEFAULT_SCRIPTS=(
    ["1"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker.sh"
    ["2"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/deploy_containers.sh"
    ["3"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_tools.sh"
    ["4"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/clean-system.sh"
    ["5"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/device_info.sh"
    ["6"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-adg.sh"
    ["7"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-alist.sh"
    ["8"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-nexterm.sh"
    ["9"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-openapi.sh"
    ["10"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/singbox-manager.sh"
    ["11"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-subc.sh"
    ["12"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/set-dns.sh"
    ["13"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_mosdns.sh"
    ["14"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/cloudflared-deploy.sh"
    ["15"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/sub-store-deploy.sh"
    ["16"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_siyuan.sh"
    ["17"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/docker_sunpanel.sh"
    ["18"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/manage_openwrt.sh"
    ["19"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup_cronjob.sh"
    ["20"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/wifi-hotspot.sh"
    ["21"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/4G-UFI_sim.sh"
    ["22"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/pve-zfsswap.sh"
    ["23"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup_tun.sh"
    ["24"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/disk_repair_tool.sh"
    ["25"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/auto_disk_mounter.sh"
    ["26"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/dae_manager.sh"
    ["27"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/netconfig.sh"
    ["28"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/casaos_installer.sh"
    ["29"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/disk_speed_test.sh"
    ["30"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-nezha.sh"
    ["31"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_singbox_docker.sh"
    ["32"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-sing-box-mihomo.sh"
    ["33"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker_ddns_go.sh"
    ["34"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/uninstall_histb.sh"
    ["35"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker_lucky.sh"
    ["36"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup-dae.sh"
    ["37"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-caddy.sh"
    ["38"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-rustdesk.sh"
    ["39"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/openwrt_mac.sh"
    ["40"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/ql.sh"
    ["41"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/ipwg.sh"
    ["42"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-deploy_frigate.sh"
    ["43"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/Shinobi.sh"
    ["44"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/pve_smart_migration.sh"
    ["45"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup_swap.sh"
)

DEFAULT_OPTIONS=(
    "1. 安装 Docker"
    "2. SSH 工具 & 测速容器"
    "3. 安装常用工具"
    "4. 清理系统垃圾"
    "5. 获取设备信息"
    "6. 安装 AdGuard Home"
    "7. 安装 Alist"
    "8. 安装 NexTerm"
    "9. 安装 OpenAPI"
    "10. 安装 Sing-box"
    "11. 安装 Subconverter"
    "12. 设置 DNS"
    "13. 安装 MosDNS"
    "14. 安装 cloudflared"
    "15. 部署 Sub-Store"
    "16. 安装 思源笔记"
    "17. 安装 Sun-Panel"
    "18. 安装 docker版OpenWrt"
    "19. 配置定时任务"
    "20. 设置 WiFi 热点"
    "21. 4G-UFI 切卡管理"
    "22. 设置 虚拟内存"
    "23. 开启 tun模式"
    "24. 设备硬盘修复设置格式工具"
    "25. 自动挂载外置硬盘"
    "26. 安装dae(大鹅代理)"
    "27. openwrt网口配置"
    "28. casaos部署"
    "29. 硬盘测速"
    "30. 哪吒探针部署"
    "31. 在docker部署sing-box和mihomo"
    "32. 安装裸核sing-box和mihomo"
    "33. 安装docker版ddns-go"
    "34. 海纳思内置卸载"
    "35. 安装docker版lucky"
    "36. dae(大鹅代理)配置"
    "37. 开启caddy反代功能"
    "38. docker部署rustdesk远程控制"
    "39. openwrt固定MAC"
    "40. 安装docker版青龙面板"
    "41. 设备网关设置"
    "42. 部署监控存盘到局域网服务器01"
    "43. 部署监控存盘到局域网服务器02"
    "44. PVE智能存储迁移脚本"
    "45. OP系统虚拟内存设置"
    "98. 快捷键管理"
)

declare -A SCRIPTS=()
declare -A CUSTOM_SCRIPT_NAMES=()
OPTIONS=()

get_next_custom_menu_id() {
    local max_id=0
    # 扫描默认选项最大编号
    for opt in "${DEFAULT_OPTIONS[@]}"; do
        local num="${opt%%.*}"
        [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -gt "$max_id" ]] && max_id="$num"
    done
    # 扫描自定义菜单最大编号
    while IFS='|' read -r id _rest; do
        [[ "$id" =~ ^[0-9]+$ ]] && [[ "$id" -gt "$max_id" ]] && max_id="$id"
    done < <(grep -v '^#' "$CUSTOM_MENU_FILE" 2>/dev/null | grep -v '^$')
    echo $((max_id + 1))
}

load_menu() {
    OPTIONS=()
    SCRIPTS=()
    CUSTOM_SCRIPT_NAMES=()
    # ✅ 用关联数组去重，替代不可靠的字符串 =~ 匹配
    declare -A seen_ids=()

    # 加载默认选项
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

    # 加载自定义菜单项
    while IFS='|' read -r id name url script_name; do
        [[ -z "$id" || "$id" == \#* ]] && continue
        [[ -n "${seen_ids[$id]+_}" ]] && continue
        seen_ids["$id"]=1
        OPTIONS+=("${id}. ${name}")
        SCRIPTS["$id"]="$url"
        CUSTOM_SCRIPT_NAMES["$id"]="$script_name"
    done < <(grep -v '^#' "$CUSTOM_MENU_FILE" 2>/dev/null | grep -v '^$')

    # 排序
    IFS=$'\n' OPTIONS=($(
        for opt in "${OPTIONS[@]}"; do echo "$opt"; done | sort -t. -k1 -n
    ))
    unset IFS

    # 特殊项（保证末尾且唯一）
    if [[ -z "${seen_ids[99]+_}" ]]; then
        OPTIONS+=("99. 管理自定义菜单")
        SCRIPTS["99"]=""
    fi
    if [[ -z "${seen_ids[0]+_}" ]]; then
        OPTIONS+=("0. 退出")
        SCRIPTS["0"]=""
    fi
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

                # ✅ 名称中含 | 会破坏文件格式，需转义
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

# ============================================================
# 打印菜单
# ============================================================
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
    # 初始化
    init_dirs || exit 1
    check_and_install_deps || exit 1

    # ✅ 仅首次运行时设置快捷键
    add_script_shortcut

    while true; do
        load_menu
        print_menu
        read -rp "请输入选项编号: " choice

        case "$choice" in
            0) echo "再见！"; exit 0 ;;
            98) manage_symlink ;;
            99) manage_custom_menu ;;
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
                    # ✅ 不在管道中调用，避免 set -e 误杀
                    script_path="$(download_script "$choice")"
                    if [[ $? -eq 0 && -n "$script_path" ]]; then
                        run_script "$script_path"
                        echo ""
                        read -rp "按回车键返回主菜单..."
                    else
                        echo "❌ 下载失败，请检查网络"
                        log "下载失败: choice=$choice"
                        read -rp "按回车键返回主菜单..."
                    fi
                else
                    echo "无效选项：$choice"
                    sleep 1
                fi
                ;;
        esac
    done
}

main