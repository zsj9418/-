#!/bin/bash
set -euo pipefail

# MosDNS 一键安装与管理脚本（优化版）

# 彩色输出
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
MAGENTA='\e[35m'
CYAN='\e[36m'
RESET='\e[0m'

# 全局变量
LOG_FILE="/var/log/mosdns_install.log"
INSTALL_PATH="/usr/local/bin"
CONFIG_PATH="/etc/mosdns"
DEFAULT_DOMESTIC_DNS="https://223.5.5.5/dns-query"
DEFAULT_FOREIGN_DNS="1.1.1.1"
DEFAULT_PORT="53"
DEFAULT_IPV6="no"
DEFAULT_RULES_URL1="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt"
DEFAULT_RULES_URL2="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
DEFAULT_ADBLOCK_URL="https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblockdns.txt"
DEFAULT_CN_IP_CIDR_URL="https://raw.githubusercontent.com/Hackl0us/GeoIP2-CN/release/CN-ip-cidr.txt"
DEFAULT_GFW_URL="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt"
PROXY_PREFIXES=("https://un.ax18.ggff.net/" "https://cdn.yyds9527.nyc.mn/")

CORE_DEPS=("curl" "unzip" "sed" "awk" "lsof" "dig")
OPTIONAL_DEPS=("net-tools" "fzf" "dnsutils" "yamllint" "cron" "resolvconf" "dnsmasq")
INSTALLED_DEPS=()

# 日志
exec > >(tee -a "$LOG_FILE") 2>&1
echo -e "${CYAN}日志记录开始：$(date)${RESET}"

# trap清理临时文件
TMP_FILES=()
trap 'for f in "${TMP_FILES[@]}"; do [ -f "$f" ] && rm -f "$f"; done' EXIT

# 检查root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：需要root权限运行此脚本${RESET}"
    exit 1
fi

# 检测包管理器
detect_pkg_manager() {
    if command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt install -y"
        UPDATE_CMD="apt update"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y"
        UPDATE_CMD="dnf makecache"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y"
        UPDATE_CMD="yum makecache"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        INSTALL_CMD="apk add"
        UPDATE_CMD="apk update"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
        INSTALL_CMD="pacman -S --noconfirm"
        UPDATE_CMD="pacman -Sy"
    else
        echo -e "${RED}警告：未检测到支持的包管理器，依赖安装可能失败${RESET}"
        PKG_MANAGER="none"
        INSTALL_CMD=":"
        UPDATE_CMD=":"
    fi
}

# 检查并安装依赖
check_install_deps() {
    echo -e "${YELLOW}检查并安装依赖...${RESET}"
    [ "$PKG_MANAGER" != "none" ] && $UPDATE_CMD 2>/dev/null
    for dep in "${CORE_DEPS[@]}"; do
        if ! command -v "${dep%%:*}" >/dev/null 2>&1; then
            echo -e "${YELLOW}安装核心依赖：$dep${RESET}"
            $INSTALL_CMD "$dep" || { echo -e "${RED}警告：无法安装 $dep，可能影响功能${RESET}"; }
            INSTALLED_DEPS+=("$dep")
        fi
    done
    for dep in "${OPTIONAL_DEPS[@]}"; do
        if ! command -v "${dep%%:*}" >/dev/null 2>&1; then
            echo -e "${YELLOW}安装可选依赖：$dep${RESET}"
            $INSTALL_CMD "$dep" 2>/dev/null || echo -e "${YELLOW}跳过 $dep，未安装${RESET}"
        fi
    done
    [ "${#INSTALLED_DEPS[@]}" -gt 0 ] && echo -e "${GREEN}已安装核心依赖：${INSTALLED_DEPS[*]}${RESET}"
}

# 下载文件带重试
download_with_retry() {
    local url="$1"
    local output="$2"
    local retries=3
    local attempt=1

    while [ $attempt -le $retries ]; do
        echo -e "${YELLOW}下载 $url (尝试 $attempt/$retries)...${RESET}"
        curl -L -# -o "$output" "$url" && return 0
        echo -e "${RED}直连下载失败${RESET}"
        sleep 2
        ((attempt++))
    done

    for prefix in "${PROXY_PREFIXES[@]}"; do
        attempt=1
        local proxy_url="${prefix}${url}"
        while [ $attempt -le $retries ]; do
            echo -e "${YELLOW}通过代理 $prefix 下载 $url (尝试 $attempt/$retries)...${RESET}"
            curl -L -# -o "$output" "$proxy_url" && return 0
            echo -e "${RED}代理 $prefix 下载失败${RESET}"
            sleep 2
            ((attempt++))
        done
    done

    echo -e "${RED}错误：下载 $url 失败，所有代理均不可用${RESET}"
    return 1
}

# 处理 adblock 文件格式
process_adblock_file() {
    local input_file="$1"
    local output_file="$2"
    echo -e "${YELLOW}处理 adblock 文件格式以适配 MosDNS...${RESET}"
    sed 's/||//; s/\^.*$//; /^$/d; /^#/d; /^\[/d; s/\s.*$//; /^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+$/d' "$input_file" > "$output_file"
    if [ -s "$output_file" ]; then
        echo -e "${GREEN}成功：adblock 文件已处理并保存到 $output_file${RESET}"
    else
        echo -e "${RED}错误：处理后的 adblock 文件为空${RESET}"
        exit 1
    fi
}

# 处理 CN-ip-cidr 文件格式
process_cn_ip_cidr_file() {
    local input_file="$1"
    local output_file="$2"
    echo -e "${YELLOW}处理 CN-ip-cidr 文件格式以适配 MosDNS...${RESET}"
    sed 's/^#.*//; /^$/d; /^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\/[0-9]\+$/!d' "$input_file" > "$output_file"
    if [ -s "$output_file" ]; then
        echo -e "${GREEN}成功：CN-ip-cidr 文件已处理并保存到 $output_file${RESET}"
    else
        echo -e "${RED}错误：处理后的 CN-ip-cidr 文件为空${RESET}"
        exit 1
    fi
}

# 处理 gfw 文件格式
process_gfw_file() {
    local input_file="$1"
    local output_file="$2"
    echo -e "${YELLOW}处理 gfw 文件格式以适配 MosDNS...${RESET}"
    sed 's/^#.*//; /^$/d; /^[a-zA-Z0-9-]\+\.[a-zA-Z0-9-]\+\.[a-zA-Z0-9-]\+\.[a-zA-Z0-9-]\+$/!d' "$input_file" > "$output_file"
    if [ -s "$output_file" ]; then
        echo -e "${GREEN}成功：gfw 文件已处理并保存到 $output_file${RESET}"
    else
        echo -e "${RED}错误：处理后的 gfw 文件为空${RESET}"
        exit 1
    fi
}

# 配置 dnsmasq 以转发 DNS 请求到 MosDNS
configure_dnsmasq_for_mosdns() {
    echo -e "${YELLOW}配置 dnsmasq 以转发 DNS 请求到 MosDNS...${RESET}"

    # 检查是否安装了 dnsmasq
    if ! command -v dnsmasq >/dev/null 2>&1; then
        echo -e "${RED}错误：未安装 dnsmasq，无法配置${RESET}"
        return 1
    fi

    # 检查是否有活动的 NetworkManager 连接
    if command -v nmcli >/dev/null 2>&1; then
        ACTIVE_CON=$(nmcli -t -f NAME con show --active | head -n1)
        if [ -n "$ACTIVE_CON" ]; then
            METHOD=$(nmcli -t -f ipv4.method con show "$ACTIVE_CON" | cut -d: -f2)
            if [ "$METHOD" = "shared" ]; then
                mkdir -p /etc/NetworkManager/conf.d
                cat > /etc/NetworkManager/conf.d/no-dns.conf <<EOF
[main]
dns=none
EOF
                mkdir -p /etc/NetworkManager/dnsmasq.d
                cat > /etc/NetworkManager/dnsmasq.d/mosdns.conf <<EOF
no-resolv
server=127.0.0.1#53
no-poll
log-queries
EOF
                systemctl restart NetworkManager
                sleep 3
                if netstat -tuln | grep -q "10.42.0.1:53"; then
                    echo -e "${GREEN}成功：NetworkManager 的 dnsmasq 已配置并运行${RESET}"
                    sleep 2
                    if journalctl -u NetworkManager | tail -n 50 | grep -q "using nameserver 127.0.0.1"; then
                        echo -e "${GREEN}确认：dnsmasq 已转发到 MosDNS${RESET}"
                    else
                        echo -e "${RED}错误：dnsmasq 未正确转发到 MosDNS${RESET}"
                        echo -e "${YELLOW}检查配置文件：${RESET}"
                        cat /etc/NetworkManager/dnsmasq.d/mosdns.conf
                        echo -e "${YELLOW}NetworkManager 日志：${RESET}"
                        journalctl -u NetworkManager | tail -n 50
                        echo -e "${YELLOW}建议：${RESET}"
                        echo "1. 确认 /etc/NetworkManager/dnsmasq.d/mosdns.conf 权限为 644"
                        echo "2. 检查是否存在其他 dnsmasq 配置文件干扰"
                        echo "3. 手动运行 'nmcli con reload' 并重启 NetworkManager"
                        return 1
                    fi
                else
                    echo -e "${RED}错误：NetworkManager 的 dnsmasq 未正确重启${RESET}"
                    journalctl -u NetworkManager | tail -n 20
                    return 1
                fi
            else
                echo -e "${YELLOW}警告：未检测到 'shared' 模式，跳过 dnsmasq 配置${RESET}"
                return 0
            fi
        else
            echo -e "${RED}错误：未找到活动 NetworkManager 连接${RESET}"
            return 1
        fi
    else
        echo -e "${YELLOW}警告：未安装 nmcli，尝试直接配置 dnsmasq${RESET}"

        if [ -f /etc/dnsmasq.conf ]; then
            echo -e "${YELLOW}配置 /etc/dnsmasq.conf 以转发到 MosDNS${RESET}"
            if ! grep -q "server=127.0.0.1#53" /etc/dnsmasq.conf; then
                echo "server=127.0.0.1#53" >> /etc/dnsmasq.conf
                echo "log-queries" >> /etc/dnsmasq.conf
                systemctl restart dnsmasq || service dnsmasq restart || /etc/init.d/dnsmasq restart
                sleep 2
                if netstat -tuln | grep -q ":53"; then
                    echo -e "${GREEN}成功：dnsmasq 已配置并运行${RESET}"
                    return 0
                else
                    echo -e "${RED}错误：dnsmasq 未正确重启${RESET}"
                    return 1
                fi
            else
                echo -e "${YELLOW}警告：dnsmasq 已配置转发到 MosDNS${RESET}"
                return 0
            fi
        else
            echo -e "${RED}错误：未找到 /etc/dnsmasq.conf${RESET}"
            return 1
        fi
    fi
}

# 固化 resolv.conf
lock_resolv_conf() {
    echo -e "${YELLOW}正在固化 /etc/resolv.conf 为 MosDNS 解析...${RESET}"
    if [ -f /etc/resolv.conf ] && [ ! -f /etc/resolv.conf.bak ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
        echo -e "${GREEN}已备份原始 /etc/resolv.conf${RESET}"
    fi

    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || echo -e "${YELLOW}警告：无法锁定文件，可能会被覆盖${RESET}"
    echo -e "${YELLOW}提示：chattr +i 可能影响系统升级或网络管理工具，请谨慎使用。${RESET}"

    sleep 1
    if grep -q "nameserver 127.0.0.1" /etc/resolv.conf; then
        echo -e "${GREEN}成功：已将 DNS 固化为 127.0.0.1${RESET}"
    else
        echo -e "${RED}错误：固化失败，请检查系统配置${RESET}"
        exit 1
    fi
}

# 还原 resolv.conf
restore_resolv_conf() {
    echo -e "${YELLOW}正在还原 /etc/resolv.conf 为系统默认设置...${RESET}"
    chattr -i /etc/resolv.conf 2>/dev/null

    if [ -f /etc/resolv.conf.bak ]; then
        mv /etc/resolv.conf.bak /etc/resolv.conf
        echo -e "${GREEN}成功：已恢复原有 DNS 配置${RESET}"
    else
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        chmod 644 /etc/resolv.conf
        echo -e "${GREEN}未找到备份，已设置为默认 DNS 8.8.8.8${RESET}"
    fi

    if command -v nmcli >/dev/null 2>&1; then
        rm -f /etc/NetworkManager/conf.d/no-dns.conf
        ACTIVE_CON=$(nmcli -t -f NAME con show --active | head -n1)
        if [ -n "$ACTIVE_CON" ]; then
            nmcli con mod "$ACTIVE_CON" ipv4.dns "" 2>/dev/null
            nmcli con mod "$ACTIVE_CON" ipv4.ignore-auto-dns no 2>/dev/null
            nmcli con up "$ACTIVE_CON" >/dev/null 2>&1
        fi
        systemctl restart NetworkManager
    fi
}

# 检查 MosDNS 状态
check_mosdns_status() {
    echo -e "${YELLOW}检查 MosDNS 运行状态...${RESET}"
    if command -v systemctl >/dev/null 2>&1 && pgrep -x systemd >/dev/null 2>&1; then
        if systemctl is-active --quiet mosdns.service; then
            echo -e "${GREEN}MosDNS 服务正在运行${RESET}"
        else
            echo -e "${RED}MosDNS 服务未运行${RESET}"
            return 1
        fi
    else
        if pgrep -x "mosdns" > /dev/null; then
            echo -e "${GREEN}MosDNS 正在运行（通过进程检查）${RESET}"
        else
            echo -e "${RED}MosDNS 未运行（通过进程检查）${RESET}"
            return 1
        fi
    fi

    echo -e "${YELLOW}测试通过 MosDNS 解析 www.example.com...${RESET}"
    RESOLVED_IP=$(dig @127.0.0.1 www.example.com +short)
    if [[ -n "$RESOLVED_IP" ]]; then
        echo -e "${GREEN}解析成功：www.example.com 的 IP 地址是 $RESOLVED_IP${RESET}"
    else
        echo -e "${RED}解析失败：无法通过 MosDNS 解析 www.example.com${RESET}"
    fi

    echo -e "${YELLOW}测试广告拦截 doubleclick.net...${RESET}"
    BLOCK_TEST=$(dig @127.0.0.1 doubleclick.net +short)
    if [[ -z "$BLOCK_TEST" ]]; then
        echo -e "${GREEN}广告拦截成功：doubleclick.net 未解析${RESET}"
    else
        echo -e "${RED}广告拦截失败：doubleclick.net 仍解析为 $BLOCK_TEST${RESET}"
    fi
}

# 查看 resolv.conf
view_resolv_conf() {
    echo -e "${YELLOW}当前 /etc/resolv.conf 的内容：${RESET}"
    cat /etc/resolv.conf
}

# 配置双ADG接入
configure_adg() {
    if [ ! -d "$CONFIG_PATH" ]; then
        echo -e "${RED}错误：MosDNS未安装${RESET}"
        exit 1
    fi

    echo -e "${YELLOW}配置双ADG接入...${RESET}"

    # 获取当前配置
    if [ -f "$CONFIG_PATH/config.yaml" ]; then
        cp "$CONFIG_PATH/config.yaml" "$CONFIG_PATH/config.yaml.bak"
    fi

    # 获取国内DNS和国外DNS地址
    echo -e "\n${YELLOW}请输入国内DNS地址（默认 $DEFAULT_DOMESTIC_DNS）：${RESET}"
    read -r -p "> " DOMESTIC_DNS
    DOMESTIC_DNS=${DOMESTIC_DNS:-$DEFAULT_DOMESTIC_DNS}

    echo -e "\n${YELLOW}请输入国外DNS地址（默认 $DEFAULT_FOREIGN_DNS）：${RESET}"
    read -r -p "> " FOREIGN_DNS
    FOREIGN_DNS=${FOREIGN_DNS:-$DEFAULT_FOREIGN_DNS}

    echo -e "\n${YELLOW}请输入MosDNS监听端口（默认 $DEFAULT_PORT）：${RESET}"
    read -r -p "> " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    echo -e "\n${YELLOW}是否监听IPv6（::1）？(yes/no, 默认 $DEFAULT_IPV6)：${RESET}"
    read -r -p "> " IPV6
    IPV6=${IPV6:-$DEFAULT_IPV6}

    # 更新配置文件
    cat > "$CONFIG_PATH/config.yaml" <<EOF
log:
  level: info
  file: "$CONFIG_PATH/mosdns.log"

plugins:
  - tag: "direct_domain"
    type: domain_set
    args:
      files:
        - "$CONFIG_PATH/cn_domains.txt"
        - "$CONFIG_PATH/cn_ip_cidr.txt"

  - tag: "remote_domain"
    type: domain_set
    args:
      files:
        - "$CONFIG_PATH/non_cn_domains.txt"
        - "$CONFIG_PATH/gfw.txt"

  - tag: "block_list"
    type: domain_set
    args:
      files:
        - "$CONFIG_PATH/adblock.txt"

  - tag: "local_forward"
    type: forward
    args:
      concurrent: 4
      upstreams:
        - addr: "$DOMESTIC_DNS"

  - tag: "remote_forward"
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "$FOREIGN_DNS"

  - tag: "local_sequence"
    type: sequence
    args:
      - exec: \$local_forward

  - tag: "remote_sequence"
    type: sequence
    args:
      - exec: \$remote_forward

  - tag: "main_sequence"
    type: sequence
    args:
      - matches: "qname \$block_list"
        exec: reject
      - matches: "qname \$direct_domain"
        exec: goto local_sequence
      - matches: "qname \$remote_domain"
        exec: goto remote_sequence
      - exec: goto remote_sequence

  - type: udp_server
    args:
      entry: main_sequence
      listen: 127.0.0.1:$PORT
EOF

    if [[ "$IPV6" == "yes" ]]; then
        cat >> "$CONFIG_PATH/config.yaml" <<EOF
  - type: udp_server
    args:
      entry: main_sequence
      listen: ::1:$PORT
EOF
    fi

    # 重启 MosDNS 服务
    if command -v systemctl >/dev/null 2>&1 && pgrep -x systemd >/dev/null 2>&1; then
        systemctl restart mosdns
        sleep 3
        if systemctl status mosdns.service | grep -q "running"; then
            echo -e "${GREEN}双ADG配置更新成功${RESET}"
        else
            echo -e "${RED}重启失败，回滚配置...${RESET}"
            mv "$CONFIG_PATH/config.yaml.bak" "$CONFIG_PATH/config.yaml"
            systemctl restart mosdns
            exit 1
        fi
    else
        killall mosdns 2>/dev/null
        "$INSTALL_PATH/mosdns" start -c "$CONFIG_PATH/config.yaml" &
        sleep 3
        if ps -ef | grep -q "[m]osdns start"; then
            echo -e "${GREEN}双ADG配置更新成功${RESET}"
        else
            echo -e "${RED}重启失败，回滚配置...${RESET}"
            mv "$CONFIG_PATH/config.yaml.bak" "$CONFIG_PATH/config.yaml"
            exit 1
        fi
    fi
}

# 生成MosDNS配置文件
generate_mosdns_config() {
    local domestic_dns="$1"
    local foreign_dns="$2"
    local port="$3"
    local ipv6="$4"
    local config_file="$5"

    cat > "$config_file" <<EOF
log:
  level: info
  file: "$CONFIG_PATH/mosdns.log"

plugins:
  - tag: "direct_domain"
    type: domain_set
    args:
      files:
        - "$CONFIG_PATH/cn_domains.txt"
        - "$CONFIG_PATH/cn_ip_cidr.txt"

  - tag: "remote_domain"
    type: domain_set
    args:
      files:
        - "$CONFIG_PATH/non_cn_domains.txt"
        - "$CONFIG_PATH/gfw.txt"

  - tag: "block_list"
    type: domain_set
    args:
      files:
        - "$CONFIG_PATH/adblock.txt"

  - tag: "local_forward"
    type: forward
    args:
      concurrent: 4
      upstreams:
        - addr: "$domestic_dns"

  - tag: "remote_forward"
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "$foreign_dns"

  - tag: "local_sequence"
    type: sequence
    args:
      - exec: \$local_forward

  - tag: "remote_sequence"
    type: sequence
    args:
      - exec: \$remote_forward

  - tag: "main_sequence"
    type: sequence
    args:
      - matches: "qname \$block_list"
        exec: reject
      - matches: "qname \$direct_domain"
        exec: goto local_sequence
      - matches: "qname \$remote_domain"
        exec: goto remote_sequence
      - exec: goto remote_sequence

  - type: udp_server
    args:
      entry: main_sequence
      listen: 127.0.0.1:$port
EOF

    if [[ "$ipv6" == "yes" ]]; then
        cat >> "$config_file" <<EOF
  - type: udp_server
    args:
      entry: main_sequence
      listen: ::1:$port
EOF
    fi
}

# 安装 MosDNS
install_mosdns() {
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
        echo -e "${GREEN}已备份DNS配置${RESET}"
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCHITECTURE="amd64" ;;
        aarch64) ARCHITECTURE="arm64" ;;
        armv7l) ARCHITECTURE="armv7" ;;
        armv6l) ARCHITECTURE="armv6" ;;
        mips) ARCHITECTURE="mips" ;;
        mipsel) ARCHITECTURE="mipsle" ;;
        i386|i686) ARCHITECTURE="386" ;;
        *) echo -e "${RED}错误：不支持的架构：$ARCH${RESET}"; exit 1 ;;
    esac
    echo -e "${GREEN}检测到架构：$ARCHITECTURE${RESET}"

    mkdir -p "$CONFIG_PATH" || { echo -e "${RED}错误：无法创建配置目录${RESET}"; exit 1; }

    # 版本选择
    if ! command -v fzf >/dev/null 2>&1; then
        VERSION="latest"
        echo -e "${YELLOW}未安装 fzf，默认使用最新版本${RESET}"
    else
        for attempt in {1..3}; do
            VERSIONS=$(curl -s --retry 3 "https://api.github.com/repos/IrineSistiana/mosdns/releases" | grep -oP '"tag_name": "\K[^"]+' | sort -rV)
            [ -n "$VERSIONS" ] && break
            echo -e "${RED}第 $attempt 次获取版本列表失败，重试...${RESET}"
            [ "$attempt" -eq 3 ] && { echo -e "${RED}错误：无法获取版本列表${RESET}"; exit 1; }
            sleep 2
        done
        VERSION=$(echo "$VERSIONS" | fzf --prompt="请选择MosDNS版本（默认最新）: " --height=10)
        VERSION=${VERSION:-latest}
    fi

    # 端口、IPv6、规则源自定义
    echo -e "\n${YELLOW}请输入MosDNS监听端口（默认 $DEFAULT_PORT）：${RESET}"
    read -r -p "> " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    echo -e "\n${YELLOW}是否监听IPv6（::1）？(yes/no, 默认 $DEFAULT_IPV6)：${RESET}"
    read -r -p "> " IPV6
    IPV6=${IPV6:-$DEFAULT_IPV6}

    echo -e "\n${YELLOW}请输入国内DNS地址（默认 $DEFAULT_DOMESTIC_DNS）：${RESET}"
    read -r -p "> " DOMESTIC_DNS
    DOMESTIC_DNS=${DOMESTIC_DNS:-$DEFAULT_DOMESTIC_DNS}

    echo -e "\n${YELLOW}请输入国外DNS地址（默认 $DEFAULT_FOREIGN_DNS）：${RESET}"
    read -r -p "> " FOREIGN_DNS
    FOREIGN_DNS=${FOREIGN_DNS:-$DEFAULT_FOREIGN_DNS}

    echo -e "\n${YELLOW}自定义规则源（直接回车使用默认）"
    echo -e "1. 国内域名规则URL（默认 $DEFAULT_RULES_URL1）："
    read -r -p "> " BASE_RULES_URL1
    BASE_RULES_URL1=${BASE_RULES_URL1:-$DEFAULT_RULES_URL1}
    echo -e "2. 国外域名规则URL（默认 $DEFAULT_RULES_URL2）："
    read -r -p "> " BASE_RULES_URL2
    BASE_RULES_URL2=${BASE_RULES_URL2:-$DEFAULT_RULES_URL2}
    echo -e "3. 广告规则URL（默认 $DEFAULT_ADBLOCK_URL）："
    read -r -p "> " ADBLOCK_URL
    ADBLOCK_URL=${ADBLOCK_URL:-$DEFAULT_ADBLOCK_URL}
    echo -e "4. CN IP CIDR规则URL（默认 $DEFAULT_CN_IP_CIDR_URL）："
    read -r -p "> " CN_IP_CIDR_URL
    CN_IP_CIDR_URL=${CN_IP_CIDR_URL:-$DEFAULT_CN_IP_CIDR_URL}
    echo -e "5. GFW规则URL（默认 $DEFAULT_GFW_URL）："
    read -r -p "> " GFW_URL
    GFW_URL=${GFW_URL:-$DEFAULT_GFW_URL}

    BASE_GITHUB_URL="https://github.com/IrineSistiana/mosdns/releases/$([ "$VERSION" = "latest" ] && echo "latest/download" || echo "download/$VERSION")/mosdns-linux-$ARCHITECTURE.zip"

    download_with_retry "$BASE_GITHUB_URL" "mosdns.zip" || exit 1
    download_with_retry "$BASE_RULES_URL1" "$CONFIG_PATH/cn_domains.txt" || exit 1
    download_with_retry "$BASE_RULES_URL2" "$CONFIG_PATH/non_cn_domains.txt" || exit 1
    download_with_retry "$ADBLOCK_URL" "$CONFIG_PATH/adblock_raw.txt" || exit 1
    download_with_retry "$CN_IP_CIDR_URL" "$CONFIG_PATH/cn_ip_cidr_raw.txt" || exit 1
    download_with_retry "$GFW_URL" "$CONFIG_PATH/gfw_raw.txt" || exit 1

    process_adblock_file "$CONFIG_PATH/adblock_raw.txt" "$CONFIG_PATH/adblock.txt"
    process_cn_ip_cidr_file "$CONFIG_PATH/cn_ip_cidr_raw.txt" "$CONFIG_PATH/cn_ip_cidr.txt"
    process_gfw_file "$CONFIG_PATH/gfw_raw.txt" "$CONFIG_PATH/gfw.txt"
    rm -f "$CONFIG_PATH/adblock_raw.txt" "$CONFIG_PATH/cn_ip_cidr_raw.txt" "$CONFIG_PATH/gfw_raw.txt"

    if [ ! -s "$CONFIG_PATH/cn_domains.txt" ] || [ ! -s "$CONFIG_PATH/non_cn_domains.txt" ] || [ ! -s "$CONFIG_PATH/adblock.txt" ] || [ ! -s "$CONFIG_PATH/cn_ip_cidr.txt" ] || [ ! -s "$CONFIG_PATH/gfw.txt" ]; then
        echo -e "${RED}错误：规则文件为空${RESET}"
        exit 1
    fi

    unzip -o mosdns.zip mosdns -d "$INSTALL_PATH" || { echo -e "${RED}错误：解压失败${RESET}"; exit 1; }
    chmod +x "$INSTALL_PATH/mosdns"
    MOSDNS_VERSION=$("$INSTALL_PATH/mosdns" version 2>/dev/null || "$INSTALL_PATH/mosdns" --version)
    echo -e "${GREEN}MosDNS 版本：$MOSDNS_VERSION${RESET}"
    rm -f mosdns.zip

    generate_mosdns_config "$DOMESTIC_DNS" "$FOREIGN_DNS" "$PORT" "$IPV6" "$CONFIG_PATH/config.yaml"

    TEMP_LOG=$(mktemp)
    TMP_FILES+=("$TEMP_LOG")
    "$INSTALL_PATH/mosdns" start -c "$CONFIG_PATH/config.yaml" >"$TEMP_LOG" 2>&1 &
    MOSDNS_PID=$!
    sleep 2
    if ! kill -0 "$MOSDNS_PID" 2>/dev/null; then
        echo -e "${RED}错误：配置文件无效或端口被占用${RESET}"
        cat "$TEMP_LOG"
        echo -e "${YELLOW}请检查${PORT}端口占用情况：${RESET}"
        netstat -tuln | grep ":$PORT" || ss -tuln | grep ":$PORT"
        exit 1
    fi
    kill "$MOSDNS_PID"

    lock_resolv_conf
    configure_dnsmasq_for_mosdns

    if command -v systemctl >/dev/null 2>&1 && pgrep -x systemd >/dev/null 2>&1; then
        cat > /etc/systemd/system/mosdns.service <<EOF
[Unit]
Description=MosDNS Service
After=network.target NetworkManager.service

[Service]
ExecStart=$INSTALL_PATH/mosdns start -c $CONFIG_PATH/config.yaml
Restart=on-failure
WorkingDirectory=$CONFIG_PATH

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mosdns.service
        systemctl start mosdns.service
        sleep 3
        if systemctl status mosdns.service | grep -q "running"; then
            echo -e "${GREEN}成功：MosDNS正常运行${RESET}"
        else
            echo -e "${RED}错误：MosDNS 服务未运行${RESET}"
            systemctl status mosdns.service
            exit 1
        fi
    else
        echo -e "${YELLOW}无 systemd，尝试直接运行 MosDNS${RESET}"
        "$INSTALL_PATH/mosdns" start -c "$CONFIG_PATH/config.yaml" &
        sleep 3
        if ps -ef | grep -q "[m]osdns start"; then
            echo -e "${GREEN}成功：MosDNS已在后台运行${RESET}"
        else
            echo -e "${RED}错误：MosDNS 启动失败${RESET}"
            exit 1
        fi
    fi

    echo -e "${GREEN}MosDNS 已启动并监听 127.0.0.1:$PORT，dnsmasq 将转发请求${RESET}"
}

# 卸载 MosDNS
uninstall_mosdns() {
    echo -e "${YELLOW}开始卸载MosDNS...${RESET}"
    if command -v systemctl >/dev/null 2>&1 && pgrep -x systemd >/dev/null 2>&1; then
        systemctl stop mosdns.service 2>/dev/null
        systemctl disable mosdns.service 2>/dev/null
        rm -f /etc/systemd/system/mosdns.service
        systemctl daemon-reload
    else
        killall mosdns 2>/dev/null
    fi
    rm -f "$INSTALL_PATH/mosdns"
    rm -rf "$CONFIG_PATH"
    rm -f /etc/NetworkManager/dnsmasq.d/mosdns.conf 2>/dev/null
    rm -f /etc/NetworkManager/conf.d/no-dns.conf 2>/dev/null

    restore_resolv_conf
    echo -e "${GREEN}MosDNS 已卸载${RESET}"
}

# 更新规则
update_rules() {
    if [ ! -d "$CONFIG_PATH" ]; then
        echo -e "${RED}错误：MosDNS未安装${RESET}"
        exit 1
    fi

    cp "$CONFIG_PATH/cn_domains.txt" "$CONFIG_PATH/cn_domains.txt.bak" 2>/dev/null
    cp "$CONFIG_PATH/non_cn_domains.txt" "$CONFIG_PATH/non_cn_domains.txt.bak" 2>/dev/null
    cp "$CONFIG_PATH/adblock.txt" "$CONFIG_PATH/adblock.txt.bak" 2>/dev/null
    cp "$CONFIG_PATH/cn_ip_cidr.txt" "$CONFIG_PATH/cn_ip_cidr.txt.bak" 2>/dev/null
    cp "$CONFIG_PATH/gfw.txt" "$CONFIG_PATH/gfw.txt.bak" 2>/dev/null

    download_with_retry "$DEFAULT_RULES_URL1" "$CONFIG_PATH/cn_domains.txt" || {
        [ -f "$CONFIG_PATH/cn_domains.txt.bak" ] && mv "$CONFIG_PATH/cn_domains.txt.bak" "$CONFIG_PATH/cn_domains.txt"
        exit 1
    }
    download_with_retry "$DEFAULT_RULES_URL2" "$CONFIG_PATH/non_cn_domains.txt" || {
        [ -f "$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "$CONFIG_PATH/non_cn_domains.txt.bak" "$CONFIG_PATH/non_cn_domains.txt"
        exit 1
    }
    download_with_retry "$DEFAULT_ADBLOCK_URL" "$CONFIG_PATH/adblock_raw.txt" || {
        [ -f "$CONFIG_PATH/adblock.txt.bak" ] && mv "$CONFIG_PATH/adblock.txt.bak" "$CONFIG_PATH/adblock.txt"
        exit 1
    }
    download_with_retry "$DEFAULT_CN_IP_CIDR_URL" "$CONFIG_PATH/cn_ip_cidr_raw.txt" || {
        [ -f "$CONFIG_PATH/cn_ip_cidr.txt.bak" ] && mv "$CONFIG_PATH/cn_ip_cidr.txt.bak" "$CONFIG_PATH/cn_ip_cidr.txt"
        exit 1
    }
    download_with_retry "$DEFAULT_GFW_URL" "$CONFIG_PATH/gfw_raw.txt" || {
        [ -f "$CONFIG_PATH/gfw.txt.bak" ] && mv "$CONFIG_PATH/gfw.txt.bak" "$CONFIG_PATH/gfw.txt"
        exit 1
    }

    process_adblock_file "$CONFIG_PATH/adblock_raw.txt" "$CONFIG_PATH/adblock.txt"
    process_cn_ip_cidr_file "$CONFIG_PATH/cn_ip_cidr_raw.txt" "$CONFIG_PATH/cn_ip_cidr.txt"
    process_gfw_file "$CONFIG_PATH/gfw_raw.txt" "$CONFIG_PATH/gfw.txt"
    rm -f "$CONFIG_PATH/adblock_raw.txt" "$CONFIG_PATH/cn_ip_cidr_raw.txt" "$CONFIG_PATH/gfw_raw.txt"

    if [ ! -s "$CONFIG_PATH/cn_domains.txt" ] || [ ! -s "$CONFIG_PATH/non_cn_domains.txt" ] || [ ! -s "$CONFIG_PATH/adblock.txt" ] || [ ! -s "$CONFIG_PATH/cn_ip_cidr.txt" ] || [ ! -s "$CONFIG_PATH/gfw.txt" ]; then
        echo -e "${RED}规则文件为空，回滚...${RESET}"
        [ -f "$CONFIG_PATH/cn_domains.txt.bak" ] && mv "$CONFIG_PATH/cn_domains.txt.bak" "$CONFIG_PATH/cn_domains.txt"
        [ -f "$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "$CONFIG_PATH/non_cn_domains.txt.bak" "$CONFIG_PATH/non_cn_domains.txt"
        [ -f "$CONFIG_PATH/adblock.txt.bak" ] && mv "$CONFIG_PATH/adblock.txt.bak" "$CONFIG_PATH/adblock.txt"
        [ -f "$CONFIG_PATH/cn_ip_cidr.txt.bak" ] && mv "$CONFIG_PATH/cn_ip_cidr.txt.bak" "$CONFIG_PATH/cn_ip_cidr.txt"
        [ -f "$CONFIG_PATH/gfw.txt.bak" ] && mv "$CONFIG_PATH/gfw.txt.bak" "$CONFIG_PATH/gfw.txt"
        exit 1
    fi

    if command -v systemctl >/dev/null 2>&1 && pgrep -x systemd >/dev/null 2>&1; then
        systemctl restart mosdns
        sleep 3
        if systemctl status mosdns.service | grep -q "running"; then
            echo -e "${GREEN}规则更新成功${RESET}"
        else
            echo -e "${RED}重启失败，回滚规则...${RESET}"
            [ -f "$CONFIG_PATH/cn_domains.txt.bak" ] && mv "$CONFIG_PATH/cn_domains.txt.bak" "$CONFIG_PATH/cn_domains.txt"
            [ -f "$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "$CONFIG_PATH/non_cn_domains.txt.bak" "$CONFIG_PATH/non_cn_domains.txt"
            [ -f "$CONFIG_PATH/adblock.txt.bak" ] && mv "$CONFIG_PATH/adblock.txt.bak" "$CONFIG_PATH/adblock.txt"
            [ -f "$CONFIG_PATH/cn_ip_cidr.txt.bak" ] && mv "$CONFIG_PATH/cn_ip_cidr.txt.bak" "$CONFIG_PATH/cn_ip_cidr.txt"
            [ -f "$CONFIG_PATH/gfw.txt.bak" ] && mv "$CONFIG_PATH/gfw.txt.bak" "$CONFIG_PATH/gfw.txt"
            systemctl restart mosdns
            exit 1
        fi
    else
        killall mosdns 2>/dev/null
        "$INSTALL_PATH/mosdns" start -c "$CONFIG_PATH/config.yaml" &
        sleep 3
        if ps -ef | grep -q "[m]osdns start"; then
            echo -e "${GREEN}规则更新成功${RESET}"
        else
            echo -e "${RED}重启失败，回滚规则...${RESET}"
            [ -f "$CONFIG_PATH/cn_domains.txt.bak" ] && mv "$CONFIG_PATH/cn_domains.txt.bak" "$CONFIG_PATH/cn_domains.txt"
            [ -f "$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "$CONFIG_PATH/non_cn_domains.txt.bak" "$CONFIG_PATH/non_cn_domains.txt"
            [ -f "$CONFIG_PATH/adblock.txt.bak" ] && mv "$CONFIG_PATH/adblock.txt.bak" "$CONFIG_PATH/adblock.txt"
            [ -f "$CONFIG_PATH/cn_ip_cidr.txt.bak" ] && mv "$CONFIG_PATH/cn_ip_cidr.txt.bak" "$CONFIG_PATH/cn_ip_cidr.txt"
            [ -f "$CONFIG_PATH/gfw.txt.bak" ] && mv "$CONFIG_PATH/gfw.txt.bak" "$CONFIG_PATH/gfw.txt"
            exit 1
        fi
    fi
}

# 显示美化的主菜单
show_menu() {
    clear
    echo -e "${CYAN}==============================================${RESET}"
    echo -e "${CYAN}          MosDNS 安装与管理脚本${RESET}"
    echo -e "${CYAN}==============================================${RESET}"
    echo -e "${YELLOW}1. 安装 MosDNS${RESET}"
    echo -e "${YELLOW}2. 卸载清理 MosDNS${RESET}"
    echo -e "${YELLOW}3. 更新规则${RESET}"
    echo -e "${YELLOW}4. 固化 DNS 配置${RESET}"
    echo -e "${YELLOW}5. 还原系统 DNS 配置${RESET}"
    echo -e "${YELLOW}6. 查看 MosDNS 状态${RESET}"
    echo -e "${YELLOW}7. 查看 /etc/resolv.conf${RESET}"
    echo -e "${YELLOW}8. 配置双ADG接入${RESET}"
    echo -e "${YELLOW}9. 退出${RESET}"
    echo -e "${CYAN}==============================================${RESET}"
    echo -n -e "${CYAN}请选择操作（1-9）：${RESET}"
}

# 主程序
main() {
    detect_pkg_manager
    while true; do
        show_menu
        read -r choice
        case $choice in
            1) check_install_deps; install_mosdns ;;
            2) uninstall_mosdns ;;
            3) update_rules ;;
            4) lock_resolv_conf ;;
            5) restore_resolv_conf ;;
            6) check_mosdns_status ;;
            7) view_resolv_conf ;;
            8) configure_adg ;;
            9) echo -e "${GREEN}退出脚本${RESET}"; exit 0 ;;
            *) echo -e "${RED}无效选项，请重新选择${RESET}"; sleep 1 ;;
        esac
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

main "$@"
