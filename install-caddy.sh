#!/bin/bash

CADDY_CONF="/etc/caddy/Caddyfile"
STATE_FILE="/tmp/deploy_state"

# 1. 识别系统类型
detect_system() {
    if grep -q "OpenWrt" /etc/os-release 2>/dev/null; then
        SYSTEM_TYPE="OpenWrt"
    else
        SYSTEM_TYPE="Other"
    fi
}

# 2. 自动安装caddy（支持多架构）
install_caddy() {
    echo "开始自动下载Caddy二进制文件..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            BINARY_URL="https://github.com/caddyserver/dist/releases/latest/download/caddy_linux_amd64.tar.gz"
            ;;
        armv7l|armv7*)
            BINARY_URL="https://github.com/caddyserver/dist/releases/latest/download/caddy_linux_armv7.tar.gz"
            ;;
        aarch64|arm64)
            BINARY_URL="https://github.com/caddyserver/dist/releases/latest/download/caddy_linux_arm64.tar.gz"
            ;;
        *)
            echo "不支持的架构：$ARCH，无法自动下载caddy。请手动安装。"
            return 1
            ;;
    esac
    TMP_DIR="/tmp/caddy_install"
    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR" || return 1
    wget -O caddy.tar.gz "$BINARY_URL" || { echo "下载失败"; return 1; }
    tar -xzf caddy.tar.gz || { echo "解压失败"; return 1; }
    cp caddy /usr/bin/ || { echo "复制到 /usr/bin/ 失败"; return 1; }
    chmod +x /usr/bin/caddy
    rm -rf "$TMP_DIR"
    echo "Caddy已安装到 /usr/bin/caddy"
    return 0
}

# 3. 检查依赖
check_and_install() {
    local cmd=$1
    local pkg=$2
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "缺少依赖：$cmd，尝试自动安装..."
        if [ "$SYSTEM_TYPE" = "OpenWrt" ]; then
            if [ "$pkg" = "caddy" ]; then
                install_caddy
                if [ $? -ne 0 ]; then
                    echo "自动安装caddy失败，请手动安装。"
                    return 1
                fi
            else
                opkg update && opkg install "$pkg"
                if [ $? -ne 0 ]; then
                    echo "安装$pkg失败"
                    return 1
                fi
            fi
        else
            echo "请手动安装 $pkg"
            return 1
        fi
    fi
}

# 4. 载入状态
load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    else
        SERVICE_STATUS="unknown"
        CADDY_RUNNING=0
    fi
}

# 5. 保存状态
save_state() {
    echo "SERVICE_STATUS='$SERVICE_STATUS'" > "$STATE_FILE"
    echo "CADDY_RUNNING=$CADDY_RUNNING" >> "$STATE_FILE"
}

# 6. 确保配置文件存在
prepare_caddy_config() {
    if [ ! -f "$CADDY_CONF" ] || [ ! -s "$CADDY_CONF" ]; then
        echo "配置文件不存在或为空，创建基础配置..."
        mkdir -p "$(dirname "$CADDY_CONF")"
        echo "# 自动生成的空配置" > "$CADDY_CONF"
    fi
}

# 7. 格式化配置文件
format_caddy_config() {
    if command -v caddy >/dev/null 2>&1; then
        caddy fmt --overwrite "$CADDY_CONF"
    fi
}

# 8. 验证配置文件
validate_caddy_config() {
    if command -v caddy >/dev/null 2>&1; then
        caddy validate --config "$CADDY_CONF"
        return $?
    else
        return 1
    fi
}

# 9. 启动caddy（后台，确保API监听）
start_caddy() {
    prepare_caddy_config
    # 如果未在运行，启动
    if ! pgrep -x "caddy" > /dev/null; then
        echo "启动caddy..."
        caddy run --config "$CADDY_CONF" &>/dev/null &   # 后台启动
        sleep 3
    fi
    # 验证配置
    if validate_caddy_config; then
        echo "配置验证通过，重载caddy..."
        caddy reload --config "$CADDY_CONF"
        echo "配置已加载"
        CADDY_RUNNING=1
    else
        echo "配置有误，未重载"
        CADDY_RUNNING=0
    fi
}

# 10. 配置caddy（用户输入）
configure_caddy() {
    prepare_caddy_config
    echo "配置caddy反向代理（支持多个域名和目标）"
    echo "每行输入：域名 目标地址（格式：domain.com 192.168.1.2:端口），空行结束"
    echo "示例："
    echo "example.com 192.168.1.10:8080"
    echo "请输入配置："
    > "$CADDY_CONF"
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
" >> "$CADDY_CONF"
    done
    start_caddy
    echo "配置完成"
}

# 11. 添加新反向代理
add_new_proxy() {
    prepare_caddy_config
    echo "添加新反向代理："
    read -rp "域名： " domain
    read -rp "目标地址（IP:端口）： " target
    if [ -z "$domain" ] || [ -z "$target" ]; then
        echo "输入无效"
        return
    fi
    echo "$domain {
  encode gzip
  reverse_proxy $target
}
" >> "$CADDY_CONF"
    start_caddy
    echo "已添加"
}

# 12. 查看状态
view_status() {
    echo "系统类型：$SYSTEM_TYPE"
    echo "服务状态：$SERVICE_STATUS"
    echo "Caddy运行：$([ "$CADDY_RUNNING" -eq 1 ] && echo "是" || echo "否")"
    echo "端口占用："
    netstat -tulnp | grep -E ':(80|443|8080)'
}

# 13. 停止端口（80/443/两者）
stop_ports() {
    echo "选择停止端口："
    echo "1. 停止80端口"
    echo "2. 停止443端口"
    echo "3. 停止80和443端口"
    read -rp "选择 (1/2/3): " port_choice
    case "$port_choice" in
        1)
            PIDS=$(netstat -tulnp | grep -E ':(80) ' | awk '{print $7}' | cut -d'/' -f1)
            ;;
        2)
            PIDS=$(netstat -tulnp | grep -E ':(443) ' | awk '{print $7}' | cut -d'/' -f1)
            ;;
        3)
            PIDS=$(netstat -tulnp | grep -E ':(80|443) ' | awk '{print $7}' | cut -d'/' -f1)
            ;;
        *)
            echo "无效选择"
            return
            ;;
    esac
    # 去重
    PIDS=$(echo "$PIDS" | sort -u)
    for pid in $PIDS; do
        echo "杀掉进程ID：$pid"
        kill "$pid" 2>/dev/null || kill -9 "$pid"
    done
    SERVICE_STATUS="stopped"
    save_state
}

# 14. 启动80端口
start_port_80() {
    echo "尝试启动80端口（假设已有服务配置监听80）..."
    # 这里示例：启动uhttpd（或其他web服务）
    /etc/init.d/uhttpd start
    /etc/init.d/uhttpd enable
    echo "80端口已启动"
    # 更新状态
    SERVICE_STATUS="uhttpd"
    save_state
}

# 15. 启动443端口
start_port_443() {
    echo "启动443端口（假设caddy配置支持监听443）..."
    start_caddy
    # start_caddy已处理
}

# 16. 启动80和443端口
start_both_ports() {
    start_port_80
    start_port_443
}

# 17. 启动caddy（确保后台运行）
start_caddy() {
    if check_and_install "caddy" "caddy"; then
        if command -v caddy >/dev/null 2>&1; then
            if ! pgrep -x "caddy" > /dev/null; then
                echo "启动caddy..."
                caddy run --config "$CADDY_CONF" &>/dev/null & 
                sleep 3
            fi
            if validate_caddy_config; then
                echo "配置验证通过，重载caddy..."
                caddy reload --config "$CADDY_CONF"
                echo "配置已加载"
                CADDY_RUNNING=1
            else
                echo "配置有误，未重载"
                CADDY_RUNNING=0
            fi
        fi
    fi
}

# 18. 其他功能（卸载、恢复）
uninstall_caddy() {
    echo "卸载caddy..."
    if command -v caddy >/dev/null 2>&1; then
        caddy stop
        if [ "$SYSTEM_TYPE" = "OpenWrt" ]; then
            opkg remove caddy
        fi
        echo "已卸载caddy"
    else
        echo "未检测到caddy"
    fi
}

restore_previous() {
    if [ "$SERVICE_STATUS" = "uhttpd" ]; then
        /etc/init.d/uhttpd start
        /etc/init.d/uhttpd enable
    elif [ "$SERVICE_STATUS" = "caddy" ]; then
        start_caddy
    fi
}

# 19. 主菜单
main_menu() {
    detect_system
    load_state
    check_and_install "netstat" "net-tools"
    check_and_install "ps" "procps"

    while true; do
        echo "=============================="
        echo "  交互式部署菜单"
        echo "=============================="
        echo "1. 查看当前系统和端口状态"
        echo "2. 停止端口（80/443/两者）"
        echo "3. 启动服务（uhttpd或caddy）"
        echo "4. 配置caddy反向代理"
        echo "5. 添加新反向代理"
        echo "6. 恢复到之前的运行状态"
        echo "7. 卸载caddy（可选）"
        echo "8. 退出"
        read -rp "请选择操作(1-8): " opt
        case "$opt" in
            1) view_status ;;
            2) stop_ports ;;
            3)
                echo "启动子菜单："
                echo "1. 启动uhttpd"
                echo "2. 启动caddy"
                echo "3. 启动80端口"
                echo "4. 启动443端口"
                echo "5. 启动80和443端口"
                read -rp "选择 (1/2/3/4/5): " sub_choice
                case "$sub_choice" in
                    1) start_uhttpd ;;
                    2) start_caddy ;;
                    3) start_port_80 ;;
                    4) start_port_443 ;;
                    5) start_both_ports ;;
                    *) echo "无效选择" ;;
                esac
                ;;
            4) 
                if command -v caddy >/dev/null 2>&1; then
                    configure_caddy
                else
                    echo "请先安装caddy"
                fi
                ;;
            5) add_new_proxy ;;
            6) restore_previous ;;
            7) uninstall_caddy ;;
            8) echo "退出"; exit 0 ;;
            *) echo "无效选择" ;;
        esac
        echo
    done
}

# 启动脚本
main_menu
