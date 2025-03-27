#!/bin/sh
set -e

# 检查 sing-box 是否存在
check_singbox() {
  if command -v sing-box > /dev/null 2>&1; then
    echo "✅ sing-box 已安装，版本号：$(sing-box version)"
    return 0
  else
    echo "⚠️ sing-box 未安装！"
    return 1
  fi
}

# 询问用户是否继续
ask_continue() {
  echo "是否继续？（回车继续，输入 'exit' 退出）"
  read user_input
  if [ "$user_input" = "exit" ]; then
    echo "脚本已退出。"
    exit 1
  else
    echo "继续执行..."
  fi
}

# 安装依赖
install_dependencies() {
  echo "正在安装 kmod-inet-diag kmod-netlink-diag kmod-tun iptables-nft..."

  # 检查并安装 kmod-nft-compat
  if ! opkg list-installed | grep -q "kmod-nft-compat"; then
    echo "正在安装 kmod-nft-compat..."
    if ! opkg install kmod-nft-compat; then
      echo "⚠️ kmod-nft-compat 安装失败！"
      ask_continue
    fi
  fi

  # 安装其他依赖
  for package in kmod-inet-diag kmod-netlink-diag kmod-tun iptables-nft; do
    if ! opkg install $package; then
      echo "⚠️ $package 安装失败！"
      ask_continue
    fi
  done
}

# 安装 sing-box
install_singbox() {
  echo "正在安装 sing-box..."
  if ! opkg install sing-box; then
    echo "⚠️ sing-box 安装失败！尝试手动下载..."

    # 手动下载并安装 sing-box
    wget https://github.com/SagerNet/sing-box/releases/download/v1.11.4/sing-box-1.11.4-android-arm64.tar.gz
    tar -zxvf sing-box-1.11.4-android-arm64.tar.gz
    mv sing-box /usr/bin/
    chmod +x /usr/bin/sing-box
    rm -rf sing-box-1.11.4-android-arm64.tar.gz sing-box

    # 检查是否安装成功
    if check_singbox; then
      echo "✅ sing-box 手动安装成功！"
    else
      echo "❌ sing-box 手动安装失败！"
      ask_continue
    fi
  fi
}

# 安装 sing-box 环境
install_singbox_environment() {
  echo "正在安装依赖..."

  # 检查 opkg update 是否成功
  if ! opkg update; then
    echo "⚠️ opkg update 失败！"
    ask_continue
  fi

  # 安装依赖
  install_dependencies

  # 安装 sing-box
  install_singbox

  # 配置防火墙
  echo "正在配置防火墙..."
  cat <<EOF >> /etc/config/firewall
config nat
        option name 'MASQUERADE'
        option src 'lan'
        option target 'MASQUERADE'
        option proto 'all'

config zone
        option name 'proxy'
        option forward 'REJECT'
        option output 'ACCEPT'
        option input 'ACCEPT'
        option mtu_fix '1'
        option device 'tun0'
        list network 'proxy'

config forwarding
        option name 'lan-proxy'
        option dest 'proxy'
        option src 'lan'
EOF

  # 配置网络
  echo "正在配置网络..."
  cat <<EOF >> /etc/config/network
config interface 'proxy'
        option proto 'none'
        option device 'tun0'
EOF

  # 重启网络和防火墙
  echo "正在重启网络和防火墙..."
  /etc/init.d/network restart
  /etc/init.d/firewall restart

  # 生成 sing-box 配置文件
  echo "正在生成 sing-box 配置文件..."
  mkdir -p /etc/sing-box

  # 交互式提示用户输入配置链接
  while true; do
    echo "请输入在线配置链接（如果直接回车，将生成最小化配置）："
    read SUBSCRIBE_URL

    if [ -z "$SUBSCRIBE_URL" ]; then
      # 用户未输入链接，生成最小化配置
      cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "mtu": 9000,
      "stack": "gvisor",
      "endpoint_independent_nat": true,
      "sniff": true,
      "sniff_override_destination": true,
      "domain_strategy": "ipv4_only",
      "proxy_protocol": false,
      "proxy_protocol_accept_no_header": false,
      "inet4_address": "172.19.0.1/30"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
      break
    else
      # 下载用户提供的配置
      echo "正在从 $SUBSCRIBE_URL 下载配置..."
      if curl -sSf -o /tmp/singbox_config.json "$SUBSCRIBE_URL"; then
        # 验证配置文件格式
        if jq empty /tmp/singbox_config.json 2>/dev/null; then
          cp /tmp/singbox_config.json /etc/sing-box/config.json
          echo "配置文件下载成功并验证有效！"
          break
        else
          echo "配置文件格式无效，请检查链接或重新输入！"
        fi
      else
        echo "下载配置失败，请检查链接或重新输入！"
      fi
    fi
  done

  # 如果下载失败或格式无效，生成最小化配置
  if [ ! -f /etc/sing-box/config.json ]; then
    echo "生成最小化配置文件..."
    cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "mtu": 9000,
      "stack": "gvisor",
      "endpoint_independent_nat": true,
      "sniff": true,
      "sniff_override_destination": true,
      "domain_strategy": "ipv4_only",
      "proxy_protocol": false,
      "proxy_protocol_accept_no_header": false,
      "inet4_address": "172.19.0.1/30"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  fi

  # 设置 sing-box 启动脚本
  echo "正在设置 sing-box 启动脚本..."
  cat <<EOF > /etc/init.d/sing-box
#!/bin/sh /etc/rc.common
#
# Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.
#

START=99
USE_PROCD=1

#####  ONLY CHANGE THIS BLOCK  ######
PROG=/usr/bin/sing-box
RES_DIR=/etc/sing-box/ # resource dir / working dir / the dir where you store ip/domain lists
CONF=./config.json   # where is the config file, it can be a relative path to $RES_DIR
#####  ONLY CHANGE THIS BLOCK  ######

start_service() {
  sleep 10
  procd_open_instance
  procd_set_param command \$PROG run -D \$RES_DIR -c \$CONF

  procd_set_param user root
  procd_set_param limits core="unlimited"
  procd_set_param limits nofile="1000000 1000000"
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param respawn "\${respawn_threshold:-3600}" "\${respawn_timeout:-5}" "\${respawn_retry:-5}"
  procd_close_instance
  iptables -I FORWARD -o tun+ -j ACCEPT
  echo "sing-box is started!"
}

stop_service() {
  service_stop \$PROG
  iptables -D FORWARD -o tun+ -j ACCEPT
  echo "sing-box is stopped!"
}

reload_service() {
  stop
  sleep 5s
  echo "sing-box is restarted!"
  start
}
EOF

  # 赋予执行权限并启动 sing-box
  echo "正在启动 sing-box..."
  chmod +x /etc/init.d/sing-box
  /etc/init.d/sing-box start
  /etc/init.d/sing-box enable

  # 立即运行下载好的配置文件
  echo "立即运行下载好的配置文件..."
  nohup sing-box run -c /etc/sing-box/config.json > /var/log/sing-box.log 2>&1 &

  echo "🎉 sing-box 安装和配置完成！"
}

# 卸载 sing-box 环境
uninstall_singbox() {
  echo "正在卸载 sing-box..."

  # 停止 sing-box 服务
  if [ -f /etc/init.d/sing-box ]; then
    /etc/init.d/sing-box stop
    /etc/init.d/sing-box disable
    rm -f /etc/init.d/sing-box
  fi

  # 删除 sing-box 配置文件
  if [ -d /etc/sing-box ]; then
    rm -rf /etc/sing-box
  fi

  # 清理防火墙规则（仅删除与 sing-box 相关的规则）
  if [ -f /etc/config/firewall ]; then
    # 删除与 sing-box 相关的 zone 规则
    sed -i "/option name 'proxy'/d" /etc/config/firewall
    sed -i "/list network 'proxy'/d" /etc/config/firewall

    # 删除与 sing-box 相关的 forwarding 规则
    sed -i "/option name 'lan-proxy'/d" /etc/config/firewall

    # 删除与 sing-box 相关的 NAT 规则
    sed -i "/option name 'MASQUERADE'/d" /etc/config/firewall

    # 重启防火墙
    /etc/init.d/firewall restart
  fi

  # 清理网络接口（仅删除与 sing-box 相关的接口）
  if [ -f /etc/config/network ]; then
    # 删除与 sing-box 相关的 proxy 接口
    sed -i "/config interface 'proxy'/d" /etc/config/network

    # 重启网络
    /etc/init.d/network restart
  fi

  # 卸载 sing-box（不强制删除依赖）
  if opkg list-installed | grep -q "sing-box"; then
    opkg remove sing-box
  fi

  echo "✅ sing-box 已卸载并清理完成！"
}

# 交互式菜单
while true; do
  echo "请选择操作："
  echo "1. 一键安装 sing-box 环境"
  echo "2. 一键卸载清理 sing-box 环境"
  echo "3. 退出"
  read -p "请输入数字选择：" choice

  case $choice in
    1)
      install_singbox_environment
      ;;
    2)
      uninstall_singbox
      ;;
    3)
      echo "退出脚本。"
      exit 0
      ;;
    *)
      echo "无效选择，请重新输入！"
      ;;
  esac
done
