#!/bin/bash

# 强制使用 bash 执行脚本
set -euo pipefail

# 初始化变量
LOG_FILE="/var/log/cron_script_manager.log"
USE_FLOCK=false # 默认不使用 flock

# 日志路径检查和设置
setup_logging() {
  local log_dir=$(dirname "$LOG_FILE")
  if [[ ! -d "$log_dir" ]]; then
    mkdir -p "$log_dir"
  fi
  if [[ ! -w "$log_dir" ]]; then
    echo -e "\033[31m日志目录 $log_dir 无写权限，请检查权限设置。\033[0m"
    LOG_FILE="/tmp/cron_script_manager.log"
  fi
  touch "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# ---- 辅助函数 --------------------------------------------

# 函数：记录日志信息到文件和控制台
log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$timestamp - $@"
  echo "$timestamp - $@" >> "$LOG_FILE"
}

# 彩色输出函数
red() { echo -e "\033[31m$@\033[0m"; }
green() { echo -e "\033[32m$@\033[0m"; }
yellow() { echo -e "\033[33m$@\033[0m"; }

# ---- 系统检查和依赖安装 ----------------------------------

# 自动识别设备架构和操作系统
detect_system_and_architecture() {
  log "开始系统检测和依赖检查..."
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release

    case "$ID" in
      debian | ubuntu)
        SYSTEM_TYPE="Debian/Ubuntu"
        CRON_PACKAGE="cron"
        PACKAGE_MANAGER="apt"
        ;;
      centos | rhel | fedora)
        SYSTEM_TYPE="CentOS/RHEL/Fedora"
        CRON_PACKAGE="cronie"
        PACKAGE_MANAGER="yum"
        ;;
      arch | manjaro)
        SYSTEM_TYPE="Arch/Manjaro"
        CRON_PACKAGE="cronie"
        PACKAGE_MANAGER="pacman"
        ;;
      alpine)
        SYSTEM_TYPE="Alpine"
        CRON_PACKAGE="dcron"
        PACKAGE_MANAGER="apk"
        ;;
      darwin)
        SYSTEM_TYPE="macOS"
        CRON_PACKAGE="cron"
        PACKAGE_MANAGER="brew"
        ;;
      openwrt | immortalwrt) # 添加 immortalwrt 的识别
        SYSTEM_TYPE="OpenWRT/ImmortalWrt" # 修改系统类型名称更准确
        CRON_PACKAGE="cron" # OpenWRT 默认使用 cron
        PACKAGE_MANAGER="opkg"
        ;;
      *)
        red "不支持的系统: $ID"
        log "警告: 不支持的系统: $ID，请手动安装 cron 和 flock (如果需要)."
        return
        ;;
    esac

    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64 | amd64)
        PLATFORM="linux/amd64"
        ;;
      armv7l | armhf)
        PLATFORM="linux/arm/v7"
        ;;
      aarch64 | arm64)
        PLATFORM="linux/arm64"
        ;;
      mipsel) # 补充 OpenWRT 常见的 MIPS EL 架构
        PLATFORM="linux/mips-el"
        ;;
      *)
        red "当前设备架构 ($ARCH) 未被支持，请确认镜像是否兼容。"
        exit 1
        ;;
    esac

    green "检测到系统：$SYSTEM_TYPE，架构：$ARCH，适配平台：$PLATFORM"

    # 安装所需依赖
    install_dependencies
  else
    red "无法确定操作系统类型，请确保手动安装 cron 和 flock (如果需要)."
    exit 1
  fi
}

# 安装系统依赖
install_dependencies() {
  if ! command -v crontab &>/dev/null; then
    log "未检测到 cron，尝试使用 '$PACKAGE_MANAGER' 安装..."
    case "$PACKAGE_MANAGER" in
      apt)
        sudo apt update
        sudo apt install -y "$CRON_PACKAGE" || { red "安装 $CRON_PACKAGE 失败。"; exit 1; }
        ;;
      yum)
        sudo yum install -y "$CRON_PACKAGE" || { red "安装 $CRON_PACKAGE 失败。"; exit 1; }
        ;;
      pacman)
        sudo pacman -Sy --noconfirm "$CRON_PACKAGE" || { red "安装 $CRON_PACKAGE 失败。"; exit 1; }
        ;;
      apk)
        sudo apk add --no-cache "$CRON_PACKAGE" || { red "安装 $CRON_PACKAGE 失败。"; exit 1; }
        ;;
      brew)
        brew install "$CRON_PACKAGE" || { red "安装 $CRON_PACKAGE 失败。"; exit 1; }
        ;;
      opkg) # OpenWRT 使用 opkg
        opkg update
        opkg install "$CRON_PACKAGE" || { red "安装 $CRON_PACKAGE 失败。"; exit 1; }
        ;;
    esac
    log "成功安装 $CRON_PACKAGE。"
  else
    log "已安装 cron，跳过安装。"
  fi

  # flock 在 OpenWRT 上可能默认不安装，但 util-linux 包通常包含 flock
  if ! command -v flock &>/dev/null; then
    log "未检测到 flock，尝试使用 '$PACKAGE_MANAGER' 安装 util-linux (包含 flock)..."
    case "$PACKAGE_MANAGER" in
      apt)
        sudo apt install -y util-linux || { red "安装 util-linux 失败。"; exit 1; }
        ;;
      yum)
        sudo yum install -y util-linux || { red "安装 util-linux 失败。"; exit 1; }
        ;;
      pacman)
        sudo pacman -Sy --noconfirm util-linux || { red "安装 util-linux 失败。"; exit 1; }
        ;;
      apk)
        sudo apk add --no-cache util-linux || { red "安装 util-linux 失败。"; exit 1; }
        ;;
      brew)
        brew install util-linux || { red "安装 util-linux 失败。"; exit 1; }
        ;;
      opkg) # OpenWRT 使用 opkg 安装 util-linux
        opkg update
        opkg install util-linux || { red "安装 util-linux 失败。"; exit 1; }
        ;;
    esac
    log "成功安装 util-linux（包含 flock）。"
  else
    log "已安装 flock，跳过安装。"
  fi
}

# ---- 输入验证和解析 ----------------------------------------

# 验证 cron 时间格式
validate_cron_time() {
  local time_format='^(\*|[0-5]?[0-9]) (\*|[0-2]?[0-9]) (\*|[0-3]?[0-9]) (\*|[0-1]?[0-9]) (\*|[0-7])$'
  if [[ $1 =~ $time_format ]]; then
    return 0
  else
    red "无效的 cron 时间格式。"
    return 1
  fi
}

# 检查重复任务
check_duplicate() {
  new_job="$1"
  existing_jobs=$(crontab -l 2>/dev/null || true)
  if grep -Fxq "$new_job" <<< "$existing_jobs"; then
    red "任务已存在，无法重复添加。"
    return 1
  fi
  return 0
}

# ---- Crontab 管理 ------------------------------------------

# 显示当前 cron 任务并允许删除
cancel_cron_job() {
  log "开始取消 cron 任务..."
  crontab_content=$(crontab -l 2>/dev/null || true)

  if [[ -z "$crontab_content" ]]; then
    yellow "当前没有设置任何 cron 任务。"
    log "当前没有设置任何 cron 任务。"
    return
  fi

  log "当前的 cron 任务:"
  # 替换 nl 命令为 awk 实现行号
  awk '{printf "%3d  %s\n", NR, $0}' <<< "$crontab_content"

  read -p "请输入要删除的任务编号（或输入 'n' 退出）: " index
  if [[ "$index" == "n" ]]; then
    return
  fi

  if ! [[ "$index" =~ ^[0-9]+$ ]]; then
    red "输入无效，必须为数字。"
    return
  fi

  new_crontab=$(echo "$crontab_content" | sed "${index}d")
  echo "$new_crontab" | crontab -
  log "已删除编号为 $index 的任务。"
}

# ---- 主程序流程 -------------------------------------------

main() {
  setup_logging
  detect_system_and_architecture

  while true; do
    echo -e "\n=========================================="
    echo "请选择操作："
    echo "1. 添加新的定时任务"
    echo "2. 取消已有的定时任务"
    echo "3. 退出"
    read -p "请输入您的选择 (1-3): " choice

    case "$choice" in
    1)
      read -p "请输入要执行的脚本路径 [默认: /usr/local/bin/example.sh]: " script_path
      script_path=${script_path:-/usr/local/bin/example.sh}
      if [[ ! -x "$script_path" || "$script_path" != /* ]]; then
        red "错误: 必须提供有效的绝对路径。"
        continue
      fi

      while true; do
        read -p "请输入 cron 时间表达式 (例如 '0 5 * * *' 表示每天凌晨 5 点, 回车使用默认 '0 5 * * *'): " cron_time
        if [[ -z "$cron_time" ]]; then
          cron_time="0 5 * * *"
          green "使用默认 cron 时间表达式: $cron_time"
          break
        fi
        if validate_cron_time "$cron_time"; then
          break
        fi
      done

      read -p "是否启用 flock 锁 (防止并发执行)? [回车=否, y=是]: " use_flock_input
      if [[ "$use_flock_input" == "y" ]]; then
        USE_FLOCK=true
      else
        USE_FLOCK=false # 显式设置，虽然默认已经是 false
      fi

      if $USE_FLOCK; then
        lock_file="/tmp/$(basename "$script_path").lock"
        final_job="$cron_time flock -xn $lock_file -c '$script_path'"
        log "已启用 flock 锁，锁文件路径: $lock_file"
      else
        final_job="$cron_time $script_path"
        log "未启用 flock 锁。"
      fi

      existing_cron=$(crontab -l 2>/dev/null) # 获取现有 crontab 内容
      if [[ -z "$existing_cron" ]]; then
        new_cron_content="$final_job" # 如果 crontab 为空，则新内容就是新任务
      else
        new_cron_content="$existing_cron"$'\n'"$final_job" # 否则，将新任务追加到现有内容末尾，并添加换行符
      fi
      echo "$new_cron_content" | crontab - # 使用 echo 和管道更新 crontab

      log "添加 cron 任务: '$final_job'"
      green "任务已成功添加。"
      ;;

    2)
      cancel_cron_job
      ;;

    3)
      echo "正在退出。"
      exit 0
      ;;

    *)
      red "无效的选择。"
      ;;
    esac
  done
}

if [[ "$(id -u)" -ne 0 ]]; then
  red "错误: 此脚本需要 root 权限。请使用 'sudo bash setup_cronjob.sh' 命令运行。"
  exit 1
fi

main
