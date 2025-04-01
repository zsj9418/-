#!/bin/bash

# 启用严格模式
set -euo pipefail
# 更友好的中断处理
trap 'echo -e "\n\e[31m操作被用户中断。\e[0m"; exit 1' INT

# 日志文件路径和轮转
LOG_FILE="$HOME/.deploy_script.log"
LOG_MAX_SIZE=3145728  # 3MB in bytes
# 检查日志文件大小，如果超过限制则清空
if [[ -f "$LOG_FILE" ]] && [[ "$(stat -c%s "$LOG_FILE")" -ge "$LOG_MAX_SIZE" ]]; then
  echo "日志文件 $LOG_FILE 超过 ${LOG_MAX_SIZE} bytes，正在清空..." > "$LOG_FILE" # 清空并记录原因
fi
# 确保日志文件存在
touch "$LOG_FILE"
# 将标准输出和标准错误都重定向到日志文件，并同时在终端显示
exec > >(tee -a "$LOG_FILE") 2>&1

# 常量
DEFAULT_PORT=3000
ONE_API_IMAGE_SPECIFIC="justsong/one-api:v0.6.11-preview.1" # 保留特定版本
# 使用官方推荐的最新镜像源
LATEST_ONE_API_IMAGE="ghcr.io/songquanpeng/one-api:latest"
DUCK2API_IMAGE="ghcr.io/aurora-develop/duck2api:latest"
DEFAULT_TZ="Asia/Shanghai" # 默认时区

# 彩色输出函数
function green() { echo -e "\e[32m$1\e[0m"; }
function red() { echo -e "\e[31m$1\e[0m"; }
function yellow() { echo -e "\e[33m$1\e[0m"; }

# 检测设备架构 (保持不变)
function detect_architecture() {
  local ARCH
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64 | amd64) PLATFORM="linux/amd64" ;;
    armv7l | armhf) PLATFORM="linux/arm/v7" ;;
    aarch64 | arm64) PLATFORM="linux/arm64" ;;
    *) red "错误：不支持的架构 ($ARCH)" && exit 1 ;;
  esac
  green "设备架构：$ARCH，适配平台：$PLATFORM"
}

# 检测操作系统 (保持不变)
function detect_os() {
  if [[ -f /etc/debian_version ]]; then
    OS="Debian/Ubuntu"
    PACKAGE_MANAGER="apt"
  elif [[ -f /etc/redhat-release ]]; then
    OS="CentOS/RHEL"
    # 更准确地判断 RHEL/CentOS 版本以选择 dnf 或 yum
    if grep -qi "stream 8" /etc/redhat-release || grep -qi "release 8" /etc/redhat-release || grep -qi "stream 9" /etc/redhat-release || grep -qi "release 9" /etc/redhat-release; then
        PACKAGE_MANAGER="dnf"
    elif grep -qi "release 7" /etc/redhat-release; then
        PACKAGE_MANAGER="yum"
    else
        # 默认为 dnf，适用于较新版本
        PACKAGE_MANAGER="dnf"
        yellow "警告：无法精确识别 CentOS/RHEL 版本，默认使用 dnf。"
    fi
  elif [[ -f /etc/arch-release ]]; then
    OS="Arch Linux"
    PACKAGE_MANAGER="pacman"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    OS="macOS"
    PACKAGE_MANAGER="brew"
  else
    red "错误：不支持的操作系统" && exit 1
  fi
  green "操作系统：$OS (包管理器: $PACKAGE_MANAGER)"
}

# 通用依赖安装函数 (保持不变)
function install_dependency() {
  local cmd=$1
  local package_name=$2 # 添加 package_name 参数
  local install_cmd=""
  case "$PACKAGE_MANAGER" in
    apt)
      install_cmd="sudo apt update && sudo apt install -y $package_name" # 使用 package_name
      ;;
    yum)
      install_cmd="sudo yum install -y $package_name" # 使用 package_name
      ;;
    dnf)
      install_cmd="sudo dnf install -y $package_name" # 使用 package_name
      ;;
    pacman)
      install_cmd="sudo pacman -Syu --noconfirm $package_name" # 使用 package_name, -Syu 更新系统
      ;;
    brew)
      # macOS brew 不需要 sudo
      install_cmd="brew install $package_name"
      ;;
    *)
      red "错误：不支持的包管理器：$PACKAGE_MANAGER"
      exit 1
      ;;
  esac
  if ! command -v $cmd &>/dev/null; then
    yellow "正在安装 $package_name (提供 $cmd 命令)..."
    if eval "$install_cmd"; then
        green "$cmd 安装成功。"
    else
        red "$cmd 安装失败，请检查错误信息并尝试手动安装。"
        exit 1
    fi
  else
    green "$cmd 已安装，跳过安装。"
  fi
}

# 检查依赖 (保持不变)
function check_dependencies() {
  # 检查 Docker
  local docker_package="docker.io" # Default for Debian/Ubuntu
  if [[ "$PACKAGE_MANAGER" == "yum" ]] || [[ "$PACKAGE_MANAGER" == "dnf" ]]; then
      docker_package="docker-ce docker-ce-cli containerd.io" # RHEL/CentOS
      # 可能需要先添加 Docker 仓库
      if ! rpm -q docker-ce &>/dev/null; then
          yellow "为 CentOS/RHEL 添加 Docker CE 仓库..."
          sudo $PACKAGE_MANAGER install -y yum-utils device-mapper-persistent-data lvm2 || true # 确保工具存在
          sudo $PACKAGE_MANAGER config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      fi
  elif [[ "$PACKAGE_MANAGER" == "pacman" ]]; then
      docker_package="docker"
  elif [[ "$PACKAGE_MANAGER" == "brew" ]]; then
      docker_package="docker" # On macOS, 'brew install docker' installs Docker Desktop
  fi
  install_dependency "docker" "$docker_package"
  # 启动并启用 Docker 服务 (Linux only)
  if [[ "$OS" != "macOS" ]]; then
      if ! systemctl is-active --quiet docker; then
          yellow "尝试启动并启用 Docker 服务..."
          sudo systemctl enable --now docker || yellow "警告：无法自动启动或启用 Docker 服务，请手动操作。"
      fi
  fi


  # 检查 Docker Compose (保持不变)
  if ! command -v docker-compose &>/dev/null; then
    yellow "正在安装 docker-compose..."
    # 使用官方推荐的 plugin 安装方式（如果 Docker 版本支持）或独立二进制文件
    if docker compose version &>/dev/null; then
         green "Docker Compose 插件已存在。"
    else
        local compose_version="v2.29.2" # 可以更新为最新稳定版
        local compose_url="https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)"
        yellow "下载 Docker Compose ${compose_version}..."
        if curl -sSL "$compose_url" -o /tmp/docker-compose; then
            local install_path="/usr/local/bin/docker-compose"
            # 对于 macOS，/usr/local/bin 通常在 PATH 中且用户可写
            if [[ "$OS" == "macOS" ]]; then
                mv /tmp/docker-compose "$install_path"
                chmod +x "$install_path"
            else
                sudo mv /tmp/docker-compose "$install_path"
                sudo chmod +x "$install_path"
            fi

            if command -v docker-compose &>/dev/null; then
                green "docker-compose 安装成功。"
            else
                red "docker-compose 安装失败，请手动安装。"
                exit 1
            fi
        else
            red "docker-compose 下载失败，请检查网络连接或手动下载安装。"
            exit 1
        fi
    fi
  else
    green "Docker Compose 已安装，跳过安装。"
  fi
}

# 检查用户权限 (保持不变，对 macOS 不适用)
function check_user_permission() {
  if [[ "$OS" == "macOS" ]]; then
      green "在 macOS 上，Docker 通常不需要特殊用户组权限。"
      return 0
  fi

  # 检查是否 root 用户
  if [[ "$EUID" -eq 0 ]]; then
      green "当前用户是 root，拥有 Docker 权限。"
      return 0
  fi

  # 检查是否在 docker 组
  if groups "$USER" | grep -q '\bdocker\b'; then
    green "当前用户已在 Docker 用户组中。"
  else
    yellow "警告：当前用户 ($USER) 未加入 Docker 用户组。"
    yellow "尝试将用户添加到 docker 组..."
    if sudo usermod -aG docker "$USER"; then
        green "已将用户 $USER 添加到 docker 组。"
        red "请完全注销并重新登录，或者运行 'newgrp docker' 命令以使组成员资格生效，否则后续 Docker 命令可能失败！"
        # 提供一个选项让用户确认他们理解了
        read -n 1 -s -r -p "按任意键继续，或按 Ctrl+C 退出并重新登录..."
        echo
    else
        red "错误：无法将用户添加到 docker 组。请手动添加或使用 sudo 运行 Docker 命令。"
        # 不退出，但后续操作可能会失败
    fi
  fi
}

# 自动分配可用端口 (保持不变)
function find_available_port() {
  local start_port=${1:-$DEFAULT_PORT}
  # 使用 ss 或 netstat 检查端口，更通用
  while ss -tuln | grep -q ":$start_port " || netstat -tuln | grep -q ":$start_port "; do
    ((start_port++))
  done
  echo $start_port
}

# 验证端口 (保持不变，略作改进)
function validate_port() {
  local suggested_port
  suggested_port=$(find_available_port "${1:-$DEFAULT_PORT}") # 允许传入默认端口建议
  green "建议使用的端口：$suggested_port"
  read -p "请输入您希望使用的端口（留空使用 $suggested_port）： " user_port
  # 使用全局变量 PORT 存储最终选择的端口
  PORT=${user_port:-$suggested_port}
  if ! [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]]; then
    red "端口号无效，请输入 1 到 65535 范围内的数字。"
    validate_port "$suggested_port" # 重新验证时传递建议端口
    return # 确保递归后退出当前层
  fi
  # 再次检查最终选择的端口是否被占用
  if ss -tuln | grep -q ":$PORT " || netstat -tuln | grep -q ":$PORT "; then
      red "端口 $PORT 已被占用，请选择其他端口。"
      validate_port "$suggested_port" # 重新验证
      return
  fi
  green "将使用端口: $PORT"
}

# 提供网络模式选择 (保持不变)
function choose_network_mode() {
  echo "请选择 Docker 网络模式："
  echo "  1. bridge (推荐, 容器有独立 IP, 通过端口映射访问)"
  echo "  2. host (容器共享主机网络, 性能稍好, 但端口冲突风险高)"
  # echo "  3. macvlan (高级模式, 不推荐新手使用)" # 暂时注释掉macvlan，简化选项
  read -p "请输入选项 (1-2, 默认 1): " mode
  mode=${mode:-1} # 默认选 1
  case $mode in
    1) NETWORK_MODE="bridge"; green "选择的网络模式：bridge"; ;;
    2) NETWORK_MODE="host"; green "选择的网络模式：host"; ;;
    # 3) NETWORK_MODE="macvlan"; green "选择的网络模式：macvlan"; ;;
    *) red "无效选项，请重新选择。" && choose_network_mode ;;
  esac
}

# 验证网络模式 (保持不变)
function validate_network_mode() {
  case "$NETWORK_MODE" in
    bridge|host) ;; # 移除 macvlan 检查
    *) red "内部错误：无效的网络模式 '$NETWORK_MODE'" && exit 1 ;;
  esac
}

# 检查是否存在同名容器 (保持不变)
function check_existing_container() {
  local name="$1"
  if docker ps -a --format '{{.Names}}' | grep -Eq "^${name}$"; then
    red "错误：名为 '$name' 的容器已存在。"
    yellow "请先使用卸载选项移除现有容器，或为新部署选择其他名称（如果脚本支持）。"
    return 1 # 返回失败状态码
  fi
  return 0 # 返回成功状态码
}

# 拉取镜像函数（带重试）
function pull_image_with_retry() {
    local image=$1
    local platform_arg=""
    # 如果 PLATFORM 已定义且非空，则添加 --platform 参数
    if [[ -n "${PLATFORM:-}" ]]; then
        platform_arg="--platform $PLATFORM"
    fi

    yellow "正在拉取镜像 $image (平台: ${PLATFORM:-自动检测})..."
    # shellcheck disable=SC2086 # platform_arg 可能为空，需要 unquoted
    if ! docker pull $platform_arg "$image"; then
        red "镜像 $image 拉取失败。"
        read -p "是否重试？(y/n，默认 n): " retry
        if [[ "$retry" =~ ^[Yy]$ ]]; then
            pull_image_with_retry "$image" # 递归调用
        else
            red "放弃拉取镜像 $image。"
            return 1 # 返回失败
        fi
    else
        green "镜像 $image 拉取成功。"
        return 0 # 返回成功
    fi
}


# 通用部署服务函数 (SQLite 版本)
# 参数: name, image, internal_port, data_dir_name
function deploy_service_sqlite() {
  local name="$1"
  local image="$2"
  local internal_port="$3"
  local data_dir_name="$4"
  local data_dir # 本地数据目录完整路径

  # 检查容器名是否冲突
  if ! check_existing_container "$name"; then return 1; fi

  validate_port "$internal_port" # 验证并设置全局变量 PORT
  choose_network_mode # 设置全局变量 NETWORK_MODE
  validate_network_mode

  # 拉取镜像
  if ! pull_image_with_retry "$image"; then return 1; fi

  # 创建数据目录（使用绝对路径更可靠）
  data_dir="$HOME/$data_dir_name" # 将数据目录放在用户主目录下
  yellow "确保数据目录存在: $data_dir"
  mkdir -p "$data_dir"
  if [[ ! -w "$data_dir" ]]; then
      red "错误：数据目录 $data_dir 不可写，请检查权限。"
      return 1
  fi

  green "正在部署 $name (SQLite 模式)..."
  local docker_run_cmd=()
  docker_run_cmd+=(docker run -d --name "$name")
  docker_run_cmd+=(--restart always)

  # 根据网络模式添加参数
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker_run_cmd+=(--network host)
    # Host 模式下，容器直接使用宿主机端口，不需要 -p
    # 但需要确保容器内部监听的端口与我们选择的 PORT 一致，或者告知用户实际监听端口
    yellow "使用 host 网络模式，容器将尝试监听端口 $internal_port。"
    # 注意：如果容器内部配置可以改变监听端口，这里可能不准确
  else # bridge 模式
    docker_run_cmd+=(--network bridge)
    docker_run_cmd+=(-p "$PORT:$internal_port") # 使用验证后的 PORT
  fi

  # 添加数据卷和时区
  docker_run_cmd+=(-v "$data_dir:/data")
  docker_run_cmd+=(-e "TZ=$DEFAULT_TZ")
  docker_run_cmd+=("$image")

  # 执行命令
  yellow "执行命令: ${docker_run_cmd[*]}"
  if ! "${docker_run_cmd[@]}"; then
      red "容器 $name 启动失败！"
      yellow "请检查容器日志获取详细错误信息: docker logs $name"
      # 尝试清理失败的容器
      docker rm "$name" &>/dev/null || true
      return 1
  fi

  # 部署成功后的提示
  green "$name 部署成功！"
  local access_ip="<您的服务器IP>"
  # 尝试获取 IP
  access_ip=$(hostname -I | awk '{print $1}' || echo "$access_ip") # 获取第一个内网IP
  local access_port=$PORT
  if [[ "$NETWORK_MODE" == "host" ]]; then
      access_port=$internal_port # Host 模式下，访问端口是容器内部监听的端口
      green "访问地址 (host 模式): http://$access_ip:$access_port"
  else
      green "访问地址 (bridge 模式): http://$access_ip:$access_port"
  fi
  green "数据目录: $data_dir"
  green "查看容器日志: docker logs $name"
  green "停止容器: docker stop $name"
  green "启动容器: docker start $name"
  green "卸载服务请使用脚本菜单。"
}

# --- 新增：部署 One-API 使用 MySQL 的函数 ---
function deploy_one_api_mysql() {
  local name="one-api-mysql" # 固定容器名
  local image="$LATEST_ONE_API_IMAGE" # 使用最新镜像
  local internal_port="3000" # One-API 默认端口
  local data_dir_name="one-api-mysql-data" # 数据目录名
  local data_dir # 本地数据目录完整路径
  local db_host db_port db_user db_pass db_name sql_dsn

  yellow "--- 部署 One-API (使用 MySQL) ---"

  # 1. 检查容器名冲突
  if ! check_existing_container "$name"; then return 1; fi

  # 2. 端口和网络模式
  validate_port "$internal_port" # 设置全局 PORT
  choose_network_mode # 设置全局 NETWORK_MODE
  validate_network_mode

  # 3. 获取 MySQL 连接信息
  yellow "请输入 MySQL 数据库连接信息:"
  read -p "  数据库主机 (例如: localhost, 192.168.1.10): " db_host
  read -p "  数据库端口 (默认 3306): " db_port
  db_port=${db_port:-3306}
  read -p "  数据库用户名 (例如: root, oneapi_user): " db_user
  read -sp "  数据库密码: " db_pass # -s 静默输入
  echo # 换行
  read -p "  数据库名称 (例如: oneapi): " db_name

  # 基本验证
  if [[ -z "$db_host" || -z "$db_user" || -z "$db_name" ]]; then
      red "错误：数据库主机、用户名和名称不能为空。"
      return 1
  fi
   if ! [[ "$db_port" =~ ^[0-9]+$ ]]; then
       red "错误：数据库端口必须是数字。"
       return 1
   fi
   # 密码可以为空，由用户决定

  # 构造 SQL_DSN 字符串 (注意密码中的特殊字符可能需要处理，但通常交给 Docker 和应用)
  sql_dsn="${db_user}:${db_pass}@tcp(${db_host}:${db_port})/${db_name}"
  yellow "将使用的 SQL_DSN: ${db_user}:******@tcp(${db_host}:${db_port})/${db_name}" # 不显示密码

  # 4. 拉取镜像
  if ! pull_image_with_retry "$image"; then return 1; fi

  # 5. 创建数据目录 (仍然需要，用于存储非数据库数据，如日志)
  data_dir="$HOME/$data_dir_name"
  yellow "确保数据目录存在: $data_dir"
  mkdir -p "$data_dir"
   if [[ ! -w "$data_dir" ]]; then
      red "错误：数据目录 $data_dir 不可写，请检查权限。"
      return 1
  fi

  # 6. 构建并执行 docker run 命令
  green "正在部署 $name (MySQL 模式)..."
  local docker_run_cmd=()
  docker_run_cmd+=(docker run -d --name "$name")
  docker_run_cmd+=(--restart always)

  # 网络模式
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker_run_cmd+=(--network host)
    yellow "使用 host 网络模式，容器将尝试监听端口 $internal_port。"
  else # bridge 模式
    docker_run_cmd+=(--network bridge)
    docker_run_cmd+=(-p "$PORT:$internal_port")
  fi

  # 添加数据卷、时区和 MySQL DSN 环境变量
  docker_run_cmd+=(-v "$data_dir:/data")
  docker_run_cmd+=(-e "TZ=$DEFAULT_TZ")
  docker_run_cmd+=(-e "SQL_DSN=$sql_dsn") # 添加 MySQL 连接字符串
  docker_run_cmd+=("$image")

  # 执行命令
  yellow "执行命令: ${docker_run_cmd[*]}" # 注意 DSN 中的密码会显示在这里，但日志中已隐藏
  if ! "${docker_run_cmd[@]}"; then
      red "容器 $name 启动失败！"
      yellow "请检查数据库连接信息是否正确，以及容器日志: docker logs $name"
      docker rm "$name" &>/dev/null || true
      return 1
  fi

  # 7. 部署成功提示
  green "$name 部署成功！(使用 MySQL)"
  local access_ip="<您的服务器IP>"
  access_ip=$(hostname -I | awk '{print $1}' || echo "$access_ip")
  local access_port=$PORT
  if [[ "$NETWORK_MODE" == "host" ]]; then
      access_port=$internal_port
      green "访问地址 (host 模式): http://$access_ip:$access_port"
  else
      green "访问地址 (bridge 模式): http://$access_ip:$access_port"
  fi
  green "数据库配置: ${db_user}@${db_host}:${db_port}/${db_name}"
  green "数据目录 (非数据库): $data_dir"
  green "查看容器日志: docker logs $name"
}
# --- 结束新增函数 ---

# 卸载服务 (通用，通过名称和数据目录名卸载)
# 参数: name, data_dir_name
function uninstall_service() {
  local name="$1"
  local data_dir_name="$2"
  local data_dir="$HOME/$data_dir_name" # 推断数据目录路径

  yellow "--- 卸载服务: $name ---"

  local container_exists=false
  if docker ps -a --format '{{.Names}}' | grep -Eq "^${name}$"; then
      container_exists=true
      yellow "正在停止并移除容器 $name..."
      if docker stop "$name" && docker rm "$name"; then
          green "容器 $name 已成功停止并移除。"
      else
          red "错误：停止或移除容器 $name 失败。请手动检查：docker ps -a"
          # 即使失败也继续尝试删除镜像和数据
      fi
  else
    yellow "未发现名为 '$name' 的容器。"
  fi

  # 尝试查找与服务相关的镜像 (基于服务名可能不准确，最好基于镜像名)
  # 这里简化处理，假设镜像名包含服务名的一部分
  local image_pattern="$name" # 简单的模式
  if [[ "$name" == "one-api-mysql" ]] || [[ "$name" == "one-api-latest" ]]; then
      image_pattern="one-api" # one-api 镜像通用模式
  elif [[ "$name" == "one-api" ]]; then
       image_pattern="justsong/one-api" # 特定版本镜像
  elif [[ "$name" == "duck2api" ]]; then
       image_pattern="duck2api"
  fi

  # 查找并尝试删除相关镜像
  local images_to_remove
  images_to_remove=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "$image_pattern" || true)
  if [[ -n "$images_to_remove" ]]; then
       yellow "发现可能相关的镜像:"
       echo "$images_to_remove"
       read -p "是否尝试移除这些镜像？(y/n，默认 n): " confirm_rmi
       if [[ "$confirm_rmi" =~ ^[Yy]$ ]]; then
           # shellcheck disable=SC2086 # images_to_remove 可能包含多个镜像
           if docker rmi $images_to_remove; then
               green "相关镜像已尝试移除。"
           else
               yellow "警告：部分或全部相关镜像移除失败（可能正在被其他容器使用）。"
           fi
       else
           yellow "跳过移除镜像。"
       fi
  else
       yellow "未发现与 '$image_pattern' 相关的镜像。"
  fi


  # 处理数据目录
  if [[ -d "$data_dir" ]]; then
    yellow "发现数据目录: $data_dir"
    read -p "是否删除此数据目录及其所有内容？(y/n，默认 n): " confirm_rm_data
    if [[ "$confirm_rm_data" =~ ^[Yy]$ ]]; then
      # 提供备份选项
      read -p "删除前是否备份数据目录 $data_dir？(y/n，默认 n): " backup
      if [[ "$backup" =~ ^[Yy]$ ]]; then
        local backup_dir="${data_dir}-backup-$(date +%Y%m%d_%H%M%S)"
        yellow "正在备份数据到 $backup_dir ..."
        if mv "$data_dir" "$backup_dir"; then
            green "数据目录已备份到 $backup_dir。"
        else
            red "错误：备份数据目录失败！请检查权限。"
            yellow "数据目录未被删除。"
        fi
      else
        yellow "正在删除数据目录 $data_dir ..."
        if rm -rf "$data_dir"; then
            green "数据目录 $data_dir 已删除。"
        else
            red "错误：删除数据目录 $data_dir 失败！请检查权限。"
        fi
      fi
    else
      yellow "数据目录 $data_dir 已保留。"
    fi
  else
       # 如果容器存在但目录不存在，也提示一下
       if [[ "$container_exists" == true ]]; then
            yellow "未找到关联的数据目录 $data_dir（或路径不匹配）。"
       fi
  fi

  # 清理无用的 Docker 资源 (可选，谨慎使用)
  # docker network prune -f || true
  # docker volume prune -f || true
  # green "无用的网络和卷已尝试清理。"
  green "卸载流程完成。"
}

# 部署特定版本 One-API (SQLite)
function deploy_one_api_specific() {
  deploy_service_sqlite "one-api" "$ONE_API_IMAGE_SPECIFIC" 3000 "one-api-data"
}

# 部署最新版 One-API (SQLite)
function deploy_latest_one_api_sqlite() {
  deploy_service_sqlite "one-api-latest" "$LATEST_ONE_API_IMAGE" 3000 "one-api-latest-data"
}

# 部署 Duck2API
function deploy_duck2api() {
  deploy_service_sqlite "duck2api" "$DUCK2API_IMAGE" 8080 "duck2api-data"
}

# 卸载项目 (更新菜单)
function uninstall_project() {
  echo "请选择要卸载的项目："
  echo "  1. One-API 特定版本 (SQLite, 容器名: one-api)"
  echo "  2. One-API 最新版 (SQLite, 容器名: one-api-latest)"
  echo "  3. One-API 最新版 (MySQL, 容器名: one-api-mysql)" # 新增
  echo "  4. Duck2API (容器名: duck2api)"
  echo "  0. 返回主菜单"
  read -p "请输入选择（0-4）： " project_choice
  case $project_choice in
    1) uninstall_service "one-api" "one-api-data" ;;
    2) uninstall_service "one-api-latest" "one-api-latest-data" ;;
    3) uninstall_service "one-api-mysql" "one-api-mysql-data" ;; # 新增
    4) uninstall_service "duck2api" "duck2api-data" ;;
    0) return ;;
    *) red "无效选项，请重新选择。" && uninstall_project ;;
  esac
}

# 查看所有容器状态 (保持不变)
function view_container_status() {
  green "--- 当前 Docker 容器状态 ---"
  # 使用更易读的格式
  if docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | wc -l | grep -q '1'; then
      yellow "当前没有运行中或已停止的容器。"
  else
      docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
  fi
  echo "-----------------------------"
}

# 主菜单 (更新选项)
function main_menu() {
  # 初始化检查
  detect_architecture
  detect_os
  check_dependencies
  check_user_permission # 检查权限，可能会提示用户重新登录

  while true; do
    echo ""
    echo "========================================"
    echo "        Docker 服务管理脚本"
    echo "========================================"
    echo "请选择要执行的操作："
    echo "  1. 部署 One-API 特定版本 (SQLite)"
    echo "  2. 部署 One-API 最新版 (SQLite)"
    echo "  3. 部署 One-API 最新版 (使用 MySQL)" # 新增
    echo "  4. 部署 Duck2API"
    echo "----------------------------------------"
    echo "  5. 卸载服务"
    echo "  6. 查看所有容器状态"
    echo "----------------------------------------"
    echo "  0. 退出脚本"
    echo "========================================"
    read -p "请输入选项编号 (0-6): " choice

    # 添加换行增加可读性
    echo ""

    case $choice in
      1) deploy_one_api_specific ;;
      2) deploy_latest_one_api_sqlite ;;
      3) deploy_one_api_mysql ;; # 调用新函数
      4) deploy_duck2api ;;
      5) uninstall_project ;;
      6) view_container_status ;;
      0) green "感谢您的使用！脚本退出。" && exit 0 ;;
      *) red "无效选项 '$choice'，请输入 0 到 6 之间的数字。" ;;
    esac

    # 在每次操作后暂停，让用户看到输出
    if [[ "$choice" != "0" ]]; then
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        echo "" # 换行
    fi
    clear # 清屏使菜单更清晰 (可选)
  done
}

# --- 脚本入口 ---
# 清屏开始
clear
main_menu
