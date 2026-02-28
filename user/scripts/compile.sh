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
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- rockchip_linux_defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- menuconfig
make ARCH=arm64 savedefconfig && mv defconfig arch/arm64/configs/rockchip_linux_defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- rk3399-eaidk-610.img KCFLAGS="-Wno-error" -j16
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- modules KCFLAGS="-Wno-error" -j16
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- modules_install INSTALL_MOD_PATH=../user/build/rootfs
cp boot.img ../user/build/kernel.img
cd -