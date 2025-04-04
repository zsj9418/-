#!/bin/bash

# MosDNS 一键安装与管理脚本

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
RESET='\e[0m'

LOG_FILE="/var/log/mosdns_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "日志记录开始：$(date)"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：需要root权限运行此脚本${RESET}"
    exit 1
fi

# 检测包管理器
if command -v apt >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    INSTALL_CMD="apt install -y"
elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    INSTALL_CMD="yum install -y"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    INSTALL_CMD="apk add"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    INSTALL_CMD="pacman -S --noconfirm"
else
    echo -e "${RED}警告：未检测到支持的包管理器，依赖安装可能失败${RESET}"
    PKG_MANAGER="none"
fi

# 核心依赖和可选依赖
CORE_DEPS=("curl" "unzip" "sed" "awk" "lsof" "dig")
OPTIONAL_DEPS=("net-tools" "fzf" "dnsutils" "yamllint" "cron" "resolvconf" "dnsmasq")
INSTALLED_DEPS=()

# 代理前缀数组
PROXY_PREFIXES=("https://ghfast.top/" "https://ghproxy.com/")

check_install_deps() {
    echo -e "${YELLOW}检查并安装依赖...${RESET}"
    [ "$PKG_MANAGER" != "none" ] && $PKG_MANAGER update 2>/dev/null
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

configure_dnsmasq_for_mosdns() {
    echo -e "${YELLOW}配置 dnsmasq 以转发 DNS 请求到 MosDNS...${RESET}"
    if command -v nmcli >/dev/null 2>&1; then
        ACTIVE_CON=$(nmcli -t -f NAME con show --active | head -n1)
        if [ -n "$ACTIVE_CON" ]; then
            METHOD=$(nmcli -t -f ipv4.method con show "$ACTIVE_CON" | cut -d: -f2)
            if [ "$METHOD" = "shared" ]; then
                # 禁用 NetworkManager 的默认 DNS 管理
                mkdir -p /etc/NetworkManager/conf.d
                cat > /etc/NetworkManager/conf.d/no-dns.conf <<EOF
[main]
dns=none
EOF
                # 配置 dnsmasq
                mkdir -p /etc/NetworkManager/dnsmasq.d
                cat > /etc/NetworkManager/dnsmasq.d/mosdns.conf <<EOF
no-resolv
server=127.0.0.1#53
no-poll
log-queries
EOF
                # 重启 NetworkManager 并验证
                systemctl restart NetworkManager
                sleep 3
                if netstat -tuln | grep -q "10.42.0.1:53"; then
                    echo -e "${GREEN}成功：NetworkManager 的 dnsmasq 已配置并运行${RESET}"
                    sleep 2
                    # 检查 dnsmasq 是否转发到 127.0.0.1
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
                        exit 1
                    fi
                else
                    echo -e "${RED}错误：NetworkManager 的 dnsmasq 未正确重启${RESET}"
                    journalctl -u NetworkManager | tail -n 20
                    exit 1
                fi
            else
                echo -e "${YELLOW}警告：未检测到 'shared' 模式，跳过 dnsmasq 配置${RESET}"
            fi
        else
            echo -e "${RED}错误：未找到活动 NetworkManager 连接${RESET}"
            exit 1
        fi
    else
        echo -e "${RED}错误：未安装 nmcli，无法配置${RESET}"
        exit 1
    fi
}

lock_resolv_conf() {
    echo -e "${YELLOW}正在固化 /etc/resolv.conf 为 MosDNS 解析...${RESET}"
    if [ -f /etc/resolv.conf ] && [ ! -f /etc/resolv.conf.bak ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
        echo -e "${GREEN}已备份原始 /etc/resolv.conf${RESET}"
    fi

    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || echo -e "${YELLOW}警告：无法锁定文件，可能会被覆盖${RESET}"

    sleep 1
    if grep -q "nameserver 127.0.0.1" /etc/resolv.conf; then
        echo -e "${GREEN}成功：已将 DNS 固化为 127.0.0.1${RESET}"
    else
        echo -e "${RED}错误：固化失败，请检查系统配置${RESET}"
        exit 1
    fi
}

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

check_mosdns_status() {
    echo -e "${YELLOW}检查 MosDNS 运行状态...${RESET}"
    if command -v systemctl >/dev/null 2>&1; then
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

view_resolv_conf() {
    echo -e "${YELLOW}当前 /etc/resolv.conf 的内容：${RESET}"
    cat /etc/resolv.conf
}

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

    INSTALL_PATH="/usr/local/bin"
    CONFIG_PATH="/etc/mosdns"
    mkdir -p "$CONFIG_PATH" || { echo -e "${RED}错误：无法创建配置目录${RESET}"; exit 1; }

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

    PORT=53

    echo -e "\n${YELLOW}请输入国内DNS地址（默认 https://223.5.5.5/dns-query）：${RESET}"
    read -p "> " DOMESTIC_DNS
    DOMESTIC_DNS=${DOMESTIC_DNS:-https://223.5.5.5/dns-query}

    echo -e "\n${YELLOW}请输入国外DNS地址（默认 1.1.1.1）：${RESET}"
    read -p "> " FOREIGN_DNS
    FOREIGN_DNS=${FOREIGN_DNS:-1.1.1.1}

    BASE_GITHUB_URL="https://github.com/IrineSistiana/mosdns/releases/$([ "$VERSION" = "latest" ] && echo "latest/download" || echo "download/$VERSION")/mosdns-linux-$ARCHITECTURE.zip"
    BASE_RULES_URL1="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt"
    BASE_RULES_URL2="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
    ADBLOCK_URL="https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblockdns.txt"
    
    download_with_retry "$BASE_GITHUB_URL" "mosdns.zip" || exit 1
    download_with_retry "$BASE_RULES_URL1" "$CONFIG_PATH/cn_domains.txt" || exit 1
    download_with_retry "$BASE_RULES_URL2" "$CONFIG_PATH/non_cn_domains.txt" || exit 1
    download_with_retry "$ADBLOCK_URL" "$CONFIG_PATH/adblock_raw.txt" || exit 1

    process_adblock_file "$CONFIG_PATH/adblock_raw.txt" "$CONFIG_PATH/adblock.txt"
    rm -f "$CONFIG_PATH/adblock_raw.txt"

    if [ ! -s "$CONFIG_PATH/cn_domains.txt" ] || [ ! -s "$CONFIG_PATH/non_cn_domains.txt" ] || [ ! -s "$CONFIG_PATH/adblock.txt" ]; then
        echo -e "${RED}错误：规则文件为空${RESET}"
        exit 1
    fi

    unzip -o mosdns.zip mosdns -d "$INSTALL_PATH" || { echo -e "${RED}错误：解压失败${RESET}"; exit 1; }
    chmod +x "$INSTALL_PATH/mosdns"
    MOSDNS_VERSION=$("$INSTALL_PATH/mosdns" version 2>/dev/null || "$INSTALL_PATH/mosdns" --version)
    echo -e "${GREEN}MosDNS 版本：$MOSDNS_VERSION${RESET}"
    rm -f mosdns.zip

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

  - tag: "remote_domain"
    type: domain_set
    args:
      files:
        - "$CONFIG_PATH/non_cn_domains.txt"

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

    TEMP_LOG=$(mktemp)
    "$INSTALL_PATH/mosdns" start -c "$CONFIG_PATH/config.yaml" >"$TEMP_LOG" 2>&1 &
    MOSDNS_PID=$!
    sleep 2
    if ! kill -0 "$MOSDNS_PID" 2>/dev/null; then
        echo -e "${RED}错误：配置文件无效或端口被占用${RESET}"
        cat "$TEMP_LOG"
        rm -f "$TEMP_LOG"
        echo -e "${YELLOW}请检查53端口占用情况：${RESET}"
        netstat -tuln | grep :53 || ss -tuln | grep :53
        exit 1
    fi
    kill "$MOSDNS_PID"
    rm -f "$TEMP_LOG"

    # 先固化 resolv.conf，再配置 dnsmasq
    lock_resolv_conf
    configure_dnsmasq_for_mosdns

    if command -v systemctl >/dev/null 2>&1; then
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

    echo -e "${GREEN}MosDNS 已启动并监听 127.0.0.1:53，dnsmasq 将转发请求${RESET}"
}

uninstall_mosdns() {
    echo -e "${YELLOW}开始卸载MosDNS...${RESET}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop mosdns.service 2>/dev/null
        systemctl disable mosdns.service 2>/dev/null
        rm -f /etc/systemd/system/mosdns.service
        systemctl daemon-reload
    else
        killall mosdns 2>/dev/null
    fi
    rm -f /usr/local/bin/mosdns
    rm -rf /etc/mosdns
    rm -f /etc/NetworkManager/dnsmasq.d/mosdns.conf 2>/dev/null
    rm -f /etc/NetworkManager/conf.d/no-dns.conf 2>/dev/null

    restore_resolv_conf
    echo -e "${GREEN}MosDNS 已卸载${RESET}"
}

update_rules() {
    CONFIG_PATH="/etc/mosdns"
    if [ ! -d "$CONFIG_PATH" ]; then
        echo -e "${RED}错误：MosDNS未安装${RESET}"
        exit 1
    fi

    cp "$CONFIG_PATH/cn_domains.txt" "$CONFIG_PATH/cn_domains.txt.bak" 2>/dev/null
    cp "$CONFIG_PATH/non_cn_domains.txt" "$CONFIG_PATH/non_cn_domains.txt.bak" 2>/dev/null
    cp "$CONFIG_PATH/adblock.txt" "$CONFIG_PATH/adblock.txt.bak" 2>/dev/null

    download_with_retry "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt" "$CONFIG_PATH/cn_domains.txt" || {
        [ -f "$CONFIG_PATH/cn_domains.txt.bak" ] && mv "$CONFIG_PATH/cn_domains.txt.bak" "$CONFIG_PATH/cn_domains.txt"
        exit 1
    }
    download_with_retry "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt" "$CONFIG_PATH/non_cn_domains.txt" || {
        [ -f "$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "$CONFIG_PATH/non_cn_domains.txt.bak" "$CONFIG_PATH/non_cn_domains.txt"
        exit 1
    }
    download_with_retry "https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblockdns.txt" "$CONFIG_PATH/adblock_raw.txt" || {
        [ -f "$CONFIG_PATH/adblock.txt.bak" ] && mv "$CONFIG_PATH/adblock.txt.bak" "$CONFIG_PATH/adblock.txt"
        exit 1
    }
    process_adblock_file "$CONFIG_PATH/adblock_raw.txt" "$CONFIG_PATH/adblock.txt"
    rm -f "$CONFIG_PATH/adblock_raw.txt"

    if [ ! -s "$CONFIG_PATH/cn_domains.txt" ] || [ ! -s "$CONFIG_PATH/non_cn_domains.txt" ] || [ ! -s "$CONFIG_PATH/adblock.txt" ]; then
        echo -e "${RED}规则文件为空，回滚...${RESET}"
        [ -f "$CONFIG_PATH/cn_domains.txt.bak" ] && mv "$CONFIG_PATH/cn_domains.txt.bak" "$CONFIG_PATH/cn_domains.txt"
        [ -f "$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "$CONFIG_PATH/non_cn_domains.txt.bak" "$CONFIG_PATH/non_cn_domains.txt"
        [ -f "$CONFIG_PATH/adblock.txt.bak" ] && mv "$CONFIG_PATH/adblock.txt.bak" "$CONFIG_PATH/adblock.txt"
        exit 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart mosdns
        sleep 3
        if systemctl status mosdns.service | grep -q "running"; then
            echo -e "${GREEN}规则更新成功${RESET}"
        else
            echo -e "${RED}重启失败，回滚规则...${RESET}"
            [ -f "$CONFIG_PATH/cn_domains.txt.bak" ] && mv "$CONFIG_PATH/cn_domains.txt.bak" "$CONFIG_PATH/cn_domains.txt"
            [ -f "$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "$CONFIG_PATH/non_cn_domains.txt.bak" "$CONFIG_PATH/non_cn_domains.txt"
            [ -f "$CONFIG_PATH/adblock.txt.bak" ] && mv "$CONFIG_PATH/adblock.txt.bak" "$CONFIG_PATH/adblock.txt"
            systemctl restart mosdns
            exit 1
        fi
    else
        killall mosdns 2>/dev/null
        /usr/local/bin/mosdns start -c "$CONFIG_PATH/config.yaml" &
        sleep 3
        if ps -ef | grep -q "[m]osdns start"; then
            echo -e "${GREEN}规则更新成功${RESET}"
        else
            echo -e "${RED}重启失败，回滚规则...${RESET}"
            [ -f "$CONFIG_PATH/cn_domains.txt.bak" ] && mv "$CONFIG_PATH/cn_domains.txt.bak" "$CONFIG_PATH/cn_domains.txt"
            [ -f "$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "$CONFIG_PATH/non_cn_domains.txt.bak" "$CONFIG_PATH/non_cn_domains.txt"
            [ -f "$CONFIG_PATH/adblock.txt.bak" ] && mv "$CONFIG_PATH/adblock.txt.bak" "$CONFIG_PATH/adblock.txt"
            exit 1
        fi
    fi
}

while true; do
    echo -e "${YELLOW}MosDNS 安装与管理脚本${RESET}"
    PS3="请选择操作（输入数字）："
    OPTIONS=("安装MosDNS" "卸载清理MosDNS" "更新规则" "固化 DNS 配置" "还原系统 DNS 配置" "查看 MosDNS 状态" "查看 /etc/resolv.conf" "退出")
    select opt in "${OPTIONS[@]}"; do
        case $opt in
            "安装MosDNS") check_install_deps; install_mosdns; break ;;
            "卸载清理MosDNS") uninstall_mosdns; break ;;
            "更新规则") update_rules; break ;;
            "固化 DNS 配置") lock_resolv_conf; break ;;
            "还原系统 DNS 配置") restore_resolv_conf; break ;;
            "查看 MosDNS 状态") check_mosdns_status; break ;;
            "查看 /etc/resolv.conf") view_resolv_conf; break ;;
            "退出") echo -e "${GREEN}退出脚本${RESET}"; exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}" ;;
        esac
    done
done

echo "日志记录结束：$(date)"
