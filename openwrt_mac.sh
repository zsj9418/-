#!/bin/bash

# 生成随机MAC地址（符合局部地址范围）
generate_mac() {
  hexchars="0123456789ABCDEF"
  echo "72:3D:E5:$(for i in {1..2}; do echo -n ${hexchars:$((RANDOM%16)):1}${hexchars:$((RANDOM%16)):1}:; done | sed 's/:$//')"
}

# 用户选择：自定义或自动
echo "请选择操作："
echo "1) 输入自定义MAC地址（直接按回车使用默认MAC）"
echo "2) 自动生成MAC地址"
read -p "请输入选项（1或2）: " choice

case "$choice" in
  1)
    # 提示用户输入MAC，未输入则使用默认
    read -p "请输入MAC地址（格式例如：72:3D:E5:25:E0:DD），直接按回车使用默认： " user_mac
    if [[ -z "$user_mac" ]]; then
      # 用户未输入，使用默认
      mac_address="72:3D:E5:25:E0:DD"
      echo "未输入，使用默认MAC地址：$mac_address"
    else
      # 简单验证MAC格式
      if [[ ! "$user_mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        echo "无效的MAC地址格式！脚本退出。"
        exit 1
      fi
      mac_address="$user_mac"
    fi
    ;;
  2)
    mac_address=$(generate_mac)
    echo "自动生成的MAC地址为：$mac_address"
    ;;
  *)
    echo "无效的选项！脚本退出。"
    exit 1
    ;;
esac

# 生成OpenWRT启动脚本
cat <<EOF > /etc/init.d/set_mac
#!/bin/sh /etc/rc.common

START=99

start() {
    ifconfig br-lan down
    ifconfig br-lan hw ether $mac_address
    ifconfig br-lan up
    logger "br-lan MAC地址已固定为 $mac_address"
}
EOF

# 赋予权限并启用
chmod +x /etc/init.d/set_mac
/etc/init.d/set_mac enable

# 提示用户
echo "脚本已部署并启用。请重启设备以应用更改。"
