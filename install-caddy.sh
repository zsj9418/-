#!/bin/bash

# 可配置变量
: ${CADDY_BIN_PATH:="/usr/local/bin/caddy"}
: ${CADDY_CONF_DIR:="/etc/caddy"}
: ${CADDY_CONF_FILE:="$CADDY_CONF_DIR/Caddyfile"}
: ${CADDY_LOG_DIR:="/var/log/caddy"}
: ${CADDY_USER:="www-data"}
: ${STATE_FILE:="${XDG_RUNTIME_DIR:-/tmp}/deploy_state"}
: ${UHTTPD_CONF_FILE:="/etc/config/uhttpd"}

# 架构映射
declare -A ARCH_MAP=(
    ["x86_64"]="amd64"
    ["aarch64"]="arm64"
    ["armv7l"]="armv7"
    ["armv6l"]="armv6"
    ["i686"]="386"
    ["ppc64le"]="ppc64le"
    ["riscv64"]="riscv64"
    ["mips"]="mips"
    ["mips64"]="mips64"
    ["mipsel"]="mipsle"
    ["mips64el"]="mips64le"
)

# 命令与包名映射
declare -A CMD_PKG_MAP=(
    ["netstat"]="net-tools"
    ["ss"]="iproute2"
    ["ps"]="procps-ng"
    ["wget"]="wget"
    ["curl"]="curl"
    ["awk"]="awk"
    ["sed"]="sed"
    ["tar"]="tar"
)

# 检查是否有sudo
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "警告: 当前用户不是root且未安装sudo，部分操作可能失败。"
        SUDO=""
    fi
fi

# 检测包管理器
detect_package_manager() {
    if command -v opkg >/dev/null 2>&1; then
        PKG_MGR="opkg"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MGR="zypper"
    else
        PKG_MGR=""
    fi
}

# 增强系统检测
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            openwrt) SYSTEM_TYPE="OpenWrt" ;;
            debian|ubuntu) SYSTEM_TYPE="Debian" ;;
            centos|fedora|rhel) SYSTEM_TYPE="RHEL" ;;
            alpine) SYSTEM_TYPE="Alpine" ;;
            *) SYSTEM_TYPE="Other" ;;
        esac

        # 检测init系统
        if [ -d /run/systemd/system ]; then
            INIT_SYSTEM="systemd"
        elif [ -x /sbin/openrc ]; then
            INIT_SYSTEM="openrc"
        elif [ -f /etc/init.d/cron ]; then
            INIT_SYSTEM="sysvinit"
        else
            INIT_SYSTEM="unknown"
        fi
    else
        SYSTEM_TYPE="Unknown"
        INIT_SYSTEM="unknown"
    fi
    detect_package_manager
}

# 服务存在性检测
service_exists() {
    local svc=$1
    if [ "$SYSTEM_TYPE" = "OpenWrt" ]; then
        [ -x "/etc/init.d/$svc" ] && return 0
        pgrep -x "$svc" >/dev/null && return 0
        return 1
    else
        case $INIT_SYSTEM in
            systemd)
                $SUDO systemctl list-unit-files | grep -q "^$svc" && return 0
                ;;
            openrc)
                $SUDO rc-service --exists "$svc" && return 0
                ;;
            sysvinit)
                [ -x "/etc/init.d/$svc" ] && return 0
                ;;
        esac
        return 1
    fi
}

# 获取所有Caddy版本（标签）
get_caddy_versions() {
    curl -s https://api.github.com/repos/caddyserver/caddy/releases | \
    grep -E '"tag_name":' | \
    sed -E 's/.*"tag_name": ?"([^"]+)".*/\1/' | \
    awk '{print NR, $0}'
}

# 用户选择版本
select_caddy_version() {
    echo "可用Caddy版本："
    get_caddy_versions
    echo "请输入要安装的版本编号（如 1）："
    read -r version_index
    version_line=$(get_caddy_versions | sed -n "${version_index}p")
    version_tag=$(echo "$version_line" | awk '{print $2}')
    echo "你选择的版本：$version_tag"
    echo "$version_tag"
}

# 根据架构拼接下载链接
get_caddy_download_url() {
    local version_tag=$1
    local arch
    arch=$(uname -m)
    local mapped_arch=${ARCH_MAP[$arch]:-$arch}
    local version_nov
    version_nov=$(echo "$version_tag" | sed 's/^v//')
    echo "https://github.com/caddyserver/caddy/releases/download/$version_tag/caddy_${version_nov}_linux_${mapped_arch}.tar.gz"
}

# 安装Caddy（支持版本选择）
install_caddy() {
    echo "检测可用Caddy版本..."
    version=$(select_caddy_version)
    if [ -z "$version" ]; then
        echo "未能获取版本信息"
        return 1
    fi

    echo "你选择的版本：$version"
    download_url=$(get_caddy_download_url "$version")
    if [ -z "$download_url" ]; then
        echo "未找到适合架构的版本下载地址" >&2
        return 1
    fi
    echo "下载地址：$download_url"

    mkdir -p "$(dirname "$CADDY_BIN_PATH")"
    mkdir -p "$CADDY_CONF_DIR"
    mkdir -p "$CADDY_LOG_DIR"

    if id "$CADDY_USER" &>/dev/null; then
        $SUDO chown -R "$CADDY_USER":"$CADDY_USER" "$CADDY_CONF_DIR" "$CADDY_LOG_DIR"
    fi

    TMP_DIR="/tmp/caddy_install"
    mkdir -p "$TMP_DIR"
    if ! wget -O "$TMP_DIR/caddy.tar.gz" "$download_url"; then
        echo "下载失败"
        return 1
    fi

    tar -xzf "$TMP_DIR/caddy.tar.gz" -C "$TMP_DIR" || { echo "解压失败"; return 1; }

    if [ -f "$TMP_DIR/caddy" ]; then
        $SUDO cp "$TMP_DIR/caddy" "$CADDY_BIN_PATH" || { echo "复制失败"; return 1; }
        $SUDO chmod +x "$CADDY_BIN_PATH"
    else
        echo "未找到caddy二进制文件"
        return 1
    fi

    rm -rf "$TMP_DIR"
    echo "Caddy已安装到 $CADDY_BIN_PATH"
}

# 检查依赖
check_and_install() {
    local cmd=$1
    local pkg=${CMD_PKG_MAP[$cmd]:-$cmd}
    if ! command -v "$cmd" >/dev/null 2>&1; then
        install_dependencies "$pkg"
    fi
}

# 安装依赖
install_dependencies() {
    local package=$1
    case $PKG_MGR in
        opkg)
            $SUDO opkg update && $SUDO opkg install "$package"
            ;;
        apt)
            $SUDO apt-get update && $SUDO apt-get install -y "$package"
            ;;
        yum)
            $SUDO yum install -y "$package"
            ;;
        dnf)
            $SUDO dnf install -y "$package"
            ;;
        apk)
            $SUDO apk add "$package"
            ;;
        zypper)
            $SUDO zypper install -y "$package"
            ;;
        *)
            echo "未知包管理器，无法自动安装 $package"
            ;;
    esac
}

# 载入状态
load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    else
        SERVICE_STATUS="unknown"
        CADDY_RUNNING=0
    fi
}

# 保存状态
save_state() {
    echo "SERVICE_STATUS='$SERVICE_STATUS'" > "$STATE_FILE"
    echo "CADDY_RUNNING=$CADDY_RUNNING" >> "$STATE_FILE"
}

# 确保配置文件存在
prepare_caddy_config() {
    if [ ! -f "$CADDY_CONF_FILE" ] || [ ! -s "$CADDY_CONF_FILE" ]; then
        echo "配置文件不存在或为空，创建基础配置..."
        mkdir -p "$(dirname "$CADDY_CONF_FILE")"
        echo "# 自动生成的空配置" > "$CADDY_CONF_FILE"
    fi
}

# 格式化配置
format_caddy_config() {
    if command -v caddy >/dev/null 2>&1; then
        caddy fmt --overwrite "$CADDY_CONF_FILE"
    fi
}

# 验证配置
validate_caddy_config() {
    if command -v caddy >/dev/null 2>&1; then
        caddy validate --config "$CADDY_CONF_FILE"
        return $?
    else
        return 1
    fi
}

# 启动caddy
start_caddy() {
    prepare_caddy_config
    if ! validate_caddy_config; then
        echo "配置有误，caddy未启动"
        CADDY_RUNNING=0
        SERVICE_STATUS="caddy"
        save_state
        return 1
    fi
    if ! pgrep -x "caddy" > /dev/null; then
        echo "启动caddy..."
        $SUDO "$CADDY_BIN_PATH" run --config "$CADDY_CONF_FILE" &>/dev/null &
        sleep 3
    fi
    echo "配置验证通过，caddy已启动"
    CADDY_RUNNING=1
    SERVICE_STATUS="caddy"
    save_state
}

# 配置反向代理
configure_caddy() {
    prepare_caddy_config
    echo "配置caddy反向代理..."
    echo "每行输入：域名 目标地址（格式：domain.com 192.168.1.2:端口），空行结束"
    echo "示例："
    echo "example.com 192.168.1.10:8080"
    echo "请输入配置："
    cp "$CADDY_CONF_FILE" "$CADDY_CONF_FILE.bak.$(date +%s)"
    > "$CADDY_CONF_FILE"
    while true; do
        read -rp "输入： " line
        [ -z "$line" ] && break
        domain=$(echo "$line" | awk '{print $1}')
        target=$(echo "$line" | awk '{print $2}')
        if [ -z "$domain" ] || [ -z "$target" ]; then
            echo "格式错误，请重试。"
            continue
        fi
        echo "$domain {
  encode gzip
  reverse_proxy $target
}
" >> "$CADDY_CONF_FILE"
    done
    start_caddy
    echo "配置完成"
}

# 添加新反向代理
add_new_proxy() {
    prepare_caddy_config
    echo "添加新反向代理："
    read -rp "域名： " domain
    read -rp "目标地址（IP:端口）： " target
    if [ -z "$domain" ] || [ -z "$target" ]; then
        echo "输入无效"
        return
    fi
    cp "$CADDY_CONF_FILE" "$CADDY_CONF_FILE.bak.$(date +%s)"
    echo "$domain {
  encode gzip
  reverse_proxy $target
}
" >> "$CADDY_CONF_FILE"
    start_caddy
    echo "已添加"
}

# 查看状态
view_status() {
    echo "系统类型：$SYSTEM_TYPE"
    echo "服务状态：$SERVICE_STATUS"
    echo "Caddy运行：$([ "$CADDY_RUNNING" -eq 1 ] && echo "是" || echo "否")"
    echo "端口占用（80/443/8080）："
    if command -v ss >/dev/null 2>&1; then
        $SUDO ss -tulnp 2>/dev/null | grep -E ':(80|443|8080)\b'
    elif command -v netstat >/dev/null 2>&1; then
        $SUDO netstat -tulnp 2>/dev/null | grep -E ':(80|443|8080)\b'
    fi

    echo "当前运行的端口："
    if pgrep -x "caddy" > /dev/null; then
        echo "Caddy 正在运行，监听端口："
        if command -v ss >/dev/null 2>&1; then
            $SUDO ss -tulnp 2>/dev/null | grep 'caddy' | awk '{print $5}' | rev | cut -d':' -f1 | rev | sort -un
        elif command -v netstat >/dev/null 2>&1; then
            $SUDO netstat -tulnp 2>/dev/null | grep 'caddy' | awk '{print $4}' | rev | cut -d':' -f1 | rev | sort -un
        fi
    fi
    if pgrep -x "uhttpd" > /dev/null; then
        echo "uHTTPd 正在运行，监听端口："
        if command -v ss >/dev/null 2>&1; then
            $SUDO ss -tulnp 2>/dev/null | grep 'uhttpd' | awk '{print $5}' | rev | cut -d':' -f1 | rev | sort -un
        elif command -v netstat >/dev/null 2>&1; then
            $SUDO netstat -tulnp 2>/dev/null | grep 'uhttpd' | awk '{print $4}' | rev | cut -d':' -f1 | rev | sort -un
        fi
    fi
}

# ============================================================
# 查看本机所有端口占用情况（跨平台/跨架构三级降级策略）
# ============================================================
show_port_usage() {
    echo "=============================="
    echo "  本机端口占用情况"
    echo "=============================="

    # ---------- 方法一：ss（iproute2，最推荐） ----------
    if command -v ss >/dev/null 2>&1; then
        echo "【工具: ss (iproute2)】"
        printf "%-6s %-40s %-14s %s\n" "协议" "本地地址:端口" "状态" "PID/程序名"
        printf '%0.s-' {1..80}; echo
        $SUDO ss -tulnp 2>/dev/null | tail -n +2 | while IFS= read -r line; do
            proto=$(echo "$line" | awk '{print $1}')
            state=$(echo "$line" | awk '{print $2}')
            local_addr=$(echo "$line" | awk '{print $5}')
            # 兼容 ss 两种输出格式:
            # 旧版: users:(("nginx",pid=123,fd=6))
            # 新版: users:(("nginx",pid=123,fd=6))
            raw_proc=$(echo "$line" | grep -oE 'users:\(\("[^"]+",pid=[0-9]+,fd=[0-9]+\)\)')
            if [ -n "$raw_proc" ]; then
                pname=$(echo "$raw_proc" | sed 's/users:(("\(.*\)",pid=\([0-9]*\),fd=[0-9]*))/\2\/\1/')
            else
                # 部分精简版ss只输出pid
                pname=$(echo "$line" | awk '{print $NF}')
                [ "$pname" = "$proto" ] && pname="-"
            fi
            printf "%-6s %-40s %-14s %s\n" "$proto" "$local_addr" "$state" "$pname"
        done
        echo ""
        return 0
    fi

    # ---------- 方法二：netstat（net-tools，兼容旧系统） ----------
    if command -v netstat >/dev/null 2>&1; then
        echo "【工具: netstat (net-tools)】"
        printf "%-6s %-40s %-14s %s\n" "协议" "本地地址:端口" "状态" "PID/程序名"
        printf '%0.s-' {1..80}; echo
        $SUDO netstat -tulnp 2>/dev/null | tail -n +3 | while IFS= read -r line; do
            # netstat 列: Proto RefCnt Flags Type State I-Node PID/Program
            # 对于 -tulnp: Proto Recv-Q Send-Q LocalAddr ForeignAddr State PID/Program
            proto=$(echo "$line" | awk '{print $1}')
            local_addr=$(echo "$line" | awk '{print $4}')
            state=$(echo "$line" | awk '{print $6}')
            pid_prog=$(echo "$line" | awk '{print $7}')
            [ -z "$pid_prog" ] && pid_prog="-"
            printf "%-6s %-40s %-14s %s\n" "$proto" "$local_addr" "$state" "$pid_prog"
        done
        echo ""
        return 0
    fi

    # ---------- 方法三：纯 /proc/net/tcp 解析（无需任何外部工具） ----------
    if [ -f /proc/net/tcp ] || [ -f /proc/net/tcp6 ]; then
        echo "【工具: /proc/net/tcp 纯Shell解析 (回退模式)】"
        printf "%-6s %-40s %-14s %s\n" "协议" "本地地址:端口" "状态" "PID/程序名"
        printf '%0.s-' {1..80}; echo

        # ── 构建 inode → PID/程序名 映射表（写入临时文件避免子shell变量丢失）──
        local inode_map_file
        inode_map_file=$(mktemp /tmp/inode_map.XXXXXX)

        for pid_dir in /proc/[0-9]*/fd/; do
            local pid
            pid=$(echo "$pid_dir" | awk -F'/' '{print $3}')
            # 必须有读权限才继续
            [ -r "$pid_dir" ] || continue
            for fd_link in "${pid_dir}"*; do
                [ -L "$fd_link" ] || continue
                local link_target
                link_target=$(readlink "$fd_link" 2>/dev/null) || continue
                case "$link_target" in
                    socket:\[*\])
                        local inode
                        inode=$(echo "$link_target" | sed 's/socket:\[\(.*\)\]/\1/')
                        local comm="-"
                        [ -r "/proc/$pid/comm" ] && comm=$(tr -d '\n' < "/proc/$pid/comm" 2>/dev/null)
                        # 格式: inode pid/comm
                        echo "$inode $pid/$comm" >> "$inode_map_file"
                        ;;
                esac
            done
        done

        # ── 状态码 → 名称 ──
        _tcp_state() {
            case "$1" in
                01) echo "ESTABLISHED" ;;  02) echo "SYN_SENT"   ;;
                03) echo "SYN_RECV"    ;;  04) echo "FIN_WAIT1"  ;;
                05) echo "FIN_WAIT2"   ;;  06) echo "TIME_WAIT"  ;;
                07) echo "CLOSE"       ;;  08) echo "CLOSE_WAIT" ;;
                09) echo "LAST_ACK"    ;;  0A) echo "LISTEN"     ;;
                0B) echo "CLOSING"     ;;   *)  echo "UNKNOWN"   ;;
            esac
        }

        # ── 小端序十六进制IPv4 → 点分十进制 ──
        _hex4_to_ip() {
            # 输入: AABBCCDD (小端序)
            local h=$1
            printf "%d.%d.%d.%d" \
                "0x${h:6:2}" "0x${h:4:2}" "0x${h:2:2}" "0x${h:0:2}"
        }

        # ── 小端序十六进制IPv6 → 标准IPv6 ──
        _hex6_to_ip() {
            # /proc/net/tcp6 每段32bit小端序，共4段，合计128bit
            local raw=$1
            local out=""
            local i=0
            while [ $i -lt 32 ]; do
                local chunk="${raw:$i:8}"
                # 每个32bit块按小端序翻转为4字节
                local be="${chunk:6:2}${chunk:4:2}${chunk:2:2}${chunk:0:2}"
                out="${out}${be:0:4}:${be:4:4}"
                i=$((i+8))
                [ $i -lt 32 ] && out="${out}:"
            done
            echo "$out"
        }

        # ── 解析单个 /proc/net/tcp[6] 文件 ──
        _parse_proc_net() {
            local file=$1
            local proto=$2
            local is_v6=$3   # 1=IPv6, 0=IPv4

            tail -n +2 "$file" 2>/dev/null | \
            while read -r _sl local_hex rem_hex st _tq _rq _tr _tm _re _uid _to inode _rest; do
                local state
                state=$(_tcp_state "$st")
                # 仅显示 LISTEN / ESTABLISHED（可按需去掉过滤）
                local hex_laddr="${local_hex%:*}"
                local hex_lport="${local_hex##*:}"
                local port
                port=$(printf "%d" "0x$hex_lport")
                local ip
                if [ "$is_v6" -eq 1 ]; then
                    ip=$(_hex6_to_ip "$hex_laddr")
                    local_display="[$ip]:$port"
                else
                    ip=$(_hex4_to_ip "$hex_laddr")
                    local_display="$ip:$port"
                fi
                # 查 inode → pid/comm
                local pid_comm="-"
                if [ -f "$inode_map_file" ]; then
                    pid_comm=$(grep "^$inode " "$inode_map_file" 2>/dev/null | head -1 | awk '{print $2}')
                    [ -z "$pid_comm" ] && pid_comm="-"
                fi
                printf "%-6s %-40s %-14s %s\n" "$proto" "$local_display" "$state" "$pid_comm"
            done
        }

        [ -f /proc/net/tcp  ] && _parse_proc_net /proc/net/tcp  "tcp"  0
        [ -f /proc/net/tcp6 ] && _parse_proc_net /proc/net/tcp6 "tcp6" 1
        [ -f /proc/net/udp  ] && _parse_proc_net /proc/net/udp  "udp"  0
        [ -f /proc/net/udp6 ] && _parse_proc_net /proc/net/udp6 "udp6" 1

        rm -f "$inode_map_file"
        echo ""
        return 0
    fi

    # ---------- 全部方法均不可用 ----------
    echo "❌ 无法获取端口信息：ss / netstat / /proc/net/tcp 均不可用。"
    echo "   请安装 iproute2（推荐）或 net-tools 后重试："
    echo "   opkg install ip-full    # OpenWrt"
    echo "   apk add iproute2        # Alpine"
    echo "   apt install iproute2    # Debian/Ubuntu"
    echo "   yum install iproute     # RHEL/CentOS"
}

# 停止端口（80/443/两者）
stop_ports() {
    echo "选择停止端口："
    echo "1. 停止80端口"
    echo "2. 停止443端口"
    echo "3. 停止80和443端口"
    read -rp "选择 (1/2/3): " port_choice
    case "$port_choice" in
        1) stop_service uhttpd ;;
        2) stop_service caddy  ;;
        3) stop_service uhttpd; stop_service caddy ;;
        *) echo "无效选择"; return ;;
    esac
    for pname in caddy uhttpd; do
        local PIDS
        PIDS=$(pgrep -x "$pname")
        for pid in $PIDS; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "杀掉进程ID：$pid ($pname)"
                kill "$pid" 2>/dev/null || kill -9 "$pid"
            fi
        done
    done
    SERVICE_STATUS="stopped"
    save_state
}

# 启动80端口
start_port_80() {
    start_service uhttpd
    echo "80端口已启动"
    SERVICE_STATUS="uhttpd"
    CADDY_RUNNING=0
    save_state
}

# 启动443端口
start_port_443() {
    start_service caddy
    echo "443端口已启动"
}

# 重新启动全部（80+443）
start_both_ports() {
    start_port_80
    start_port_443
}

# 停止服务
stop_service() {
    local svc=$1
    if ! service_exists "$svc"; then
        echo "服务 $svc 不存在，无法停止。"
        return 1
    fi
    if [ "$SYSTEM_TYPE" = "OpenWrt" ]; then
        if [ "$svc" = "caddy" ]; then
            local PIDS
            PIDS=$(pgrep -x caddy)
            if [ -n "$PIDS" ]; then
                echo "正在杀掉caddy进程: $PIDS"
                kill $PIDS 2>/dev/null
                sleep 2
                PIDS=$(pgrep -x caddy)
                [ -n "$PIDS" ] && kill -9 $PIDS 2>/dev/null
            else
                echo "未检测到caddy进程"
            fi
        else
            if [ -x "/etc/init.d/$svc" ]; then
                /etc/init.d/$svc stop
                /etc/init.d/$svc disable 2>/dev/null
            else
                local PIDS
                PIDS=$(pgrep -x "$svc")
                if [ -n "$PIDS" ]; then
                    kill $PIDS 2>/dev/null
                    sleep 2
                    PIDS=$(pgrep -x "$svc")
                    [ -n "$PIDS" ] && kill -9 $PIDS 2>/dev/null
                fi
            fi
        fi
    else
        case $INIT_SYSTEM in
            systemd)
                $SUDO systemctl stop "$svc"
                $SUDO systemctl disable "$svc"
                ;;
            openrc)
                $SUDO rc-service "$svc" stop
                $SUDO rc-update del "$svc"
                ;;
            sysvinit)
                $SUDO service "$svc" stop
                $SUDO update-rc.d "$svc" remove
                ;;
            *)
                $SUDO /etc/init.d/"$svc" stop
                $SUDO /etc/init.d/"$svc" disable
                ;;
        esac
    fi
    echo "$svc已停止并禁用"
}

# 启动服务
start_service() {
    local svc=$1
    if ! service_exists "$svc"; then
        echo "服务 $svc 不存在，无法启动。"
        return 1
    fi
    if [ "$SYSTEM_TYPE" = "OpenWrt" ]; then
        if [ "$svc" = "caddy" ]; then
            start_caddy
        else
            if [ -x "/etc/init.d/$svc" ]; then
                /etc/init.d/$svc start
                /etc/init.d/$svc enable
            else
                "$svc" &
            fi
        fi
    else
        case $INIT_SYSTEM in
            systemd)
                $SUDO systemctl start "$svc"
                $SUDO systemctl enable "$svc"
                ;;
            openrc)
                $SUDO rc-service "$svc" start
                $SUDO rc-update add "$svc" default
                ;;
            sysvinit)
                $SUDO service "$svc" start
                $SUDO update-rc.d "$svc" defaults
                ;;
            *)
                $SUDO /etc/init.d/"$svc" start
                $SUDO /etc/init.d/"$svc" enable
                ;;
        esac
    fi
    echo "$svc已启动并启用"
}

# 重启服务
restart_service() {
    local svc=$1
    if ! service_exists "$svc"; then
        echo "服务 $svc 不存在，无法重启。"
        return 1
    fi
    if [ "$SYSTEM_TYPE" = "OpenWrt" ]; then
        if [ "$svc" = "caddy" ]; then
            stop_service caddy
            start_caddy
        else
            if [ -x "/etc/init.d/$svc" ]; then
                /etc/init.d/$svc restart
            else
                local PIDS
                PIDS=$(pgrep -x "$svc")
                if [ -n "$PIDS" ]; then
                    kill $PIDS 2>/dev/null
                    sleep 2
                    PIDS=$(pgrep -x "$svc")
                    [ -n "$PIDS" ] && kill -9 $PIDS 2>/dev/null
                fi
                "$svc" &
            fi
        fi
    else
        case $INIT_SYSTEM in
            systemd) $SUDO systemctl restart "$svc" ;;
            openrc)  $SUDO rc-service "$svc" restart ;;
            sysvinit) $SUDO service "$svc" restart ;;
            *) $SUDO /etc/init.d/"$svc" restart ;;
        esac
    fi
    echo "$svc已重启"
}

# 获取服务状态（运行和启用）
get_service_status() {
    local svc_name=$1
    local running="否"
    local enabled="否"
    if [ "$SYSTEM_TYPE" = "OpenWrt" ]; then
        if [ "$svc_name" = "caddy" ]; then
            pgrep -x caddy >/dev/null && running="是"
            enabled="否"
        else
            if [ -x "/etc/init.d/$svc_name" ]; then
                /etc/init.d/$svc_name status 2>/dev/null | grep -q running && running="是"
                /etc/init.d/$svc_name enabled 2>/dev/null | grep -q enabled && enabled="是"
            else
                pgrep -x "$svc_name" >/dev/null && running="是"
                enabled="否"
            fi
        fi
    else
        case $INIT_SYSTEM in
            systemd)
                $SUDO systemctl is-active  --quiet "$svc_name" && running="是"
                $SUDO systemctl is-enabled --quiet "$svc_name" && enabled="是"
                ;;
            openrc)
                $SUDO rc-service "$svc_name" status &>/dev/null && running="是"
                $SUDO rc-update show | grep -q "$svc_name" && enabled="是"
                ;;
            sysvinit)
                $SUDO service "$svc_name" status &>/dev/null && running="是"
                [ -x "/etc/init.d/$svc_name" ] && enabled="是"
                ;;
            *)
                $SUDO /etc/init.d/"$svc_name" status &>/dev/null && running="是"
                $SUDO /etc/init.d/"$svc_name" enabled &>/dev/null && enabled="是"
                ;;
        esac
    fi
    echo "$running|$enabled"
}

# 修改uHTTPd端口
modify_uhttpd_port() {
    read -rp "请输入新的uHTTPd监听端口： " new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
        echo "无效的端口号"
        return
    fi
    if grep -q "option listen_http" "$UHTTPD_CONF_FILE"; then
        $SUDO sed -i "s/\(.*option listen_http[[:space:]]*\)[0-9]\+/\1$new_port/" "$UHTTPD_CONF_FILE"
    else
        echo "option listen_http $new_port" >> "$UHTTPD_CONF_FILE"
    fi
    echo "uHTTPd端口已修改为 $new_port"
    restart_service uhttpd
}

# 卸载caddy
uninstall_caddy() {
    stop_service caddy
    $SUDO rm -f "$CADDY_BIN_PATH"
    echo "已卸载caddy"
}

# 恢复之前状态
restore_previous() {
    if [ "$SERVICE_STATUS" = "uhttpd" ]; then
        start_port_80
    elif [ "$SERVICE_STATUS" = "caddy" ]; then
        start_caddy
    fi
}

# ============================================================
# 主菜单
# ============================================================
main_menu() {
    detect_system
    load_state
    for cmd in ss netstat ps wget curl awk sed tar; do
        check_and_install "$cmd"
    done

    while true; do
        echo "=============================="
        echo "  交互式部署菜单"
        echo "=============================="
        echo "1.  查看当前系统和端口状态"
        echo "2.  停止端口（80/443/两者）"
        echo "3.  启动端口（80/443/两者）"
        echo "4.  停止服务（uhttpd或caddy）"
        echo "5.  启动服务（uhttpd或caddy）"
        echo "6.  配置caddy反向代理"
        echo "7.  添加新反向代理"
        echo "8.  恢复到之前的运行状态"
        echo "9.  卸载caddy"
        echo "10. 修改uHTTPd端口"
        echo "11. 重启uHTTPd"
        echo "12. 查看uHTTPd状态"
        echo "13. 查看本机端口占用情况"   # ← 新增
        echo "14. 退出"
        read -rp "请选择操作(1-14): " opt

        case "$opt" in
            1) view_status ;;
            2) stop_ports ;;
            3)
                echo "启动端口："
                echo "1. 启动80端口"
                echo "2. 启动443端口"
                echo "3. 启动80和443端口"
                read -rp "选择 (1/2/3): " port_choice
                case "$port_choice" in
                    1) start_port_80    ;;
                    2) start_port_443   ;;
                    3) start_both_ports ;;
                    *) echo "无效选择"  ;;
                esac
                ;;
            4)
                echo "当前服务状态："
                uhttpd_status=$(get_service_status uhttpd)
                caddy_status=$(get_service_status caddy)
                echo "uhttpd：$(echo "$uhttpd_status" | cut -d'|' -f1)，启用：$(echo "$uhttpd_status" | cut -d'|' -f2)"
                echo "caddy：$(echo "$caddy_status"  | cut -d'|' -f1)，启用：$(echo "$caddy_status"  | cut -d'|' -f2)"
                read -rp "选择要停止的服务 (uhttpd/caddy): " svc_to_stop
                stop_service "$svc_to_stop"
                ;;
            5)
                echo "当前服务状态："
                uhttpd_status=$(get_service_status uhttpd)
                caddy_status=$(get_service_status caddy)
                echo "uhttpd：$(echo "$uhttpd_status" | cut -d'|' -f1)，启用：$(echo "$uhttpd_status" | cut -d'|' -f2)"
                echo "caddy：$(echo "$caddy_status"  | cut -d'|' -f1)，启用：$(echo "$caddy_status"  | cut -d'|' -f2)"
                read -rp "选择要启动的服务 (uhttpd/caddy): " svc_to_start
                start_service "$svc_to_start"
                ;;
            6)
                if command -v caddy >/dev/null 2>&1; then
                    configure_caddy
                else
                    echo "请先安装caddy"
                fi
                ;;
            7)  add_new_proxy    ;;
            8)  restore_previous ;;
            9)  uninstall_caddy  ;;
            10) modify_uhttpd_port ;;
            11) restart_service uhttpd ;;
            12)
                uhttpd_status=$(get_service_status uhttpd)
                echo "uhttpd状态：$(echo "$uhttpd_status" | cut -d'|' -f1)，启用：$(echo "$uhttpd_status" | cut -d'|' -f2)"
                ;;
            13) show_port_usage ;;   # ← 新增
            14) echo "退出"; exit 0 ;;
            *)  echo "无效选择" ;;
        esac
        read -rp "按回车键继续..."
    done
}

# 启动脚本
main_menu
