#!/bin/bash

# 脚本保存目录和文件路径
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="dae_manager.sh"
CONFIG_FILE="/etc/dae/config.dae"
LOG_FILE="/var/log/dae.log"
LOG_SIZE_LIMIT=$((1 * 1024 * 1024)) # 1MB
ENV_FILE="$HOME/.dae_env"
DOCKER_CONFIG_DIR="/etc/dae"

# 全局变量
ARCH_TYPE=""
LAN_IFACE_DETECTED=""
WAN_IFACE_DETECTED=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 基础核心组件 ====================

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[错误] 请以 root 权限运行此脚本（或使用 sudo %0）${NC}"
        exit 1
    fi
}

# 加载环境变量
load_env() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi
}

# 保存环境变量
save_env() {
    local key=$1
    local value=$2
    if [ ! -f "$ENV_FILE" ]; then
        touch "$ENV_FILE"
        chmod 0600 "$ENV_FILE"
    fi
    if grep -q "^$key=" "$ENV_FILE"; then
        sed -i "s|^$key=.*|$key=\"$value\"|" "$ENV_FILE"
    else
        echo "$key=\"$value\"" >> "$ENV_FILE"
    fi
}

# 检查日志大小并清空防爆盘
check_log_size() {
    if [ -f "$LOG_FILE" ]; then
        LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$LOG_SIZE" -gt "$LOG_SIZE_LIMIT" ]; then
            echo -e "${YELLOW}[系统] 日志文件超过1MB，正在自动轮转清空...${NC}"
            > "$LOG_FILE"
        fi
    fi
}

# 清理残留网络资源以避免 eBPF 挂载冲突
clean_network_resources() {
    echo -e "${YELLOW}[清理] 正在排查并清理现有网络挂载资源以防冲突...${NC}"
    ip rule del fwmark 114514 2>/dev/null
    ip route flush table 114514 2>/dev/null
    ip link delete dae 2>/dev/null
    
    # 终止可能挂滞的裸进程
    if pgrep -f "/usr/bin/dae" >/dev/null; then
        echo -e "${YELLOW}[清理] 检测到残留 dae 后台进程，正在强制终止...${NC}"
        pkill -9 -f "/usr/bin/dae"
    fi
}

# ==================== 环境智能体检模块 ====================

# 检查是否在容器环境中（防报错）
check_container() {
    if [ -f /.dockerenv ] || grep -qE 'docker|lxc|kubepods' /proc/1/cgroup; then
        return 1
    fi
    return 0
}

# 深度检查 eBPF 内核支持
check_ebpf_support() {
    echo -e "${BLUE}[体检] 正在诊断系统底层内核 eBPF 支持特征...${NC}"
    
    # 提取内核版本号
    KERNEL_VER=$(uname -r)
    MAIN_VER=$(echo "$KERNEL_VER" | cut -d. -f1)
    SUB_VER=$(echo "$KERNEL_VER" | cut -d. -f2)
    
    echo -e "${CYAN}- 当前系统内核版本: $KERNEL_VER${NC}"
    
    # 内核版本软性校验
    if [ "$MAIN_VER" -lt 5 ] || { [ "$MAIN_VER" -eq 5 ] && [ "$SUB_VER" -lt 17 ]; }; then
        echo -e "${RED}[警告] 您的系统内核低于 dae 官方推荐的最低底线 5.17！${NC}"
        echo -e "${YELLOW}（强烈推荐使用 OpenWrt 24.10/25.12 的 6.6 或 6.12 固件）${NC}"
        echo -e "是否仍要强行安装继续冒险？(y/n, 默认n): "
        read -r force_kernel
        if [[ "$force_kernel" != "y" && "$force_kernel" != "Y" ]]; then
            echo -e "${RED}[终止] 请升级系统固件后再试。${NC}"
            exit 1
        fi
    fi

    # 物理支撑特征检测
    if [ -f /sys/kernel/debug/tracing/events/bpf ] || command -v bpftool >/dev/null 2>&1; then
        echo -e "${GREEN}[支持] 恭喜，检测到完备的 BPF 跟踪器节点。${NC}"
        return 0
    elif grep -q "CONFIG_BPF=y" /boot/config-$(uname -r) 2>/dev/null; then
        echo -e "${GREEN}[支持] 检测到编译内核中已静态打入 CONFIG_BPF。${NC}"
        return 0
    else
        echo -e "${RED}[报错] 主机内核缺乏完整 eBPF 指令集映射(CONFIG_BPF缺失)！${NC}"
        echo -e "${YELLOW}大鹅代理强依赖内核。建议强行下一步，若无法启动请更换支持 eBPF 的固件。${NC}"
        echo -e "回车键确认已知晓该风险..."
        read -r
        return 0
    fi
}

# 智能网卡接口嗅探器 (杜绝小白忘记选Lan口导致断网的宇宙级痛点)
smart_interface_sniffer() {
    echo -e "${BLUE}[嗅探] 正在分析本地网络拓扑接口，请勿选错...${NC}"
    
    # 获取所有的物理/非虚拟接口
    ALL_INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-|dae|gretun|sit|tun')
    
    echo -e "${YELLOW}--- 发现的局域网卡候选接口列表 ---${NC}"
    IFS=$'\n' read -rd '' -a iface_list <<< "$ALL_INTERFACES"
    
    for i in "${!iface_list[@]}"; do
        # 尝试读取接口IP
        IFACE_IP=$(ip -4 addr show "${iface_list[$i]}" 2>/dev/null | grep -oP '(?<=inet )\d+(\.\d+){3}')
        echo -e "$((i+1))) 网卡名称: ${GREEN}${iface_list[$i]}${NC} [当前IP: ${CYAN}${IFACE_IP:-未分配}${NC}]"
    done
    
    echo -e "${YELLOW}请输入数字选择您要接管走代理的局域网接口 (LAN口):${NC}"
    echo -e "${CYAN}(小白提示：若分不清，或有多网口需合并走代理，直接敲回车将全选接管，确保生效！)${NC}"
    read -r user_iface_choice
    
    if [ -z "$user_iface_choice" ]; then
        # 盲选策略：将所有有效接口打包塞入
        LAN_IFACE_DETECTED=$(echo "$ALL_INTERFACES" | paste -sd, - | sed 's/,/", "/g')
        LAN_IFACE_DETECTED="\"$LAN_IFACE_DETECTED\""
        echo -e "${GREEN}[全能绑定] 脚本已采用广撒网策略，绑定全部物理网口。${NC}"
    else
        idx=$((user_iface_choice-1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#iface_list[@]}" ]; then
            LAN_IFACE_DETECTED="\"${iface_list[$idx]}\""
            echo -e "${GREEN}[精准绑定] 已锁定局域网接管接口: $LAN_IFACE_DETECTED${NC}"
        else
            LAN_IFACE_DETECTED="\"eth1\""
            echo -e "${RED}[选择有误] 输入数字越界，脚本已为您自动 fallback 缺省选用 \"eth1\"。${NC}"
        fi
    fi
    
    # 自动探测 WAN 接口类型
    WAN_IFACE_DETECTED="auto"
}

# 初始化安装宿主依赖
check_system() {
    if [ -f "/etc/dae/.setup_done" ]; then
        # 提取之前算好的架构
        ARCH=$(uname -m)
        case $ARCH in
            x86_64) ARCH_TYPE="amd64" ;;
            aarch64) ARCH_TYPE="arm64" ;;
        esac
        return 0
    fi
    
    echo -e "${YELLOW}[环境] 正在进行大鹅初始化套件安装...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_TYPE="amd64" ;;
        aarch64) ARCH_TYPE="arm64" ;;
        *) echo -e "${RED}[致命] 暂不支持此硬件架构: $ARCH${NC}"; exit 1 ;;
    esac

    if [ -f /etc/debian_version ]; then
        OS="debian"
        PKG_MANAGER="apt"
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        PKG_MANAGER="yum"
    else
        echo -e "${RED}[致命] 当前仅支持 Debian/Ubuntu 或 CentOS 衍生版软路由系统${NC}"
        exit 1
    fi

    echo -e "${BLUE}[系统] 正在拉取底层缺失的动态组件: wget, curl, unzip, iproute2...${NC}"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt update -y && apt install -y wget curl unzip nano iproute2 bc sed >/dev/null 2>&1
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum install -y wget curl unzip nano iproute2 bc sed >/dev/null 2>&1
    fi
    
    mkdir -p /etc/dae
    touch /etc/dae/.setup_done
}

# 检查Docker
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}[Docker] 宿主机未检测到 Docker，尝试极速一键安装中...${NC}"
        if [ -f /etc/debian_version ]; then
            apt update -y && apt install -y docker.io >/dev/null 2>&1 || return 1
        elif [ -f /etc/redhat-release ]; then
            yum install -y docker >/dev/null 2>&1 || return 1
        fi
        systemctl start docker
        systemctl enable docker
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}[Docker] 引擎自动拉取失败，请手动部署 Docker 后重试方案6。${NC}"
        return 1
    fi
    return 0
}

# ==================== 自动化通知扩展 (企业微信) ====================

send_wechat_notification() {
    load_env
    if [ -z "$WECHAT_WEBHOOK" ]; then
        echo -e "${YELLOW}[通知] 未配置微信Webhook。跳过推送。可以在主菜单按2进行补齐。${NC}"
        return 0
    fi
    
    local msg=$1
    echo -e "${BLUE}[通知] 正在向企业微信发送即时运维报告...${NC}"
    
    curl -s -X POST "$WECHAT_WEBHOOK" \
       -H 'Content-Type: application/json' \
       -d "{
            \"msgtype\": \"text\",
            \"text\": {
                \"content\": \"【大鹅云助手】运维状态更新\n报告时间：$(date '+%Y-%m-%d %H:%M:%S')\n事件详情：$msg\"
            }
       }" >/dev/null
}

# ==================== 核心配置逻辑 ====================

# 配置或修改订阅
set_subscription() {
    load_env
    if [ -n "$SUB_URL" ]; then
        echo -e "${GREEN}[现有配置] 已存在老旧订阅地址: $SUB_URL${NC}"
        echo -e "是否沿用当前地址？(y/n, 默认y): "
        read -r use_existing
        if [ "$use_existing" = "n" ] || [ "$use_existing" = "N" ]; then
            SUB_URL=""
        fi
    fi

    while [ -z "$SUB_URL" ]; do
        echo -e "${YELLOW}================================================================${NC}"
        echo -e "${PURPLE}【重要提示】大鹅属于扁平透明代理，其解析器只认识如下三种通用的原始扁平格式：${NC}"
        echo -e "1. 以 ss://, vless://, trojan:// 开头的通用单个链接"
        echo -e "2. 机场直接提供的通用全平台节点在线明文/Base64文本流地址"
        echo -e "${RED}✘ 注意：机场给的普通 Clash 订阅(.yaml结尾)不可直接粘贴！${NC}"
        echo -e "${CYAN}💡 解决办法：使用公开解析网站（如 sub.w1.gq）将您的 Clash 转换为通用节点链接！${NC}"
        echo -e "${YELLOW}================================================================${NC}"
        echo -e "请输入经过妥协或转换后的【标准通用订阅URL】： "
        read -r input_url
        if [ -z "$input_url" ]; then
            echo -e "${RED}[有误] 输入不合法，不允许为空。${NC}"
        else
            SUB_URL="$input_url"
            save_env "SUB_URL" "$SUB_URL"
            break
        fi
    done

    # 询问配置企业微信 Webhook
    echo -e "${YELLOW}是否配置/覆盖企业微信运维推送机器人通知地址？ (y/n, 直接回车跳过):${NC}"
    read -r setup_wx
    if [[ "$setup_wx" == "y" || "$setup_wx" == "Y" ]]; then
        echo -e "请粘贴您的企业微信群机器人 Webhook 完整 URL: "
        read -r input_wx
        if [ -n "$input_wx" ]; then
            WECHAT_WEBHOOK="$input_wx"
            save_env "WECHAT_WEBHOOK" "$WECHAT_WEBHOOK"
        fi
    fi

    # 更新配置文件
    if [ -f "$CONFIG_FILE" ]; then
        # 基于规则块进行精准重洗替换
        sed -i '/subscription {/,/}/c\subscription {\n    "'"$SUB_URL"'"\n}' "$CONFIG_FILE"
        chmod 0600 "$CONFIG_FILE"
        echo -e "${GREEN}[完成] 订阅文件已全覆盖刷新！${NC}"
        
        # 判断服务是否在运行，若在运行则优雅触发冷重启加载
        if systemctl is-active dae >/dev/null 2>&1; then
            echo -e "${YELLOW}[联动] 发现大鹅服务正在活跃，正在拉起最新订阅节点组...${NC}"
            systemctl restart dae
        fi
        send_wechat_notification "成功在非Docker原生环境更新了配置订阅源，网元节点正在刷新同步。"
    else
        echo -e "${RED}[断层] 配置文件 $CONFIG_FILE 离奇失踪，请先按 1 走一次全盘安装！${NC}"
        return 1
    fi
}

# ==================== 选项 1：原生模式安装 ====================

install_dae() {
    if ! check_container; then
        echo -e "${RED}[冲突] 宿主机本身已处于容器内，禁止套娃安装原始大鹅！${NC}"
        echo -e "${YELLOW}请退出当前容器至外层，或直接退回主菜单选选项 6 以 Docker 承载。${NC}"
        return 1
    fi
    
    # 触发核心硬件环境体检
    check_ebpf_support || return 1
    smart_interface_sniffer

    echo -e "${YELLOW}[部署] 正在全盘刮除旧大鹅代理文件防冲突残留...${NC}"
    systemctl stop dae >/dev/null 2>&1
    systemctl disable dae >/dev/null 2>&1
    rm -rf /usr/bin/dae /etc/dae/config.dae /etc/systemd/system/dae.service /var/run/dae.pid
    systemctl daemon-reload

    # 组装下载地址
    DAE_URL="https://github.com/daeuniverse/dae/releases/download/v0.9.0/dae-linux-${ARCH_TYPE}.zip"

    echo -e "${BLUE}[拉取] 正在从官方云端下载核心二进制包 v0.9.0 ...${NC}"
    wget -O /tmp/dae.zip "$DAE_URL" || {
        echo -e "${RED}[死锁] 链接超时！可能本地网络阻断，请挂物理梯子再行下载。${NC}"
        return 1
    }
    
    mkdir -p /tmp/dae_unzip
    unzip -o /tmp/dae.zip -d /tmp/dae_unzip || {
        echo -e "${RED}[损毁] 解压失败，下载的包不完整。${NC}"
        return 1
    }

    # 智能识别解压结果
    if [ -f /tmp/dae_unzip/dae-linux-"$ARCH_TYPE" ]; then
        mv /tmp/dae_unzip/dae-linux-"$ARCH_TYPE" /usr/bin/dae
    elif [ -f /tmp/dae_unzip/dae ]; then
        mv /tmp/dae_unzip/dae /usr/bin/dae
    else
        echo -e "${RED}[断裂] 解压包中未检索到大鹅标准二进制。${NC}"
        return 1
    fi

    chmod +x /usr/bin/dae
    mkdir -p /etc/dae

    # 分流包兜底补充
    echo -e "${BLUE}[路由] 正在注入大鹅官方分流数据库（GeoIP / GeoSite）...${NC}"
    wget -O /etc/dae/geoip.dat https://github.com/v2rayA/dist-v2ray-rules-dat/raw/master/geoip.dat || {
        echo -e "${YELLOW}[绕行] 规则数据库连通失败，启用脚本内部静态 fallback${NC}"
    }
    wget -O /etc/dae/geosite.dat https://github.com/v2rayA/dist-v2ray-rules-dat/raw/master/geosite.dat || {
        echo -e "${YELLOW}[绕行] 规则数据库连通失败，启用脚本内部静态 fallback${NC}"
    }

    # 一键打入最通透、对小白最友好的带有精细化流媒体、AI分流的配置单
    echo -e "${BLUE}[配置] 正在为你量身定制精细化内核分流控制矩阵...${NC}"
    cat <<EOF > "$CONFIG_FILE"
global {
    lan_interface: [$LAN_IFACE_DETECTED]
    wan_interface: $WAN_IFACE_DETECTED
    log_level: info
    allow_insecure: false
    auto_config_kernel_parameter: true
}

subscription {
}

group {
    proxy {
        # 自动探测时段最低平均延迟，稳定不掉线
        policy: min_moving_avg
    }
    # 特调的高级流媒体与AI定向特定分组块
    ai_media {
        policy: min_moving_avg
    }
}

routing {
    # 确保国境内、内网资源完美100%全速直连，不绕路
    dip(geoip:private) -> direct
    dip(geoip:cn) -> direct
    domain(geosite:cn) -> direct
    
    # 针对小白最易卡死的海外AI工具，实现物理侧精准切流保护
    domain(keyword: 'openai', keyword: 'chatgpt') -> ai_media
    domain(keyword: 'gemini', keyword: 'generativelanguage') -> ai_media
    domain(keyword: 'anthropic', keyword: 'claude') -> ai_media
    domain(keyword: 'netflix', keyword: 'youtube') -> ai_media

    # 其余海外未知流量全局交由主代理池进行透明中转
    fallback: proxy
}
EOF
    chmod 0600 "$CONFIG_FILE"

    # 生成标准 Systemd 服务单元
    cat <<EOF > /etc/systemd/system/dae.service
[Unit]
Description=dae Advanced Dashboard Service
Documentation=https://github.com/daeuniverse/dae
After=network.target network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/dae run --config /etc/dae/config.dae
Restart=on-failure
RestartSec=5s
PIDFile=/var/run/dae.pid

[Install]
WantedBy=multi-user.target
EOF

    # 联动交互引导配置节点
    echo -e "${GREEN}[大吉] 核心程序就位。现在开始设定您的网络节点。${NC}"
    set_subscription || {
        echo -e "${RED}[突发] 订阅写入故障，后续请按 2 手工补票。${NC}"
    }

    # 复位网络并强起
    clean_network_resources
    systemctl daemon-reload
    systemctl enable dae >/dev/null 2>&1
    systemctl start dae

    if systemctl is-active dae >/dev/null 2>&1; then
        echo -e "${GREEN}======================================================${NC}"
        echo -e "${GREEN}🚀 恭喜！大鹅原生高性能 eBPF 透明代理已经在您的系统完美落地奔跑！${NC}"
        echo -e "${CYAN}💡 您刚刚选定的局域网卡已写入底层。${NC}"
        echo -e "${CYAN}   由于大鹅属于纯底层内核代理，无任何多余开销，测试全局分流请前往浏览器验证。${NC}"
        echo -e "${GREEN}======================================================${NC}"
        send_wechat_notification "大鹅底层服务组件全新安装并成功在宿主机环境点火上线！"
    else
        echo -e "${RED}[阻滞] 进程拉起失败！一般原因为刚才填写的订阅里没有有效节点，或是内核底层不咬合。${NC}"
        echo -e "${YELLOW}请排查日志：journalctl -u dae -n 20${NC}"
    fi

    # 清除临时垃圾
    rm -rf /tmp/dae* 2>/dev/null
}

# ==================== 选项 6：Docker 独立沙盒模式 ====================

install_dae_docker() {
    # 强制内核特征复查
    check_ebpf_support || return 1
    if ! check_docker; then
        return 1
    fi

    echo -e "${RED}⚠️【高能警告】大鹅核心涉及大量的内核态注入。${NC}"
    echo -e "${YELLOW}非极特殊情况，官方极不推荐在容器内执行大鹅。这可能需要消耗特权特控。${NC}"
    echo -e "是否依然一意孤行启动沙盒方案？(y/n, 默认n): "
    read -r continue_docker
    if [[ "$continue_docker" != "y" && "$continue_docker" != "Y" ]]; then
        return 0
    fi

    # 检测落后内核
    KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
    if [ "$(echo "$KERNEL_VERSION < 5.17" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
        echo -e "${RED}[爆雷] 宿主内核版本 ($KERNEL_VERSION) 低于大鹅硬标准5.17，Docker形态几乎必挂！${NC}"
    fi

    echo -e "${YELLOW}请输入要搭建容器的基底镜像（直接回车默认小白推荐的 ubuntu:22.04）:${NC}"
    read -r DOCKER_IMAGE
    DOCKER_IMAGE=${DOCKER_IMAGE:-ubuntu:22.04}

    if docker ps -a | grep -q dae; then
        echo -e "${YELLOW}[Docker] 发现同名老容器，正在物理碾碎...${NC}"
        docker rm -f dae >/dev/null 2>&1
    fi

    echo -e "${BLUE}[Docker] 正在全速同步并拉取大底层镜像 $DOCKER_IMAGE ...${NC}"
    docker pull "$DOCKER_IMAGE" || {
        echo -e "${RED}[死锁] 拉取容器公有云镜像失败，请检查 Docker 国内加速代理源配置！${NC}"
        return 1
    }

    mkdir -p "$DOCKER_CONFIG_DIR"

    # 特殊联动：为 Docker 生成一套适配其桥接环路的专属极简配置
    set_subscription_docker

    echo -e "${BLUE}[Docker] 正在通过特权挂载方式完成内部构件装配...${NC}"
    
    # 动态转换底层宿主指令架构集映射参数
    M_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

    # 临时特权进入，完成全自动静态编译
    docker run --rm --privileged --network=host -v /sys:/sys -v /dev:/dev -v "$DOCKER_CONFIG_DIR:/etc/dae" "$DOCKER_IMAGE" /bin/bash -c "
        apt update -y && apt install -y wget unzip iproute2 >/dev/null 2>&1 &&
        wget -O /tmp/dae.zip https://github.com/daeuniverse/dae/releases/download/v0.9.0/dae-linux-${M_ARCH}.zip &&
        unzip -o /tmp/dae.zip -d /etc/dae &&
        (mv /etc/dae/dae-linux-* /usr/bin/dae 2>/dev/null || mv /etc/dae/dae /usr/bin/dae) &&
        chmod +x /usr/bin/dae &&
        wget -O /etc/dae/geoip.dat https://github.com/v2rayA/dist-v2ray-rules-dat/raw/master/geoip.dat &&
        wget -O /etc/dae/geosite.dat https://github.com/v2rayA/dist-v2ray-rules-dat/raw/master/geosite.dat
    " || {
        echo -e "${RED}[致命] 容器编译管道断裂，特权注入被宿主系统内核安全防护拦截。${NC}"
        return 1
    }

    # 提示运行指令
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}[通畅] Docker 预装配完成。准备点火运行！${NC}"
    echo -e "${YELLOW}正在通过 --privileged (特权模式) 以及 --network=host 挂载运行大鹅容器...${NC}"
    
    docker run -d \
        --name dae \
        --restart always \
        --privileged \
        --network=host \
        -v /sys:/sys \
        -v /dev:/dev \
        -v "$DOCKER_CONFIG_DIR:/etc/dae" \
        "$DOCKER_IMAGE" \
        /usr/bin/dae run --config /etc/dae/config.dae

    if [ "$(docker inspect -f '{{.State.Running}}' dae 2>/dev/null)" = "true" ]; then
        echo -e "${GREEN}[点火成功] 容器大鹅已经深度咬合宿主网络成功上线运行！${NC}"
        send_wechat_notification "大鹅代理已在 Docker 沙盒特权形态下成功点火并启动拦截。"
    else
        echo -e "${RED}[熄火] 容器虽然创建，但因内核拒绝提权直接秒退。请执行 'docker logs dae' 查看内幕。${NC}"
    fi
}

# 内部配套：为 Docker 精准配置初始订阅模板
set_subscription_docker() {
    load_env
    if [ -n "$SUB_URL" ]; then
        echo -e "${GREEN}[现有配置] 已存在老旧订阅地址: $SUB_URL${NC}"
        echo -e "是否在 Docker 中沿用此订阅？(y/n, 默认y):"
        read -r use_existing
        if [[ "$use_existing" == "n" || "$use_existing" == "N" ]]; then
            SUB_URL=""
        fi
    fi

    while [ -z "$SUB_URL" ]; do
        echo -e "${YELLOW}请输入用于 Docker 挂载的标准扁平节点订阅 URL:${NC}"
        read -r SUB_URL
        if [ -z "$SUB_URL" ]; then
            echo -e "${RED}输入不能为空${NC}"
        else
            save_env "SUB_URL" "$SUB_URL"
        fi
    done

    # 针对 Docker 共享网络栈，lan_interface 留空使大鹅自动包络宿主网口最为稳妥
    cat <<EOF > "$DOCKER_CONFIG_DIR/config.dae"
global {
    lan_interface: ""
    wan_interface: auto
    log_level: info
    allow_insecure: false
    auto_config_kernel_parameter: true
}

subscription {
    "$SUB_URL"
}

group {
    proxy {
        policy: min_moving_avg
    }
}

routing {
    dip(geoip:private) -> direct
    dip(geoip:cn) -> direct
    domain(geosite:cn) -> direct
    fallback: proxy
}
EOF
    chmod 0600 "$DOCKER_CONFIG_DIR/config.dae"
}

# ==================== 选项 3：全生命周期管理系统 ====================

manage_dae() {
    while true; do
        echo -e "\n${PURPLE}====== 🧭 子控制台：本地原生 dae 状态管理 ======${NC}"
        echo "1) ⚡ 瞬时启动/重载大鹅进程"
        echo "2) 🛑 彻底断开大鹅内核拦截 (停止)"
        echo "3) 🩺 调取 Systemd 原生看板与最近日志"
        echo "4) 🔙 返回主菜单"
        echo -e "${PURPLE}================================================${NC}"
        echo -e "请输入子选项并回车 (1-4): ${NC}"
        read -r sub_choice
        case $sub_choice in
            1)
                clean_network_resources
                systemctl daemon-reload
                if systemctl start dae; then
                    echo -e "${GREEN}[成功] 大鹅已展翅高飞，接管系统网络。${NC}"
                    send_wechat_notification "大鹅透明代理成功触发手动重载启动指令。"
                else
                    echo -e "${RED}[失败] 启动受阻，请按 3 诊断详细日志。${NC}"
                fi
                ;;
            2)
                systemctl stop dae
                clean_network_resources
                echo -e "${GREEN}[歇业] 大鹅已成功收回内核接管，网络已全盘恢复纯净状态。${NC}"
                send_wechat_notification "警告：大鹅透明代理已被人工触发冷关闭，系统已退出底层中转。"
                ;;
            3)
                echo -e "${CYAN}--- 服务实时摘要看板 ---${NC}"
                systemctl status dae --no-pager -l
                echo -e "${CYAN}--- 末尾10条内核中转深度追踪日志 ---${NC}"
                journalctl -u dae --no-pager -n 10
                ;;
            4) break ;;
            *) echo -e "${RED}[误入] 无效子编号，请输入 1-4 之间的数。${NC}" ;;
        esac
    done
}

# ==================== 选项 4：彻底清除残留卸载器 ====================

uninstall_dae() {
    echo -e "${RED}⚠️【高危】这将会完全抹除大鹅所有本土文件及持久化订阅变量数据！${NC}"
    echo -e "确定要这么做吗？(y/n, 默认n):"
    read -r confirm_un
    if [[ "$confirm_un" != "y" && "$confirm_un" != "Y" ]]; then
        return 0
    fi

    echo -e "${YELLOW}[卸载] 正在紧急撤销服务层...${NC}"
    systemctl stop dae >/dev/null 2>&1
    systemctl disable dae >/dev/null 2>&1
    
    clean_network_resources

    echo -e "${YELLOW}[卸载] 正在粉碎本地静态路由依赖文件与缓存...${NC}"
    rm -rf /usr/bin/dae /etc/dae /var/log/dae.log /etc/systemd/system/dae.service "$ENV_FILE"
    systemctl daemon-reload
    
    echo -e "${GREEN}[净空] 卸载圆满完成！无任何注册表和残留文件挂滞。${NC}"
    send_wechat_notification "重要提示：大鹅透明代理套件已被从宿主机上人工彻底清除卸载。"
}

# ==================== 系统服务固化 ====================

save_script() {
    # 自动建立快捷软链接，方便随时直接输入 dae_manager.sh 呼出菜单
    if [ ! -f "$INSTALL_DIR/$SCRIPT_NAME" ]; then
        cp "$0" "$INSTALL_DIR/$SCRIPT_NAME"
        chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
        ln -sf "$INSTALL_DIR/$SCRIPT_NAME" /usr/bin/dae_manager >/dev/null 2>&1
    fi
}

# ==================== 万流归宗：主控制菜单 ====================

main_menu() {
    while true; do
        # 每次返回主菜单前，自动完成一次微型日志检查，防止把空间写爆
        check_log_size
        
        echo -e "\n${GREEN}================================================================${NC}"
        echo -e "${GREEN}      🦢 欢迎使用 dae (大鹅) 高性能 eBPF 透明代理全能部署管家 ${NC}"
        echo -e "${CYAN}        (全面兼容 OpenWrt 24.10/25.12 架构设计与AI特调分流) ${NC}"
        echo -e "${GREEN}================================================================${NC}"
        echo -e " 1) ${GREEN}🚀 一键智能体检并安装 dae（原生高性能推荐模式）${NC}"
        echo -e " 2) 🔗 设置/覆写扁平订阅地址及企业微信联动"
        echo -e " 3) ⚙️ 启动/停止/查看原生大鹅运行状态与核心中转日志"
        echo -e " 4) ❌ 彻底卸载大鹅并干净清洗全部本地残留文件"
        echo -e " 5) 🚪 退出当前自动化运维脚本"
        echo -e " --------------------------------------------------------------"
        echo -e " 6) 📦 ${YELLOW}【沙盒形态】在特权 Docker 独立虚拟化环境中安装配置 dae${NC}"
        echo -e "${GREEN}================================================================${NC}"
        echo -e "请选择操作菜单项并按下回车键 (${YELLOW}1-6${NC}): "
        read -r choice
        
        case $choice in
            1) install_dae ;;
            2) set_subscription ;;
            3) manage_dae ;;
            4) uninstall_dae ;;
            5) echo -e "${GREEN}[退出] 感谢您的使用，祝您愉快！${NC}"; exit 0 ;;
            6) install_dae_docker ;;
            *) echo -e "${RED}[误入] 输入非法，请输入有效数字 1 至 6！${NC}" ;;
        esac
    done
}

# ==================== 自动化流水线触发大入口 ====================
check_root
check_system
save_script
main_menu
