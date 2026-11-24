#!/bin/sh

echo "========== 自动查找 U 盘 =========="

if [ ! -r /proc/mounts ] || [ ! -r /proc/partitions ]; then
    echo "失败：系统缺少磁盘或挂载信息。"
    exit 1
fi

DEV=""
MNT=""
COUNT=0

# 优先查找已挂载、挂载目录明显标记为 USB 的 sd 分区。
while read device dir fstype options rest; do
    case "$device" in
        /dev/sd*)
            case "$dir" in
                /mnt/usb*|/media/usb*|/mnt/USB*|/media/USB*)
                    case "$dir" in
                        *\\*) continue ;;
                    esac
                    DEV="$device"
                    MNT="$dir"
                    COUNT=$((COUNT + 1))
                    ;;
            esac
            ;;
    esac
done < /proc/mounts

if [ "$COUNT" -gt 1 ]; then
    echo "失败：发现多个已挂载的 USB 候选设备，无法安全确定使用哪一个。"
    echo "请只保留一个 U 盘后重新运行。"
    exit 1
fi

if [ "$COUNT" -eq 1 ]; then
    echo "找到已挂载的 U 盘候选：$DEV -> $MNT"
else
    # 根据 sysfs 路径确认 USB 磁盘，避免仅凭 sda 猜测。
    DISK=""
    DISK_COUNT=0

    for P in /sys/block/sd*; do
        [ -e "$P" ] || continue

        PATH_INFO="$(readlink -f "$P/device" 2>/dev/null)"
        case "$PATH_INFO" in
            *usb*)
                DISK="${P##*/}"
                DISK_COUNT=$((DISK_COUNT + 1))
                ;;
        esac
    done

    if [ "$DISK_COUNT" -eq 0 ]; then
        echo "失败：没有可靠识别到 U 盘。"
        echo "可能是旧版系统不支持所需的 USB 路径查询，或 U 盘未识别。"
        echo "请检查 U 盘连接；不要格式化。"
        exit 1
    fi

    if [ "$DISK_COUNT" -gt 1 ]; then
        echo "失败：发现多个 USB 磁盘，无法安全自动选择。"
        echo "请只保留一个 U 盘后重新运行。"
        exit 1
    fi

    PART_COUNT=0
    for P in /sys/block/"$DISK"/"$DISK"[0-9]*; do
        [ -e "$P" ] || continue
        PART="${P##*/}"
        [ -b "/dev/$PART" ] || continue
        DEV="/dev/$PART"
        PART_COUNT=$((PART_COUNT + 1))
    done

    if [ "$PART_COUNT" -gt 1 ]; then
        echo "失败：U 盘有多个分区，无法安全自动选择。"
        exit 1
    fi

    if [ "$PART_COUNT" -eq 0 ]; then
        DEV="/dev/$DISK"
    fi

    if [ ! -b "$DEV" ]; then
        echo "失败：找不到块设备 $DEV。"
        exit 1
    fi

    # 检查该设备是否已经挂载到其他位置。
    while read device dir fstype options rest; do
        if [ "$device" = "$DEV" ]; then
            case "$dir" in
                *\\*)
                    echo "失败：挂载路径包含特殊字符，无法安全处理。"
                    exit 1
                    ;;
            esac
            MNT="$dir"
            break
        fi
    done < /proc/mounts

    if [ -n "$MNT" ]; then
        echo "找到已挂载的 U 盘：$DEV -> $MNT"
    else
        MNT="/tmp/pon_usb_$$"

        if [ -e "$MNT" ] || ! mkdir "$MNT"; then
            echo "失败：无法创建临时挂载目录。"
            exit 1
        fi

        echo "正在挂载 $DEV ..."
        if mount "$DEV" "$MNT" 2>/dev/null; then
            :
        elif mount -t vfat "$DEV" "$MNT" 2>/dev/null; then
            :
        else
            echo "失败：无法挂载 U 盘。"
            echo "可能是不支持该文件系统，或权限不足。"
            rmdir "$MNT" 2>/dev/null
            exit 1
        fi

        echo "挂载成功：$DEV -> $MNT"
    fi
fi

OUT="$MNT/pon_report_$$.txt"
MATCHES="/tmp/pon_matches_$$.txt"

if [ -e "$OUT" ] || [ -e "$MATCHES" ]; then
    echo "失败：目标文件已存在，为避免覆盖而退出。"
    exit 1
fi

if ! (umask 077; : > "$OUT") 2>/dev/null; then
    echo "失败：U 盘无法写入，可能是只读或空间不足。"
    exit 1
fi

if ! (umask 077; : > "$MATCHES") 2>/dev/null; then
    echo "失败：无法创建临时文件。"
    exit 1
fi

echo "========== 自动查找光猫配置 =========="
echo "正在搜索，请稍候，不要拔出 U 盘……"

# 仅搜索部分常见文本配置；不读取原始 Flash 分区。
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

MODEL=""
MODEL_SOURCE=""

for F in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
    if [ -r "$F" ]; then
        VALUE="$(tr -d '\000' < "$F" 2>/dev/null)"
        if [ -n "$VALUE" ]; then
            MODEL="$VALUE"
            MODEL_SOURCE="$F"
            break
        fi
    fi
done

{
    echo "================================================"
    echo "             PONWRT 参数整理报告"
    echo "================================================"
    echo
    echo "重要：本文件可能包含密码、SN、MAC 等敏感信息。"
    echo "候选原文需要确认来源和含义，不能盲目填入。"
    echo

    echo "【原光猫型号：自动查找】"
    if [ -n "$MODEL" ]; then
        echo "设备树型号候选：$MODEL"
        echo "来源：$MODEL_SOURCE"
        echo "注意：这可能是板卡型号，不一定是商品型号。"
    else
        echo "设备树型号：未找到"
    fi
    echo "其他型号候选：请查看本报告末尾的配置原文。"
    echo

    echo "【一、线路配置 -> 光链路】"
    echo
    echo "启用光链路：按实际需求启用"
    echo "线路协议：未确认"
    echo

    echo "【二、线路配置 -> 运营商认证】"
    echo
    echo "ONU MAC 地址：未确认"
    echo "LOID：未确认"
    echo "LOID 密码：未确认"
    echo "ONU 序列号（SN）：未确认"
    echo "SN 十六进制格式：未确认"
    echo "PLOAM 密码：未确认"
    echo "PLOAM 十六进制格式：未确认"
    echo "OMCI 增强认证 PSK：未确认"
    echo
    echo "说明：普通网口 MAC 不一定是 ONU MAC。"
    echo "PSK 不可由 LOID 密码推算，也不可随意填全零。"
    echo

    echo "【三、线路配置 -> 高级参数】"
    echo
    echo "OMCC 版本：未确认；不确定时保持默认值"
    echo "禁用 OMCI 增强认证：未确认；不确定时保持默认值"
    echo "设备型号：查看上方型号候选及下方配置原文"
    echo "硬件版本：未确认"
    echo "软件版本：未确认"
    echo "OMCI 运营商 ID：未确认"
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
    echo "仅搜索部分常见文本文件，结果可能不完整。"
    echo
    if [ -s "$MATCHES" ]; then
        cat "$MATCHES"
    else
        echo "本次没有找到匹配内容。"
    fi
    echo
    echo "报告结束。"
} > "$OUT" 2>&1

RC=$?
rm -f "$MATCHES"
sync

if [ "$RC" -ne 0 ]; then
    echo "失败：写入报告时发生错误，请检查 U 盘。"
    exit 1
fi

echo
echo "========== 导出完成 =========="
echo "文件：$OUT"
ls -l "$OUT"
echo "请关闭光猫电源后再拔出 U 盘。"
echo "报告可能包含敏感信息，请勿公开分享。"
PON_SCRIPT
