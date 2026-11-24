#!/bin/sh

echo "================================================"
echo "      光猫信息导出工具（兼容旧版 BusyBox）"
echo "================================================"
echo
echo "本工具不会格式化 U 盘，也不会修改 PON 配置。"
echo "导出文件可能包含密码等敏感信息，请勿公开分享。"
echo

if [ ! -r /proc/partitions ] || [ ! -r /proc/mounts ]; then
    echo "失败：系统没有提供必要的磁盘信息。"
    exit 1
fi

echo "【系统识别到的 sd 磁盘及分区】"
echo "名称             大小（KB）"
awk '
    $4 ~ /^sd[a-z]+[0-9]*$/ {
        printf "%-16s %s\n", $4, $3
    }
' /proc/partitions

echo
echo "【当前已挂载的 sd 设备】"
awk '
    $1 ~ /^\/dev\/sd[a-z]+[0-9]*$/ {
        print $1 " -> " $2 "  文件系统：" $3 "  选项：" $4
    }
' /proc/mounts

echo
echo "请输入 U 盘分区名称，例如 sda1。"
echo "不要输入 /dev/，不要输入 mtdblock、loop 或其他非 U 盘设备。"
echo "请结合 U 盘容量和上面的挂载信息判断。"
echo "不确定时输入 q 退出，并把上面的输出发给我。"
printf "U 盘分区名称："
read NAME

case "$NAME" in
    q|Q|"")
        echo "已退出，没有修改磁盘。"
        exit 0
        ;;
    *[!a-z0-9]*)
        echo "失败：名称包含不允许的字符。"
        exit 1
        ;;
esac

# 只允许 /proc/partitions 中列出的 sd 分区或磁盘。
if ! awk -v n="$NAME" '
    $4 == n && $4 ~ /^sd[a-z]+[0-9]*$/ { found=1 }
    END { exit !found }
' /proc/partitions; then
    echo "失败：系统磁盘列表中没有这个 sd 设备：$NAME"
    exit 1
fi

DEV="/dev/$NAME"

if [ ! -b "$DEV" ]; then
    echo "失败：设备节点 $DEV 不存在或不是块设备。"
    echo "请提供 ls -l /dev 和 cat /proc/partitions 的输出。"
    exit 1
fi

echo
echo "你选择的是：$DEV"
echo "请再次确认它是你的 U 盘，而不是其他磁盘。"
printf "确认请输入 YES，其他任何输入都会退出："
read CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "已取消。"
    exit 0
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
            echo "失败：挂载路径包含空格或特殊字符，无法可靠处理。"
            echo "请提供 mount 的输出。"
            exit 1
            ;;
    esac
    echo "使用已有挂载：$DEV -> $MNT"
else
    MNT="/tmp/pon_usb_$$"

    if [ -e "$MNT" ]; then
        echo "失败：临时挂载目录已存在：$MNT"
        exit 1
    fi

    if ! mkdir "$MNT"; then
        echo "失败：无法创建临时挂载目录。"
        exit 1
    fi

    echo "正在尝试挂载 $DEV ..."
    if mount "$DEV" "$MNT" 2>/dev/null; then
        echo "挂载成功：$MNT"
    elif mount -t vfat "$DEV" "$MNT" 2>/dev/null; then
        echo "按 FAT 文件系统挂载成功：$MNT"
    else
        echo "失败：无法挂载该设备。"
        echo "可能是文件系统不受支持、权限不足或 U 盘异常。"
        echo "请勿格式化；请提供以下命令输出："
        echo "mount"
        echo "cat /proc/partitions"
        echo "dmesg | tail -50"
        rmdir "$MNT" 2>/dev/null
        exit 1
    fi
fi

OUT="$MNT/pon_report_$$.txt"
MATCHES="/tmp/pon_matches_$$.txt"

if [ -e "$OUT" ]; then
    echo "失败：目标文件已存在，为避免覆盖而退出：$OUT"
    exit 1
fi

if ! (umask 077; : > "$OUT") 2>/dev/null; then
    echo "失败：无法写入 $MNT，可能是只读或空间不足。"
    exit 1
fi

echo
echo "正在查找配置，可能需要一些时间，请不要拔出 U 盘……"

# 只搜索有限目录中的常见小型文本配置文件。
# 不扫描 U 盘、不读取原始 Flash 分区。
: > "$MATCHES"

for DIR in /flash /data /etc /rom /usr/local; do
    [ -d "$DIR" ] || continue

    find "$DIR" -type f -size -256k \
        \( -name '*.xml' -o -name '*.conf' -o \
           -name '*.cfg' -o -name '*.ini' -o \
           -name '*.txt' \) 2>/dev/null |
    while IFS= read -r FILE; do
        RESULT=$(
            head -c 65536 "$FILE" 2>/dev/null |
            grep -i -E 'loid|ploam|gpon|epon|xg.?pon|xgs.?pon|omci|omcc|onu.?mac|pon.?mac|onu.?sn|pon.?sn|serial.?number|product.?class|product.?model|device.?model|model.?name|equipment.?id|hardware.?version|software.?version|vendor.?id|operator.?id|manufacturer' |
            head -n 20 |
            cut -c 1-2000
        )

        if [ -n "$RESULT" ]; then
            echo "来源文件：$FILE"
            echo "$RESULT"
            echo
        fi
    done >> "$MATCHES"
done

{
    echo "================================================"
    echo "            PONWRT 填写信息报告"
    echo "================================================"
    echo
    echo "重要：本文件可能含密码、SN、MAC 等敏感信息。"
    echo "候选原文不一定属于本机 PON 注册配置，须核对后使用。"
    echo "找不到不代表设备没有该参数，可能存放在其他位置。"
    echo

    echo "【原光猫型号：自动查找】"
    MODEL_FOUND=0

    for F in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
        if [ -r "$F" ]; then
            MODEL="$(tr -d '\000' < "$F" 2>/dev/null)"
            if [ -n "$MODEL" ]; then
                echo "设备树型号候选：$MODEL"
                echo "来源：$F"
                echo "注意：可能是板卡或芯片型号，不一定是商品型号。"
                MODEL_FOUND=1
                break
            fi
        fi
    done

    if [ "$MODEL_FOUND" -eq 0 ]; then
        echo "设备树型号：未找到。请查看本报告末尾的候选配置。"
    fi
    echo

    echo "【一、线路配置 -> 光链路】"
    echo
    echo "启用光链路：按实际需求启用"
    echo "线路协议：待确认"
    echo

    echo "【二、线路配置 -> 运营商认证】"
    echo
    echo "ONU MAC 地址：待确认"
    echo "LOID：待确认"
    echo "LOID 密码：待确认"
    echo "ONU 序列号（SN）：待确认"
    echo "SN 十六进制格式：待确认"
    echo "PLOAM 密码：待确认"
    echo "PLOAM 十六进制格式：待确认"
    echo "OMCI 增强认证 PSK：待确认"
    echo
    echo "注意：普通网口 MAC 不一定是 ONU MAC。"
    echo "PSK 不能根据其他密码推算，也不能随意填全零。"
    echo

    echo "【三、线路配置 -> 高级参数】"
    echo
    echo "OMCC 版本：待确认；不确定时保留默认值"
    echo "禁用 OMCI 增强认证：待确认；不确定时保留默认值"
    echo "设备型号：查看上方型号候选及下方配置原文"
    echo "硬件版本：待确认"
    echo "软件版本：待确认"
    echo "OMCI 运营商 ID：待确认"
    echo

    echo "【四、设备基础信息】"
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
    echo "网络接口 MAC，仅供辨认："
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
            echo "$TOOL：存在"
        fi
    done
    echo

    echo "【五、配置文件候选原文】"
    echo "只搜索有限目录、常见扩展名的小型文件；结果可能不完整。"
    echo "每个文件最多展示 20 行，每行最多 2000 字符。"
    echo
    if [ -s "$MATCHES" ]; then
        cat "$MATCHES"
    else
        echo "本次搜索未找到匹配内容。"
    fi
    echo
    echo "报告结束。"
} > "$OUT" 2>&1

RC=$?
rm -f "$MATCHES"
sync

if [ "$RC" -ne 0 ]; then
    echo "失败：写入报告时发生错误，请检查 U 盘空间及权限。"
    exit 1
fi

echo
echo "================================================"
echo "导出完成：$OUT"
echo "文件名：${OUT##*/}"
echo "请关闭光猫电源后再拔出 U 盘。"
echo "================================================"
ls -l "$OUT"
PON_SCRIPT
