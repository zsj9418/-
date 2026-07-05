#!/bin/bash
set -euo pipefail

# ============================================================
# 一键 DNS 设置脚本（安全版）
# 特性：先备份 → 检测网络 → 确认后再修改 → 支持一键回滚
# ============================================================

# 定义颜色输出
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
blue()   { echo -e "\033[36m$*\033[0m"; }

# 默认 DNS 设置
DNS_CHINA_DEFAULT="223.5.5.5"
DNS_GLOBAL_DEFAULT="8.8.8.8"

# 备份相关路径
BACKUP_DIR="/etc/dns-backup"
BACKUP_RESOLV="$BACKUP_DIR/resolv.conf.original"
BACKUP_INFO="$BACKUP_DIR/network-info.txt"
BACKUP_TIMESTAMP="$BACKUP_DIR/backup-timestamp"
LOG_FILE="/var/log/set_dns.log"

# ============================================================
# 基础工具函数
# ============================================================

init_log() {
    if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
        LOG_FILE="/tmp/set_dns.log"
    fi
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

separator() {
    echo ""
    echo "============================================================"
    echo ""
}

# 获取系统类型
get_os_type() {
    local os="unsupported"
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            ubuntu|debian)       os="ubuntu/debian" ;;
            centos|rhel|fedora)  os="centos" ;;
            arch)                os="arch" ;;
            alpine)              os="alpine" ;;
        esac
    fi
    echo "$os"
}

# 验证 IP 地址合法性
validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # 检查每个段是否在 0-255 范围内
        IFS='.' read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# 确认操作
confirm() {
    local msg="${1:-确认继续？}"
    local default="${2:-n}"
    local prompt

    if [[ "$default" == "y" ]]; then
        prompt="$msg [Y/n]: "
    else
        prompt="$msg [y/N]: "
    fi

    read -r -p "$prompt" answer
    answer="${answer:-$default}"

    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# 核心功能：网络信息采集
# ============================================================

# 获取当前完整网络信息
collect_network_info() {
    yellow "📡 正在采集当前网络信息..."
    echo ""

    local info=""

    # 采集时间
    info+="采集时间:       $(date '+%Y-%m-%d %H:%M:%S %Z')\n"
    info+="系统时间区:     $(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '未知')\n"
    info+="\n"

    # 当前 DNS
    info+="当前 DNS 配置:\n"
    if [[ -f /etc/resolv.conf ]]; then
        while IFS= read -r line; do
            info+="  $line\n"
        done < /etc/resolv.conf
    else
        info+="  /etc/resolv.conf 不存在\n"
    fi
    info+="\n"

    # IPv4 地址（多种方式获取）
    local ipv4=""
    ipv4=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || \
           curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || \
           curl -4 -s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null || \
           echo "获取失败")
    info+="IPv4 地址:      $ipv4\n"

    # IPv6 地址
    local ipv6=""
    ipv6=$(curl -6 -s --max-time 5 https://ifconfig.me 2>/dev/null || \
           curl -6 -s --max-time 5 https://api6.ipify.org 2>/dev/null || \
           echo "无IPv6或获取失败")
    info+="IPv6 地址:      $ipv6\n"

    # 网络接口信息
    info+="\n网络接口信息:\n"
    if command -v ip &>/dev/null; then
        while IFS= read -r line; do
            info+="  $line\n"
        done <<< "$(ip -4 addr show scope global 2>/dev/null | grep -E 'inet |^[0-9]' || echo '  无法获取')"
    fi

    # 默认网关
    local gateway=""
    gateway=$(ip route show default 2>/dev/null | head -n1 || echo "无法获取")
    info+="\n默认网关:       $gateway\n"

    # 当前活动连接
    if command -v nmcli &>/dev/null; then
        info+="\nNetworkManager 活动连接:\n"
        while IFS= read -r line; do
            info+="  $line\n"
        done <<< "$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null || echo '  无活动连接')"
    fi

    # resolv.conf 类型检测（是否为符号链接）
    info+="\n/etc/resolv.conf 类型:\n"
    if [[ -L /etc/resolv.conf ]]; then
        local link_target
        link_target=$(readlink -f /etc/resolv.conf)
        info+="  符号链接 → $link_target\n"
        info+="  (可能由 systemd-resolved 管理)\n"
    elif [[ -f /etc/resolv.conf ]]; then
        info+="  普通文件\n"
    else
        info+="  不存在\n"
    fi

    # systemd-resolved 状态
    if command -v resolvectl &>/dev/null; then
        info+="\nsystemd-resolved 状态:\n"
        while IFS= read -r line; do
            info+="  $line\n"
        done <<< "$(resolvectl status 2>/dev/null | head -20 || echo '  无法获取')"
    fi

    echo -e "$info"
    # 返回信息供保存使用
    COLLECTED_INFO="$info"
}

# ============================================================
# 核心功能：备份
# ============================================================

backup_current_dns() {
    yellow "💾 正在备份当前 DNS 配置..."
    echo ""

    # 创建备份目录
    sudo mkdir -p "$BACKUP_DIR"

    # 检查是否已有备份
    if [[ -f "$BACKUP_RESOLV" ]]; then
        yellow "⚠️  检测到已有备份文件："
        echo "  备份时间: $(cat "$BACKUP_TIMESTAMP" 2>/dev/null || echo '未知')"
        echo "  备份内容:"
        sed 's/^/    /' "$BACKUP_RESOLV"
        echo ""

        if confirm "是否覆盖已有备份？（选 n 将保留旧备份）" "n"; then
            # 先把旧备份再存一份带时间戳的
            local old_ts
            old_ts=$(cat "$BACKUP_TIMESTAMP" 2>/dev/null | tr ' :' '_-' || echo "unknown")
            sudo cp "$BACKUP_RESOLV" "$BACKUP_DIR/resolv.conf.${old_ts}"
            yellow "旧备份已另存为: $BACKUP_DIR/resolv.conf.${old_ts}"
        else
            green "保留已有备份，跳过备份步骤。"
            return 0
        fi
    fi

    # 备份 resolv.conf
    if [[ -f /etc/resolv.conf ]]; then
        # 如果是符号链接，备份实际内容
        if [[ -L /etc/resolv.conf ]]; then
            sudo cp --dereference /etc/resolv.conf "$BACKUP_RESOLV"
            echo "$(readlink -f /etc/resolv.conf)" | sudo tee "$BACKUP_DIR/resolv-link-target" > /dev/null
        else
            sudo cp /etc/resolv.conf "$BACKUP_RESOLV"
        fi
    fi

    # 保存完整网络信息
    echo -e "$COLLECTED_INFO" | sudo tee "$BACKUP_INFO" > /dev/null

    # 记录备份时间
    date '+%Y-%m-%d %H:%M:%S' | sudo tee "$BACKUP_TIMESTAMP" > /dev/null

    # 备份 NetworkManager 连接配置（如果使用）
    if command -v nmcli &>/dev/null; then
        local conn_name
        conn_name=$(nmcli -t -f NAME connection show --active 2>/dev/null | head -n1 || echo "")
        if [[ -n "$conn_name" ]]; then
            local current_dns
            current_dns=$(nmcli -t -f ipv4.dns connection show "$conn_name" 2>/dev/null || echo "")
            echo "$conn_name" | sudo tee "$BACKUP_DIR/nm-connection-name" > /dev/null
            echo "$current_dns" | sudo tee "$BACKUP_DIR/nm-dns-config" > /dev/null
        fi
    fi

    green "✅ 备份完成！"
    echo "  备份目录: $BACKUP_DIR"
    echo "  备份文件:"
    ls -la "$BACKUP_DIR/" 2>/dev/null | tail -n +2 | sed 's/^/    /'
    echo ""
}

# ============================================================
# 核心功能：网络连通性测试
# ============================================================

test_network() {
    yellow "🌐 正在测试网络连通性..."
    echo ""

    local all_ok=true
    local results=""

    # 测试项目
    declare -A test_targets=(
        ["本地DNS解析"]="ping -c 1 -W 3 localhost"
        ["局域网网关"]="ping -c 1 -W 3 $(ip route show default 2>/dev/null | awk '{print $3}' | head -n1)"
        ["国内HTTP(百度)"]="curl -4 --max-time 5 --output /dev/null --silent --head --fail https://www.baidu.com"
        ["国外HTTP(谷歌)"]="curl -4 --max-time 5 --output /dev/null --silent --head --fail https://www.google.com"
        ["DNS解析测试(国内)"]="nslookup baidu.com 2>/dev/null | grep -q 'Address'"
        ["DNS解析测试(国外)"]="nslookup google.com 2>/dev/null | grep -q 'Address'"
    )

    # 按顺序测试
    local order=("本地DNS解析" "局域网网关" "DNS解析测试(国内)" "DNS解析测试(国外)" "国内HTTP(百度)" "国外HTTP(谷歌)")

    for name in "${order[@]}"; do
        local cmd="${test_targets[$name]:-}"
        if [[ -z "$cmd" ]]; then
            continue
        fi

        printf "  %-25s " "$name"

        if eval "$cmd" 2>/dev/null; then
            green "✅ 正常"
        else
            red "❌ 失败"
            all_ok=false
        fi
    done

    echo ""

    if $all_ok; then
        green "🎉 所有网络测试通过！"
    else
        yellow "⚠️  部分网络测试未通过，请注意检查。"
    fi

    return 0
}

# 快速网络检测（仅检测是否能上网，不输出详细信息）
quick_network_check() {
    if ping -c 1 -W 3 "$(ip route show default 2>/dev/null | awk '{print $3}' | head -n1)" &>/dev/null; then
        return 0  # 网关可达
    fi
    return 1  # 网关不可达
}

# ============================================================
# 核心功能：设置 DNS
# ============================================================

set_dns() {
    local dns_china="${1:-$DNS_CHINA_DEFAULT}"
    local dns_global="${2:-$DNS_GLOBAL_DEFAULT}"

    # 验证 DNS 地址
    if ! validate_ip "$dns_china"; then
        red "❌ 无效的国内 DNS 地址: $dns_china"
        return 1
    fi
    if ! validate_ip "$dns_global"; then
        red "❌ 无效的国外 DNS 地址: $dns_global"
        return 1
    fi

    local os_type
    os_type=$(get_os_type)

    yellow "📝 即将设置 DNS："
    echo "  国内 DNS: $dns_china"
    echo "  国外 DNS: $dns_global"
    echo "  系统类型: $os_type"
    echo ""

    # 检测 systemd-resolved
    local use_resolved=false
    if systemctl is-active systemd-resolved &>/dev/null; then
        use_resolved=true
        yellow "检测到 systemd-resolved 正在运行"
    fi

    case "$os_type" in
        "ubuntu/debian"|"arch")
            if $use_resolved; then
                # 使用 systemd-resolved 的方式设置
                yellow "通过 systemd-resolved 设置 DNS..."

                # 创建或修改 resolved 配置
                sudo mkdir -p /etc/systemd/resolved.conf.d/
                sudo tee /etc/systemd/resolved.conf.d/custom-dns.conf > /dev/null <<EOF
[Resolve]
DNS=$dns_china $dns_global
FallbackDNS=114.114.114.114 1.1.1.1
EOF
                sudo systemctl restart systemd-resolved

                # 确保 resolv.conf 指向 resolved
                if [[ ! -L /etc/resolv.conf ]] || [[ "$(readlink -f /etc/resolv.conf)" != "/run/systemd/resolve/stub-resolv.conf" ]]; then
                    yellow "修复 resolv.conf 链接..."
                    sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
                fi
            else
                # 直接修改 resolv.conf
                yellow "直接修改 /etc/resolv.conf..."
                sudo tee /etc/resolv.conf > /dev/null <<EOF
# DNS 由 set_dns 脚本设置 - $(date '+%Y-%m-%d %H:%M:%S')
# 原始备份位于: $BACKUP_DIR
nameserver $dns_china
nameserver $dns_global
EOF
            fi
            ;;

        "centos")
            if command -v nmcli &>/dev/null; then
                local conn_name
                conn_name=$(nmcli -t -f NAME connection show --active 2>/dev/null | head -n1 || echo "")
                if [[ -z "$conn_name" ]]; then
                    red "❌ 未找到活动的网络连接！"
                    return 1
                fi
                yellow "通过 NetworkManager 设置 DNS (连接: $conn_name)..."
                nmcli connection modify "$conn_name" ipv4.dns "$dns_china,$dns_global"
                nmcli connection modify "$conn_name" ipv4.ignore-auto-dns yes
                nmcli connection up "$conn_name"
            else
                # 回退到直接修改 resolv.conf
                sudo tee /etc/resolv.conf > /dev/null <<EOF
# DNS 由 set_dns 脚本设置 - $(date '+%Y-%m-%d %H:%M:%S')
nameserver $dns_china
nameserver $dns_global
EOF
            fi
            ;;

        "alpine")
            sudo tee /etc/resolv.conf > /dev/null <<EOF
# DNS 由 set_dns 脚本设置 - $(date '+%Y-%m-%d %H:%M:%S')
nameserver $dns_china
nameserver $dns_global
EOF
            ;;

        *)
            red "❌ 不支持的系统类型: $os_type"
            return 1
            ;;
    esac

    green "✅ DNS 已设置完成！"
    echo ""

    # 显示当前实际 DNS
    yellow "当前生效的 DNS 配置："
    if command -v resolvectl &>/dev/null && systemctl is-active systemd-resolved &>/dev/null; then
        resolvectl status 2>/dev/null | grep -A5 "DNS Server" | head -6 | sed 's/^/  /'
    else
        grep nameserver /etc/resolv.conf 2>/dev/null | sed 's/^/  /'
    fi
    echo ""
}

# ============================================================
# 核心功能：回滚恢复
# ============================================================

rollback_dns() {
    yellow "🔄 正在恢复 DNS 配置..."
    echo ""

    if [[ ! -d "$BACKUP_DIR" ]] || [[ ! -f "$BACKUP_RESOLV" ]]; then
        red "❌ 未找到备份文件！无法回滚。"
        echo "  备份目录: $BACKUP_DIR"
        return 1
    fi

    echo "备份时间: $(cat "$BACKUP_TIMESTAMP" 2>/dev/null || echo '未知')"
    echo "备份内容:"
    sed 's/^/  /' "$BACKUP_RESOLV"
    echo ""

    if ! confirm "确认恢复到备份的 DNS 配置？" "y"; then
        yellow "取消回滚。"
        return 0
    fi

    local os_type
    os_type=$(get_os_type)

    case "$os_type" in
        "ubuntu/debian"|"arch")
            if systemctl is-active systemd-resolved &>/dev/null; then
                # 移除自定义 resolved 配置
                if [[ -f /etc/systemd/resolved.conf.d/custom-dns.conf ]]; then
                    sudo rm -f /etc/systemd/resolved.conf.d/custom-dns.conf
                    sudo systemctl restart systemd-resolved
                fi
                # 恢复 resolv.conf 链接
                if [[ -f "$BACKUP_DIR/resolv-link-target" ]]; then
                    local link_target
                    link_target=$(cat "$BACKUP_DIR/resolv-link-target")
                    sudo ln -sf "$link_target" /etc/resolv.conf
                fi
            else
                sudo cp "$BACKUP_RESOLV" /etc/resolv.conf
            fi
            ;;

        "centos")
            if command -v nmcli &>/dev/null && [[ -f "$BACKUP_DIR/nm-connection-name" ]]; then
                local conn_name
                conn_name=$(cat "$BACKUP_DIR/nm-connection-name")
                local old_dns
                old_dns=$(cat "$BACKUP_DIR/nm-dns-config" | sed 's/ipv4.dns://')

                if [[ -n "$old_dns" && "$old_dns" != " " ]]; then
                    nmcli connection modify "$conn_name" ipv4.dns "$old_dns"
                else
                    nmcli connection modify "$conn_name" ipv4.dns ""
                    nmcli connection modify "$conn_name" ipv4.ignore-auto-dns no
                fi
                nmcli connection up "$conn_name"
            else
                sudo cp "$BACKUP_RESOLV" /etc/resolv.conf
            fi
            ;;

        "alpine"|*)
            sudo cp "$BACKUP_RESOLV" /etc/resolv.conf
            ;;
    esac

    green "✅ DNS 配置已恢复！"
    echo ""

    yellow "恢复后的 DNS 配置："
    grep nameserver /etc/resolv.conf 2>/dev/null | sed 's/^/  /' || echo "  无法读取"
    echo ""
}

# ============================================================
# 核心功能：查看备份信息
# ============================================================

show_backup_info() {
    yellow "📋 备份信息："
    echo ""

    if [[ ! -d "$BACKUP_DIR" ]]; then
        red "未找到任何备份。"
        return 1
    fi

    if [[ -f "$BACKUP_TIMESTAMP" ]]; then
        echo "备份时间: $(cat "$BACKUP_TIMESTAMP")"
    fi
    echo "备份目录: $BACKUP_DIR"
    echo ""

    if [[ -f "$BACKUP_RESOLV" ]]; then
        yellow "原始 resolv.conf 内容："
        sed 's/^/  /' "$BACKUP_RESOLV"
        echo ""
    fi

    if [[ -f "$BACKUP_INFO" ]]; then
        yellow "备份时的完整网络信息："
        sed 's/^/  /' "$BACKUP_INFO"
    fi

    echo ""
    yellow "当前 DNS 配置（对比）："
    if [[ -f /etc/resolv.conf ]]; then
        sed 's/^/  /' /etc/resolv.conf
    fi
    echo ""
}

# ============================================================
# 交互式菜单
# ============================================================

show_menu() {
    echo ""
    blue "╔══════════════════════════════════════════════╗"
    blue "║       🛡️  安全 DNS 设置工具 v2.0             ║"
    blue "╠══════════════════════════════════════════════╣"
    blue "║                                              ║"
    blue "║  1) 📡 查看当前网络信息                      ║"
    blue "║  2) 🌐 测试网络连通性                        ║"
    blue "║  3) 💾 仅备份当前 DNS（不修改）              ║"
    blue "║  4) ⚙️  设置 DNS（自动先备份）                ║"
    blue "║  5) 🔄 回滚恢复原始 DNS                      ║"
    blue "║  6) 📋 查看备份信息                          ║"
    blue "║  7) 🚀 一键操作（备份→设置→测试）            ║"
    blue "║  0) 退出                                     ║"
    blue "║                                              ║"
    blue "╚══════════════════════════════════════════════╝"
    echo ""
}

# ============================================================
# 各菜单选项的处理函数
# ============================================================

menu_view_network() {
    separator
    collect_network_info
    separator
}

menu_test_network() {
    separator
    test_network
    separator
}

menu_backup_only() {
    separator
    collect_network_info
    backup_current_dns
    green "仅执行了备份，未修改任何 DNS 设置。"
    separator
}

menu_set_dns() {
    separator

    # 第一步：显示当前网络
    yellow "📌 第一步：查看当前网络状态"
    collect_network_info

    separator

    # 第二步：备份
    yellow "📌 第二步：备份当前配置"
    if ! confirm "是否备份当前 DNS 配置？（强烈建议）" "y"; then
        yellow "⚠️  跳过备份，风险自担！"
        if ! confirm "确定不备份就修改 DNS？" "n"; then
            yellow "取消操作。"
            return
        fi
    else
        backup_current_dns
    fi

    separator

    # 第三步：输入新 DNS
    yellow "📌 第三步：设置新的 DNS"
    echo ""
    echo "常用 DNS 参考："
    echo "  国内: 223.5.5.5 (阿里) | 119.29.29.29 (腾讯) | 114.114.114.114"
    echo "  国外: 8.8.8.8 (Google) | 1.1.1.1 (Cloudflare) | 208.67.222.222 (OpenDNS)"
    echo ""

    local dns_china dns_global

    read -r -p "请输入国内 DNS 地址（默认: $DNS_CHINA_DEFAULT，回车使用默认）：" dns_china
    dns_china="${dns_china:-$DNS_CHINA_DEFAULT}"

    read -r -p "请输入国外 DNS 地址（默认: $DNS_GLOBAL_DEFAULT，回车使用默认）：" dns_global
    dns_global="${dns_global:-$DNS_GLOBAL_DEFAULT}"

    echo ""
    yellow "即将设置："
    echo "  国内 DNS: $dns_china"
    echo "  国外 DNS: $dns_global"
    echo ""

    if ! confirm "确认修改 DNS？" "y"; then
        yellow "取消修改。"
        return
    fi

    set_dns "$dns_china" "$dns_global"

    # 第四步：验证
    separator
    yellow "📌 第四步：验证修改结果"
    if confirm "是否立即测试网络连通性？" "y"; then
        test_network

        echo ""
        if ! confirm "网络是否正常？（如果异常请选 n 立即回滚）" "y"; then
            red "⚠️  网络异常！正在自动回滚..."
            rollback_dns
            test_network
        fi
    fi

    separator
}

menu_rollback() {
    separator
    rollback_dns

    if confirm "是否测试恢复后的网络连通性？" "y"; then
        test_network
    fi
    separator
}

menu_show_backup() {
    separator
    show_backup_info
    separator
}

menu_one_click() {
    separator
    yellow "🚀 一键操作模式：备份 → 设置 DNS → 测试网络"
    echo ""

    # 1. 采集信息
    yellow "━━━ 步骤 1/4: 采集当前网络信息 ━━━"
    collect_network_info

    separator

    # 2. 检测当前网络
    yellow "━━━ 步骤 2/4: 检测当前网络状态 ━━━"
    test_network

    # 如果当前网络就不通，提醒用户
    if ! quick_network_check; then
        echo ""
        red "⚠️  警告：当前网关不可达，你的网络本身可能存在问题！"
        yellow "这可能是路由器/网络设备的问题，修改 DNS 可能无法解决。"
        echo ""
        if ! confirm "仍然继续修改 DNS？" "n"; then
            yellow "取消操作。建议先检查路由器和物理网络连接。"
            return
        fi
    fi

    separator

    # 3. 备份
    yellow "━━━ 步骤 3/4: 备份当前 DNS 配置 ━━━"
    backup_current_dns

    separator

    # 4. 设置 DNS
    yellow "━━━ 步骤 4/4: 设置新 DNS 并验证 ━━━"
    echo ""
    echo "将使用默认 DNS："
    echo "  国内: $DNS_CHINA_DEFAULT (阿里)"
    echo "  国外: $DNS_GLOBAL_DEFAULT (Google)"
    echo ""

    if ! confirm "使用以上默认 DNS？（选 n 可自定义输入）" "y"; then
        local dns_china dns_global
        read -r -p "国内 DNS: " dns_china
        read -r -p "国外 DNS: " dns_global
        dns_china="${dns_china:-$DNS_CHINA_DEFAULT}"
        dns_global="${dns_global:-$DNS_GLOBAL_DEFAULT}"
        set_dns "$dns_china" "$dns_global"
    else
        set_dns "$DNS_CHINA_DEFAULT" "$DNS_GLOBAL_DEFAULT"
    fi

    echo ""
    yellow "修改后网络测试："
    test_network

    echo ""
    if ! confirm "网络是否正常？（选 n 将立即回滚恢复）" "y"; then
        red "正在回滚..."
        rollback_dns
        echo ""
        yellow "回滚后网络测试："
        test_network
    else
        green "🎉 DNS 设置完成！一切正常！"
    fi

    separator
}

# ============================================================
# 命令行参数支持
# ============================================================

show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --info        查看当前网络信息"
    echo "  --test        测试网络连通性"
    echo "  --backup      仅备份当前 DNS"
    echo "  --set [国内DNS] [国外DNS]  设置 DNS"
    echo "  --rollback    回滚恢复原始 DNS"
    echo "  --show-backup 查看备份信息"
    echo "  --auto        一键自动操作"
    echo "  --help        显示帮助"
    echo ""
    echo "示例:"
    echo "  $0                          # 交互式菜单"
    echo "  $0 --backup                 # 仅备份"
    echo "  $0 --set 223.5.5.5 8.8.8.8  # 设置指定 DNS"
    echo "  $0 --rollback               # 回滚恢复"
}

# ============================================================
# 主流程
# ============================================================

main() {
    init_log

    # 处理命令行参数
    if [[ $# -gt 0 ]]; then
        case "$1" in
            --info)
                collect_network_info
                ;;
            --test)
                test_network
                ;;
            --backup)
                collect_network_info
                backup_current_dns
                ;;
            --set)
                COLLECTED_INFO="(命令行模式)"
                collect_network_info
                backup_current_dns
                set_dns "${2:-$DNS_CHINA_DEFAULT}" "${3:-$DNS_GLOBAL_DEFAULT}"
                test_network
                ;;
            --rollback)
                rollback_dns
                ;;
            --show-backup)
                show_backup_info
                ;;
            --auto)
                menu_one_click
                ;;
            --help|-h)
                show_help
                ;;
            *)
                red "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
        exit 0
    fi

    # 交互式菜单
    COLLECTED_INFO=""

    while true; do
        show_menu
        read -r -p "请选择操作 [0-7]: " choice

        case "$choice" in
            1) menu_view_network ;;
            2) menu_test_network ;;
            3) menu_backup_only ;;
            4) menu_set_dns ;;
            5) menu_rollback ;;
            6) menu_show_backup ;;
            7) menu_one_click ;;
            0)
                green "再见！"
                exit 0
                ;;
            *)
                red "无效选择，请输入 0-7"
                ;;
        esac
    done
}

main "$@"
