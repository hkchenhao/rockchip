#!/bin/bash -e

# 1.Download and prepare(run as sudo/root)
cd build
wget https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04-base-arm64.tar.gz -P /tmp
tar -xzpf /tmp/ubuntu-base-26.04-base-arm64.tar.gz -C rootfs
cp -b /usr/bin/qemu-aarch64-static rootfs/usr/bin/
cp -b /etc/resolv.conf rootfs/etc/resolv.conf

# 2.Chroot
mount -t proc /proc rootfs/proc && mount -t sysfs /sys rootfs/sys && mount -o bind /dev rootfs/dev && mount -o bind /dev/pts rootfs/dev/pts
chroot rootfs /bin/bash && dpkg --print-architecture
cat << EOF
  DEBIAN_FRONTEND=noninteractive apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade
  DEBIAN_FRONTEND=noninteractive apt install -y \
      systemd systemd-sysv systemd-resolved systemd-timesyncd \
      dbus udev kmod sudo zsh vim less tzdata\
      network-manager wpasupplicant iproute2 net-tools iputils-ping \
      openssh-server ca-certificates curl \
      usb-modeswitch usbutils i2c-tools gpiod e2fsprogs \
      build-essential python3 cmake pkg-config git
  passwd root
  rm -rf /var/lib/apt/lists/* && rm -rf /var/cache/
  exit
EOF
umount rootfs/dev/pts && umount rootfs/dev && umount rootfs/sys && umount rootfs/proc

# 3.Install module and overlay
make -C ../kernel ARCH=arm64 modules_install INSTALL_MOD_PATH="$PWD/rootfs"
cp -a --no-preserve=ownership ../user/overlay/. rootfs/

# 4.Make image
rm -f image/rootfs.img
mkfs.ext4 -F -L linuxroot -d rootfs image/rootfs.img 1024M
e2fsck -pf image/rootfs.img
resize2fs -M image/rootfs.img

# 5.Resize rootfs(run on develop board)
resize2fs /dev/mmcblk0p4