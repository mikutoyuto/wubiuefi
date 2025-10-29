#!/bin/sh
set -x

# --- Start: UEFI Boot Entry Creation ---

# 1. Get the actual OS Name from the installed system
#    The installed system is mounted at /target
OS_NAME=""
if [ -f /target/etc/os-release ]; then
    # Try getting the pretty name first
    OS_NAME=$(grep '^PRETTY_NAME=' /target/etc/os-release | cut -d'"' -f2)
    # Fallback to the basic name if pretty name isn't found
    [ -z "$OS_NAME" ] && OS_NAME=$(grep '^NAME=' /target/etc/os-release | cut -d'"' -f2)
fi
# Final fallback if reading os-release failed
[ -z "$OS_NAME" ] && OS_NAME="Ubuntu (Wubi)"

echo "Determined OS Name: $OS_NAME" # Debug output

# 2. Define the target EFI loader path
EFI_LOADER_PATH="\\EFI\\ubuntu\\wubildr\\shimx64.efi" # Path format for efibootmgr -l
EFI_LOADER_PATH_GREP="EFI/ubuntu/wubildr/shimx64.efi" # Path format for grep

# 3. Find the ESP (EFI System Partition) device and partition number
#    Assuming Ubiquity mounted it at /target/boot/efi during install
ESP_MOUNT_POINT="/target/boot/efi"
ESP_DEVICE=$(df "$ESP_MOUNT_POINT" 2>/dev/null | tail -n 1 | awk '{print $1}')

if [ -z "$ESP_DEVICE" ] || [ ! -b "$ESP_DEVICE" ]; then
    echo "Error: Could not determine ESP device from $ESP_MOUNT_POINT. Skipping UEFI modification." >&2 # Error message in English
else
    # Extract disk and partition number (e.g., /dev/nvme0n1p1 -> /dev/nvme0n1 and 1)
    ESP_DISK=$(echo "$ESP_DEVICE" | sed -E 's/p?[0-9]+$//')
    ESP_PART_NUM=$(echo "$ESP_DEVICE" | grep -oE '[0-9]+$')

    echo "Determined ESP Device: $ESP_DEVICE, Disk: $ESP_DISK, Partition: $ESP_PART_NUM" # Debug output

    if [ -z "$ESP_DISK" ] || [ -z "$ESP_PART_NUM" ]; then
        echo "Error: Could not parse ESP disk/partition number from $ESP_DEVICE. Skipping UEFI modification." >&2 # Error message in English
    else
        # 5. Create the new, correctly named UEFI entry
        echo "Creating new UEFI entry: '$OS_NAME'" # Debug output
        efibootmgr -c -d "$ESP_DISK" -p "$ESP_PART_NUM" -L "$OS_NAME" -l "$EFI_LOADER_PATH"

        if [ $? -ne 0 ]; then
            echo "Error: Failed to create new UEFI entry for '$OS_NAME'." >&2 # Error message in English
        else
            echo "Successfully created new UEFI entry." # Debug output

            # 6. Set the new entry to be the first boot option
            #    Need to get the exact number assigned
            NEW_BOOT_NUM=$(efibootmgr | grep "$OS_NAME" | grep -i "$EFI_LOADER_PATH_GREP" | head -n 1 | grep -oE '^Boot[0-9A-F]+' | sed 's/Boot//')
            CURRENT_BOOT_ORDER=$(efibootmgr | grep '^BootOrder:' | sed 's/BootOrder: //')

            if [ -n "$NEW_BOOT_NUM" ] && [ -n "$CURRENT_BOOT_ORDER" ]; then
                # Remove the new number from the current order (if present) and prepend it
                CLEANED_ORDER=$(echo "$CURRENT_BOOT_ORDER" | sed "s/$NEW_BOOT_NUM,//g" | sed "s/,$NEW_BOOT_NUM//g")
                # Handle case where the order might become empty if only the new entry existed before cleaning
                if [ "$CLEANED_ORDER" = "$NEW_BOOT_NUM" ]; then CLEANED_ORDER=""; fi
                # Prepend the new boot number
                if [ -n "$CLEANED_ORDER" ]; then
                    NEW_BOOT_ORDER="$NEW_BOOT_NUM,$CLEANED_ORDER"
                else
                    NEW_BOOT_ORDER="$NEW_BOOT_NUM"
                fi

                echo "Setting new boot order: $NEW_BOOT_ORDER" # Debug output
                efibootmgr -o "$NEW_BOOT_ORDER"
                if [ $? -ne 0 ]; then
                     echo "Warning: Failed to set boot order." >&2 # Warning message in English
                fi
            else
                echo "Warning: Could not get new boot number or current boot order. Boot order not changed." >&2 # Warning message in English
            fi

            # 7. Set UEFI Boot Menu Timeout to 0 seconds
            echo "Setting UEFI boot menu timeout to 0 seconds..." # Debug output
            efibootmgr -t 0
            if [ $? -ne 0 ]; then
                echo "Warning: Failed to set boot timeout." >&2 # Warning message in English
            fi
        fi
    fi
fi

# --- End: UEFI Boot Entry Creation ---

#Override target
if [ -d /custom-installation ]; then 
    cp -af /custom-installation/target-override/* /target/ || true
    rm -rf /custom-installation/target-override* || true
fi

#usplash.conf is sometimes incorrect 
#https://bugs.launchpad.net/ubuntu/+source/ubiquity/+bug/150930
#better wrong geometry than black screen
#~ echo '
#~ xres=1024
#~ yres=768
#~ ' > /etc/usplash.conf

#Install external packages
if [ -d /custom-installation/packages ]; then 
    cp -af /custom-installation/packages /target/tmp/custom-packages || true
    mount -o bind /proc /target/proc || true
    mount -o bind /dev /target/dev || true 
    for package in $(ls /custom-installation/packages); do
        package=$(basename $package)
        chroot /target /usr/bin/dpkg -i /tmp/custom-packages/$package || true
    done
    umount /target/proc || true
    umount /target/dev || true 
fi

#remove preseed file and menu.lst
#rm /host/ubuntu/install/custom-installation/preseed.cfg || true
#rm /host/ubuntu/install/boot/grub/menu.lst || true
rm -rf /host/ubuntu/install || true

