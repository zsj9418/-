#!/bin/bash
# Docker管理脚本
# 功能：支持 Watchtower 和 Sub-Store 的部署、通知、日志记录和数据备份/恢复
# 增强功能：用户可以选择网络模式（bridge 或 host），支持自定义端口。
# 动态脚本加载：支持在根目录下自动创建一个目录并挂载读取各种规则文件以备后续的拓展性

# 配置区（默认值）
DATA_DIR="$HOME/substore/data"
SCRIPTS_DIR="$HOME/substore/scripts"
BACKUP_DIR="$HOME/substore/backup"
LOG_DIR="$HOME/substore/logs"
LOG_FILE="$LOG_DIR/docker_management.log"
LOG_MAX_SIZE=1048576  # 1M
CONTAINER_NAME="substore"
WATCHTOWER_CONTAINER_NAME="watchtower"
TIMEZONE="Asia/Shanghai"
SUB_STORE_IMAGE_NAME="xream/sub-store"
WATCHTOWER_IMAGE_NAME="containrrr/watchtower"
DEFAULT_SUB_STORE_PATH="/12345678"  # 修改默认路径

# 默认端口
DEFAULT_FRONTEND_PORT=3000
DEFAULT_BACKEND_PORT=3001

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 创建必要的目录
create_directories() {
  mkdir -p "$DATA_DIR"
  mkdir -p "$SCRIPTS_DIR"
  mkdir -p "$BACKUP_DIR"
  mkdir -p "$LOG_DIR"
  log "INFO" "所有必要的目录已创建"
}

# 初始化日志
log() {
  local level=$1
  local message=$2
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  case $level in
    "INFO") echo -e "${GREEN}[INFO] $timestamp - $message${NC}" >&2 ;; # Redirect to stderr
    "WARN") echo -e "${YELLOW}[WARN] $timestamp - $message${NC}" >&2 ;; # Redirect to stderr
    "ERROR") echo -e "${RED}[ERROR] $timestamp - $message${NC}" >&2 ;; # Redirect to stderr
  esac
  echo "[$level] $timestamp - $message" >> "$LOG_FILE"

  # 限制日志大小为 1M，超过后清空
  if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
    > "$LOG_FILE"
    log "INFO" "日志文件大小超过 1M，已清空日志。"
  fi
}

# 检测设备架构和操作系统
detect_system() {
  log "INFO" "正在检测设备架构和操作系统..."
  ARCH=$(uname -m)
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  fi
  log "INFO" "设备架构: $ARCH, 操作系统: $OS"
}

# 检测端口是否可用
check_port_available() {
  local port=$1
  if lsof -i:"$port" >/dev/null 2>&1; then
    return 1  # 端口被占用
  else
    return 0  # 端口可用
  fi
}

# 提示用户输入端口
prompt_for_port() {
  local prompt_message=$1
  local default_port=$2
  local port=""

  while true; do
    read -p "$prompt_message [$default_port]: " port
    port=${port:-$default_port}  # 如果用户未输入，使用默认端口
    if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 1 ] && [ $port -le 65535 ]; then
      if check_port_available "$port"; then
        echo "$port"
        return
      else
        log "WARN" "端口 $port 已被占用，请选择其他端口"
      fi
    else
      log "WARN" "无效的端口号，请输入1到65535之间的数字"
    fi
  done
}

# 提示用户输入路径
prompt_for_path() {
  local default_path=$(basename "$DEFAULT_SUB_STORE_PATH")
  local user_input=""
  read -p "请输入 Sub-Store 前后端路径（只需输入路径名，不需加/） [$default_path]: " user_input
  user_input=${user_input:-$default_path}
  SUB_STORE_FRONTEND_BACKEND_PATH="/${user_input}"
  log "INFO" "设置前后端路径为: $SUB_STORE_FRONTEND_BACKEND_PATH"
}

# 安装依赖（根据系统和架构）
install_dependencies() {
  log "INFO" "正在安装依赖..."
  if ! command -v docker &> /dev/null; then
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
      apt update && apt install -y curl lsof || {
        log "ERROR" "依赖安装失败，请检查网络连接"
        exit 1
      }
      curl -fsSL https://get.docker.com | sh || {
        log "ERROR" "Docker安装失败"
        exit 1
      }
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
      yum install -y curl lsof || {
        log "ERROR" "依赖安装失败，请检查网络连接"
        exit 1
      }
      curl -fsSL https://get.docker.com | sh || {
        log "ERROR" "Docker安装失败"
        exit 1
      }
    else
      log "ERROR" "不支持的操作系统: $OS"
      exit 1
    fi
    systemctl enable --now docker
    log "INFO" "Docker 已成功安装"
  else
    log "INFO" "Docker 已存在，跳过安装"
  fi

  # 检查并安装 jq
  if ! command -v jq &> /dev/null; then
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
      apt install -y jq || {
        log "ERROR" "jq 安装失败"
        exit 1
      }
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
      yum install -y jq || {
        log "ERROR" "jq 安装失败"
        exit 1
      }
    else
      log "ERROR" "不支持的操作系统: $OS"
      exit 1
    fi
    log "INFO" "jq 已成功安装"
  else
    log "INFO" "jq 已存在，跳过安装"
  fi
}

# 部署 Watchtower
install_watchtower() {
  log "INFO" "正在部署 Watchtower..."
  docker run -d \
    --name $WATCHTOWER_CONTAINER_NAME \
    --restart=always \
    --net=host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    $WATCHTOWER_IMAGE_NAME \
    --cleanup \
    -i 3600 || {
      log "ERROR" "Watchtower 部署失败"
      exit 1
    }
  log "INFO" "Watchtower 部署成功"
}

# 获取 Sub-Store 版本列表
get_substore_versions() {
  log "INFO" "正在获取 Sub-Store 版本列表..."
  # 调用 Docker Hub API 获取版本信息，增加 page_size 参数以获取更多版本
  curl -s "https://hub.docker.com/v2/repositories/xream/sub-store/tags/?page_size=15" | jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-http-meta)?$' | sort -r
}

# 提示用户选择版本
prompt_for_version() {
  local versions=($(get_substore_versions))
  local num_versions=${#versions[@]}

  if [ $num_versions -eq 0 ]; then
    log "ERROR" "无法获取 Sub-Store 版本列表"
    exit 1
  fi

  echo "请选择 Sub-Store 版本："
  for i in "${!versions[@]}"; do
    echo "$((i + 1)). ${versions[$i]}"
  done

  while true; do
    read -p "请输入版本编号: " version_choice
    if [[ $version_choice =~ ^[0-9]+$ ]] && [ $version_choice -ge 1 ] && [ $version_choice -le $num_versions ]; then
      SUB_STORE_VERSION=${versions[$((version_choice - 1))]}
      break
    else
      log "WARN" "无效的选择，请重新输入"
    fi
  done

  log "INFO" "选择的 Sub-Store 版本: $SUB_STORE_VERSION"
}

# 初始化示例脚本
initialize_example_scripts() {
  echo "是否需要初始化示例脚本目录? (y/n) [默认: y]: "
  read init_scripts
  init_scripts=${init_scripts:-y}
  if [[ "$init_scripts" == "y" || "$init_scripts" == "Y" ]]; then
    cat <<'EOF' > "$SCRIPTS_DIR/ip风险度.js"
async function operator(proxies, targetPlatform, context) {
    const $ = $substore;
    const cacheEnabled = $arguments.cache;
    const cache = scriptResourceCache;

    // 配置参数
    const CONFIG = {
        TIMEOUT: parseInt($arguments.timeout) || 10000,
        RETRIES: parseInt($arguments.retries) || 3,
        RETRY_DELAY: parseInt($arguments.retry_delay) || 2000,
        CONCURRENCY: parseInt($arguments.concurrency) || 10
    };

    const ipListAPIs = [
        'https://raw.githubusercontent.com/X4BNet/lists_vpn/main/output/datacenter/ipv4.txt',
        'https://raw.githubusercontent.com/X4BNet/lists_vpn/main/output/vpn/ipv4.txt',
        'https://check.torproject.org/exit-addresses',
        'https://www.dan.me.uk/torlist/',
        'https://raw.githubusercontent.com/jhassine/server-ip-addresses/refs/heads/master/data/datacenters.txt'
    ];

    let riskyIPs = new Set();
    const cacheKey = 'risky_ips_cache';
    const cacheExpiry = 6 * 60 * 60 * 1000; // 缩短缓存时间到 6 小时

    // 尝试使用缓存
    if (cacheEnabled) {
        const cachedData = cache.get(cacheKey);
        if (cachedData?.timestamp && (Date.now() - cachedData.timestamp < cacheExpiry)) {
            riskyIPs = new Set(cachedData.ips);
            $.info(' 使用缓存数据 ');
            return await processProxies();
        }
    }

    let initialLoadSuccess = false; // 标记首次加载是否成功

    // 获取风险 IP 列表
    async function fetchIPList(api) {
        const options = {
            url: api,
            timeout: CONFIG.TIMEOUT,
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            }
        };

        let retries = 0;
        while (retries < CONFIG.RETRIES) {
            try {
                const response = await $.http.get(options);
                if (response.body) {
                    // 特殊处理 TOR 列表
                    if (api.includes('torproject.org/exit-addresses')) {
                        return response.body.split('\n')
                            .filter(line => line.startsWith('ExitAddress'))
                            .map(line => line.split(' ')[1])
                            .filter(Boolean);
                    } else if (api.includes('dan.me.uk/torlist/')) {
                        return response.body.split('\n')
                            .map(line => line.trim())
                            .filter(line => line && /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(line));
                    }
                    return response.body
                        .split('\n')
                        .map(line => line.trim())
                        .filter(line => line && !line.startsWith('#'));
                }
                return;
            } catch (error) {
                retries++;
                $.error(`获取 IP 列表失败 (尝试 ${retries}/${CONFIG.RETRIES}): ${api}, ${error}`);
                if (retries === CONFIG.RETRIES) {
                    return;
                }
                await $.wait(CONFIG.RETRY_DELAY * retries);
            }
        }
        return;
    }

    // 更新风险 IP 列表
    try {
        const results = await Promise.all(ipListAPIs.map(api => fetchIPList(api)));
        const fetchedIPs = results.flat();
        if (fetchedIPs.length > 0) {
            riskyIPs = new Set(fetchedIPs);
            $.info(`成功更新风险 IP 列表: ${riskyIPs.size} 条记录`);
            initialLoadSuccess = true;
            if (cacheEnabled) {
                cache.set(cacheKey, {
                    timestamp: Date.now(),
                    ips: Array.from(riskyIPs)
                });
            }
        } else {
            $.warn(' 未获取到任何 IP 数据 ');
        }
    } catch (error) {
        $.error(`更新风险 IP 列表失败: ${error}`);
    } finally {
        if (!initialLoadSuccess && cacheEnabled && !cache.get(cacheKey)?.ips) {
            $.warn(' 首次加载 IP 列表失败且没有可用缓存，可能无法进行风险 IP 检测。');
        } else if (!initialLoadSuccess && !cacheEnabled) {
            $.warn(' 首次加载 IP 列表失败且未启用缓存，可能无法进行风险 IP 检测。');
        }
    }

    return await processProxies();

    // 处理代理列表并筛除风险 IP
    async function processProxies() {
        const nonRiskyProxies = [];
        for (const proxy of proxies) {
            try {
                const node = ProxyUtils.produce([{ ...proxy }], 'ClashMeta', 'internal')?.[0];
                if (node) {
                    const serverAddress = node.server;
                    if (isIPAddress(serverAddress) && isRiskyIP(serverAddress)) {
                        $.info(`发现风险 IP 节点，已排除: ${proxy.name} (${serverAddress})`);
                    } else {
                        nonRiskyProxies.push(proxy);
                    }
                } else {
                    nonRiskyProxies.push(proxy);
                    $.warn(`处理节点失败，已保留: ${proxy.name}`);
                }
            } catch (e) {
                $.error(`处理节点失败，已保留: ${proxy.name}, 错误: ${e}`);
                nonRiskyProxies.push(proxy);
            }
        }
        $.info(`处理完成，剩余 ${nonRiskyProxies.length} 个非风险 IP 节点`);
        return nonRiskyProxies;
    }

    function isIPAddress(ip) {
        return /^(\d{1,3}\.){3}\d{1,3}$/.test(ip);
    }

    function isRiskyIP(ip) {
        if (riskyIPs.has(ip)) return true;
        for (const riskyCIDR of riskyIPs) {
            if (riskyCIDR.includes('/') && isIPInCIDR(ip, riskyCIDR)) return true;
        }
        return false;
    }

    function isIPInCIDR(ip, cidr) {
        const [range, bits = 32] = cidr.split('/');
        const mask = ~((1 << (32 - bits)) - 1);
        const ipNum = ip.split('.').reduce((sum, part) => (sum << 8) + parseInt(part, 10), 0);
        const rangeNum = range.split('.').reduce((sum, part) => (sum << 8) + parseInt(part, 10), 0);
        return (ipNum & mask) === (rangeNum & mask);
    }
}
EOF
    chmod +x "$SCRIPTS_DIR/ip风险度.js"
    log "INFO" "已初始化示例脚本: $SCRIPTS_DIR/ip风险度.js"
  fi
}

# 部署 Sub-Store
install_substore() {
  prompt_for_version

  log "INFO" "正在拉取镜像 xream/sub-store:$SUB_STORE_VERSION..."
  docker pull "xream/sub-store:$SUB_STORE_VERSION"

  # 提示用户选择网络模式
  while true; do
    read -p "请选择网络模式 (bridge 或 host) [默认: bridge]: " network_mode
    network_mode=${network_mode:-bridge}
    if [[ "$network_mode" == "bridge" || "$network_mode" == "host" ]]; then
      NETWORK_MODE="$network_mode"
      break
    else
      log "WARN" "无效的网络模式，请重新输入"
    fi
  done

  # 提示用户输入路径
  prompt_for_path

  log "INFO" "正在启动容器，网络模式: $NETWORK_MODE"
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker run -d \
      --network host \
      --name $CONTAINER_NAME \
      --restart=always \
      -v "${DATA_DIR}:/opt/app/data" \
      -v "${SCRIPTS_DIR}:/opt/app/scripts" \
      -e TZ=${TIMEZONE} \
      -e SUB_STORE_FRONTEND_BACKEND_PATH=${SUB_STORE_FRONTEND_BACKEND_PATH} \
      "xream/sub-store:$SUB_STORE_VERSION" || {
        log "ERROR" "容器启动失败"
        exit 1
      }
  else
    log "INFO" "提示用户自定义端口..."
    HOST_PORT_1=$(prompt_for_port "请输入前端端口 (Web UI)" $DEFAULT_FRONTEND_PORT)
    HOST_PORT_2=$(prompt_for_port "请输入后端端口" $DEFAULT_BACKEND_PORT)

    docker run -d \
      --name $CONTAINER_NAME \
      --restart=always \
      -p $HOST_PORT_1:3000 \
      -p $HOST_PORT_2:3001 \
      -v "${DATA_DIR}:/opt/app/data" \
      -v "${SCRIPTS_DIR}:/opt/app/scripts" \
      -e TZ=${TIMEZONE} \
      -e SUB_STORE_FRONTEND_BACKEND_PATH=${SUB_STORE_FRONTEND_BACKEND_PATH} \
      "xream/sub-store:$SUB_STORE_VERSION" || {
        log "ERROR" "容器启动失败"
        exit 1
      }
  fi

  log "INFO" "Sub-Store 容器启动成功"
}

# 查看所有容器状态
check_all_containers_status() {
  log "INFO" "正在检查所有容器状态..."
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# 增强版卸载容器
uninstall_container() {
  local container_name=$1
  local image_name=$2

  if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    log "INFO" "正在卸载容器 $container_name..."
    docker stop $container_name
    docker rm $container_name
    log "INFO" "容器 $container_name 已停止并移除"

    # 询问是否删除镜像
    read -p "是否删除镜像 $image_name? (y/n) [默认: n]: " remove_image
    remove_image=${remove_image:-n}
    if [[ "$remove_image" == "y" || "$remove_image" == "Y" ]]; then
      docker rmi $image_name
      log "INFO" "镜像 $image_name 已删除"
    fi

    # 询问是否清理卷
    read -p "是否清理相关数据卷 $DATA_DIR? (y/n) [默认: n]: " remove_volume
    remove_volume=${remove_volume:-n}
    if [[ "$remove_volume" == "y" || "$remove_volume" == "Y" ]] && [ "$container_name" == "$CONTAINER_NAME" ]; then
      rm -rf "$DATA_DIR"
      log "INFO" "数据卷 $DATA_DIR 已清理"
    fi
  else
    log "WARN" "容器 $container_name 未运行，跳过卸载"
  fi
}

# 数据备份
backup_data() {
  if [ -d "$DATA_DIR" ]; then
    log "INFO" "正在备份数据..."
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/backup_$TIMESTAMP.tar.gz"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$BACKUP_FILE" -C "$DATA_DIR" .
    log "INFO" "数据已备份到: $BACKUP_FILE"
  else
    log "WARN" "未找到数据目录，跳过备份"
  fi
}

# 数据恢复
restore_data() {
  local latest_backup=$(ls -t $BACKUP_DIR/*.tar.gz 2>/dev/null | head -n 1)
  if [ -z "$latest_backup" ]; then
    log "WARN" "未找到备份文件，跳过恢复"
    return
  fi

  log "INFO" "正在恢复数据..."
  mkdir -p "$DATA_DIR"
  tar -xzf "$latest_backup" -C "$DATA_DIR"
  log "INFO" "数据已从 $latest_backup 恢复"
}

# 交互式菜单
interactive_menu() {
  while true; do
    echo -e "\n选择操作："
    echo "1. 部署 Sub-Store"
    echo "2. 部署 Watchtower"
    echo "3. 查看所有容器状态"
    echo "4. 卸载容器（Sub-Store 或 Watchtower）"
    echo "5. 数据备份"
    echo "6. 数据恢复"
    echo "7. 退出"
    read -p "请输入选项编号: " choice

    case $choice in
      1)
        create_directories
        initialize_example_scripts
        install_substore
        ;;
      2) install_watchtower ;;
      3) check_all_containers_status ;;
      4)
        echo -e "选择卸载的容器："
        echo "1. Sub-Store"
        echo "2. Watchtower"
        read -p "请输入选项编号: " uninstall_choice
        case $uninstall_choice in
          1) uninstall_container $CONTAINER_NAME "xream/sub-store:$SUB_STORE_VERSION" ;;
          2) uninstall_container $WATCHTOWER_CONTAINER_NAME $WATCHTOWER_IMAGE_NAME ;;
          *) log "WARN" "无效输入，返回主菜单" ;;
        esac
        ;;
      5) backup_data ;;
      6) restore_data ;;
      7)
        log "INFO" "退出脚本"
        exit 0
        ;;
      *)
        log "WARN" "无效输入，请重新选择"
        ;;
    esac
  done
}

# 主流程
main() {
  create_directories
  detect_system
  install_dependencies
  interactive_menu
}

# 执行入口
main "$@"
