#!/usr/bin/env bash

set -e

exec &> >(tee "configure.log")

print () {
    echo -e "\n\033[1m> $1\033[0m\n"
}

ask () {
    read -p "> $1 " -r
    echo
}

menu () {
    PS3="> Choose a number: "
    select i in "$@"
    do
        echo "$i"
        break
    done
}

# Tests
tests () {
    ls /sys/firmware/efi/efivars > /dev/null && \
        ping voidlinux.org -c 1 > /dev/null &&  \
        modprobe zfs &&                         \
        print "Tests ok"
}

select_disks () {
    # Set DISKS
    print "Select two disks for ZFS mirror pool:"
    select ENTRY in $(ls /dev/disk/by-id/);
    do
        DISK1="/dev/disk/by-id/$ENTRY"
        echo "$DISK1" > /tmp/disk1
        echo "First disk: $ENTRY"
        break
    done

    select ENTRY in $(ls /dev/disk/by-id/);
    do
        DISK2="/dev/disk/by-id/$ENTRY"
        echo "$DISK2" > /tmp/disk2
        echo "Second disk: $ENTRY"
        break
    done
}

wipe () {
    ask "Do you want to wipe all data on $DISK1 and $DISK2 ?"
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        # Clear disks
        dd if=/dev/zero of="$DISK1" bs=512 count=1
        dd if=/dev/zero of="$DISK2" bs=512 count=1
        wipefs -af "$DISK1" "$DISK2"
        sgdisk -Zo "$DISK1"
        sgdisk -Zo "$DISK2"
    fi
}

partition () {
    # EFI part on both disks
    print "Creating EFI partitions on both disks"
    sgdisk -n1:1M:+512M -t1:EF00 "$DISK1"
    sgdisk -n1:1M:+512M -t1:EF00 "$DISK2"
    EFI1="$DISK1-part1"
    EFI2="$DISK2-part1"

    # ZFS parts on both disks
    print "Creating ZFS partitions on both disks"
    sgdisk -n3:0:0 -t3:bf01 "$DISK1"
    sgdisk -n3:0:0 -t3:bf01 "$DISK2"
    ZFS1="$DISK1-part3"
    ZFS2="$DISK2-part3"

    # Inform kernel
    partprobe "$DISK1" "$DISK2"

    # Format EFI parts
    sleep 1
    print "Format EFI partitions"
    mkfs.vfat "$EFI1"
    mkfs.vfat "$EFI2"
}

zfs_passphrase () {
    # Generate key
    print "Set ZFS passphrase"
    read -r -p "> ZFS passphrase: " -s pass
    echo
    echo "$pass" > /etc/zfs/zroot.key
    chmod 000 /etc/zfs/zroot.key
}

create_pool () {
    # Create ZFS pool with mirror
    print "Create ZFS pool with mirror"
    zpool create -f -o ashift=12                          \
                 -o autotrim=on                           \
                 -O acltype=posixacl                      \
                 -O compression=zstd                      \
                 -O relatime=on                           \
                 -O xattr=sa                              \
                 -O dnodesize=legacy                      \
                 -O encryption=aes-256-gcm                \
                 -O keyformat=passphrase                  \
                 -O keylocation=file:///etc/zfs/zroot.key \
                 -O normalization=formD                   \
                 -O mountpoint=none                       \
                 -O canmount=off                          \
                 -O devices=off                           \
                 -R /mnt                                  \
                 zroot mirror "$ZFS1" "$ZFS2"
}

create_root_dataset () {
    # Slash dataset
    print "Create root dataset"
    zfs create -o mountpoint=none                 zroot/ROOT

    # Set cmdline
    zfs set org.zfsbootmenu:commandline="ro quiet" zroot/ROOT
}

create_system_dataset () {
    print "Create slash dataset"
    zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/"$1"

    # Generate zfs hostid
    print "Generate hostid"
    zgenhostid

    # Set bootfs
    print "Set ZFS bootfs"
    zpool set bootfs="zroot/ROOT/$1" zroot

    # Manually mount slash dataset
    zfs mount zroot/ROOT/"$1"

    # Create XBPS cache dataset under var
    zfs create -o compression=off zroot/ROOT/"$1"/var/cache/xbps
}

create_home_dataset () {
    print "Create home dataset"
    zfs create -o mountpoint=/ -o canmount=off zroot/data
    zfs create                                 zroot/data/home
    zfs create -o mountpoint=/root             zroot/data/home/root
}

export_pool () {
    print "Export zpool"
    zpool export zroot
}

import_pool () {
    print "Import zpool"
    zpool import -d /dev/disk/by-id -R /mnt zroot -N -f
    zfs load-key zroot
}

mount_system () {
    print "Mount slash dataset"
    zfs mount zroot/ROOT/"$1"
    zfs mount -a

    # Mount EFI parts
    print "Mount EFI parts"
    EFI1="$DISK1-part1"
    EFI2="$DISK2-part1"
    mkdir -p /mnt/efi
    mount "$EFI1" /mnt/efi
    mkdir -p /mnt/efi2
    mount "$EFI2" /mnt/efi2
}

copy_zpool_cache () {
    # Copy ZFS cache
    print "Generate and copy zfs cache"
    mkdir -p /mnt/etc/zfs
    zpool set cachefile=/etc/zfs/zpool.cache zroot
}

# Main

tests

print "Is this the first install or a second install to dualboot ?"
install_reply=$(menu first dualboot)

select_disks
zfs_passphrase

# If first install
if [[ $install_reply == "first" ]]
then
    # Wipe the disks
    wipe
    # Create partition tables
    partition
    # Create ZFS pool
    create_pool
    # Create root dataset
    create_root_dataset
fi

ask "Name of the slash dataset ?"
name_reply="$REPLY"
echo "$name_reply" > /tmp/root_dataset

if [[ $install_reply == "dualboot" ]]
then
    import_pool
fi

create_system_dataset "$name_reply"

if [[ $install_reply == "first" ]]
then
    create_home_dataset
fi

export_pool
import_pool
mount_system "$name_reply"
copy_zpool_cache

# Finish
echo -e "\e[32mAll OK"
