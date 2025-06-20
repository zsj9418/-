#!/bin/bash

# 可配置变量
: ${CADDY_BIN_PATH:="/usr/local/bin/caddy"}
: ${CADDY_CONF_DIR:="/etc/caddy"}
: ${CADDY_CONF_FILE:="$CADDY_CONF_DIR/Caddyfile"}
: ${CADDY_LOG_DIR:="/var/log/caddy"}
: ${CADDY_USER:="www-data"}
: ${STATE_FILE:="${XDG_RUNTIME_DIR:-/tmp}/deploy_state"}

# 架构映射
declare -A ARCH_MAP=(
    ["x86_64"]="amd64"
    ["aarch64"]="arm64"
    ["armv7l"]="armv7"
    ["armv6l"]="armv6"
    ["i686"]="386"
    ["ppc64le"]="ppc64le"
    ["riscv64"]="riscv64"
)

# 1. 增强系统检测
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
}

# 2. 获取所有Caddy版本（标签）
get_caddy_versions() {
  curl -s https://api.github.com/repos/caddyserver/caddy/releases | \
  grep -E '"tag_name":' | \
  sed -E 's/.*"tag_name": ?"([^"]+)".*/\1/' | \
  awk '{print NR, $0}'
}

# 3. 用户选择版本
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

# 4. 根据架构拼接下载链接
get_caddy_download_url() {
  local version_tag=$1
  local arch=$(uname -m)
  local mapped_arch=${ARCH_MAP[$arch]:-$arch}
  echo "https://github.com/caddyserver/caddy/releases/download/$version_tag/caddy_${version_tag}_linux_${mapped_arch}.tar.gz"
}

# 5. 安装Caddy（支持版本选择）
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

  # 创建必要目录
  mkdir -p "$(dirname "$CADDY_BIN_PATH")"
  mkdir -p "$CADDY_CONF_DIR"
  mkdir -p "$CADDY_LOG_DIR"
  
  # 设置用户权限
  if id "$CADDY_USER" &>/dev/null; then
    chown -R "$CADDY_USER":"$CADDY_USER" "$CADDY_CONF_DIR" "$CADDY_LOG_DIR"
  fi

  # 下载压缩包
  TMP_DIR="/tmp/caddy_install"
  mkdir -p "$TMP_DIR"
  wget -O "$TMP_DIR/caddy.tar.gz" "$download_url" || { echo "下载失败"; return 1; }
  
  # 解压
  tar -xzf "$TMP_DIR/caddy.tar.gz" -C "$TMP_DIR"
  
  # 复制二进制
  cp "$TMP_DIR/caddy" "$CADDY_BIN_PATH" || { echo "复制失败"; return 1; }
  chmod +x "$CADDY_BIN_PATH"
  
  # 清理
  rm -rf "$TMP_DIR"
  echo "Caddy已安装到 $CADDY_BIN_PATH"
}

# 6. 检查依赖
check_and_install() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null; then
        case $cmd in
            caddy) install_caddy ;;
            netstat)
                install_dependencies net-tools
                ;;
            ps)
                install_dependencies procps
                ;;
        esac
    fi
}

# 7. 载入状态
load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    else
        SERVICE_STATUS="unknown"
        CADDY_RUNNING=0
    fi
}

# 8. 保存状态
save_state() {
    echo "SERVICE_STATUS='$SERVICE_STATUS'" > "$STATE_FILE"
    echo "CADDY_RUNNING=$CADDY_RUNNING" >> "$STATE_FILE"
}

# 9. 确保配置文件存在
prepare_caddy_config() {
    if [ ! -f "$CADDY_CONF_FILE" ] || [ ! -s "$CADDY_CONF_FILE" ]; then
        echo "配置文件不存在或为空，创建基础配置..."
        mkdir -p "$(dirname "$CADDY_CONF_FILE")"
        echo "# 自动生成的空配置" > "$CADDY_CONF_FILE"
    fi
}

# 10. 格式化配置
format_caddy_config() {
    if command -v caddy >/dev/null 2>&1; then
        caddy fmt --overwrite "$CADDY_CONF_FILE"
    fi
}

# 11. 验证配置
validate_caddy_config() {
    if command -v caddy >/dev/null 2>&1; then
        caddy validate --config "$CADDY_CONF_FILE"
        return $?
    else
        return 1
    fi
}

# 12. 启动caddy
start_caddy() {
    prepare_caddy_config
    if ! pgrep -x "caddy" > /dev/null; then
        echo "启动caddy..."
        caddy run --config "$CADDY_CONF_FILE" &>/dev/null &
        sleep 3
    fi
    if validate_caddy_config; then
        echo "配置验证通过，caddy已启动"
        CADDY_RUNNING=1
    else
        echo "配置有误，caddy未启动"
        CADDY_RUNNING=0
    fi
    SERVICE_STATUS="caddy"
    save_state
}

# 13. 配置反向代理
configure_caddy() {
    prepare_caddy_config
    echo "配置caddy反向代理..."
    echo "每行输入：域名 目标地址（格式：domain.com 192.168.1.2:端口），空行结束"
    echo "示例："
    echo "example.com 192.168.1.10:8080"
    echo "请输入配置："
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

# 14. 添加新反向代理
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
" >> "$CADDY_CONF_FILE"
    start_caddy
    echo "已添加"
}

# 15. 查看状态
view_status() {
    echo "系统类型：$SYSTEM_TYPE"
    echo "服务状态：$SERVICE_STATUS"
    echo "Caddy运行：$([ "$CADDY_RUNNING" -eq 1 ] && echo "是" || echo "否")"
    echo "端口占用："
    netstat -tulnp | grep -E ':(80|443|8080)'
}

# 16. 停止端口（80/443/两者）
stop_ports() {
    echo "选择停止端口："
    echo "1. 停止80端口"
    echo "2. 停止443端口"
    echo "3. 停止80和443端口"
    read -rp "选择 (1/2/3): " port_choice
    case "$port_choice" in
        1)
            stop_service uhttpd
            ;;
        2)
            stop_service caddy
            ;;
        3)
            stop_service uhttpd
            stop_service caddy
            ;;
        *)
            echo "无效选择"
            return
            ;;
    esac
    # 杀残留进程
    local PIDS
    PIDS=$(netstat -tulnp | grep -E ':(80|443) ' | awk '{print $7}' | cut -d'/' -f1)
    for pid in $PIDS; do
        echo "杀掉进程ID：$pid"
        kill "$pid" 2>/dev/null || kill -9 "$pid"
    done
    SERVICE_STATUS="stopped"
    save_state
}

# 17. 启动80端口
start_port_80() {
    start_service uhttpd
    echo "80端口已启动"
    SERVICE_STATUS="uhttpd"
    CADDY_RUNNING=0
    save_state
}

# 18. 启动443端口
start_port_443() {
    start_service caddy
    echo "443端口已启动"
}

# 19. 重新启动全部（80+443）
start_both_ports() {
    start_port_80
    start_port_443
}

# 20. 启动caddy
start_caddy() {
    if check_and_install "caddy" "caddy"; then
        start_service caddy
        if validate_caddy_config; then
            echo "配置验证通过，caddy已启动"
            CADDY_RUNNING=1
        else
            echo "配置有误，caddy未启动"
            CADDY_RUNNING=0
        fi
        SERVICE_STATUS="caddy"
        save_state
    fi
}

# 21. 卸载caddy
uninstall_caddy() {
    stop_service caddy
    rm -f "$CADDY_BIN_PATH"
    echo "已卸载caddy"
}

# 22. 恢复之前状态
restore_previous() {
    if [ "$SERVICE_STATUS" = "uhttpd" ]; then
        start_port_80
    elif [ "$SERVICE_STATUS" = "caddy" ]; then
        start_caddy
    fi
}

# 23. 停止服务
stop_service() {
    local svc=$1
    case $INIT_SYSTEM in
        systemd)
            systemctl stop $svc
            systemctl disable $svc
            ;;
        openrc)
            rc-service $svc stop
            rc-update del $svc
            ;;
        sysvinit)
            service $svc stop
            update-rc.d $svc remove
            ;;
        *)
            /etc/init.d/$svc stop
            /etc/init.d/$svc disable
            ;;
    esac
    echo "$svc已停止并禁用"
}

# 24. 获取服务状态（运行和启用）
get_service_status() {
    local svc_name=$1
    local running="否"
    local enabled="否"
    case $INIT_SYSTEM in
        systemd)
            systemctl is-active --quiet $svc_name && running="是"
            systemctl is-enabled --quiet $svc_name && enabled="是"
            ;;
        openrc)
            rc-service $svc_name status &>/dev/null && running="是"
            rc-update show | grep -q $svc_name && enabled="是"
            ;;
        sysvinit)
            service $svc_name status &>/dev/null && running="是"
            [ -x /etc/init.d/$svc_name ] && enabled="是"
            ;;
        *)
            /etc/init.d/$svc_name status &>/dev/null && running="是"
            /etc/init.d/$svc_name enabled &>/dev/null && enabled="是"
            ;;
    esac
    echo "$running|$enabled"
}

# 25. 主菜单
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
        echo "3. 启动端口（80/443/两者）"
        echo "4. 停止服务（uhttpd或caddy）"
        echo "5. 启动服务（uhttpd或caddy）"
        echo "6. 配置caddy反向代理"
        echo "7. 添加新反向代理"
        echo "8. 恢复到之前的运行状态"
        echo "9. 卸载caddy"
        echo "10. 退出"
        read -rp "请选择操作(1-10): " opt

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
                    1) start_port_80 ;;
                    2) start_port_443 ;;
                    3)
                        start_port_80
                        start_port_443
                        ;;
                    *) echo "无效选择" ;;
                esac
                ;;
            4)
                # 显示状态
                echo "当前服务状态："
                uhttpd_status=$(get_service_status uhttpd)
                caddy_status=$(get_service_status caddy)
                echo "uhttpd：$(echo $uhttpd_status | cut -d'|' -f1)，启用：$(echo $uhttpd_status | cut -d'|' -f2)"
                echo "caddy：$(echo $caddy_status | cut -d'|' -f1)，启用：$(echo $caddy_status | cut -d'|' -f2)"
                # 停止
                stop_service
                ;;
            5)
                # 显示状态
                echo "当前服务状态："
                uhttpd_status=$(get_service_status uhttpd)
                caddy_status=$(get_service_status caddy)
                echo "uhttpd：$(echo $uhttpd_status | cut -d'|' -f1)，启用：$(echo $uhttpd_status | cut -d'|' -f2)"
                echo "caddy：$(echo $caddy_status | cut -d'|' -f1)，启用：$(echo $caddy_status | cut -d'|' -f2)"
                # 启动
                echo "选择启动哪个服务："
                echo "1. 启动uhttpd"
                echo "2. 启动caddy"
                read -rp "输入 (1/2): " svc_choice
                if [ "$svc_choice" = "1" ]; then
                    start_port_80
                elif [ "$svc_choice" = "2" ]; then
                    start_caddy
                else
                    echo "无效选择"
                fi
                ;;
            6) 
                if command -v caddy >/dev/null 2>&1; then
                    configure_caddy
                else
                    echo "请先安装caddy"
                fi
                ;;
            7) add_new_proxy ;;
            8) restore_previous ;;
            9) uninstall_caddy ;;
            10) echo "退出"; exit 0 ;;
            *) echo "无效选择" ;;
        esac
        echo
    done
}

# 启动脚本
main_menu
