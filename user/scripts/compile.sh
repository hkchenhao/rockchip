#!/bin/bash -e

# Prepare
sudo apt install bc bison build-essential cpio device-tree-compiler flex libelf-dev libncurses-dev libssl-dev lz4 \
                 make python-is-python3 gcc gcc-aarch64-linux-gnu

# Clone
git clone https://github.com/rockchip-linux/rkbin loader -b master --single-branch --depth 1
git clone https://github.com/rockchip-linux/u-boot uboot -b next-dev --single-branch --depth 1
git clone https://github.com/rockchip-linux/kernel.git kernel -b develop-6.1 --single-branch --depth 1

# Build
cd loader
./tools/boot_merger ./RKBOOT/RK3399MINIALL.ini
./tools/trust_merger ./RKTRUST/RK3399TRUST.ini
cp rk3399_loader_*.bin ../user/build/loader.bin
cp trust.img ../user/build/trust.img
cd -

cd uboot
make distclean
make CROSS_COMPILE=aarch64-none-linux-gnu- rk3399_defconfig
make CROSS_COMPILE=aarch64-none-linux-gnu- menuconfig
make savedefconfig && mv defconfig ./configs/rk3399_defconfig
make CROSS_COMPILE=aarch64-none-linux-gnu- KCFLAGS="-Wno-error" -j16
./../loader/tools/loaderimage --pack --uboot u-boot.bin uboot.img 0x200000 --size 2048 2
cp uboot.img ../user/build/uboot.img
cd -

# Ref: https://www.cnblogs.com/solo666/p/15953768.html https://blog.csdn.net/fhy00229390/article/details/112980643)
cd kernel
make distclean
make O="$PWD/build/kernel" ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- rockchip_linux_defconfig rockchip_linux_user.config
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- menuconfig
make ARCH=arm64 savedefconfig && mv defconfig arch/arm64/configs/rockchip_linux_defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- rk3399-blend.img KCFLAGS="-Wno-error" -j16
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- modules KCFLAGS="-Wno-error" -j16
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- modules_install INSTALL_MOD_PATH=../build/rootfs
cp boot.img ../build/image/kernel.img
cd -

# Rootfs
wget https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04-base-arm64.tar.gz -P /tmp
cd build && sudo mkdir rootfs && sudo tar -xzpf /tmp/ubuntu-base-26.04-base-arm64.tar.gz -C rootfs
# sudo sh tools/register_binfmt.sh
#sudo apt-get install qemu-user-static && sudo cp /usr/bin/qemu-arm-static rootfs/usr/bin/
sudo cp -b /etc/resolv.conf rootfs/etc/resolv.conf
sudo mount -t proc /proc rootfs/proc && sudo mount -t sysfs /sys rootfs/sys && sudo mount -o bind /dev rootfs/dev && sudo mount -o bind /dev/pts rootfs/dev/pts
sudo chroot rootfs /bin/bash && dpkg --print-architecture
cat << EOF
  DEBIAN_FRONTEND=noninteractive apt update && DEBIAN_FRONTEND=noninteractive apt upgrade
  DEBIAN_FRONTEND=noninteractive apt install udev kmod sudo vim net-tools openssh-server
  passwd root
  rm -rf /var/lib/apt/lists/* && rm -rf /var/cache/
  mkdir -p /lib/firmware
  exit
EOF
sudo umount rootfs/dev/pts && sudo umount rootfs/dev && sudo umount rootfs/sys && sudo umount rootfs/proc
sudo make -C ../kernel ARCH=arm64 modules_install INSTALL_MOD_PATH=rootfs
sudo cp -a firmware/. rootfs/lib/firmware/

# Expand ext4 to the rootfs:grow partition on boot (already-full filesystems are a no-op).
# This grows the mounted root filesystem only; it does not change the partition table.
sudo test -x rootfs/usr/lib/systemd/systemd-growfs
sudo test -f rootfs/usr/lib/systemd/system/systemd-growfs-root.service
sudo mkdir -p rootfs/etc/systemd/system/systemd-growfs-root.service.d \
             rootfs/etc/systemd/system/local-fs.target.wants
sudo tee rootfs/etc/systemd/system/systemd-growfs-root.service.d/order.conf >/dev/null <<'EOF'
[Unit]
Before=local-fs.target
EOF
sudo ln -sfn /usr/lib/systemd/system/systemd-growfs-root.service \
    rootfs/etc/systemd/system/local-fs.target.wants/systemd-growfs-root.service

sudo rm -f image/rootfs.img && sudo mkfs.ext4 -F -L linuxroot -d rootfs image/rootfs.img 1024M
sudo e2fsck -pf image/rootfs.img
sudo resize2fs -M image/rootfs.img
