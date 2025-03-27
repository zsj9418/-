#!/bin/bash
# 检查是否以 root 用户运行
if [[ $EUID -ne 0 ]]; then
  echo "错误: 请以 root 用户身份运行此脚本。"
  exit 1
fi

# 获取物理内存大小 (MB)
physical_mem_mb=$(free -m | awk '/Mem:/ {print $2}')
# 计算默认虚拟内存大小 (物理内存的两倍，GB)
default_swap_gb=$((physical_mem_mb * 2 / 1024))

# 询问用户设置虚拟内存大小
read -p "请输入您要设置的虚拟内存大小 (GB)，留空则默认为 ${default_swap_gb}GB: " swap_size_gb

# 如果用户未输入，则使用默认值
if [[ -z "$swap_size_gb" ]]; then
  swap_size_gb=$default_swap_gb
fi

# 检查输入是否为数字
if ! [[ "$swap_size_gb" =~ ^[0-9]+$ ]]; then
  echo "错误: 虚拟内存大小必须为数字 (GB)。"
  exit 1
fi

# 定义 ZFS 卷路径
swap_zvol="/dev/zvol/rpool/swap"
zfs_dataset="rpool/swap"

# 函数: 创建虚拟内存
create_swap() {
  if zfs list rpool/swap > /dev/null 2>&1; then
    # rpool/swap 数据集已存在
    echo "警告: 发现已存在名为 'rpool/swap' 的 ZFS 数据集。"

    # 检查是否已经启用
    if swapon -s | grep "/dev/zvol/rpool/swap" > /dev/null; then
      echo "虚拟内存 '/dev/zvol/rpool/swap' 已经启用。"
      check_swap_status
      return 0
    fi

    echo "请选择操作:"
    echo "  1. 尝试激活已存在的虚拟内存卷" # Changed option name for clarity
    echo "  2. 删除已存在的 'rpool/swap' 数据集并重新创建"
    echo "  3. 取消操作"
    read -p "请选择 (1-3): " existing_dataset_choice

    case "$existing_dataset_choice" in
      1) # 尝试重新启用 (激活)
         echo "尝试激活已存在的虚拟内存卷 '/dev/zvol/rpool/swap'..." # More descriptive message
         if swapon ${swap_zvol} ; then
           echo "虚拟内存激活成功。"
           check_swap_status
         else
           echo "激活虚拟内存失败，请检查 ${swap_zvol} 是否为有效的交换卷。"
         fi
         return 0 ;;
      2) # 删除并重新创建
         echo "您选择了删除已存在的 'rpool/swap' 数据集并重新创建。"
         delete_swap
         if [[ $? -ne 0 ]]; then
           echo "删除现有数据集失败，操作终止。"
           return 1
         fi
         ;; # 删除成功后，继续执行下面的创建流程
      3) echo "取消创建虚拟内存操作。"; return 0 ;;
      *) echo "无效的选项，操作取消。"; return 0 ;;
    esac
  fi

  # 如果 rpool/swap 不存在，或者用户选择了删除后重新创建，则执行以下创建流程
  echo "开始创建 ${swap_size_gb}GB 虚拟内存..."
  zfs create -V ${swap_size_gb}G -b 8k ${zfs_dataset}
  if [[ $? -ne 0 ]]; then
    echo "创建 ZFS 卷失败，请检查错误信息。"
    return 1
  fi
  echo "ZFS 卷 ${zfs_dataset} 创建成功。"

  echo "格式化虚拟内存..."
  mkswap ${swap_zvol}
  if [[ $? -ne 0 ]]; then
    echo "格式化虚拟内存失败，请检查错误信息。"
    zfs destroy ${zfs_dataset} # 创建失败，清理卷
    return 1
  fi
  echo "虚拟内存格式化完成。"

  echo "启用虚拟内存..."
  swapon ${swap_zvol}
  if [[ $? -ne 0 ]]; then
    echo "启用虚拟内存失败，请检查错误信息。"
    return 1
  fi
  echo "虚拟内存启用成功。"
  echo "虚拟内存已设置为 ${swap_size_gb}GB，并已启用。"
}


# 函数: 卸载虚拟内存
disable_swap() {
  echo "开始卸载虚拟内存..."
  swapoff ${swap_zvol}
  if [[ $? -ne 0 ]]; then
    echo "卸载虚拟内存失败，请检查错误信息。"
    return 1
  fi
  echo "虚拟内存卸载成功。"
}

# 函数: 查看虚拟内存状态
check_swap_status() {
  echo "当前虚拟内存状态:"
  swapon -s
  free -h
}

# 函数: 删除虚拟内存 (包括 ZFS 卷)
delete_swap() {
  echo "警告: 您将要彻底删除虚拟内存 (ZFS 卷 ${zfs_dataset})，数据将无法恢复。"
  read -p "请再次输入 'yes' 确认删除: " confirm_delete
  if [[ "$confirm_delete" != "yes" ]]; then
    echo "取消删除操作。"
    return 0
  fi

  echo "开始卸载虚拟内存..."
  swapoff ${swap_zvol}
  swapoff_result=$?
  if [[ $swapoff_result -ne 0 ]]; then
    echo "卸载虚拟内存失败，错误代码: ${swapoff_result}。"
    if [[ $swapoff_result -eq 255 ]]; then # 假设 255 是 "Invalid argument" 错误码
      echo "可能是因为虚拟内存未正确激活或存在其他问题。"
      echo "建议您先手动检查 '/dev/zvol/rpool/swap' 的状态，并尝试重启系统后再试。"
    fi
    echo "无法继续删除操作，请手动检查或稍后重试。"
    return 1
  fi
  echo "虚拟内存卸载成功。"

  # 删除 ZFS 卷，加入重试机制
  local retry_count=3
  local destroy_result=1 # 初始化为失败状态
  while [[ $retry_count -gt 0 && $destroy_result -ne 0 ]]; do
    echo "删除 ZFS 卷 ${zfs_dataset} (尝试 ${4 - retry_count}/3)..."
    zfs destroy ${zfs_dataset}
    destroy_result=$?
    if [[ $destroy_result -ne 0 ]]; then
      echo "删除 ZFS 卷失败，错误代码: ${destroy_result}。"
      if [[ $destroy_result -eq 16 ]]; then # 假设 16 是 "dataset is busy" 错误码
        echo "ZFS 卷可能正忙，无法删除。"
        echo "请检查是否有进程正在使用该卷，或尝试卸载挂载点 (如果存在)。"
      fi
      if [[ $retry_count -gt 1 ]]; then
        echo "重试删除操作..."
        sleep 2  # 稍作等待
      fi
    fi
    ((retry_count--))
  done

  if [[ $destroy_result -eq 0 ]]; then
    echo "ZFS 卷 ${zfs_dataset} 删除成功，虚拟内存已彻底移除。"
  else
    echo "删除 ZFS 卷失败，重试次数已用尽，请手动检查或稍后重试。"
  fi
}


# 主菜单循环
while true; do
  echo ""
  echo "虚拟内存管理菜单:"
  echo "1. 创建并启用虚拟内存"
  echo "2. 卸载虚拟内存"
  echo "3. 查看虚拟内存状态"
  echo "4. 彻底删除虚拟内存 (ZFS 卷)"
  echo "5. 退出"
  read -p "请选择操作 (1-5): " choice

  case "$choice" in
    1) create_swap ;;
    2) disable_swap ;;
    3) check_swap_status ;;
    4) delete_swap ;;
    5) echo "退出脚本."; exit 0 ;;
    *) echo "无效的选项，请重新选择。" ;;
  esac
done
