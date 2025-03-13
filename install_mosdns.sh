#!/bin/bash

# MosDNS 一键安装与管理脚本（专业版）

# 颜色定义
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
RESET='\e[0m'

# 日志文件
LOG_FILE="/var/log/mosdns_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "日志记录开始：$(date)"

# 检查root权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：需要root权限运行此脚本，请使用 sudo${RESET}"
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
else
    echo -e "${RED}错误：未检测到支持的包管理器（apt/yum/dnf）${RESET}"
    exit 1
fi

# 依赖列表
DEPENDENCIES=("curl" "unzip" "sed" "net-tools" "awk" "fzf" "dnsutils" "yamllint")
INSTALLED_DEPS=()

# 检查并安装依赖
check_install_deps() {
    echo -e "${YELLOW}检查并安装依赖...${RESET}"
    $PKG_MANAGER update
    for dep in "${DEPENDENCIES[@]}"; do
        if ! command -v "${dep%%:*}" >/dev/null 2>&1; then
            echo -e "${YELLOW}安装缺失依赖：$dep${RESET}"
            case "$dep" in
                fzf) $INSTALL_CMD fzf || { echo -e "${RED}警告：无法安装 fzf，将使用默认版本${RESET}"; USE_LATEST=true; } ;;
                dnsutils) $INSTALL_CMD dnsutils || echo -e "${YELLOW}警告：无法安装 dig，跳过自动验证${RESET}" ;;
                yamllint) $INSTALL_CMD yamllint || echo -e "${YELLOW}警告：无法安装 yamllint，跳过高级语法检查${RESET}" ;;
                *) $INSTALL_CMD "$dep" || { echo -e "${RED}错误：无法安装 $dep${RESET}"; exit 1; } ;;
            esac
            INSTALLED_DEPS+=("$dep")
        fi
    done
    [ "${#INSTALLED_DEPS[@]}" -gt 0 ] && echo -e "${GREEN}已安装依赖：${INSTALLED_DEPS[*]}${RESET}"
}

# 配置双ADG并生成新配置文件
configure_dual_adg() {
    echo -e "\n${YELLOW}配置双AdGuard Home (ADG) 分流${RESET}"
    echo -e "请输入负责国内DNS的ADG地址（格式：IP:端口，默认 127.0.0.1:530）："
    read -p "> " LOCAL_ADG
    LOCAL_ADG=${LOCAL_ADG:-127.0.0.1:530}
    if ! [[ "$LOCAL_ADG" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        echo -e "${RED}错误：格式无效，必须为 IP:端口（如 127.0.0.1:530）${RESET}"
        exit 1
    fi

    echo -e "请输入负责国外DNS的ADG地址（格式：IP:端口，默认 127.0.0.1:531）："
    read -p "> " REMOTE_ADG
    REMOTE_ADG=${REMOTE_ADG:-127.0.0.1:531}
    if ! [[ "$REMOTE_ADG" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        echo -e "${RED}错误：格式无效，必须为 IP:端口（如 127.0.0.1:531）${RESET}"
        exit 1
    fi

    # 检查端口是否被占用（排除mosdns自身）
    for PORT in "${LOCAL_ADG##*:}" "${REMOTE_ADG##*:}"; do
        if netstat -tuln | grep -v "127.0.0.1:53" | grep -q ":$PORT "; then
            echo -e "${RED}错误：端口 $PORT 已被占用，请选择其他端口${RESET}"
            exit 1
        fi
    done

    # 生成新配置文件
    echo -e "${YELLOW}生成新配置文件...${RESET}"
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
        - "$CONFIG_PATH/accelerated-domains.china.conf.raw.txt"
        - "$CONFIG_PATH/apple.china.conf.raw.txt"

  - tag: "local_forward"
    type: forward
    args:
      concurrent: 4
      upstreams:
        - addr: "$LOCAL_ADG"  # 国内ADG

  - tag: "remote_forward"
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "$REMOTE_ADG"  # 国外ADG

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
      - exec: goto remote_sequence

  - type: udp_server
    args:
      entry: main_sequence
      listen: 127.0.0.1:53
EOF

    # 校验新配置文件
    echo -e "${YELLOW}校验新配置文件语法...${RESET}"
    if command -v yamllint >/dev/null 2>&1; then
        TEMP_YAML_CONF=$(mktemp)
        cat > "$TEMP_YAML_CONF" <<EOF
---
extends: default
rules:
  key-duplicates: enable
EOF
        if ! yamllint -c "$TEMP_YAML_CONF" "$CONFIG_PATH/config.yaml"; then
            echo -e "${RED}错误：新配置文件语法无效，请检查 $CONFIG_PATH/config.yaml${RESET}"
            rm -f "$TEMP_YAML_CONF"
            exit 1
        fi
        rm -f "$TEMP_YAML_CONF"
        echo -e "${GREEN}新配置文件语法校验通过${RESET}"
    else
        echo -e "${YELLOW}警告：未安装 yamllint，跳过高级语法检查${RESET}"
    fi

    # 测试运行新配置文件
    echo -e "${YELLOW}测试运行新配置文件...${RESET}"
    TEMP_LOG=$(mktemp)
    /usr/local/bin/mosdns start -c "$CONFIG_PATH/config.yaml" >"$TEMP_LOG" 2>&1 &
    MOSDNS_PID=$!
    sleep 2
    if ! kill -0 "$MOSDNS_PID" 2>/dev/null; then
        echo -e "${RED}错误：新配置文件运行失败，请检查 $CONFIG_PATH/config.yaml${RESET}"
        echo -e "${YELLOW}详细信息：${RESET}"
        cat "$TEMP_LOG"
        rm -f "$TEMP_LOG"
        exit 1
    fi
    kill "$MOSDNS_PID"
    echo -e "${GREEN}新配置文件测试通过${RESET}"
    rm -f "$TEMP_LOG"

    # 重启服务
    echo -e "${YELLOW}重启MosDNS服务以应用新配置...${RESET}"
    systemctl restart mosdns
    sleep 3
    if systemctl status mosdns.service | grep -q "running"; then
        echo -e "${GREEN}成功：MosDNS已重启并应用新配置${RESET}"
        echo -e "国内DNS指向：$LOCAL_ADG"
        echo -e "国外DNS指向：$REMOTE_ADG"
    else
        echo -e "${RED}错误：MosDNS 重启失败${RESET}"
        systemctl status mosdns.service
        exit 1
    fi
}

# 安装MosDNS
install_mosdns() {
    # 检测架构
    echo -e "${YELLOW}检测系统架构...${RESET}"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCHITECTURE="amd64" ;;
        aarch64) ARCHITECTURE="arm64" ;;
        armv7l) ARCHITECTURE="arm" ;;
        riscv64) ARCHITECTURE="riscv64" ;;
        *) echo -e "${RED}错误：不支持的架构：$ARCH${RESET}"; exit 1 ;;
    esac
    echo -e "${GREEN}检测到架构：$ARCHITECTURE${RESET}"

    # 确定安装路径
    INSTALL_PATH="/usr/local/bin"
    CONFIG_PATH="/etc/mosdns"
    mkdir -p "$CONFIG_PATH" || { echo -e "${RED}错误：无法创建配置目录 $CONFIG_PATH${RESET}"; exit 1; }
    echo -e "${GREEN}安装路径：$INSTALL_PATH${RESET}"
    echo -e "${GREEN}配置路径：$CONFIG_PATH${RESET}"

    # 获取MosDNS版本
    echo -e "\n${YELLOW}获取MosDNS版本列表...${RESET}"
    if [ "${USE_LATEST:-false}" = true ] || ! command -v fzf >/dev/null 2>&1; then
        VERSION="latest"
        echo -e "${GREEN}未安装 fzf 或跳过选择，默认使用最新版本${RESET}"
    else
        for attempt in {1..3}; do
            VERSIONS=$(curl -s --retry 3 "https://api.github.com/repos/IrineSistiana/mosdns/releases" | grep -oP '"tag_name": "\K[^"]+' | sort -rV)
            [ -n "$VERSIONS" ] && break
            echo -e "${RED}第 $attempt 次获取版本列表失败，重试...${RESET}"
            [ "$attempt" -eq 3 ] && { echo -e "${RED}错误：无法获取版本列表，请检查网络${RESET}"; exit 1; }
            sleep 2
        done
        VERSION=$(echo "$VERSIONS" | fzf --prompt="请选择MosDNS版本（默认最新）: " --height=10)
        VERSION=${VERSION:-latest}
    fi
    echo -e "${GREEN}选择的版本：$VERSION${RESET}"

    # 用户输入：监听端口
    echo -e "\n${YELLOW}请输入MosDNS监听端口（默认53）：${RESET}"
    read -p "> " PORT
    PORT=${PORT:-53}
    if netstat -tuln | grep -q ":$PORT "; then
        echo -e "${RED}错误：端口 $PORT 已被占用，请选择其他端口或释放该端口${RESET}"
        exit 1
    fi

    # 用户输入：国内DNS
    echo -e "\n${YELLOW}请输入国内DNS地址（格式：https://x.x.x.x/dns-query），每行一个${RESET}"
    echo "按两次回车结束，留空使用默认（223.5.5.5, 223.6.6.6 等）："
    DOMESTIC_DNS=()
    DEFAULT_DOMESTIC=("https://223.5.5.5/dns-query" "https://223.6.6.6/dns-query" "https://1.12.12.12/dns-query" "https://120.53.53.53/dns-query")
    while true; do
        read -p "> " INPUT
        if [ -z "$INPUT" ]; then
            if [ ${#DOMESTIC_DNS[@]} -eq 0 ]; then
                DOMESTIC_DNS=("${DEFAULT_DOMESTIC[@]}")
                echo -e "${GREEN}使用默认国内DNS：${DOMESTIC_DNS[*]}${RESET}"
            fi
            break
        fi
        if [[ "$INPUT" =~ ^https://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/dns-query$ ]]; then
            DOMESTIC_DNS+=("$INPUT")
        else
            echo -e "${RED}警告：格式错误（需为 https://x.x.x.x/dns-query），已忽略${RESET}"
        fi
    done

    # 用户输入：国外DNS
    echo -e "\n${YELLOW}请输入国外DNS地址（格式：x.x.x.x），每行一个${RESET}"
    echo "按两次回车结束，留空使用默认（1.1.1.1, 1.0.0.1）："
    FOREIGN_DNS=()
    DEFAULT_FOREIGN=("1.1.1.1" "1.0.0.1")
    while true; do
        read -p "> " INPUT
        if [ -z "$INPUT" ]; then
            if [ ${#FOREIGN_DNS[@]} -eq 0 ]; then
                FOREIGN_DNS=("${DEFAULT_FOREIGN[@]}")
                echo -e "${GREEN}使用默认国外DNS：${FOREIGN_DNS[*]}${RESET}"
            fi
            break
        fi
        if [[ "$INPUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            FOREIGN_DNS+=("$INPUT")
        else
            echo -e "${RED}警告：格式错误（需为 x.x.x.x），已忽略${RESET}"
        fi
    done

    # 用户输入：HTTP/3支持
    echo -e "\n${YELLOW}是否为国内DNS启用HTTP/3支持？(y/n，默认y)：${RESET}"
    read -p "> " HTTP3
    HTTP3=${HTTP3:-y}
    [ "$HTTP3" = "y" ] && ENABLE_HTTP3="true" || ENABLE_HTTP3="false"

    # 下载文件
    echo -e "\n${YELLOW}下载MosDNS和域名列表...${RESET}"
    DOWNLOAD_URL="https://github.com/IrineSistiana/mosdns/releases/$([ "$VERSION" = "latest" ] && echo "latest/download" || echo "download/$VERSION")/mosdns-linux-$ARCHITECTURE.zip"
    echo -e "${YELLOW}下载URL：$DOWNLOAD_URL${RESET}"
    curl -L -# -o mosdns.zip "$DOWNLOAD_URL" || { echo -e "${RED}错误：MosDNS 下载失败，请检查网络或版本号${RESET}"; exit 1; }
    curl -L -# -o "$CONFIG_PATH/accelerated-domains.china.conf" "https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf" || {
        echo -e "${RED}错误：加速域名列表下载失败${RESET}"; exit 1;
    }
    curl -L -# -o "$CONFIG_PATH/apple.china.conf" "https://github.com/felixonmars/dnsmasq-china-list/raw/master/apple.china.conf" || {
        echo -e "${RED}错误：苹果域名列表下载失败${RESET}"; exit 1;
    }

    # 解压和验证
    echo -e "${YELLOW}处理文件...${RESET}"
    unzip -o mosdns.zip mosdns -d "$INSTALL_PATH" || { echo -e "${RED}错误：解压失败${RESET}"; exit 1; }
    chmod +x "$INSTALL_PATH/mosdns"
    MOSDNS_VERSION=$("$INSTALL_PATH/mosdns" version 2>/dev/null || "$INSTALL_PATH/mosdns" --version)
    echo -e "${GREEN}MosDNS 版本：$MOSDNS_VERSION${RESET}"
    rm -f mosdns.zip
    awk '{print $2}' "$CONFIG_PATH/accelerated-domains.china.conf" > "$CONFIG_PATH/accelerated-domains.china.conf.raw.txt"
    awk '{print $2}' "$CONFIG_PATH/apple.china.conf" > "$CONFIG_PATH/apple.china.conf.raw.txt"

    # 生成初始配置文件
    echo -e "${YELLOW}生成初始配置文件...${RESET}"
    cat > "$CONFIG_PATH/config.yaml" <<EOF
log:
  level: info
  file: "$CONFIG_PATH/mosdns.log"

plugins:
  - tag: "direct_domain"
    type: domain_set
    args:
      files:
        - "$CONFIG_PATH/accelerated-domains.china.conf.raw.txt"
        - "$CONFIG_PATH/apple.china.conf.raw.txt"

  - tag: "local_forward"
    type: forward
    args:
      concurrent: 4
      upstreams:
$(for addr in "${DOMESTIC_DNS[@]}"; do
    echo "        - addr: \"$addr\""
    echo "          enable_http3: $ENABLE_HTTP3"
    echo "          enable_pipeline: true"
    echo "          dial_addr: \"${addr#https://}\""
done | sed 's|/dns-query||')

  - tag: "remote_forward"
    type: forward
    args:
      concurrent: 2
      upstreams:
$(for addr in "${FOREIGN_DNS[@]}"; do echo "        - addr: \"$addr\""; done)

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
      - exec: goto remote_sequence

  - type: udp_server
    args:
      entry: main_sequence
      listen: 127.0.0.1:$PORT
EOF

    # 校验初始配置文件
    echo -e "${YELLOW}校验初始配置文件语法...${RESET}"
    if command -v yamllint >/dev/null 2>&1; then
        TEMP_YAML_CONF=$(mktemp)
        cat > "$TEMP_YAML_CONF" <<EOF
---
extends: default
rules:
  key-duplicates: enable
EOF
        if ! yamllint -c "$TEMP_YAML_CONF" "$CONFIG_PATH/config.yaml"; then
            echo -e "${RED}错误：初始配置文件语法无效，请检查 $CONFIG_PATH/config.yaml${RESET}"
            rm -f "$TEMP_YAML_CONF"
            exit 1
        fi
        rm -f "$TEMP_YAML_CONF"
        echo -e "${GREEN}初始配置文件语法校验通过${RESET}"
    else
        echo -e "${YELLOW}警告：未安装 yamllint，跳过高级语法检查${RESET}"
    fi

    # 测试运行初始配置文件
    echo -e "${YELLOW}测试运行初始配置文件...${RESET}"
    TEMP_LOG=$(mktemp)
    "$INSTALL_PATH/mosdns" start -c "$CONFIG_PATH/config.yaml" >"$TEMP_LOG" 2>&1 &
    MOSDNS_PID=$!
    sleep 2
    if ! kill -0 "$MOSDNS_PID" 2>/dev/null; then
        echo -e "${RED}错误：初始配置文件运行失败，请检查 $CONFIG_PATH/config.yaml${RESET}"
        echo -e "${YELLOW}详细信息：${RESET}"
        cat "$TEMP_LOG"
        rm -f "$TEMP_LOG"
        exit 1
    fi
    kill "$MOSDNS_PID"
    echo -e "${GREEN}初始配置文件测试通过${RESET}"
    rm -f "$TEMP_LOG"

    # 检查并禁用冲突服务
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到 systemd-resolved 运行，可能冲突，正在禁用...${RESET}"
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        RESOLVED_DISABLED=true
    fi

    # 创建systemd服务
    echo -e "${YELLOW}设置系统服务...${RESET}"
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

    # 运行验证
    echo -e "${YELLOW}验证MosDNS运行...${RESET}"
    sleep 3
    if systemctl status mosdns.service | grep -q "running"; then
        if command -v dig >/dev/null 2>&1; then
            if dig @127.0.0.1 -p "$PORT" example.com >/dev/null 2>&1; then
                echo -e "${GREEN}成功：MosDNS正常运行${RESET}"
            else
                echo -e "${RED}失败：MosDNS未正常运行，请检查日志 $CONFIG_PATH/mosdns.log${RESET}"
                systemctl status mosdns.service
                cat "$CONFIG_PATH/mosdns.log"
                exit 1
            fi
        else
            echo -e "${YELLOW}未安装 dig，无法自动验证，请手动测试${RESET}"
        fi
    else
        echo -e "${RED}错误：MosDNS 服务未运行${RESET}"
        systemctl status mosdns.service
        exit 1
    fi

    # 交互式选项：配置双ADG
    echo -e "\n${YELLOW}安装完成！是否配置双AdGuard Home分流？(y/n)：${RESET}"
    read -p "> " CONFIG_ADG
    if [ "${CONFIG_ADG:-n}" = "y" ]; then
        configure_dual_adg
    else
        echo -e "${GREEN}跳过双ADG配置，使用默认DNS分流${RESET}"
    fi

    # 完成提示
    echo -e "\n${GREEN}MosDNS 已启动并监听 127.0.0.1:$PORT${RESET}"
    echo -e "配置文件：$CONFIG_PATH/config.yaml"
    echo -e "日志文件：$CONFIG_PATH/mosdns.log"
    echo -e "\n${YELLOW}常用命令：${RESET}"
    echo "  查看状态：systemctl status mosdns"
    echo "  停止服务：systemctl stop mosdns"
    echo "  重启服务：systemctl restart mosdns"
    echo "  查看日志：tail -f $CONFIG_PATH/mosdns.log"
}

# 卸载清理MosDNS
uninstall_mosdns() {
    echo -e "${YELLOW}开始卸载并清理MosDNS...${RESET}"
    INSTALL_PATH="/usr/local/bin"
    CONFIG_PATH="/etc/mosdns"

    if systemctl is-active mosdns.service >/dev/null 2>&1; then
        systemctl stop mosdns.service
        systemctl disable mosdns.service
    fi
    rm -f /etc/systemd/system/mosdns.service
    systemctl daemon-reload
    rm -f "$INSTALL_PATH/mosdns"
    rm -rf "$CONFIG_PATH"

    if [ "${RESOLVED_DISABLED:-false}" = true ] && command -v systemd-resolve >/dev/null 2>&1; then
        echo -e "${YELLOW}恢复 systemd-resolved 服务...${RESET}"
        systemctl enable systemd-resolved
        systemctl start systemd-resolved
    fi

    echo -e "${GREEN}MosDNS 已卸载并清理完成！${RESET}"
}

# 交互式菜单
echo -e "${YELLOW}MosDNS 安装与管理脚本${RESET}"
PS3="请选择操作（输入数字）："
OPTIONS=("安装MosDNS" "卸载清理MosDNS" "退出")
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
        "退出")
            echo -e "${GREEN}退出脚本${RESET}"
            exit 0
            ;;
        *) echo -e "${RED}无效选项，请输入 1-3${RESET}" ;;
    esac
done

echo "日志记录结束：$(date)"
