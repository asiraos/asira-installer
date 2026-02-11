#!/bin/bash

# Get real disk and partition information
get_real_disks() {
    lsblk -dpno NAME,SIZE,TYPE | grep disk | while read -r name size type; do
        echo "$name $size"
    done
}

get_real_partitions() {
    local disk=$1
    lsblk -pno NAME,SIZE,FSTYPE,MOUNTPOINT "$disk" | grep -v "^$disk" | while read -r name size fstype mount; do
        echo "$name $size $fstype $mount"
    done
}

get_free_space() {
    local disk=$1
    local parted_cmd="parted"
    if command -v sudo >/dev/null 2>&1; then
        parted_cmd="sudo parted"
    fi
    $parted_cmd "$disk" unit GB print free 2>/dev/null | awk '
        /Free Space/ {
            start=$1
            size=$3
            n=size
            gsub(/[^0-9.]/, "", n)
            if (n+0 > max) {
                max=n+0
                best_start=start
                best_size=size
            }
        }
        END {
            if (max > 0) {
                print best_start " " best_size
            }
        }
    '
}

# Get the highest existing partition number on a disk (0 if none)
get_last_partition_number() {
    local disk=$1
    local disk_name
    disk_name=$(basename "$disk")
    lsblk -ln -o NAME "$disk" | awk -v d="$disk_name" '
        NR>1 {
            n=$1
            sub("^"d, "", n)
            sub("^p", "", n)
            if (n ~ /^[0-9]+$/ && n+0 > max) max = n+0
        }
        END { print max+0 }
    '
}
# Disk Selection
disk_selection() {
    show_banner
    gum style --foreground 214 "Disk Selection"
    echo ""
    
    # Show selected mountpoints under title
    if [ -f "/tmp/asiraos/mounts" ]; then
        gum style --foreground 46 "Selected Mountpoints:"
        table_output=$(awk -F ' -> ' 'NF==2 {print $1 "," $2}' /tmp/asiraos/mounts | \
            gum table --columns "Partition,Mountpoint" --widths 28,16 --print)
        term_width=$(tput cols 2>/dev/null || echo 80)
        while IFS= read -r l; do
            clean_line=$(echo -e "$l" | sed 's/\x1b\[[0-9;]*m//g')
            left=$(( (term_width - ${#clean_line}) / 2 ))
            [ "$left" -lt 0 ] && left=0
            printf "%*s%s\n" "$left" "" "$l"
        done <<< "$table_output"
        echo ""
    fi
    
    # Check if we have root and boot partitions
    HAS_ROOT=false
    HAS_BOOT=false
    if [ -f "/tmp/asiraos/mounts" ]; then
        if grep -q " -> /$" /tmp/asiraos/mounts; then
            HAS_ROOT=true
        fi
        if grep -q " -> /boot/efi$" /tmp/asiraos/mounts || grep -q " -> /boot$" /tmp/asiraos/mounts; then
            HAS_BOOT=true
        fi
    fi
    
    # Build menu options - remove "Recommended" if partitions are configured
    if [ "$HAS_ROOT" = true ] && [ "$HAS_BOOT" = true ]; then
        MENU_OPTIONS=("🚀 Continue to Next Step" "Auto Partition" "Custom Partition Setup")
    else
        MENU_OPTIONS=("Auto Partition (Recommended)" "Custom Partition Setup")
    fi
    
    # Add clear option if mounts exist
    if [ -f "/tmp/asiraos/mounts" ]; then
        MENU_OPTIONS+=("Clear All Mountpoints")
    fi
    
    MENU_OPTIONS+=("← Back")
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${MENU_OPTIONS[@]}")
    
    case $CHOICE in
        "Custom Partition Setup")
            manual_partition
            ;;
        "Auto Partition (Recommended)"|"Auto Partition")
            auto_partition
            ;;
        "Clear All Mountpoints")
            rm -f /tmp/asiraos/mounts
            gum style --foreground 46 "All mountpoints cleared"
            sleep 1
            disk_selection
            ;;
        "🚀 Continue to Next Step")
            mount_partitions_and_continue
            ;;
        "← Back")
            if [ "$BASIC_MODE" = true ]; then
                basic_step_1_disk
            else
                advanced_setup
            fi
            ;;
    esac
}

mount_partitions_and_continue() {
    gum style --foreground 205 "Mounting partitions..."
    
    # Unmount any existing mounts
    umount -R /mnt 2>/dev/null || true
    
    # Mount root partition first
    ROOT_PARTITION=$(grep " -> /$" /tmp/asiraos/mounts | cut -d' ' -f1 | head -1)
    if [ -n "$ROOT_PARTITION" ]; then
        gum style --foreground 46 "Mounting root: $ROOT_PARTITION -> /mnt"
        mount "$ROOT_PARTITION" /mnt
    fi
    
    # Mount other partitions
    while IFS= read -r line; do
        PARTITION=$(echo "$line" | cut -d' ' -f1)
        MOUNTPOINT=$(echo "$line" | cut -d' ' -f3)
        
        # Skip root partition (already mounted)
        if [ "$MOUNTPOINT" = "/" ]; then
            continue
        fi
        
        # Create mountpoint and mount
        mkdir -p "/mnt$MOUNTPOINT"
        gum style --foreground 46 "Mounting: $PARTITION -> /mnt$MOUNTPOINT"
        
        if [ "$MOUNTPOINT" = "/boot/efi" ]; then
            mount -t vfat "$PARTITION" "/mnt$MOUNTPOINT"
        elif [ "$MOUNTPOINT" = "/boot" ]; then
            mount "$PARTITION" "/mnt$MOUNTPOINT"
        else
            mount "$PARTITION" "/mnt$MOUNTPOINT"
        fi
    done < /tmp/asiraos/mounts
    
    gum style --foreground 46 "✓ All partitions mounted successfully"
    sleep 1
    
    if [ "$BASIC_MODE" = true ]; then
        basic_step_15_install
    else
        advanced_setup
    fi
}

# Manual Partition
manual_partition() {
    show_banner
    gum style --foreground 214 "Manual Partition"
    echo ""
    
    # Get real available disks
    DISK_OPTIONS=()
    while read -r disk_line; do
        disk_name=$(echo "$disk_line" | awk '{print $1}' | sed 's|/dev/||')
        disk_size=$(echo "$disk_line" | awk '{print $2}')
        DISK_OPTIONS+=("$disk_name ($disk_size)")
    done < <(get_real_disks)
    
    if [ ${#DISK_OPTIONS[@]} -eq 0 ]; then
        gum style --foreground 196 "No disks found"
        gum input --placeholder "Press Enter to go back..."
        disk_selection
        return
    fi
    
    # Let user select disk
    gum style --foreground 46 "Select disk:"
    SELECTED_OPTION=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${DISK_OPTIONS[@]}")
    DISK=$(echo "$SELECTED_OPTION" | cut -d' ' -f1)
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Create/Edit Partitions (cfdisk)" \
        "Set Mountpoints" \
        "← Back")
    
    case $CHOICE in
        "Create/Edit Partitions (cfdisk)")
            gum style --foreground 214 "Opening cfdisk for /dev/$DISK"
            sleep 1
            cfdisk /dev/$DISK
            echo -e "${GREEN}Partitioning completed for /dev/$DISK${NC}"
            gum input --placeholder "Press Enter to continue..."
            manual_partition
            ;;
        "Set Mountpoints")
            set_mountpoints "$DISK"
            ;;
        "← Back")
            disk_selection
            ;;
    esac
}

# Set Mountpoints with proper partition detection
set_mountpoints() {
    local disk=$1
    show_banner
    gum style --foreground 214 "Set Mountpoints for /dev/$disk"
    echo ""
    
    # Get real partitions for this disk
    PARTITION_OPTIONS=()
    while read -r part_line; do
        if [ -n "$part_line" ]; then
            part_name=$(echo "$part_line" | awk '{print $1}' | sed 's|/dev/||')
            part_size=$(echo "$part_line" | awk '{print $2}')
            part_fstype=$(echo "$part_line" | awk '{print $3}')
            part_mount=$(echo "$part_line" | awk '{print $4}')
            
            if [ "$part_fstype" = "" ]; then
                part_fstype="unformatted"
            fi
            
            PARTITION_OPTIONS+=("$part_name ($part_size, $part_fstype)")
        fi
    done < <(get_real_partitions "/dev/$disk")
    
    if [ ${#PARTITION_OPTIONS[@]} -eq 0 ]; then
        gum style --foreground 214 "No partitions found on /dev/$disk"
        gum style --foreground 214 "Please create partitions first using cfdisk"
        gum input --placeholder "Press Enter to go back..."
        manual_partition
        return
    fi
    
    # Let user select partition
    gum style --foreground 46 "Select partition:"
    SELECTED_OPTION=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${PARTITION_OPTIONS[@]}")
    PARTITION=$(echo "$SELECTED_OPTION" | awk '{print $1}' | tr -d '│├└─')

    # Normalize partition name (remove /dev/ if already present)
    PARTITION="${PARTITION#/dev/}"

    # Verify partition exists
    if [ ! -b "/dev/$PARTITION" ]; then
        gum style --foreground 196 "Error: Partition /dev/$PARTITION not found"
        gum input --placeholder "Press Enter to try again..."
        set_mountpoints "$disk"
        return
    fi

    
    # Select mountpoint
    MOUNTPOINT=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "/" \
        "/boot" \
        "/boot/efi" \
        "/home" \
        "/var" \
        "/tmp" \
        "Custom")
    
    if [ "$MOUNTPOINT" = "Custom" ]; then
        MOUNTPOINT=$(gum input --placeholder "Enter custom mountpoint (e.g., /opt)")
    fi
    
    # Check if mountpoint already exists
    if grep -q " -> $MOUNTPOINT$" /tmp/asiraos/mounts 2>/dev/null; then
        gum style --foreground 196 "Mountpoint $MOUNTPOINT already exists!"
        gum input --placeholder "Press Enter to try again..."
        set_mountpoints "$disk"
        return
    fi
    
    # Ask if user wants to format the partition
    FORMAT_CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Format partition" \
        "Use existing filesystem")
    
    if [ "$FORMAT_CHOICE" = "Format partition" ]; then
        format_partition "/dev/$PARTITION" "$MOUNTPOINT"
    fi
    
    # Save mountpoint configuration
    mkdir -p /tmp/asiraos
    echo "/dev/$PARTITION -> $MOUNTPOINT" >> /tmp/asiraos/mounts
    gum style --foreground 46 "Mountpoint set: /dev/$PARTITION -> $MOUNTPOINT"
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Set Another Mountpoint" \
        "🚀 Continue to Disk Selection" \
        "← Back")
    
    case $CHOICE in
        "Set Another Mountpoint")
            set_mountpoints "$disk"
            ;;
        "🚀 Continue to Disk Selection")
            disk_selection
            ;;
        "← Back")
            manual_partition
            ;;
    esac
}

# Create partition in free space
create_partition_in_free_space() {
    local disk=$1
    
    gum style --foreground 205 "Creating new partition in free space..."
    
    # Get free space info
    FREE_SPACE_INFO=$(get_free_space "/dev/$disk")
    FREE_START=$(echo "$FREE_SPACE_INFO" | awk '{print $1}')
    FREE_SIZE=$(echo "$FREE_SPACE_INFO" | awk '{print $2}')
    
    if [ -z "$FREE_START" ] || [ "$FREE_SIZE" = "0GB" ]; then
        gum style --foreground 196 "No free space available"
        gum input --placeholder "Press Enter to continue..."
        set_mountpoints "$disk"
        return
    fi
    
    # Get partition size from user
    PART_SIZE=$(gum input --placeholder "Enter partition size (e.g., 20GB, 50%, or 'all' for remaining space)")
    
    if [ -z "$PART_SIZE" ]; then
        gum style --foreground 196 "Invalid size"
        gum input --placeholder "Press Enter to try again..."
        create_partition_in_free_space "$disk"
        return
    fi
    
    # Calculate end position
    if [ "$PART_SIZE" = "all" ]; then
        END_POS="100%"
    elif [[ "$PART_SIZE" == *"%" ]]; then
        END_POS="$PART_SIZE"
    else
        # Convert to MB and calculate end
        SIZE_MB=$(echo "$PART_SIZE" | sed 's/GB//' | awk '{print $1 * 1024}')
        START_MB=$(echo "$FREE_START" | sed 's/GB//' | awk '{print $1 * 1024}')
        END_MB=$((START_MB + SIZE_MB))
        END_POS="${END_MB}MB"
    fi
    
    # Get next partition number
    LAST_PART=$(get_last_partition_number "/dev/$disk")
    NEXT_PART=$((LAST_PART + 1))
    
    # Create partition
    gum style --foreground 205 "Creating partition $NEXT_PART..."
    parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$END_POS" --script
    
    # Wait for kernel to recognize new partition
    sleep 2
    partprobe "/dev/$disk"
    udevadm settle
    
    # Construct partition device name
    if [[ "$disk" =~ nvme ]]; then
        NEW_PARTITION="${disk}p${NEXT_PART}"
    else
        NEW_PARTITION="${disk}${NEXT_PART}"
    fi
    
    # Verify partition was created
    if [ -b "/dev/$NEW_PARTITION" ]; then
        gum style --foreground 46 "✓ Partition /dev/$NEW_PARTITION created successfully"
        # Continue with mountpoint selection for the new partition
        set_mountpoints_for_partition "$NEW_PARTITION"
    else
        gum style --foreground 196 "Failed to create partition"
        gum input --placeholder "Press Enter to continue..."
        set_mountpoints "$disk"
    fi
}

# Set mountpoints for a specific partition
set_mountpoints_for_partition() {
    local partition=$1
    
    gum style --foreground 46 "Setting mountpoint for /dev/$partition"
    
    # Select mountpoint
    MOUNTPOINT=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "/" \
        "/boot" \
        "/boot/efi" \
        "/home" \
        "/var" \
        "/tmp" \
        "Custom")
    
    if [ "$MOUNTPOINT" = "Custom" ]; then
        MOUNTPOINT=$(gum input --placeholder "Enter custom mountpoint (e.g., /opt)")
    fi
    
    # Check if mountpoint already exists
    if grep -q " -> $MOUNTPOINT$" /tmp/asiraos/mounts 2>/dev/null; then
        gum style --foreground 196 "Mountpoint $MOUNTPOINT already exists!"
        gum input --placeholder "Press Enter to try again..."
        set_mountpoints_for_partition "$partition"
        return
    fi
    
    # Format the new partition
    format_partition "/dev/$partition" "$MOUNTPOINT"
    
    # Save mountpoint configuration
    mkdir -p /tmp/asiraos
    echo "/dev/$partition -> $MOUNTPOINT" >> /tmp/asiraos/mounts
    gum style --foreground 46 "Mountpoint set: /dev/$partition -> $MOUNTPOINT"
    
    disk_selection
}

# Format partition based on mountpoint
format_partition() {
    local partition=$1
    local mountpoint=$2
    
    if [ "$mountpoint" = "/boot/efi" ]; then
        gum style --foreground 205 "Formatting $partition as EFI System (FAT32)..."
        mkfs.fat -F32 "$partition"
    elif [ "$mountpoint" = "/boot" ]; then
        # Check if system is EFI or BIOS
        if [ -d "/sys/firmware/efi" ]; then
            # EFI system - format as FAT32
            FS_TYPE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
                "EFI System (FAT32)")
            gum style --foreground 205 "Formatting $partition as EFI System (FAT32)..."
            mkfs.fat -F32 "$partition"
        else
            # BIOS/MBR system - show regular filesystem options
            FS_TYPE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
                "ext4" \
                "ext3" \
                "xfs" \
                "btrfs")
            
            case $FS_TYPE in
                "ext4")
                    gum style --foreground 205 "Formatting $partition as ext4..."
                    mkfs.ext4 "$partition"
                    ;;
                "ext3")
                    gum style --foreground 205 "Formatting $partition as ext3..."
                    mkfs.ext3 "$partition"
                    ;;
                "xfs")
                    gum style --foreground 205 "Formatting $partition as xfs..."
                    mkfs.xfs "$partition"
                    ;;
                "btrfs")
                    gum style --foreground 205 "Formatting $partition as btrfs..."
                    mkfs.btrfs "$partition"
                    ;;
            esac
        fi
    else
        # Ask user for filesystem type
        FS_TYPE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
            "ext4" \
            "ext3" \
            "xfs" \
            "btrfs")
        
        case $FS_TYPE in
            "ext4")
                gum style --foreground 205 "Formatting $partition as ext4..."
                mkfs.ext4 "$partition"
                ;;
            "ext3")
                gum style --foreground 205 "Formatting $partition as ext3..."
                mkfs.ext3 "$partition"
                ;;
            "xfs")
                gum style --foreground 205 "Formatting $partition as xfs..."
                mkfs.xfs "$partition"
                ;;
            "btrfs")
                gum style --foreground 205 "Formatting $partition as btrfs..."
                mkfs.btrfs "$partition"
                ;;
        esac
    fi
    gum style --foreground 46 "✓ Formatting completed"
}

# Auto Partition with proper disk detection
auto_partition() {
    show_banner
    gum style --foreground 214 "Auto Partition"
    echo ""

    # Detect boot mode
    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="EFI"
        BOOT_MOUNTPOINT="/boot/efi"
        gum style --foreground 46 "✓ EFI boot mode detected"
    else
        BOOT_MODE="BIOS"
        BOOT_MOUNTPOINT="/boot"
        gum style --foreground 46 "✓ BIOS boot mode detected"
    fi
    echo ""

    gum style --foreground 46 "Detecting available storage..."
    ALL_OPTIONS=()

    # ---- DISK SCAN ----
    while read -r disk size; do
        [ -z "$disk" ] && continue
        [[ "$disk" != /dev/* ]] && disk="/dev/$disk"
        [ ! -b "$disk" ] && continue
        disk_name=$(basename "$disk")

        ALL_OPTIONS+=("DISK|$disk_name|$size")

        # Largest free-space region for this disk (for auto partition choices).
        FREE_SPACE_INFO=$(get_free_space "$disk")
        if [ -n "$FREE_SPACE_INFO" ]; then
            free_size=$(echo "$FREE_SPACE_INFO" | awk '{print $2}')
            free_num=$(echo "$free_size" | sed 's/[^0-9.]//g')
            [ -z "$free_num" ] && free_num=0
            if awk "BEGIN {exit !($free_num > 0.01)}"; then
                ALL_OPTIONS+=("FREE|$disk_name|$free_size")
            fi
        fi

        # partitions
        while read -r p s f m; do
            [ -z "$p" ] && continue
            part_name=$(basename "$p")
            ALL_OPTIONS+=("PART|$part_name|$s|${f:-unformatted}")
        done < <(get_real_partitions "$disk")

    done < <(get_real_disks)

    [ ${#ALL_OPTIONS[@]} -eq 0 ] && {
        gum style --foreground 196 "No storage devices found"
        gum input --placeholder "Press Enter..."
        return
    }

    # ---- UI ----
    DISPLAY=()
    for opt in "${ALL_OPTIONS[@]}"; do
        IFS='|' read -r t n s f <<< "$opt"
        case "$t" in
            DISK) DISPLAY+=("$n ($s) - Whole Disk") ;;
            FREE) DISPLAY+=(" └─ free space on $n ($s)") ;;
            PART) DISPLAY+=(" └─ $n ($s, $f)") ;;
        esac
    done

    SELECTED_UI=$(gum choose "${DISPLAY[@]}")

    # ---- PARSE SELECTION SAFELY ----
    for i in "${!DISPLAY[@]}"; do
        if [ "${DISPLAY[$i]}" = "$SELECTED_UI" ]; then
            IFS='|' read -r TYPE NAME SIZE FSTYPE <<< "${ALL_OPTIONS[$i]}"
            break
        fi
    done

    echo ""
    gum style --foreground 46 "Selected: $TYPE → /dev/$NAME"

    # ---- MODE ----
    case "$TYPE" in
        DISK) MODE="wholedisk"; TARGET_DISK="$NAME" ;;
        FREE) MODE="freespace"; TARGET_DISK="$NAME" ;;
        PART) MODE="partition"; TARGET_PART="/dev/$NAME" ;;
    esac

    gum style --foreground 196 "⚠ This may ERASE data"
    CONFIRM=$(gum choose "Yes" "No")
    [ "$CONFIRM" = "No" ] && return

    # ---- PARTITION SCHEME ----
    SCHEME=$(gum choose \
        "Basic (Boot + Root)" \
        "Standard (Boot + Root + Home)")

    umount -R /mnt 2>/dev/null || true

    case "$MODE" in
        wholedisk)
            wipefs -af "/dev/$TARGET_DISK" 2>/dev/null || true
            if [ "$SCHEME" = "Standard (Boot + Root + Home)" ]; then
                create_standard_partitions_wholedisk "$TARGET_DISK"
            else
                create_basic_partitions_wholedisk "$TARGET_DISK"
            fi
            return
            ;;
        freespace)
            if [ "$SCHEME" = "Standard (Boot + Root + Home)" ]; then
                create_standard_partitions_freespace "$TARGET_DISK"
            else
                create_basic_partitions_freespace "$TARGET_DISK"
            fi
            return
            ;;
        partition)
            rm -f /tmp/asiraos/mounts
            mkdir -p /tmp/asiraos

            gum style --foreground 205 "Formatting $TARGET_PART as ext4..."
            mkfs.ext4 -F "$TARGET_PART"
            echo "$TARGET_PART -> /" >> /tmp/asiraos/mounts

            if [ "$BOOT_MODE" = "EFI" ]; then
                PARENT_DISK=$(lsblk -no PKNAME "$TARGET_PART" | head -1)
                if [ -n "$PARENT_DISK" ]; then
                    EFI_PART=$(lsblk -rno NAME,FSTYPE,PARTTYPE "/dev/$PARENT_DISK" | awk '
                        $2 ~ /vfat|fat32/ {print $1; exit}
                        $3 ~ /c12a7328-f81f-11d2-ba4b-00a0c93ec93b/ {print $1; exit}
                    ')
                    if [ -n "$EFI_PART" ]; then
                        echo "/dev/$EFI_PART -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
                    else
                        gum style --foreground 196 "EFI partition not found on /dev/$PARENT_DISK"
                        gum input --placeholder "Press Enter to continue..."
                        disk_selection
                        return
                    fi
                fi
            fi

            partition_complete
            return
            ;;
    esac
}



# Create basic partitions on whole disk
create_basic_partitions_wholedisk() {
    local disk=$1
    gum style --foreground 205 "Creating basic partitions on whole disk /dev/${disk}..."
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Unmount any existing partitions
    umount /dev/${disk}* 2>/dev/null || true
    swapoff /dev/${disk}* 2>/dev/null || true
    
    # Create new partition table
    if [ "$BOOT_MODE" = "EFI" ]; then
        gum style --foreground 205 "Creating GPT partition table..."
        parted /dev/$disk mklabel gpt --script
        
        gum style --foreground 205 "Creating EFI Boot partition (1GB)"
        parted /dev/$disk mkpart primary fat32 1MB 1025MB --script
        parted /dev/$disk set 1 boot on --script
        
        gum style --foreground 205 "Creating Root partition (remaining space)"
        parted /dev/$disk mkpart primary ext4 1025MB 100% --script
    else
        gum style --foreground 205 "Creating MBR partition table..."
        parted /dev/$disk mklabel msdos --script
        
        gum style --foreground 205 "Creating BIOS Boot partition (512MB)"
        parted /dev/$disk mkpart primary ext4 1MB 513MB --script
        parted /dev/$disk set 1 boot on --script
        
        gum style --foreground 205 "Creating Root partition (remaining space)"
        parted /dev/$disk mkpart primary ext4 513MB 100% --script
    fi
    
    # Wait for kernel to recognize partitions
    sleep 3
    partprobe /dev/$disk
    udevadm settle
    
    # Construct partition device names
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p1"
        ROOT_DEV="/dev/${disk}p2"
    else
        BOOT_DEV="/dev/${disk}1"
        ROOT_DEV="/dev/${disk}2"
    fi
    
    # Format partitions
    gum style --foreground 205 "Formatting partitions..."
    mkfs.fat -F32 "$BOOT_DEV"
    mkfs.ext4 "$ROOT_DEV"
    
    # Save mountpoints
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    
    gum style --foreground 46 "✓ Basic partitions created successfully"
    partition_complete
}

# Create standard partitions on whole disk
create_standard_partitions_wholedisk() {
    local disk=$1
    gum style --foreground 205 "Creating standard partitions on whole disk /dev/${disk}..."
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Unmount any existing partitions
    umount /dev/${disk}* 2>/dev/null || true
    swapoff /dev/${disk}* 2>/dev/null || true
    
    # Create new partition table
    if [ "$BOOT_MODE" = "EFI" ]; then
        parted /dev/$disk mklabel gpt --script
        
        gum style --foreground 205 "Creating EFI Boot partition (1GB)"
        parted /dev/$disk mkpart primary fat32 1MB 1025MB --script
        parted /dev/$disk set 1 boot on --script
        
        gum style --foreground 205 "Creating Root partition (30GB)"
        parted /dev/$disk mkpart primary ext4 1025MB 31745MB --script
        
        gum style --foreground 205 "Creating Home partition (remaining space)"
        parted /dev/$disk mkpart primary ext4 31745MB 100% --script
    else
        parted /dev/$disk mklabel msdos --script
        
        gum style --foreground 205 "Creating BIOS Boot partition (512MB)"
        parted /dev/$disk mkpart primary ext4 1MB 513MB --script
        parted /dev/$disk set 1 boot on --script
        
        gum style --foreground 205 "Creating Root partition (30GB)"
        parted /dev/$disk mkpart primary ext4 513MB 31233MB --script
        
        gum style --foreground 205 "Creating Home partition (remaining space)"
        parted /dev/$disk mkpart primary ext4 31233MB 100% --script
    fi
    
    # Wait for kernel to recognize partitions
    sleep 3
    partprobe /dev/$disk
    udevadm settle
    
    # Construct partition device names
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p1"
        ROOT_DEV="/dev/${disk}p2"
        HOME_DEV="/dev/${disk}p3"
    else
        BOOT_DEV="/dev/${disk}1"
        ROOT_DEV="/dev/${disk}2"
        HOME_DEV="/dev/${disk}3"
    fi
    
    # Format partitions
    gum style --foreground 205 "Formatting partitions..."
    mkfs.fat -F32 "$BOOT_DEV"
    mkfs.ext4 "$ROOT_DEV"
    mkfs.ext4 "$HOME_DEV"
    
    # Save mountpoints
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    echo "$HOME_DEV -> /home" >> /tmp/asiraos/mounts
    
    gum style --foreground 46 "✓ Standard partitions created successfully"
    partition_complete
}

# Create custom partitions on whole disk
create_custom_partitions_wholedisk() {
    local disk=$1
    echo -e "${CYAN}Creating custom partitions on whole disk /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Ask for additional partitions
    ADDITIONAL_PARTITIONS=$(gum choose --no-limit --cursor-prefix "> " --selected-prefix "* " \
        "Home partition" \
        "Var partition" \
        "Tmp partition")
    
    # Unmount any existing partitions
    umount /dev/${disk}* 2>/dev/null || true
    swapoff /dev/${disk}* 2>/dev/null || true
    
    # Create new partition table
    if [ "$BOOT_MODE" = "EFI" ]; then
        parted /dev/$disk mklabel gpt --script
        
        echo -e "${CYAN}- Creating EFI Boot partition (1GB)${NC}"
        parted /dev/$disk mkpart primary fat32 1MB 1025MB --script
        parted /dev/$disk set 1 boot on --script
        
        echo -e "${CYAN}- Creating Root partition (30GB)${NC}"
        parted /dev/$disk mkpart primary ext4 1025MB 31745MB --script
        
        local next_start=31745
        local part_num=3
    else
        parted /dev/$disk mklabel msdos --script
        
        echo -e "${CYAN}- Creating BIOS Boot partition (512MB)${NC}"
        parted /dev/$disk mkpart primary ext4 1MB 513MB --script
        parted /dev/$disk set 1 boot on --script
        
        echo -e "${CYAN}- Creating Root partition (30GB)${NC}"
        parted /dev/$disk mkpart primary ext4 513MB 31233MB --script
        
        local next_start=31233
        local part_num=3
    fi
    
    # Create additional partitions
    if [[ $ADDITIONAL_PARTITIONS == *"Var partition"* ]]; then
        echo -e "${CYAN}- Creating Var partition (10GB)${NC}"
        local var_end=$((next_start + 10240))
        parted /dev/$disk mkpart primary ext4 ${next_start}MB ${var_end}MB --script
        next_start=$var_end
        ((part_num++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Tmp partition"* ]]; then
        echo -e "${CYAN}- Creating Tmp partition (5GB)${NC}"
        local tmp_end=$((next_start + 5120))
        parted /dev/$disk mkpart primary ext4 ${next_start}MB ${tmp_end}MB --script
        next_start=$tmp_end
        ((part_num++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Home partition"* ]]; then
        echo -e "${CYAN}- Creating Home partition (remaining space)${NC}"
        parted /dev/$disk mkpart primary ext4 ${next_start}MB 100% --script
        ((part_num++))
    fi
    
    # Wait for kernel to recognize partitions
    sleep 3
    partprobe /dev/$disk
    udevadm settle
    
    # Format and save mountpoints
    local current_part=1
    
    # Boot partition
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p${current_part}"
    else
        BOOT_DEV="/dev/${disk}${current_part}"
    fi
    
    mkfs.fat -F32 "$BOOT_DEV"
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    ((current_part++))
    
    # Root partition
    if [[ "$disk" =~ nvme ]]; then
        ROOT_DEV="/dev/${disk}p${current_part}"
    else
        ROOT_DEV="/dev/${disk}${current_part}"
    fi
    mkfs.ext4 "$ROOT_DEV"
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    ((current_part++))
    
    # Additional partitions
    if [[ $ADDITIONAL_PARTITIONS == *"Var partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            VAR_DEV="/dev/${disk}p${current_part}"
        else
            VAR_DEV="/dev/${disk}${current_part}"
        fi
        mkfs.ext4 "$VAR_DEV"
        echo "$VAR_DEV -> /var" >> /tmp/asiraos/mounts
        ((current_part++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Tmp partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            TMP_DEV="/dev/${disk}p${current_part}"
        else
            TMP_DEV="/dev/${disk}${current_part}"
        fi
        mkfs.ext4 "$TMP_DEV"
        echo "$TMP_DEV -> /tmp" >> /tmp/asiraos/mounts
        ((current_part++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Home partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            HOME_DEV="/dev/${disk}p${current_part}"
        else
            HOME_DEV="/dev/${disk}${current_part}"
        fi
        mkfs.ext4 "$HOME_DEV"
        echo "$HOME_DEV -> /home" >> /tmp/asiraos/mounts
        ((current_part++))
    fi
    
    echo -e "${GREEN}✓ Custom partitions created successfully${NC}"
    partition_complete
}

# Create basic partitions in free space - FIXED VERSION
create_basic_partitions_freespace() {
    local disk=$1
    
    echo -e "${CYAN}Creating basic partitions in free space on /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Get real free space information
    FREE_SPACE_INFO=$(get_free_space "/dev/$disk")
    if [ -z "$FREE_SPACE_INFO" ]; then
        gum style --foreground 196 "ERROR: No free space found on /dev/$disk"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    FREE_START=$(echo "$FREE_SPACE_INFO" | awk '{print $1}')
    FREE_SIZE=$(echo "$FREE_SPACE_INFO" | awk '{print $2}')
    
    if [ "$FREE_SIZE" = "0GB" ] || [ "$FREE_SIZE" = "0.00GB" ]; then
        gum style --foreground 196 "ERROR: No usable free space available"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    echo -e "${GREEN}Found free space: $FREE_SIZE starting at $FREE_START${NC}"
    
    # Get next available partition numbers
    LAST_PART=$(get_last_partition_number "/dev/$disk")
    BOOT_PART=$((LAST_PART + 1))
    ROOT_PART=$((LAST_PART + 2))
    
    echo -e "${GREEN}Will create partitions: $BOOT_PART (boot) and $ROOT_PART (root)${NC}"
    
    # Unmount any existing partitions on this disk
    umount /dev/${disk}* 2>/dev/null || true
    swapoff /dev/${disk}* 2>/dev/null || true
    
    # Create partitions based on boot mode
    if [ "$BOOT_MODE" = "EFI" ]; then
        # Calculate boot partition end (1GB from start)
        BOOT_SIZE_GB=1
        BOOT_END=$(echo "$FREE_START" | sed 's/GB//' | awk -v size="$BOOT_SIZE_GB" '{printf "%.2fGB", $1 + size}')
        
        echo -e "${CYAN}Creating EFI boot partition: $FREE_START to $BOOT_END${NC}"
        parted "/dev/$disk" mkpart primary fat32 "$FREE_START" "$BOOT_END" --script
        parted "/dev/$disk" set "$BOOT_PART" boot on --script
        
        echo -e "${CYAN}Creating root partition: $BOOT_END to end of free space${NC}"
        parted "/dev/$disk" mkpart primary ext4 "$BOOT_END" "100%" --script
    else
        # BIOS mode - 512MB boot partition
        BOOT_SIZE_GB=0.5
        BOOT_END=$(echo "$FREE_START" | sed 's/GB//' | awk -v size="$BOOT_SIZE_GB" '{printf "%.2fGB", $1 + size}')
        
        echo -e "${CYAN}Creating BIOS boot partition: $FREE_START to $BOOT_END${NC}"
        parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$BOOT_END" --script
        parted "/dev/$disk" set "$BOOT_PART" boot on --script
        
        echo -e "${CYAN}Creating root partition: $BOOT_END to end of free space${NC}"
        parted "/dev/$disk" mkpart primary ext4 "$BOOT_END" "100%" --script
    fi
    
    # Wait for kernel to recognize new partitions
    echo -e "${CYAN}Waiting for system to recognize new partitions...${NC}"
    sleep 3
    partprobe "/dev/$disk"
    udevadm settle
    sleep 2
    
    # Construct partition device names
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p${BOOT_PART}"
        ROOT_DEV="/dev/${disk}p${ROOT_PART}"
    else
        BOOT_DEV="/dev/${disk}${BOOT_PART}"
        ROOT_DEV="/dev/${disk}${ROOT_PART}"
    fi
    
    # Verify partitions were created
    if [ ! -b "$BOOT_DEV" ]; then
        gum style --foreground 196 "ERROR: Boot partition $BOOT_DEV was not created"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    if [ ! -b "$ROOT_DEV" ]; then
        gum style --foreground 196 "ERROR: Root partition $ROOT_DEV was not created"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    # Format partitions
    echo -e "${CYAN}Formatting partitions...${NC}"
    echo -e "${GREEN}Formatting $BOOT_DEV as FAT32...${NC}"
    mkfs.fat -F32 "$BOOT_DEV"
    
    echo -e "${GREEN}Formatting $ROOT_DEV as ext4...${NC}"
    mkfs.ext4 "$ROOT_DEV"
    
    # Save mountpoints
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    
    echo -e "${GREEN}✓ Basic partitions created successfully in free space${NC}"
    echo -e "${GREEN}Boot: $BOOT_DEV -> $BOOT_MOUNTPOINT${NC}"
    echo -e "${GREEN}Root: $ROOT_DEV -> /${NC}"
    
    partition_complete
}

# Create standard partitions in free space - FIXED VERSION
create_standard_partitions_freespace() {
    local disk=$1
    echo -e "${CYAN}Creating standard partitions in free space on /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Get real free space information
    FREE_SPACE_INFO=$(get_free_space "/dev/$disk")
    if [ -z "$FREE_SPACE_INFO" ]; then
        gum style --foreground 196 "ERROR: No free space found"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    FREE_START=$(echo "$FREE_SPACE_INFO" | awk '{print $1}')
    FREE_SIZE=$(echo "$FREE_SPACE_INFO" | awk '{print $2}')
    
    # Get next available partition numbers
    LAST_PART=$(get_last_partition_number "/dev/$disk")
    BOOT_PART=$((LAST_PART + 1))
    ROOT_PART=$((LAST_PART + 2))
    HOME_PART=$((LAST_PART + 3))
    
    # Create partitions
    if [ "$BOOT_MODE" = "EFI" ]; then
        BOOT_END=$(echo "$FREE_START" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 1}')
        ROOT_END=$(echo "$BOOT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 30}')
        
        parted "/dev/$disk" mkpart primary fat32 "$FREE_START" "$BOOT_END" --script
        parted "/dev/$disk" set "$BOOT_PART" boot on --script
        parted "/dev/$disk" mkpart primary ext4 "$BOOT_END" "$ROOT_END" --script
        parted "/dev/$disk" mkpart primary ext4 "$ROOT_END" "100%" --script
    else
        BOOT_END=$(echo "$FREE_START" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 0.5}')
        ROOT_END=$(echo "$BOOT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 30}')
        
        parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$BOOT_END" --script
        parted "/dev/$disk" set "$BOOT_PART" boot on --script
        parted "/dev/$disk" mkpart primary ext4 "$BOOT_END" "$ROOT_END" --script
        parted "/dev/$disk" mkpart primary ext4 "$ROOT_END" "100%" --script
    fi
    
    # Wait for kernel recognition
    sleep 3
    partprobe "/dev/$disk"
    udevadm settle
    
    # Construct device names
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p${BOOT_PART}"
        ROOT_DEV="/dev/${disk}p${ROOT_PART}"
        HOME_DEV="/dev/${disk}p${HOME_PART}"
    else
        BOOT_DEV="/dev/${disk}${BOOT_PART}"
        ROOT_DEV="/dev/${disk}${ROOT_PART}"
        HOME_DEV="/dev/${disk}${HOME_PART}"
    fi
    
    # Format partitions
    mkfs.fat -F32 "$BOOT_DEV"
    mkfs.ext4 "$ROOT_DEV"
    mkfs.ext4 "$HOME_DEV"
    
    # Save mountpoints
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    echo "$HOME_DEV -> /home" >> /tmp/asiraos/mounts
    
    echo -e "${GREEN}✓ Standard partitions created successfully in free space${NC}"
    partition_complete
}

# Create custom partitions in free space - FIXED VERSION
create_custom_partitions_freespace() {
    local disk=$1
    echo -e "${CYAN}Creating custom partitions in free space on /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Ask for additional partitions first
    ADDITIONAL_PARTITIONS=$(gum choose --no-limit --cursor-prefix "> " --selected-prefix "* " \
        "Home partition" \
        "Var partition" \
        "Tmp partition")
    
    # Get real free space information
    FREE_SPACE_INFO=$(get_free_space "/dev/$disk")
    if [ -z "$FREE_SPACE_INFO" ]; then
        gum style --foreground 196 "ERROR: No free space found"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    FREE_START=$(echo "$FREE_SPACE_INFO" | awk '{print $1}')
    
    # Get next available partition numbers
    LAST_PART=$(get_last_partition_number "/dev/$disk")
    PART_NUM=$((LAST_PART + 1))
    
    # Create boot partition
    if [ "$BOOT_MODE" = "EFI" ]; then
        CURRENT_END=$(echo "$FREE_START" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 1}')
        parted "/dev/$disk" mkpart primary fat32 "$FREE_START" "$CURRENT_END" --script
        parted "/dev/$disk" set "$PART_NUM" boot on --script
    else
        CURRENT_END=$(echo "$FREE_START" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 0.5}')
        parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$CURRENT_END" --script
        parted "/dev/$disk" set "$PART_NUM" boot on --script
    fi
    
    BOOT_PART=$PART_NUM
    ((PART_NUM++))
    
    # Create root partition (30GB)
    ROOT_END=$(echo "$CURRENT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 30}')
    parted "/dev/$disk" mkpart primary ext4 "$CURRENT_END" "$ROOT_END" --script
    ROOT_PART=$PART_NUM
    ((PART_NUM++))
    CURRENT_END=$ROOT_END
    
    # Create additional partitions
    if [[ $ADDITIONAL_PARTITIONS == *"Var partition"* ]]; then
        VAR_END=$(echo "$CURRENT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 10}')
        parted "/dev/$disk" mkpart primary ext4 "$CURRENT_END" "$VAR_END" --script
        VAR_PART=$PART_NUM
        ((PART_NUM++))
        CURRENT_END=$VAR_END
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Tmp partition"* ]]; then
        TMP_END=$(echo "$CURRENT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 5}')
        parted "/dev/$disk" mkpart primary ext4 "$CURRENT_END" "$TMP_END" --script
        TMP_PART=$PART_NUM
        ((PART_NUM++))
        CURRENT_END=$TMP_END
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Home partition"* ]]; then
        parted "/dev/$disk" mkpart primary ext4 "$CURRENT_END" "100%" --script
        HOME_PART=$PART_NUM
        ((PART_NUM++))
    fi
    
    # Wait for kernel recognition
    sleep 3
    partprobe "/dev/$disk"
    udevadm settle
    
    # Format and save mountpoints
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p${BOOT_PART}"
        ROOT_DEV="/dev/${disk}p${ROOT_PART}"
    else
        BOOT_DEV="/dev/${disk}${BOOT_PART}"
        ROOT_DEV="/dev/${disk}${ROOT_PART}"
    fi
    
    # Format boot and root
    mkfs.fat -F32 "$BOOT_DEV"
    mkfs.ext4 "$ROOT_DEV"
    
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    
    # Format additional partitions
    if [[ $ADDITIONAL_PARTITIONS == *"Var partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            VAR_DEV="/dev/${disk}p${VAR_PART}"
        else
            VAR_DEV="/dev/${disk}${VAR_PART}"
        fi
        mkfs.ext4 "$VAR_DEV"
        echo "$VAR_DEV -> /var" >> /tmp/asiraos/mounts
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Tmp partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            TMP_DEV="/dev/${disk}p${TMP_PART}"
        else
            TMP_DEV="/dev/${disk}${TMP_PART}"
        fi
        mkfs.ext4 "$TMP_DEV"
        echo "$TMP_DEV -> /tmp" >> /tmp/asiraos/mounts
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Home partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            HOME_DEV="/dev/${disk}p${HOME_PART}"
        else
            HOME_DEV="/dev/${disk}${HOME_PART}"
        fi
        mkfs.ext4 "$HOME_DEV"
        echo "$HOME_DEV -> /home" >> /tmp/asiraos/mounts
    fi
    
    echo -e "${GREEN}✓ Custom partitions created successfully in free space${NC}"
    partition_complete
}

# Partition completion
partition_complete() {
    gum style --foreground 46 "Partitioning completed successfully!"
    echo ""
    gum style --foreground 46 "Created mountpoints:"
    if [ -f "/tmp/asiraos/mounts" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && gum style --foreground 46 "$line"
        done < /tmp/asiraos/mounts
    fi
    echo ""
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "🚀 Continue to Disk Selection" \
        "View Partition Details")
    
    case $CHOICE in
        "🚀 Continue to Disk Selection")
            disk_selection
            ;;
        "View Partition Details")
            gum style --foreground 214 "Current partition layout:"
            while IFS= read -r line; do
                [ -n "$line" ] && gum style --foreground 46 "$line"
            done < <(lsblk)
            gum input --placeholder "Press Enter to continue..."
            disk_selection
            ;;
    esac
}
