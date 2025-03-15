#!/bin/bash

# 检查用户是否为root
if [ "$EUID" -ne 0 ]; then
  echo "请以root用户运行此脚本，请使用sudo或root权限运行。"
  exit 1
fi

# 初始化日志文件
LOG_FILE="/var/log/install_tools.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "日志文件: $LOG_FILE"

# 检测系统包管理器
if command -v apt &> /dev/null; then
  PKG_MANAGER="apt"
  SOURCES_LIST="/etc/apt/sources.list"
  SOURCES_BACKUP="/etc/apt/sources.list.backup"
elif command -v yum &> /dev/null; then
  PKG_MANAGER="yum"
  SOURCES_LIST="/etc/yum.repos.d/CentOS-Base.repo"
  SOURCES_BACKUP="/etc/yum.repos.d/CentOS-Base.repo.backup"
elif command -v dnf &> /dev/null; then
  PKG_MANAGER="dnf"
  SOURCES_LIST="/etc/yum.repos.d/fedora.repo"
  SOURCES_BACKUP="/etc/yum.repos.d/fedora.repo.backup"
elif command -v apk &> /dev/null; then
  PKG_MANAGER="apk"
elif command -v pacman &> /dev/null; then
  PKG_MANAGER="pacman"
else
  echo "未检测到支持的包管理器 (apt/yum/dnf/apk/pacman)，脚本无法继续。"
  exit 1
fi

# 检测设备架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)
    ARCH="amd64"
    ;;
  aarch64)
    ARCH="arm64"
    ;;
  armv7l)
    ARCH="armv7"
    ;;
  *)
    echo "不支持的设备架构: $ARCH"
    exit 1
    ;;
esac
echo "检测到设备架构为：$ARCH"

# 检测系统版本
if [ "$PKG_MANAGER" = "apt" ]; then
  SYSTEM_VERSION=$(lsb_release -cs)
  echo "检测到系统版本: $SYSTEM_VERSION"
fi

# 错误处理函数
handle_error() {
  local message="$1"
  echo "错误: $message"
  echo "是否跳过此步骤继续往后执行？"
  select choice in "跳过" "退出脚本"; do
    case $choice in
      "跳过") return 0 ;;
      "退出脚本") exit 1 ;;
      *) echo "无效选项，请重新选择。" ;;
    esac
  done
}

# 备份源文件
backup_sources() {
  echo "正在备份源文件..."
  if [ -f "$SOURCES_LIST" ]; then
    cp "$SOURCES_LIST" "$SOURCES_BACKUP" || handle_error "备份源文件失败"
    echo "源文件已备份到 $SOURCES_BACKUP"
  else
    echo "未找到源文件，跳过备份。"
  fi
}

# 还原备份源
restore_sources() {
  echo "正在还原源文件..."
  if [ -f "$SOURCES_BACKUP" ]; then
    cp "$SOURCES_BACKUP" "$SOURCES_LIST" || handle_error "还原源文件失败"
    echo "源文件已从 $SOURCES_BACKUP 还原。"
  else
    echo "未找到备份文件，跳过还原。"
  fi
}

# 更换为阿里源
change_to_aliyun() {
  echo "正在更换为阿里云镜像源..."
  case $PKG_MANAGER in
    apt)
      sed -i "s|http://[^/]*|http://mirrors.aliyun.com|g" "$SOURCES_LIST"
      sed -i "s|ubuntu|ubuntu $SYSTEM_VERSION|g" "$SOURCES_LIST" || handle_error "更换阿里云镜像源失败"
      ;;
    yum|dnf)
      curl -o "$SOURCES_LIST" http://mirrors.aliyun.com/repo/Centos-7.repo || handle_error "下载阿里云镜像源配置失败"
      ;;
    pacman)
      sudo sed -i "s|^Server = .*|Server = http://mirrors.aliyun.com/archlinux/$repo/os/$ARCH|g" /etc/pacman.d/mirrorlist || handle_error "更换阿里云镜像源失败"
      ;;
    apk)
      echo "阿里云暂不支持 apk 包管理器源切换。"
      ;;
    *)
      echo "未找到适配的源配置，跳过更换。"
      ;;
  esac
  echo "已更换为阿里云镜像源。"
}

# 更新系统包
update_system() {
  echo "正在更新系统包..."
  $PKG_MANAGER update -y || handle_error "系统更新失败，请检查网络连接或包管理器状态。"
}

# 安装常用工具
install_common_tools() {
  echo "正在安装常用工具..."
  
  # 原有的常用工具
  COMMON_TOOLS="sudo git vim curl wget htop tmux tree zip unzip openssh-server dos2unix"

  # 从分析的脚本中提取的必要依赖项
  NECESSARY_TOOLS="jq lsof tar iptables ipset resolvconf util-linux cron net-tools fzf dnsutils psmisc yamllint"

  # 动态检查工具是否已安装
  for TOOL in $COMMON_TOOLS $NECESSARY_TOOLS; do
    if command -v "$TOOL" &> /dev/null; then
      echo "$TOOL 已安装，跳过安装。"
    else
      echo "正在安装 $TOOL..."
      $PKG_MANAGER install -y "$TOOL" || handle_error "安装 $TOOL 失败，请检查网络连接或包管理器状态。"
    fi
  done

  echo "常用工具和必要依赖安装完成。"
}

# 安装开发工具
install_dev_tools() {
  echo "正在安装开发工具..."
  DEV_TOOLS="build-essential gcc g++ make cmake python3 python3-pip nodejs npm openjdk-17-jdk maven"
  for TOOL in $DEV_TOOLS; do
    if command -v "$TOOL" &> /dev/null; then
      echo "$TOOL 已安装，跳过安装。"
    else
      echo "正在安装 $TOOL..."
      $PKG_MANAGER install -y "$TOOL" || handle_error "安装 $TOOL 失败，请检查网络连接或包管理器状态。"
    fi
  done
  echo "开发工具安装完成。"
}

# 清理缓存
clean_package_cache() {
  echo "正在清理系统缓存..."
  case $PKG_MANAGER in
    apt)
      sudo apt autoremove -y && sudo apt clean || handle_error "清理缓存失败"
      ;;
    yum|dnf)
      sudo $PKG_MANAGER autoremove -y && sudo $PKG_MANAGER clean all || handle_error "清理缓存失败"
      ;;
    apk)
      sudo apk cache clean || handle_error "清理缓存失败"
      ;;
    pacman)
      sudo pacman -Rns $(pacman -Qdtq) --noconfirm && sudo pacman -Scc --noconfirm || handle_error "清理缓存失败"
      ;;
  esac
  echo "系统缓存清理完成。"
}

# 限制日志文件大小
manage_log_file() {
  local max_size=1048576  # 1MB
  if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $max_size ]]; then
    echo "日志文件大小超过 1MB，正在清空..."
    > "$LOG_FILE"
  fi
}

# 验证镜像源有效性
verify_sources() {
  echo "正在验证镜像源有效性..."
  case $PKG_MANAGER in
    apt)
      apt update || handle_error "镜像源验证失败，请检查镜像源地址是否正确。"
      ;;
    yum|dnf)
      $PKG_MANAGER makecache || handle_error "镜像源验证失败，请检查镜像源地址是否正确。"
      ;;
    pacman)
      sudo pacman -Syy || handle_error "镜像源验证失败，请检查镜像源地址是否正确。"
      ;;
  esac
  echo "镜像源验证成功。"
}

# 主清理函数
perform_cleanup() {
  echo "正在执行清理工作..."
  clean_package_cache
  manage_log_file
  echo "清理工作完成！"
}

# 交互式菜单
while true; do
  echo "
请选择要执行的操作：
1. 更换为阿里云镜像源
2. 更新系统包
3. 安装常用工具
4. 安装开发工具
5. 清理系统缓存
6. 验证镜像源有效性
7. 还原备份源
8. 执行清理工作
9. 退出脚本
"
  read -p "请输入选项编号：" CHOICE
  case $CHOICE in
    1)
      backup_sources
      change_to_aliyun
      ;;
    2)
      update_system
      ;;
    3)
      install_common_tools
      ;;
    4)
      install_dev_tools
      ;;
    5)
      clean_package_cache
      ;;
    6)
      verify_sources
      ;;
    7)
      restore_sources
      ;;
    8)
      perform_cleanup
      ;;
    9)
      echo "退出脚本。"
      break
      ;;
    *)
      echo "无效选项，请重新输入。"
      ;;
  esac
done
