#!/bin/sh

### 配置常量 ###
LOG_FILE="/var/log/docker_monitor.log"  # 日志文件路径
WEBHOOK_URL=""                          # 企业微信机器人 Webhook URL
DEPENDENCIES="curl jq"                  # 必需依赖
CONFIG_FILE="/etc/docker_monitor.conf"  # 配置文件路径
MAX_LOG_SIZE=1048576                    # 最大日志文件大小 (1 MB)
SCRIPT_PATH="$(realpath "$0")"          # 当前脚本路径
SCRIPT_NAME="docker_monitor"            # 脚本名称
MAX_RETRIES=10                          # 最大重试次数
RETRY_INTERVAL=5                        # 重试间隔时间（秒）
STABILIZATION_WAIT=60                   # 重启后稳定等待时间（秒）

### 彩色输出函数 ###
red() { echo "\033[31m$*\033[0m"; }
yellow() { echo "\033[33m$*\033[0m"; }
green() { echo "\033[32m$*\033[0m"; }

### 检查依赖并补全 ###
check_dependencies() {
    echo "正在检查依赖..."
    local missing_deps=""
    for dep in $DEPENDENCIES; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done

    if [ -n "$missing_deps" ]; then
        echo "缺少以下依赖：$missing_deps"
        echo "正在安装依赖..."
        if command -v apt >/dev/null 2>&1; then
            sudo apt update && sudo apt install -y $missing_deps
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y $missing_deps
        elif command -v apk >/dev/null 2>&1; then
            sudo apk add --no-cache $missing_deps
        elif command -v opkg >/dev/null 2>&1; then
            sudo opkg update && sudo opkg install $missing_deps
        else
            echo "无法自动安装依赖，请手动安装以下工具：$missing_deps"
            exit 1
        fi
    else
        green "所有依赖已满足。"
    fi
}

### 保存用户配置 ###
save_config() {
    echo "WEBHOOK_URL=\"$WEBHOOK_URL\"" > "$CONFIG_FILE"
    echo "AUTOSTART_ENABLED=\"$AUTOSTART_ENABLED\"" >> "$CONFIG_FILE"
    if [ $? -ne 0 ]; then
        red "保存配置文件失败。"
        exit 1
    fi
    green "配置文件已保存。"
}

### 加载用户配置 ###
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
        if [ $? -ne 0 ]; then
            red "加载配置文件失败。"
            exit 1
        fi
        green "配置文件已加载。"
    else
        echo "未检测到配置文件，首次运行需要配置。"
        configure_script
    fi
}

### 配置脚本（首次运行时提示配置机器人 URL 和自启动选项） ###
configure_script() {
    echo "是否启用企业微信机器人通知？(y/n)"
    read ENABLE_WEBHOOK
    if [ "$ENABLE_WEBHOOK" = "y" ]; then
        while [ -z "$WEBHOOK_URL" ]; do
            echo "请输入企业微信机器人 Webhook URL（留空回车表示不通知）："
            read WEBHOOK_URL
        done
        echo "企业微信机器人已启用。"
    else
        echo "企业微信机器人通知已跳过。"
    fi

    echo "是否启用后台自启动检测 Docker 状态功能？(y/n)"
    read ENABLE_AUTOSTART
    if [ "$ENABLE_AUTOSTART" = "y" ]; then
        AUTOSTART_ENABLED="yes"
        setup_autostart
        green "后台自启动功能已启用。"
    else
        AUTOSTART_ENABLED="no"
        echo "后台自启动功能未启用。"
    fi

    save_config
}

### 设置自启动 ###
setup_autostart() {
    if command -v systemctl >/dev/null 2>&1; then
        local service_file="/etc/systemd/system/${SCRIPT_NAME}.service"
        echo "[Unit]
Description=Docker Monitor Service
After=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH
Restart=always

[Install]
WantedBy=multi-user.target" | sudo tee "$service_file" > /dev/null
        sudo systemctl daemon-reload
        sudo systemctl enable "${SCRIPT_NAME}.service"
        if [ $? -ne 0 ]; then
            red "启用服务失败。"
            exit 1
        fi
    elif [ -f "/etc/rc.local" ]; then
        if ! grep -q "$SCRIPT_PATH" /etc/rc.local; then
            sudo sed -i -e "\$i $SCRIPT_PATH &\n" /etc/rc.local
            if [ $? -ne 0 ]; then
                red "修改 rc.local 文件失败。"
                exit 1
            fi
        fi
    else
        red "无法设置自启动，系统不支持 systemd 且没有 rc.local 文件。"
        exit 1
    fi
}

### 获取 Docker 状态信息 ###
get_docker_status() {
    local containers=$(docker ps -q | wc -l)
    local images=$(docker images -q | wc -l)
    local networks=$(docker network ls -q | wc -l)
    local volumes=$(docker volume ls -q | wc -l)

    echo "容器: $containers, 镜像: $images, 网络: $networks, 卷: $volumes"
}

### 检查 Docker 状态是否正常 ###
is_docker_normal() {
    local status=$(get_docker_status)
    local containers=$(echo "$status" | awk -F', ' '{print $1}' | cut -d' ' -f2)
    local images=$(echo "$status" | awk -F', ' '{print $2}' | cut -d' ' -f2)
    local networks=$(echo "$status" | awk -F', ' '{print $3}' | cut -d' ' -f2)
    local volumes=$(echo "$status" | awk -F', ' '{print $4}' | cut -d' ' -f2)

    if [ "$containers" -eq 0 ] && [ "$images" -eq 0 ] && [ "$networks" -eq 0 ] && [ "$volumes" -eq 0 ]; then
        return 1
    elif [ "$networks" -ne 3 ] || [ "$volumes" -ne 0 ]; then
        return 1
    else
        return 0
    fi
}

### 重启 Docker 服务 ###
restart_docker() {
    echo "Docker 状态异常，正在重启 Docker 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl restart docker
    elif command -v service >/dev/null 2>&1; then
        sudo service docker restart
    else
        red "无法重启 Docker 服务，系统不支持 systemd 或 service 命令。"
        exit 1
    fi
}

### 等待 Docker 服务稳定 ###
wait_for_docker_stability() {
    echo "等待 Docker 服务稳定..."
    sleep $STABILIZATION_WAIT
}

### 发送企业微信通知 ###
send_wechat_notification() {
    if [ -z "$WEBHOOK_URL" ]; then
        yellow "未配置企业微信 Webhook，跳过通知"
        return
    fi

    local message="$1"
    local retries=0

    while [ $retries -lt $MAX_RETRIES ]; do
        curl -sSf -H "Content-Type: application/json" \
            -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"[设备: $(hostname)] Docker 状态通知:\n$message\"}}" \
            "$WEBHOOK_URL" >/dev/null
        if [ $? -eq 0 ]; then
            green "通知发送成功。"
            return 0
        else
            red "通知发送失败，重试中...（第 $((retries + 1)) 次）"
            retries=$((retries + 1))
            sleep $RETRY_INTERVAL
        fi
    done

    red "通知发送失败次数已达上限（$MAX_RETRIES 次）。"
    return 1
}

### 日志记录 ###
log_info() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then
        echo "日志目录不存在：$(dirname "$LOG_FILE")"
        return 1
    fi

    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -ge $MAX_LOG_SIZE ]; then
        echo "日志文件大小超过 1MB，正在清空日志文件..."
        > "$LOG_FILE"
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

### 主函数 ###
main() {
    # 检查并安装依赖
    check_dependencies

    # 加载或配置用户配置
    load_config

    # 如果启用了后台运行，等待系统稳定
    if [ "$AUTOSTART_ENABLED" = "yes" ]; then
        wait_for_docker_stability
    fi

    # 获取当前 Docker 状态
    local current_status=$(get_docker_status)
    log_info "当前 Docker 状态: $current_status"

    # 检查 Docker 状态是否正常
    if is_docker_normal; then
        green "Docker 状态正常。"
        send_wechat_notification "Docker 状态正常: $current_status"
    else
        red "Docker 状态异常: $current_status"
        send_wechat_notification "Docker 状态异常: $current_status"

        # 重启 Docker 服务
        restart_docker
        wait_for_docker_stability

        # 重新获取 Docker 状态
        local new_status=$(get_docker_status)
        log_info "重启后 Docker 状态: $new_status"

        if is_docker_normal; then
            green "Docker 重启后状态正常。"
            send_wechat_notification "Docker 重启后状态正常: $new_status"
        else
            red "Docker 重启后状态仍然异常: $new_status"
            send_wechat_notification "Docker 重启后状态仍然异常: $new_status"
        fi
    fi
}

main
