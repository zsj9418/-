#!/bin/bash
set -euo pipefail

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 日志记录函数
log() {
    local log_file="/var/log/sing-box-install.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a $log_file >/dev/null
}

# 输入验证：版本号
validate_version() {
    if [[ ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9\.]+)?$ ]]; then
        echo -e "${RED}无效的版本号格式${NC}"
        exit 1
    fi
}

# 输入验证：URL
validate_url() {
    if [[ ! $1 =~ ^https?:// ]]; then
        echo -e "${RED}无效的URL格式${NC}"
        exit 1
    fi
}

# 错误重试函数
retry() {
    local retries=3
    local count=0
    until "$@"; do
        count=$((count + 1))
        if [ $count -lt $retries ]; then
            echo -e "${YELLOW}操作失败，重试中... ($count/$retries)${NC}"
            sleep 2
        else
            echo -e "${RED}操作失败，重试次数已达上限${NC}"
            return 1
        fi
    done
}

# 获取架构信息
get_arch() {
    case $(uname -m) in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)       echo -e "${RED}不支持的架构: $(uname -m)${NC}" >&2; exit 1 ;;
    esac
}

# 安装依赖
install_deps() {
    if command -v apt &>/dev/null; then
        sudo apt update
        sudo apt install -y curl tar iptables ipset jq
    elif command -v yum &>/dev/null; then
        sudo yum install -y curl tar iptables ipset jq
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y curl tar iptables ipset jq
    elif command -v apk &>/dev/null; then
        sudo apk add curl tar iptables ipset jq
    elif command -v zypper &>/dev/null; then
        sudo zypper install -y curl tar iptables ipset jq
    else
        echo -e "${RED}不支持的包管理器${NC}"
        exit 1
    fi
}

# 获取本机IP
get_gateway_ip() {
    local iface=$(ip route show default | awk '/default/ {print $5}')
    ip addr show dev $iface | awk '/inet / {print $2}' | cut -d'/' -f1
}

# 检查配置文件格式
check_config() {
    if ! jq empty /etc/sing-box/config.json &>/dev/null; then
        echo -e "${RED}配置文件格式错误，请检查订阅URL${NC}"
        exit 1
    fi
}

# 检查服务状态
check_service_status() {
    if ! systemctl is-active --quiet sing-box; then
        echo -e "${RED}服务启动失败，请检查配置${NC}"
        journalctl -u sing-box -n 50 --no-pager
        exit 1
    fi
}

# 卸载功能
uninstall() {
    echo -e "${YELLOW}正在卸载sing-box...${NC}"
    sudo systemctl stop sing-box || true
    sudo systemctl disable sing-box || true
    sudo rm -f /usr/local/bin/sing-box
    sudo rm -rf /etc/sing-box
    sudo rm -f /etc/systemd/system/sing-box.service
    sudo systemctl daemon-reload
    echo -e "${GREEN}卸载完成${NC}"
}

# 主安装流程
main() {
    echo -e "${GREEN}开始安装sing-box...${NC}"
    log "开始安装sing-box"

    # 卸载功能
    if [[ $1 == "uninstall" ]]; then
        uninstall
        exit 0
    fi

    # 1. 架构检测
    ARCH=$(get_arch)
    echo -e "${GREEN}检测到系统架构: ${ARCH}${NC}"
    log "检测到系统架构: $ARCH"

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
    log "选择的版本: $version"

    # 3. 安装依赖
    echo -e "${YELLOW}正在检查依赖...${NC}"
    log "正在检查依赖"
    install_deps

    # 4. 下载安装
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${repo_tag}/sing-box-${file_tag}-linux-${ARCH}.tar.gz"
    echo -e "${YELLOW}下载地址: ${DOWNLOAD_URL}${NC}"
    log "下载地址: $DOWNLOAD_URL"
    
    TEMP_DIR=$(mktemp -d)
    retry curl -sSL $DOWNLOAD_URL | tar xz -C $TEMP_DIR
    sudo cp $TEMP_DIR/sing-box-${file_tag}-linux-${ARCH}/sing-box /usr/local/bin/
    sudo chmod +x /usr/local/bin/sing-box

    # 5. 配置订阅
    read -p "请输入配置文件订阅URL: " config_url
    validate_url "$config_url"
    sudo mkdir -p /etc/sing-box
    if ! curl -sSL $config_url | sudo tee /etc/sing-box/config.json >/dev/null; then
        echo -e "${RED}配置文件下载失败${NC}"
        exit 1
    fi
    check_config
    log "配置文件下载完成"

    # 6. 创建服务文件
    cat <<EOF | sudo tee /etc/systemd/system/sing-box.service >/dev/null
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
    sudo systemctl daemon-reload
    sudo systemctl enable sing-box
    if ! sudo systemctl start sing-box; then
        echo -e "${RED}服务启动失败，请检查配置${NC}"
        journalctl -u sing-box -n 50 --no-pager
        exit 1
    fi
    check_service_status
    log "服务启动成功"

    # 8. 网络配置
    GATEWAY_IP=$(get_gateway_ip)
    echo -e "${YELLOW}配置网关地址: ${GATEWAY_IP}${NC}"
    log "配置网关地址: $GATEWAY_IP"
    
    sudo sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf >/dev/null

    sudo iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE
    sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null

    # 显示使用信息
    echo -e "${GREEN}安装完成！请将其他设备的网关设置为: ${GATEWAY_IP}${NC}"
    echo -e "服务状态检查: ${YELLOW}systemctl status sing-box${NC}"
    echo -e "日志查看: ${YELLOW}journalctl -u sing-box -f${NC}"
    log "安装完成"
}

# 异常处理
trap 'echo -e "${RED}安装中断，正在清理...${NC}"; rm -rf $TEMP_DIR; exit 1' INT

# 主函数调用
if [[ $# -gt 0 && $1 == "uninstall" ]]; then
    uninstall
else
    main "$@"
fi
