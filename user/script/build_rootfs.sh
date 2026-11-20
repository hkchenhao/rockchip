#!/bin/bash -e

# 1.Download and prepare(run as sudo/root)
cd build
wget https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04-base-arm64.tar.gz -P /tmp
tar -xzpf /tmp/ubuntu-base-26.04-base-arm64.tar.gz -C rootfs
cp /usr/bin/qemu-aarch64-static rootfs/usr/bin/ # The develop not need to execute
cp /etc/resolv.conf rootfs/etc/resolv.conf
cp ../user/package/*.deb rootfs/tmp/

# 2.Chroot
mount -t proc /proc rootfs/proc && mount -t sysfs /sys rootfs/sys && mount -o bind /dev rootfs/dev && mount -o bind /dev/pts rootfs/dev/pts
chroot rootfs /bin/bash && dpkg --print-architecture
cat <<'EOF'
  export LANG=C.UTF-8 LC_ALL=C.UTF-8
  DEBIAN_FRONTEND=noninteractive apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade
  DEBIAN_FRONTEND=noninteractive apt install -y \
      ubuntu-minimal \
      zsh curl wget vim tree git cmake build-essential pkgconf \
      net-tools network-manager openssh-server rfkill iperf3 \
      usb-modeswitch usbutils pciutils alsa-utils i2c-tools bluez gpiod evtest \
      /tmp/*.deb
  rm -rf /var/lib/apt/lists/* && rm -rf /var/cache/* && rm -f /tmp/*.deb

  passwd root
  echo ubuntu > /etc/hostname
  echo 'LANG=C.UTF-8' > /etc/default/locale
  ln -sfn /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

  #  chsh -s /bin/zsh
  #  sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  #  git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
  #  git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
  #  vim ~/.zshrc
  #  plugins=(git extract z zsh-autosuggestions zsh-syntax-highlighting)

  exit
EOF
umount rootfs/dev/pts && umount rootfs/dev && umount rootfs/sys && umount rootfs/proc

# 3.Install module and overlay
make -C ../kernel ARCH=arm64 modules_install INSTALL_MOD_PATH="$PWD/rootfs"
cp -a --no-preserve=ownership ../user/overlay/. rootfs/

# 4.Make image
rm -f image/rootfs.img
mkfs.ext4 -F -L linuxroot -d rootfs image/rootfs.img 4096M
e2fsck -pf image/rootfs.img
resize2fs -M image/rootfs.img

# 5.Resize rootfs(run on develop board)
resize2fs /dev/mmcblk0p4
