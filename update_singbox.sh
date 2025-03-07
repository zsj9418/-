#!/bin/bash
set -euo pipefail

# 环境变量文件路径
ENV_FILE="$HOME/.singbox_env"

# 彩色输出
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

# 加载环境变量
load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
    green "已加载环境变量配置文件 $ENV_FILE"
  else
    yellow "未检测到环境变量配置文件，将进入交互式变量输入"
    setup_env
  fi
}

# 保存环境变量到文件
save_env() {
  cat >"$ENV_FILE" <<EOF
WX_WEBHOOK="$WX_WEBHOOK"
SUBSCRIBE_URLS="$SUBSCRIBE_URLS"
CONFIG_PATH="$CONFIG_PATH"
LOG_FILE="$LOG_FILE"
EOF
  green "环境变量已保存到 $ENV_FILE"
}

# 交互式配置环境变量
setup_env() {
  read -p "请输入企业微信 Webhook 地址（可直接回车跳过，默认不通知）: " WX_WEBHOOK
  WX_WEBHOOK=${WX_WEBHOOK:-""}

  read -p "请输入订阅链接（多个链接用空格分隔，必填）: " SUBSCRIBE_URLS
  if [[ -z "$SUBSCRIBE_URLS" ]]; then
    red "订阅链接不能为空，请重新运行脚本配置"
    exit 1
  fi

  read -p "请输入配置文件路径 [默认: /etc/sing-box/config.json]: " CONFIG_PATH
  CONFIG_PATH=${CONFIG_PATH:-"/etc/sing-box/config.json"}

  read -p "请输入日志文件路径 [默认: /var/log/sing-box-update.log]: " LOG_FILE
  LOG_FILE=${LOG_FILE:-"/var/log/sing-box-update.log"}

  save_env
}

# 企业微信通知
send_msg() {
  if [[ -z "$WX_WEBHOOK" ]]; then
    yellow "未配置企业微信 Webhook，跳过通知"
    return
  fi
  local msg=$1
  curl -sSf -H "Content-Type: application/json" \
    -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"$msg\"}}" \
    "$WX_WEBHOOK" >/dev/null || red "通知发送失败"
}

# 安装依赖
install_dependencies() {
  if ! command -v jq >/dev/null 2>&1; then
    yellow "检测到 jq 未安装，正在安装..."
    if command -v apt >/dev/null 2>&1; then
      apt update && apt install -y jq
    elif command -v yum >/dev/null 2>&1; then
      yum install -y jq
    else
      red "未找到支持的包管理器，请手动安装 jq"
      exit 1
    fi
    green "jq 安装完成"
  fi
}

# 停止 sing-box 服务
stop_singbox() {
  if systemctl is-active --quiet sing-box; then
    systemctl stop sing-box
    green "sing-box 服务已停止"
  elif pgrep sing-box >/dev/null 2>&1; then
    killall sing-box
    green "sing-box 进程已终止"
  else
    yellow "sing-box 未运行"
  fi
}

# 启动 sing-box 服务
start_singbox() {
  if systemctl list-unit-files | grep -q sing-box; then
    systemctl start sing-box
    green "sing-box 服务已启动"
  else
    nohup sing-box run -c "$CONFIG_PATH" >/dev/null 2>&1 &
    green "sing-box 已通过手动方式启动"
  fi
}

# 备份配置文件
backup_config() {
  if [[ -f "$CONFIG_PATH" ]]; then
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    green "配置文件已备份到: ${CONFIG_PATH}.bak"
  else
    yellow "配置文件不存在，跳过备份"
  fi
}

# 还原配置文件
restore_config() {
  if [[ -f "${CONFIG_PATH}.bak" ]]; then
    cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    green "配置文件已还原: $CONFIG_PATH"
  else
    red "无备份文件，无法还原"
  fi
}

# 验证配置文件是否有效
validate_config() {
  if [[ ! -s "$CONFIG_PATH" ]]; then
    red "配置文件为空"
    return 1
  fi
  if ! jq empty "$CONFIG_PATH" >/dev/null 2>&1; then
    red "配置文件格式无效"
    return 1
  fi
  return 0
}

# 获取节点数量
get_node_count() {
  jq '.outbounds | length' "$CONFIG_PATH" 2>/dev/null || echo "0"
}

# 更新配置文件
update_config() {
  local message="📡 sing-box 更新报告"
  local success=false
  for sub in $SUBSCRIBE_URLS; do
    yellow "正在从 $sub 下载配置..."
    if curl -L "$sub" -o "$CONFIG_PATH" >/dev/null 2>&1; then
      if validate_config; then
        backup_config
        stop_singbox
        start_singbox
        local node_count=$(get_node_count)
        if [[ "$node_count" -eq "0" ]]; then
          message="$message\n⚠️ 更新成功但未检测到节点: $sub"
        else
          message="$message\n✅ 更新成功: $sub\n节点数: $node_count"
        fi
        success=true
        break
      else
        message="$message\n❌ 无效的配置文件: $sub"
        restore_config
      fi
    else
      message="$message\n❌ 下载失败: $sub"
    fi
  done

  if ! $success; then
    restore_config
    message="$message\n❌ 所有订阅链接均失败，已还原备份配置"
  fi

  send_msg "$message"
  echo -e "$message"
  if $success; then
    exit 0
  else
    exit 1
  fi
}

# 主流程
main() {
  load_env
  install_dependencies
  update_config
}

main
