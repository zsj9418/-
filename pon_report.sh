#!/bin/sh

DEV=/dev/sda1
MNT_DEFAULT=/mnt/usb1_1

echo "========== 1. 检查 U 盘 =========="

if [ ! -b "$DEV" ]; then
    echo "失败：没有找到 $DEV。"
    echo "请确认插入的是之前那个 U 盘，等待 10 秒后执行："
    echo "cat /proc/partitions"
    echo "mount"
    exit 1
fi

MNT=""
while read device dir fstype options rest; do
    if [ "$device" = "$DEV" ]; then
        MNT="$dir"
        break
    fi
done < /proc/mounts

if [ -n "$MNT" ]; then
    case "$MNT" in
        *\\*)
            echo "失败：挂载路径包含特殊字符，请提供 mount 输出。"
            exit 1
            ;;
    esac
    echo "已挂载：$DEV -> $MNT"
else
    MNT="$MNT_DEFAULT"

    while read device dir fstype options rest; do
        if [ "$dir" = "$MNT" ]; then
            echo "失败：目录 $MNT 已被 $device 使用。"
            echo "请把 mount 命令输出发给我。"
            exit 1
        fi
    done < /proc/mounts

    mkdir -p "$MNT" || {
        echo "失败：无法创建 $MNT。"
        exit 1
    }

    echo "正在挂载 $DEV ..."
    if ! mount -t vfat "$DEV" "$MNT"; then
        echo "失败：无法挂载 U 盘。"
        echo "不要格式化，请提供 mount 和 dmesg 输出。"
        exit 1
    fi

    echo "挂载成功：$MNT"
fi

OUT="$MNT/pon_report_$$.txt"

if ! (umask 077; : > "$OUT") 2>/dev/null; then
    echo "失败：U 盘无法写入，可能是只读或空间不足。"
    exit 1
fi

echo "========== 2. 查找设备信息 =========="
echo "正在搜索，请稍候，不要拔出 U 盘……"

# 搜索有限范围内的小型文本配置文件。
# 输出匹配原文，不自动假定字段含义。
search_config()
{
    PATTERN="$1"
    FOUND=0

    for DIR in /flash /data /etc; do
        [ -d "$DIR" ] || continue

        find "$DIR" -type f -size -256k \
            \( -name '*.xml' -o -name '*.conf' -o \
               -name '*.cfg' -o -name '*.ini' -o \
               -name '*.txt' \) 2>/dev/null |
        while IFS= read -r FILE; do
            RESULT=$(
                head -c 65536 "$FILE" 2>/dev/null |
                grep -i -E "$PATTERN" |
                head -n 10 |
                cut -c 1-2000
            )

            if [ -n "$RESULT" ]; then
                echo "来源文件：$FILE"
                echo "$RESULT"
                echo
            fi
        done
    done
}

{
    echo "================================================"
    echo "         PONWRT 填写信息及候选数据"
    echo "================================================"
    echo
    echo "重要：候选原文需要根据型号和字段含义核对，不能盲目填入。"
    echo "文件可能包含密码、SN、MAC 等敏感信息，请勿公开发布。"
    echo "本报告只搜索有限的常见文本配置，不保证能找到所有参数。"
    echo

    echo "【原光猫型号：自动查找】"
    echo

    MODEL_FOUND=0
    for F in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
        if [ -r "$F" ]; then
            MODEL="$(tr -d '\000' < "$F" 2>/dev/null)"
            if [ -n "$MODEL" ]; then
                echo "设备树型号候选：$MODEL"
                echo "来源：$F"
                echo "注意：此值也可能是芯片或板卡型号，不一定是光猫商品型号。"
                MODEL_FOUND=1
                break
            fi
        fi
    done

    if [ "$MODEL_FOUND" -eq 0 ]; then
        echo "设备树型号：未找到"
    fi

    echo
    echo "配置文件中的型号候选原文："
    search_config 'product.?class|product.?model|device.?model|model.?name|equipment.?id'
    echo "（如果上方没有候选原文，表示本次搜索未找到。）"
    echo

    echo "【一、线路配置 -> 光链路】"
    echo
    echo "启用光链路："
    echo "如需启用 PON 光链路，勾选；以实际使用需求为准。"
    echo
    echo "线路协议："
    echo "待确认。PONWRT 当前显示 GPON 不代表原光猫一定是 GPON。"
    echo "配置候选原文："
    search_config 'pon.?mode|pon.?type|gpon|epon|xg.?pon|xgs.?pon'
    echo "（无候选原文则表示未找到。）"
    echo

    echo "【二、线路配置 -> 运营商认证】"
    echo
    echo "ONU MAC 地址：待确认"
    echo "注意：普通网口 MAC 不一定是 ONU MAC。"
    echo
    echo "LOID：待确认"
    echo "LOID 密码：待确认"
    echo "ONU 序列号（SN）：待确认"
    echo "PLOAM 密码：待确认"
    echo "OMCI 增强认证 PSK：待确认"
    echo
    echo "以上项目的配置候选原文："
    search_config 'loid|ploam|onu.?mac|pon.?mac|onu.?sn|pon.?sn|serial.?number|omci.*psk|psk.*omci'
    echo "（无候选原文则表示未找到。）"
    echo
    echo "注意：密码可能为空、加密、编码或保存在其他位置。"
    echo "PSK 不能根据 LOID 密码推算，也不能随意填全零。"
    echo

    echo "【三、线路配置 -> 高级参数】"
    echo
    echo "OMCC 版本：待确认，不确定时保留 PONWRT 默认值。"
    echo "禁用 OMCI 增强认证：待确认，不确定时保留默认设置。"
    echo "设备型号：查看本报告开头的型号候选，核对后填写。"
    echo "硬件版本：待确认。"
    echo "软件版本：待确认。"
    echo "OMCI 运营商 ID：待确认。"
    echo
    echo "高级参数配置候选原文："
    search_config 'omcc|equipment.?id|hardware.?version|software.?version|vendor.?id|operator.?id|manufacturer'
    echo "（无候选原文则表示未找到。）"
    echo

    echo "================================================"
    echo "【四、设备基础信息：用于进一步识别型号】"
    echo "================================================"
    echo
    echo "系统："
    uname -a 2>/dev/null
    echo
    echo "CPU："
    cat /proc/cpuinfo 2>/dev/null
    echo
    echo "Flash 分区："
    cat /proc/mtd 2>/dev/null
    echo
    echo "网络接口 MAC（仅供辨认，不等同于 ONU MAC）："
    for F in /sys/class/net/*/address; do
        [ -r "$F" ] || continue
        IFACE="${F%/address}"
        IFACE="${IFACE##*/}"
        echo "$IFACE: $(cat "$F" 2>/dev/null)"
    done
    echo
    echo "常见 PON 目录："
    for DIR in /proc/pon /proc/gpon /proc/epon /sys/class/pon; do
        if [ -d "$DIR" ]; then
            echo "--- $DIR ---"
            ls -la "$DIR" 2>/dev/null
        fi
    done
    echo
    echo "常见查询工具："
    for TOOL in omcicli gpon epon pon ethtool; do
        if command -v "$TOOL" >/dev/null 2>&1; then
            echo "$TOOL: 存在"
        fi
    done
    echo
    echo "报告结束。"
} > "$OUT" 2>&1

RC=$?
sync

if [ "$RC" -ne 0 ]; then
    echo "失败：写入报告时发生错误，请检查 U 盘。"
    exit 1
fi

echo
echo "========== 导出完成 =========="
echo "文件路径：$OUT"
echo "文件名：${OUT##*/}"
ls -l "$OUT"
echo
echo "文件可能包含敏感信息，请勿公开发布。"
echo "建议关闭光猫电源后再拔出 U 盘。"
PON_SCRIPT
