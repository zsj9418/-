#!/bin/bash

# MosDNS 一键安装与管理脚本（通用版）

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

# 核心依赖（必装）
CORE_DEPS=("curl" "unzip" "sed" "awk" "lsof")
# 可选依赖（非必需）
OPTIONAL_DEPS=("net-tools" "fzf" "dnsutils" "yamllint" "cron")
INSTALLED_DEPS=()

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
        echo -e "${RED}下载失败，重试中...${RESET}"
        sleep 2
        ((attempt++))
    done
    echo -e "${RED}错误：下载 $url 失败${RESET}"
    return 1
}

release_port_53() {
    echo -e "${YELLOW}检查并释放53端口...${RESET}"
    if command -v netstat >/dev/null 2>&1 && netstat -tuln | grep -q ":53 "; then
        if command -v lsof >/dev/null 2>&1; then
            PIDS=$(lsof -i :53 | awk 'NR>1 {print $2}' | sort -u)
            for PID in $PIDS; do
                SERVICE=$(ps -p "$PID" -o comm=)
                echo -e "${YELLOW}找到占用53端口的服务：$SERVICE (PID: $PID)${RESET}"
                if command -v systemctl >/dev/null 2>&1 && systemctl is-active "systemd-resolved" >/dev/null 2>&1 && [[ "$SERVICE" =~ systemd ]]; then
                    systemctl stop systemd-resolved
                    systemctl disable systemd-resolved
                else
                    kill -9 "$PID"
                fi
            done
        else
            echo -e "${YELLOW}未安装 lsof，无法精确释放端口，尝试直接杀进程${RESET}"
            kill -9 $(netstat -tuln | grep ":53 " | awk '{print $NF}') 2>/dev/null
        fi
        sleep 1
        if netstat -tuln | grep -q ":53 "; then
            echo -e "${RED}错误：无法释放53端口${RESET}"
            exit 1
        fi
        echo -e "${GREEN}53端口已释放${RESET}"
    else
        echo -e "${GREEN}53端口未被占用或 netstat 未安装${RESET}"
    fi
}

configure_dual_adg() {
    echo -e "\n${YELLOW}配置双AdGuard Home分流${RESET}"
    echo -e "请输入国内ADG地址（默认 127.0.0.1:530）："
    read -p "> " LOCAL_ADG
    LOCAL_ADG=${LOCAL_ADG:-127.0.0.1:530}
    if ! [[ "$LOCAL_ADG" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        echo -e "${RED}错误：格式无效${RESET}"
        exit 1
    fi

    echo -e "请输入国外ADG地址（默认 127.0.0.1:531）："
    read -p "> " REMOTE_ADG
    REMOTE_ADG=${REMOTE_ADG:-127.0.0.1:531}
    if ! [[ "$REMOTE_ADG" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        echo -e "${RED}错误：格式无效${RESET}"
        exit 1
    fi

    CONFIG_PATH="/etc/mosdns"
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

  - tag: "local_forward"
    type: forward
    args:
      concurrent: 4
      upstreams:
        - addr: "$LOCAL_ADG"

  - tag: "remote_forward"
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "$REMOTE_ADG"

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
      - matches: "qname \$direct_domain"
        exec: goto local_sequence
      - matches: "qname \$remote_domain"
        exec: goto remote_sequence
      - exec: goto remote_sequence

  - type: udp_server
    args:
      entry: main_sequence
      listen: 127.0.0.1:53
EOF

    TEMP_LOG=$(mktemp)
    /usr/local/bin/mosdns start -c "$CONFIG_PATH/config.yaml" >"$TEMP_LOG" 2>&1 &
    MOSDNS_PID=$!
    sleep 2
    if ! kill -0 "$MOSDNS_PID" 2>/dev/null; then
        echo -e "${RED}错误：新配置文件无效${RESET}"
        cat "$TEMP_LOG"
        rm -f "$TEMP_LOG"
        exit 1
    fi
    kill "$MOSDNS_PID"
    rm -f "$TEMP_LOG"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart mosdns
        sleep 3
        if systemctl status mosdns.service | grep -q "running"; then
            echo -e "${GREEN}成功：MosDNS已重启并应用新配置${RESET}"
        else
            echo -e "${RED}错误：MosDNS 重启失败${RESET}"
            systemctl status mosdns.service
            exit 1
        fi
    else
        echo -e "${YELLOW}无 systemd，跳过服务重启，请手动重启 MosDNS${RESET}"
    fi
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

    release_port_53
    PORT=53

    echo -e "\n${YELLOW}请输入国内DNS地址（默认 https://223.5.5.5/dns-query）：${RESET}"
    read -p "> " DOMESTIC_DNS
    DOMESTIC_DNS=${DOMESTIC_DNS:-https://223.5.5.5/dns-query}

    echo -e "\n${YELLOW}请输入国外DNS地址（默认 1.1.1.1）：${RESET}"
    read -p "> " FOREIGN_DNS
    FOREIGN_DNS=${FOREIGN_DNS:-1.1.1.1}

    DOWNLOAD_URL="https://github.com/IrineSistiana/mosdns/releases/$([ "$VERSION" = "latest" ] && echo "latest/download" || echo "download/$VERSION")/mosdns-linux-$ARCHITECTURE.zip"
    download_with_retry "$DOWNLOAD_URL" "mosdns.zip" || exit 1
    download_with_retry "https://ghfast.top/https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt" "$CONFIG_PATH/cn_domains.txt" || exit 1
    download_with_retry "https://ghfast.top/https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt" "$CONFIG_PATH/non_cn_domains.txt" || exit 1

    if [ ! -s "$CONFIG_PATH/cn_domains.txt" ] || [ ! -s "$CONFIG_PATH/non_cn_domains.txt" ]; then
        echo -e "${RED}错误：规则文件为空${RESET}"
        exit 1
    fi

    unzip -o mosdns.zip mosdns -d "$INSTALL_PATH" || { echo -e "${RED}错误：解压失败${RESET}"; exit 1; }
    chmod +x "$INSTALL_PATH/mosdns"
    MOSDNS_VERSION=$("$INSTALL_PATH/mosdns" version 2>/dev/null || "$INSTALL_PATH/mosdns" --version)
    echo -e "${GREEN}MosDNS 版本：$MOSDNS_VERSION${RESET}"
    rm -f mosdns.zip

    dial_addr="${DOMESTIC_DNS#https://}"
    dial_addr="${dial_addr%/dns-query}"
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

  - tag: "local_forward"
    type: forward
    args:
      concurrent: 4
      upstreams:
        - addr: "$DOMESTIC_DNS"
          enable_http3: true
          enable_pipeline: true
          dial_addr: "$dial_addr"

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
        echo -e "${RED}错误：配置文件无效${RESET}"
        cat "$TEMP_LOG"
        rm -f "$TEMP_LOG"
        exit 1
    fi
    kill "$MOSDNS_PID"
    rm -f "$TEMP_LOG"

    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/mosdns.service <<EOF
[Unit]
Description=MosDNS Service
After=network.target

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
            echo "nameserver 127.0.0.1" > /etc/resolv.conf
            chmod 644 /etc/resolv.conf
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
            echo "nameserver 127.0.0.1" > /etc/resolv.conf
            chmod 644 /etc/resolv.conf
        else
            echo -e "${RED}错误：MosDNS 启动失败${RESET}"
            exit 1
        fi
    fi

    echo -e "\n${YELLOW}是否配置双AdGuard Home分流？(y/n)：${RESET}"
    read -p "> " CONFIG_ADG
    if [ "${CONFIG_ADG:-n}" = "y" ]; then
        configure_dual_adg
    fi

    echo -e "\n${GREEN}MosDNS 已启动并监听 127.0.0.1:53${RESET}"
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

    if [ -f /etc/resolv.conf.bak ]; then
        mv /etc/resolv.conf.bak /etc/resolv.conf
        echo -e "${GREEN}已还原DNS配置${RESET}"
    else
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        chmod 644 /etc/resolv.conf
        echo -e "${GREEN}未找到备份，使用默认DNS 8.8.8.8${RESET}"
    fi

    crontab -l 2>/dev/null | grep -v "update_mosdns_rules.sh" | crontab -
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

    download_with_retry "https://ghfast.top/https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt" "$CONFIG_PATH/cn_domains.txt" || {
        [ -f "$CONFIG_PATH/cn_domains.txt.bak" ] && mv "$CONFIG_PATH/cn_domains.txt.bak" "$CONFIG_PATH/cn_domains.txt"
        exit 1
    }
    download_with_retry "https://ghfast.top/https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt" "$CONFIG_PATH/non_cn_domains.txt" || {
        [ -f "$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "$CONFIG_PATH/non_cn_domains.txt.bak" "$CONFIG_PATH/non_cn_domains.txt"
        exit 1
    }

    if [ ! -s "$CONFIG_PATH/cn_domains.txt" ] || [ ! -s "$CONFIG_PATH/non_cn_domains.txt" ]; then
        echo -e "${RED}规则文件为空，回滚...${RESET}"
        [ -f "$CONFIG_PATH/cn_domains.txt.bak" ] && mv "$CONFIG_PATH/cn_domains.txt.bak" "$CONFIG_PATH/cn_domains.txt"
        [ -f "$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "$CONFIG_PATH/non_cn_domains.txt.bak" "$CONFIG_PATH/non_cn_domains.txt"
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
            exit 1
        fi
    fi

    if command -v cron >/dev/null 2>&1; then
        cat > /usr/local/bin/update_mosdns_rules.sh <<EOF
#!/bin/bash
CONFIG_PATH="/etc/mosdns"
cp "\$CONFIG_PATH/cn_domains.txt" "\$CONFIG_PATH/cn_domains.txt.bak" 2>/dev/null
cp "\$CONFIG_PATH/non_cn_domains.txt" "\$CONFIG_PATH/non_cn_domains.txt.bak" 2>/dev/null
curl -L -o "\$CONFIG_PATH/cn_domains.txt" "https://ghfast.top/https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt" || {
    [ -f "\$CONFIG_PATH/cn_domains.txt.bak" ] && mv "\$CONFIG_PATH/cn_domains.txt.bak" "\$CONFIG_PATH/cn_domains.txt"
    exit 1
}
curl -L -o "\$CONFIG_PATH/non_cn_domains.txt" "https://ghfast.top/https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt" || {
    [ -f "\$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "\$CONFIG_PATH/non_cn_domains.txt.bak" "\$CONFIG_PATH/non_cn_domains.txt"
    exit 1
}
if [ ! -s "\$CONFIG_PATH/cn_domains.txt" ] || [ ! -s "\$CONFIG_PATH/non_cn_domains.txt" ]; then
    [ -f "\$CONFIG_PATH/cn_domains.txt.bak" ] && mv "\$CONFIG_PATH/cn_domains.txt.bak" "\$CONFIG_PATH/cn_domains.txt"
    [ -f "\$CONFIG_PATH/non_cn_domains.txt.bak" ] && mv "\$CONFIG_PATH/non_cn_domains.txt.bak" "\$CONFIG_PATH/non_cn_domains.txt"
    exit 1
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart mosdns
else
    killall mosdns 2>/dev/null
    /usr/local/bin/mosdns start -c "\$CONFIG_PATH/config.yaml" &
fi
EOF
        chmod +x /usr/local/bin/update_mosdns_rules.sh
        (crontab -l 2>/dev/null | grep -v "update_mosdns_rules.sh"; echo "0 0 * * 5 /usr/local/bin/update_mosdns_rules.sh") | crontab -
        echo -e "${GREEN}已设置每周五自动更新${RESET}"
    else
        echo -e "${YELLOW}无 cron，跳过自动更新设置${RESET}"
    fi
}

echo -e "${YELLOW}MosDNS 安装与管理脚本${RESET}"
PS3="请选择操作（输入数字）："
OPTIONS=("安装MosDNS" "卸载清理MosDNS" "更新规则" "退出")
select opt in "${OPTIONS[@]}"; do
    case $opt in
        "安装MosDNS")
            check_install_deps
            install_mosdns
            break
            ;;
        "卸载清理MosDNS")
            uninstall_mosdns
            break
            ;;
        "更新规则")
            update_rules
            break
            ;;
        "退出")
            echo -e "${GREEN}退出脚本${RESET}"
            exit 0
            ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
done

echo "日志记录结束：$(date)"
