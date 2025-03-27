#!/bin/bash

# 检查是否以 root 用户运行
if [[ $EUID -ne 0 ]]; then
  echo "错误: 请以 root 用户身份运行此脚本。"
  exit 1
fi

# --- 函数定义 ---

# 函数: 获取物理内存大小 (MB)
get_physical_memory() {
  free -m | awk '/Mem:/ {print $2}'
}

# 函数: 查看虚拟内存状态
check_swap_status() {
  echo "当前虚拟内存状态:"
  swapon -s
  free -h
}

# 函数: 卸载虚拟内存
disable_swap() {
  echo "开始卸载虚拟内存..."
  swapoff /dev/zvol/rpool/swap
  if [[ $? -ne 0 ]]; then
    echo "卸载虚拟内存失败，请检查错误信息。"
    return 1
  fi
  echo "虚拟内存卸载成功。"
}

# 函数: 创建 ZFS 虚拟内存 (ZFS 专用)
create_zfs_swap() {
  local swap_size_gb="$1"
  local zfs_dataset="rpool/swap"
  local swap_zvol="/dev/zvol/rpool/swap"

  if zfs list "$zfs_dataset" > /dev/null 2>&1; then
    # rpool/swap 数据集已存在
    echo "警告: 发现已存在名为 '$zfs_dataset' 的 ZFS 数据集。"

    # 检查是否已经启用
    if swapon -s | grep "$swap_zvol" > /dev/null; then
      echo "虚拟内存 '$swap_zvol' 已经启用。"
      check_swap_status
      return 0
    fi

    echo "请选择操作:"
    echo "  1. 尝试激活已存在的虚拟内存卷"
    echo "  2. 删除已存在的 '$zfs_dataset' 数据集并重新创建"
    echo "  3. 取消操作"
    read -p "请选择 (1-3): " existing_dataset_choice

    case "$existing_dataset_choice" in
      1) # 尝试重新启用 (激活)
         echo "尝试激活已存在的虚拟内存卷 '$swap_zvol'..."
         if swapon "$swap_zvol" ; then
           echo "虚拟内存激活成功。"
           check_swap_status
         else
           echo "激活虚拟内存失败，请检查 '$swap_zvol' 是否为有效的交换卷。"
         fi
         return 0 ;;
      2) # 删除并重新创建
         echo "您选择了删除已存在的 '$zfs_dataset' 数据集并重新创建。"
         delete_zfs_swap
         if [[ $? -ne 0 ]]; then
           echo "删除现有数据集失败，操作终止。"
           return 0 # 返回主菜单
         fi
         ;; # 删除成功后，继续执行下面的创建流程
      3) echo "取消创建虚拟内存操作。"; return 0 ;;
      *) echo "无效的选项，操作取消。"; return 0 ;;
    esac
  fi

  echo "开始创建 ${swap_size_gb}GB ZFS 虚拟内存..."
  zfs create -V ${swap_size_gb}G -b 8k "$zfs_dataset"
  if [[ $? -ne 0 ]]; then
    echo "创建 ZFS 卷失败，请检查错误信息。"
    return 1
  fi
  echo "ZFS 卷 '$zfs_dataset' 创建成功。"

  echo "格式化虚拟内存..."
  mkswap "$swap_zvol"
  if [[ $? -ne 0 ]]; then
    echo "格式化虚拟内存失败，请检查错误信息。"
    zfs destroy "$zfs_dataset" # 创建失败，清理卷
    return 1
  fi
  echo "虚拟内存格式化完成。"

  echo "启用虚拟内存..."
  swapon "$swap_zvol"
  if [[ $? -ne 0 ]]; then
    echo "启用虚拟内存失败，请检查错误信息。"
    return 1
  fi
  echo "虚拟内存启用成功。"
  echo "虚拟内存已设置为 ${swap_size_gb}GB，并已启用。"
}

# 函数: 删除 ZFS 虚拟内存 (ZFS 专用)
delete_zfs_swap() {
  local zfs_dataset="rpool/swap"
  local swap_zvol="/dev/zvol/rpool/swap"

  echo "警告: 您将要彻底删除虚拟内存 (ZFS 卷 ${zfs_dataset})，数据将无法恢复。"
  read -p "请再次输入 'yes' 确认删除: " confirm_delete
  if [[ "$confirm_delete" != "yes" ]]; then
    echo "取消删除操作。"
    return 0 # 返回主菜单
  fi

  # 检查是否已经启用
  if swapon -s | grep "$swap_zvol" > /dev/null; then
    echo "开始卸载虚拟内存..."
    swapoff "$swap_zvol"
    swapoff_result=$?
    if [[ $swapoff_result -ne 0 ]]; then
      echo "卸载虚拟内存失败，错误代码: ${swapoff_result}。"
      if [[ $swapoff_result -eq 255 ]]; then # 假设 255 是 "Invalid argument" 错误码
        echo "可能是因为虚拟内存未正确激活或存在其他问题。"
        echo "建议您先手动检查 '$swap_zvol' 的状态，并尝试重启系统后再试。"
      fi
      echo "无法继续删除操作，请手动检查或稍后重试。"
      return 0 # 返回主菜单
    fi
    echo "虚拟内存卸载成功。"
  else
    echo "虚拟内存 '$swap_zvol' 未启用，直接删除。"
  fi

  # 删除 ZFS 卷，加入重试机制
  local retry_count=3
  local destroy_result=1 # 初始化为失败状态
  while [[ $retry_count -gt 0 && $destroy_result -ne 0 ]]; do
    echo "删除 ZFS 卷 ${zfs_dataset} (尝试 $((4 - retry_count))/3)..."
    zfs destroy "$zfs_dataset"
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
  return 0 # 返回主菜单
}

# 函数: 创建文件交换空间 (ext4/XFS/etc. 专用)
create_file_swap() {
  local swap_size_gb="$1"
  local swap_file="/swapfile"  # 交换文件路径

  echo "开始创建 ${swap_size_gb}GB 文件交换空间..."
  # 检查是否已经存在交换文件
  if [[ -f "$swap_file" ]]; then
    echo "警告: 发现已存在交换文件 '$swap_file'。"
    echo "请选择操作:"
    echo "  1. 尝试启用已存在的交换文件"
    echo "  2. 删除已存在的交换文件并重新创建"
    echo "  3. 取消操作"
    read -p "请选择 (1-3): " existing_file_choice

    case "$existing_file_choice" in
      1) # 尝试启用
         echo "尝试启用已存在的交换文件..."
         if swapon "$swap_file" ; then
           echo "虚拟内存激活成功。"
           check_swap_status
         else
           echo "激活虚拟内存失败，请检查 '$swap_file' 是否为有效的交换文件。"
         fi
         return 0 ;;
      2) # 删除并重新创建
         echo "您选择了删除已存在的交换文件并重新创建。"
         rm -f "$swap_file"  # 删除旧文件
         if [[ $? -ne 0 ]]; then
           echo "删除现有交换文件失败，操作终止。"
           return 1
         fi
         ;; # 删除成功后，继续执行创建流程
      3) echo "取消创建虚拟内存操作。"; return 0 ;;
      *) echo "无效的选项，操作取消。"; return 0 ;;
    esac
  fi

  # 创建交换文件
  fallocate -l ${swap_size_gb}G "$swap_file"  # 使用 fallocate 创建空文件
  if [[ $? -ne 0 ]]; then
    echo "创建交换文件失败，请检查错误信息。"
    return 1
  fi
  echo "交换文件 '$swap_file' 创建成功。"

  # 设置权限
  chmod 600 "$swap_file"
  if [[ $? -ne 0 ]]; then
    echo "设置交换文件权限失败，请检查错误信息。"
    rm -f "$swap_file" # 权限设置失败，删除文件
    return 1
  fi
  echo "设置交换文件权限完成。"

  # 格式化
  mkswap "$swap_file"
  if [[ $? -ne 0 ]]; then
    echo "格式化交换文件失败，请检查错误信息。"
    rm -f "$swap_file" # 格式化失败，删除文件
    return 1
  fi
  echo "交换文件格式化完成。"

  # 启用
  swapon "$swap_file"
  if [[ $? -ne 0 ]]; then
    echo "启用虚拟内存失败，请检查错误信息。"
    rm -f "$swap_file" # 启用失败，删除文件
    return 1
  fi
  echo "虚拟内存启用成功。"
  echo "虚拟内存已设置为 ${swap_size_gb}GB，并已启用。"

  # 持久化 (添加到 /etc/fstab)
  echo "$swap_file swap swap defaults 0 0" | sudo tee -a /etc/fstab
  if [[ $? -ne 0 ]]; then
      echo "警告：无法将交换文件添加到 /etc/fstab，请手动添加。"
  fi
}

# 函数: 删除文件交换空间 (ext4/XFS/etc. 专用)
delete_file_swap() {
  local swap_file="/swapfile"

  echo "警告: 您将要彻底删除文件交换空间 '$swap_file'，数据将无法恢复。"
  read -p "请再次输入 'yes' 确认删除: " confirm_delete
  if [[ "$confirm_delete" != "yes" ]]; then
    echo "取消删除操作。"
    return 0
  fi

  echo "开始卸载虚拟内存..."
  swapoff "$swap_file"
  if [[ $? -ne 0 ]]; then
    echo "卸载虚拟内存失败，请检查错误信息。"
    return 1
  fi
  echo "虚拟内存卸载成功。"

  echo "删除交换文件 '$swap_file'..."
  rm -f "$swap_file"
  if [[ $? -ne 0 ]]; then
    echo "删除交换文件失败，请检查错误信息。"
    return 1
  fi
  echo "交换文件 '$swap_file' 删除成功，虚拟内存已彻底移除。"

  # 从 /etc/fstab 中移除
  sed -i '/\/swapfile swap/d' /etc/fstab  # 移除 fstab 中的条目
  if [[ $? -ne 0 ]]; then
      echo "警告：无法从 /etc/fstab 中移除交换文件条目，请手动移除。"
  fi
}

# --- 主程序 ---

# 获取物理内存大小
physical_mem_mb=$(get_physical_memory)
default_swap_gb=$((physical_mem_mb * 2 / 1024))

# --- 检测根文件系统类型 ---
root_fs_type=$(df -T / | awk 'NR==2 {print $2}')

# --- 选择虚拟内存管理方式 ---
echo ""
echo "检测到根文件系统类型: $root_fs_type"

if [[ "$root_fs_type" == "zfs" ]]; then
  echo "系统使用 ZFS 文件系统。"
  echo "将使用 ZFS 卷的方式创建和管理虚拟内存。"
  create_swap_func="create_zfs_swap"
  delete_swap_func="delete_zfs_swap"

elif [[ "$root_fs_type" == "ext4" || "$root_fs_type" == "xfs" || "$root_fs_type" == "ext3" ]]; then
  echo "系统使用 $root_fs_type 文件系统。"
  echo "将使用文件交换空间的方式创建和管理虚拟内存。"
  create_swap_func="create_file_swap"
  delete_swap_func="delete_file_swap"
else
  echo "不支持的根文件系统类型: $root_fs_type"
  echo "请手动配置虚拟内存。"
  exit 1
fi

# --- 主菜单循环 ---
while true; do
  echo ""
  echo "虚拟内存管理菜单:"
  echo "1. 创建并启用虚拟内存"
  echo "2. 卸载虚拟内存"
  echo "3. 查看虚拟内存状态"
  echo "4. 彻底删除虚拟内存"
  echo "5. 退出"
  read -p "请选择操作 (1-5): " choice

  case "$choice" in
    1)
      # 进入创建虚拟内存的子菜单
      echo "创建并启用虚拟内存"
      echo "-------------------"
      echo "1. 输入自定义虚拟内存大小并创建"
      echo "2. 使用默认大小 (${default_swap_gb}GB) 创建"
      echo "3. 返回主菜单"
      read -p "请选择操作 (1-3): " create_choice

      case "$create_choice" in
        1)
          read -p "请输入您要设置的虚拟内存大小 (GB): " swap_size_gb
          if ! [[ "$swap_size_gb" =~ ^[0-9]+$ ]]; then
            echo "错误: 虚拟内存大小必须为数字 (GB)。"
            continue
          fi
          "$create_swap_func" "$swap_size_gb" ;;
        2)
          echo "使用默认大小 (${default_swap_gb}GB) 创建..."
          "$create_swap_func" "$default_swap_gb" ;;
        3)
          continue ;;
        *) 
          echo "无效的选项，操作取消。" ;;
      esac ;;
    2) disable_swap ;;
    3) check_swap_status ;;
    4) "$delete_swap_func" ;;  # 调用相应的文件系统删除函数
    5) echo "退出脚本."; exit 0 ;;
    *) echo "无效的选项，请重新选择。" ;;
  esac
done
