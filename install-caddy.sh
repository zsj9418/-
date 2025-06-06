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
  local base_url="https://github.com/caddyserver/caddy/releases/download/$version_tag"

  case "$arch" in
    aarch64|arm64)
      echo "$base_url/caddy_${version_tag}_linux_arm64.tar.gz"
      ;;
    x86_64|amd64)
      echo "$base_url/caddy_${version_tag}_linux_amd64.tar.gz"
      ;;
    armv7l|armv7*)
      echo "$base_url/caddy_${version_tag}_linux_armv7.tar.gz"
      ;;
    *)
      echo "未支持的架构：$arch" >&2
      return 1
      ;;
  esac
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

  # 下载压缩包
  TMP_DIR="/tmp/caddy_install"
  mkdir -p "$TMP_DIR"
  wget -O "$TMP_DIR/caddy.tar.gz" "$download_url" || { echo "下载失败"; return 1; }
  # 解压
  tar -xzf "$TMP_DIR/caddy.tar.gz" -C "$TMP_DIR"
  # 复制二进制
  cp "$TMP_DIR/caddy" /usr/bin/ || { echo "复制失败"; return 1; }
  chmod +x /usr/bin/caddy
  # 清理
  rm -rf "$TMP_DIR"
  echo "Caddy已安装到 /usr/bin/caddy"
}

# 6. 检查依赖
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
    if [ ! -f "$CADDY_CONF" ] || [ ! -s "$CADDY_CONF" ]; then
        echo "配置文件不存在或为空，创建基础配置..."
        mkdir -p "$(dirname "$CADDY_CONF")"
        echo "# 自动生成的空配置" > "$CADDY_CONF"
    fi
}

# 10. 格式化配置
format_caddy_config() {
    if command -v caddy >/dev/null 2>&1; then
        caddy fmt --overwrite "$CADDY_CONF"
    fi
}

# 11. 验证配置
validate_caddy_config() {
    if command -v caddy >/dev/null 2>&1; then
        caddy validate --config "$CADDY_CONF"
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
        caddy run --config "$CADDY_CONF" &>/dev/null &
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
" >> "$CADDY_CONF"
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
            /etc/init.d/uhttpd stop
            /etc/init.d/uhttpd disable
            ;;
        2)
            /etc/init.d/caddy stop
            /etc/init.d/caddy disable
            ;;
        3)
            /etc/init.d/uhttpd stop
            /etc/init.d/uhttpd disable
            /etc/init.d/caddy stop
            /etc/init.d/caddy disable
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
    /etc/init.d/uhttpd enable
    /etc/init.d/uhttpd start
    echo "80端口已启动"
    SERVICE_STATUS="uhttpd"
    CADDY_RUNNING=0
    save_state
}

# 18. 启动443端口
start_port_443() {
    /etc/init.d/caddy enable
    /etc/init.d/caddy start
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
        /etc/init.d/caddy enable
        /etc/init.d/caddy start
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
    /etc/init.d/caddy stop
    /etc/init.d/caddy disable
    echo "已卸载caddy"
}

# 22. 恢复之前状态
restore_previous() {
    if [ "$SERVICE_STATUS" = "uhttpd" ]; then
        /etc/init.d/uhttpd start
        /etc/init.d/uhttpd enable
    elif [ "$SERVICE_STATUS" = "caddy" ]; then
        start_caddy
    fi
}

# 23. 停止服务（uhttpd或caddy）
stop_service() {
    echo "请选择要停止的服务："
    echo "1. uhttpd"
    echo "2. caddy"
    read -rp "输入 (1/2): " svc_choice
    if [ "$svc_choice" = "1" ]; then
        /etc/init.d/uhttpd stop
        /etc/init.d/uhttpd disable
        echo "uhttpd已停止并禁用"
        if [ $? -eq 0 ]; then
            echo "操作成功"
        else
            echo "操作失败"
        fi
    elif [ "$svc_choice" = "2" ]; then
        /etc/init.d/caddy stop
        /etc/init.d/caddy disable
        echo "caddy已停止并禁用"
        if [ $? -eq 0 ]; then
            echo "操作成功"
        else
            echo "操作失败"
        fi
    else
        echo "无效选择"
    fi
}

# 24. 获取服务状态（运行和启用）
get_service_status() {
    local svc_name=$1
    local running="否"
    local enabled="否"
    /etc/init.d/$svc_name status >/dev/null 2>&1 && running="是"
    /etc/init.d/$svc_name enabled >/dev/null 2>&1 && enabled="是"
    echo "$running|$enabled"
}

# 25. 主菜单（排序优化）
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
