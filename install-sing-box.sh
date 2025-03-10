#!/bin/bash
set -euo pipefail

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 日志记录函数
log() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}此脚本必须以root用户运行${NC}"
        exit 1
    fi
}

# 获取架构信息
get_arch() {
    case $(uname -m) in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)       echo -e "${RED}未知架构: $(uname -m)${NC}" >&2; exit 1 ;;
    esac
}

# 安装依赖
install_deps() {
    log "正在检查依赖..."
    if command -v apt &>/dev/null; then
        apt update
        apt install -y curl tar iptables ipset
    elif command -v yum &>/dev/null; then
        yum install -y curl tar iptables ipset
    elif command -v apk &>/dev/null; then
        apk add curl tar iptables ipset
    else
        echo -e "${RED}不支持的包管理器${NC}"
        exit 1
    fi
}

# 获取本机IP
get_gateway_ip() {
    local iface=$(ip route show default | awk '/default/ {print $5}')
    if [[ -z $iface ]]; then
        echo -e "${RED}无法获取默认网络接口${NC}"
        exit 1
    fi
    ip addr show dev $iface | awk '/inet / {print $2}' | cut -d'/' -f1
}

# 验证版本号格式
validate_version() {
    local version=$1
    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$ ]]; then
        echo -e "${RED}无效的版本号格式${NC}"
        exit 1
    fi
}

# 验证订阅URL
validate_url() {
    local url=$1
    if [[ ! $url =~ ^https?:// ]]; then
        echo -e "${RED}无效的订阅URL${NC}"
        exit 1
    fi
}

# 清理临时文件
cleanup() {
    if [[ -d $TEMP_DIR ]]; then
        log "清理临时文件..."
        rm -rf $TEMP_DIR
    fi
}

# 检查iptables规则
check_iptables() {
    log "检查 iptables NAT 规则..."
    if ! iptables -t nat -L | grep -q "MASQUERADE"; then
        log "iptables规则未生效，重新配置..."
        iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE
        save_iptables_rules
    fi
}

# 保存iptables规则
save_iptables_rules() {
    mkdir -p /etc/iptables
    iptables-save | tee /etc/iptables/rules.v4 >/dev/null
}

# 检查网络通畅性
check_network() {
    log "检查网络通畅性..."
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        echo -e "${RED}无法连接到外网，请检查网络配置${NC}"
        exit 1
    fi
    echo -e "${GREEN}网络连接正常${NC}"
}

# 检查默认路由
check_default_route() {
    log "检查默认路由..."
    local default_route=$(ip route show | grep "^default")
    if [[ -z "$default_route" ]]; then
        echo -e "${RED}未找到默认路由，请手动配置${NC}"
        exit 1
    fi
    log "默认路由：$default_route"
}

# 启用网络转发
enable_ip_forwarding() {
    log "启用网络转发..."
    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' | tee -a /etc/sysctl.conf >/dev/null
    log "网络转发已启用"
}

# 卸载清理
uninstall() {
    log "开始卸载sing-box..."
    systemctl stop sing-box || true
    systemctl disable sing-box || true
    rm -f /etc/systemd/system/sing-box.service
    rm -f /usr/local/bin/sing-box
    rm -rf /etc/sing-box
    iptables -t nat -D POSTROUTING -s 192.168.0.0/16 -j MASQUERADE || true
    save_iptables_rules
    log "sing-box已卸载，网络配置已恢复"
}

# 主安装流程
install() {
    check_root
    trap 'echo -e "${RED}安装中断，正在清理...${NC}"; cleanup; exit 1' INT

    # 1. 架构检测
    ARCH=$(get_arch)
    log "检测到系统架构: ${ARCH}"

    # 2. 版本选择
    read -p "选择版本类型 (测试版输入a/正式版输入s): " version_type
    case $version_type in
        a*) 
            read -p "请输入测试版完整版本号 (例如: 1.12.0-alpha.9): " version
            validate_version "$version"
            repo_tag="v$version"
            file_tag="$version"
            ;;
        s*)
            read -p "请输入正式版完整版本号 (例如: 1.11.3): " version
            validate_version "$version"
            repo_tag="v$version"
            file_tag="$version"
            ;;
        *) 
            echo -e "${RED}无效选择${NC}"
            exit 1
            ;;
    esac

    # 3. 安装依赖
    install_deps

    # 4. 下载安装
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${repo_tag}/sing-box-${file_tag}-linux-${ARCH}.tar.gz"
    log "下载地址: ${DOWNLOAD_URL}"
    
    TEMP_DIR=$(mktemp -d)
    if ! curl -sSL $DOWNLOAD_URL | tar xz -C $TEMP_DIR; then
        echo -e "${RED}下载或解压失败${NC}"
        cleanup
        exit 1
    fi

    if ! cp $TEMP_DIR/sing-box-${file_tag}-linux-${ARCH}/sing-box /usr/local/bin/; then
        echo -e "${RED}复制文件失败${NC}"
        cleanup
        exit 1
    fi
    chmod +x /usr/local/bin/sing-box

    # 5. 配置订阅
    read -p "请输入配置文件订阅URL: " config_url
    validate_url "$config_url"
    mkdir -p /etc/sing-box
    if ! curl -sSL $config_url | tee /etc/sing-box/config.json >/dev/null; then
        echo -e "${RED}配置文件下载失败${NC}"
        cleanup
        exit 1
    fi

    # 6. 创建服务文件
    cat <<EOF | tee /etc/systemd/system/sing-box.service >/dev/null
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 7. 启动服务
    systemctl daemon-reload
    systemctl enable sing-box
    if ! systemctl start sing-box; then
        echo -e "${RED}服务启动失败，请检查配置${NC}"
        journalctl -u sing-box -n 50 --no-pager
        cleanup
        exit 1
    fi

    # 8. 网络配置
    GATEWAY_IP=$(get_gateway_ip)
    log "配置网关地址: ${GATEWAY_IP}"
    
    enable_ip_forwarding
    check_default_route
    iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE
    save_iptables_rules

    # 9. 检查iptables规则和网络
    check_iptables
    check_network

    # 显示使用信息
    echo -e "${GREEN}安装完成！请将其他设备的网关设置为: ${GATEWAY_IP}${NC}"
    echo -e "服务状态检查: ${YELLOW}systemctl status sing-box${NC}"
    echo -e "日志查看: ${YELLOW}journalctl -u sing-box -f${NC}"
}

# 主菜单
main_menu() {
    echo -e "${GREEN}请选择操作：${NC}"
    echo "1. 安装 sing-box"
    echo "2. 卸载 sing-box"
    read -p "请输入选项 (1 或 2): " choice

    case $choice in
        1)
            install
            ;;
        2)
            uninstall
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            exit 1
            ;;
    esac
}

# 主入口
main_menu
