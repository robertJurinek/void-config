#!/bin/bash

set -e
exec &> >(tee "install.log")

# Debug
if [[ "$1" == "debug" ]]
then
    set -x
    debug=1
fi

print () {
    echo -e "\n\033[1m> $1\033[0m\n"
    if [[ -n "$debug" ]]
    then
      read -rp "press enter to continue"
    fi
}

# Root dataset
root_dataset=$(cat /tmp/root_dataset)

# Set mirrors and architecture
REPO=https://repo-de.voidlinux.org/current
ARCH=x86_64

# Copy keys
print 'Copy xbps keys'
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

### Install base system
print 'Install Void Linux'
XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" \
  base-system \
  void-repo-nonfree \

# Init chroot
print 'Init chroot'
mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc

# Disable gummiboot post install hooks, only installs for generate-zbm
echo "GUMMIBOOT_DISABLE=1" > /mnt/etc/default/gummiboot

# Install packages
print 'Install packages'
packages=(
  intel-ucode
  zfs
  zfsbootmenu
  efibootmgr
  gummiboot # required by zfsbootmenu
  chrony # ntp
  cronie # cron
  seatd # minimal seat management daemon, required by sway
  acpid # power management
  socklog-void # syslog daemon
  iwd # wifi daemon
  dhclient
  openresolv # dns
  git
  xorg 
)

XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" "${packages[@]}"

# Set hostname
read -r -p 'Please enter hostname : ' hostname
echo "$hostname" > /mnt/etc/hostname

# Configure zfs
print 'Copy ZFS files'
cp /etc/hostid /mnt/etc/hostid
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
cp /etc/zfs/zroot.key /mnt/etc/zfs

# Configure iwd
cat > /mnt/etc/iwd/main.conf <<"EOF"
[General]
UseDefaultInterface=true
EnableNetworkConfiguration=true
EOF

# Configure DNS
cat >> /mnt/etc/resolvconf.conf <<"EOF"
resolv_conf=/etc/resolv.conf
name_servers_append="1.1.1.1 9.9.9.9"
name_server_blacklist="192.168.*"
EOF

# Enable ip forward
cat > /mnt/etc/sysctl.conf <<"EOF"
net.ipv4.ip_forward = 1
EOF

# Prepare locales and keymap
print 'Prepare locales and keymap'
echo 'KEYMAP=us' > /mnt/etc/vconsole.conf
echo 'en_US.UTF-8 UTF-8' > /mnt/etc/default/libc-locales
echo 'LANG="en_US.UTF-8"' > /mnt/etc/locale.conf

# Configure system
cat >> /mnt/etc/rc.conf << EOF
KEYMAP="us"
TIMEZONE="Europe/Bratislava"
HARDWARECLOCK="UTC"
EOF

# Configure dracut
print 'Configure dracut'
cat > /mnt/etc/dracut.conf.d/zol.conf <<"EOF"
hostonly="yes"
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs resume "
install_items+=" /etc/zfs/zroot.key "
EOF

### Configure username
print 'Set your username'
read -r -p "Username: " user

### Chroot
print 'Chroot to configure services'
chroot /mnt/ /bin/bash -e <<EOF
  # Configure DNS
  resolvconf -u

  # Configure services
  ln -s /etc/sv/dhcpcd-eth0 /etc/runit/runsvdir/default/
  ln -s /etc/sv/iwd /etc/runit/runsvdir/default/
  ln -s /etc/sv/chronyd /etc/runit/runsvdir/default/
  ln -s /etc/sv/crond /etc/runit/runsvdir/default/
  ln -s /etc/sv/dbus /etc/runit/runsvdir/default/
  ln -s /etc/sv/seatd /etc/runit/runsvdir/default/
  ln -s /etc/sv/acpid /etc/runit/runsvdir/default/
  ln -s /etc/sv/socklog-unix /etc/runit/runsvdir/default/
  ln -s /etc/sv/nanoklogd /etc/runit/runsvdir/default/

  # Generates locales
  xbps-reconfigure -f glibc-locales

  # Add user
  zfs create zroot/data/home/${user}
  useradd -m ${user} -G network,wheel,socklog,video,audio,_seatd,input
  chown -R ${user}:${user} /home/${user}

  # Configure fstab
  grep efi1 /proc/mounts > /etc/fstab
  grep efi2 /proc/mounts >> /etc/fstab
EOF

# Configure fstab
print 'Configure fstab'
cat >> /mnt/etc/fstab <<"EOF"
tmpfs     /dev/shm                  tmpfs     rw,nosuid,nodev,noexec,inode64  0 0
tmpfs     /tmp                      tmpfs     defaults,nosuid,nodev           0 0
efivarfs  /sys/firmware/efi/efivars efivarfs  defaults                        0 0
EOF

# Set root passwd
print 'Set root password'
chroot /mnt /bin/passwd

# Set user passwd
print 'Set user password'
chroot /mnt /bin/passwd "$user"

# Configure sudo
print 'Configure sudo'
cat > /mnt/etc/sudoers <<EOF
root ALL=(ALL) ALL
$user ALL=(ALL) ALL
Defaults rootpw
EOF

### Configure zfsbootmenu

# Create dirs for EFI partitions
mkdir -p /mnt/efi1/EFI/ZBM /mnt/efi2/EFI/ZBM
mkdir -p /etc/zfsbootmenu/dracut.conf.d

# Configure zfsbootmenu for disk1
print 'Configure zfsbootmenu for disk1'
cat > /mnt/etc/zfsbootmenu/config.yaml <<EOF
Global:
  ManageImages: true
  BootMountPoint: /efi1
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
Components:
  Enabled: false
EFI:
  ImageDir: /efi1/EFI/ZBM
  Versions: false
  Enabled: true
Kernel:
  CommandLine: ro quiet loglevel=0
  Prefix: vmlinuz
EOF

# Configure zfsbootmenu for disk2
print 'Configure zfsbootmenu for disk2'
cat > /mnt/etc/zfsbootmenu/config_disk2.yaml <<EOF
Global:
  ManageImages: true
  BootMountPoint: /efi2
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
Components:
  Enabled: false
EFI:
  ImageDir: /efi2/EFI/ZBM
  Versions: false
  Enabled: true
Kernel:
  CommandLine: ro quiet loglevel=0
  Prefix: vmlinuz
EOF

# Generate ZBM for disk1
print 'Generate ZBM for disk1'
chroot /mnt/ /bin/bash -e <<"EOF"
  # Export locale
  export LANG="en_US.UTF-8"
  # Generate initramfs, zfsbootmenu for disk1
  xbps-reconfigure -fa
EOF

# Generate ZBM for disk2
print 'Generate ZBM for disk2'
chroot /mnt/ /bin/bash -e <<"EOF"
  # Export locale
  export LANG="en_US.UTF-8"
  # Generate initramfs, zfsbootmenu for disk2
  xbps-reconfigure -fa -C /etc/zfsbootmenu/config_disk2.yaml
EOF

# Set DISKS
if [[ -f /tmp/disk1 && -f /tmp/disk2 ]]
then
  DISK1=$(cat /tmp/disk1)
  DISK2=$(cat /tmp/disk2)
else
  print 'Select the disks you installed on:'
  select ENTRY in $(ls /dev/disk/by-id/);
  do
      DISK1="/dev/disk/by-id/$ENTRY"
      echo "Creating boot entries on $ENTRY."
      break
  done

  select ENTRY in $(ls /dev/disk/by-id/);
  do
      DISK2="/dev/disk/by-id/$ENTRY"
      echo "Creating boot entries on $ENTRY."
      break
  done
fi

# Create UEFI entries for disk1
print 'Create efi boot entries for disk1'
modprobe efivarfs
mountpoint -q /sys/firmware/efi/efivars \
    || mount -t efivarfs efivarfs /sys/firmware/efi/efivars

if efibootmgr | grep ZFSBootMenu
then
  for entry in $(efibootmgr | grep ZFSBootMenu | sed -E 's/Boot([0-9]+).*/\1/')
  do
    efibootmgr -B -b "$entry"
  done
fi

efibootmgr --disk "$DISK1" \
  --part 1 \
  --create \
  --label "ZFSBootMenu Backup" \
  --loader "\EFI\ZBM\vmlinuz-backup.efi" \
  --verbose
efibootmgr --disk "$DISK1" \
  --part 1 \
  --create \
  --label "ZFSBootMenu" \
  --loader "\EFI\ZBM\vmlinuz.efi" \
  --verbose

# Create UEFI entries for disk2
print 'Create efi boot entries for disk2'
efibootmgr --disk "$DISK2" \
  --part 1 \
  --create \
  --label "ZFSBootMenu Backup" \
  --loader "\EFI\ZBM\vmlinuz-backup.efi" \
  --verbose
efibootmgr --disk "$DISK2" \
  --part 1 \
  --create \
  --label "ZFSBootMenu" \
  --loader "\EFI\ZBM\vmlinuz.efi" \
  --verbose

# Umount all parts
print 'Umount all parts'
umount /mnt/efi1
umount /mnt/efi2
umount -l /mnt/{dev,proc,sys}
zfs umount -a

# Export zpool
print 'Export zpool'
zpool export zroot

# Finish
echo -e '\e[32mAll OK\033[0m'