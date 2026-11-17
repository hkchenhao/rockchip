#!/bin/bash -e

# Prepare
sudo apt install -y bc bison build-essential cpio device-tree-compiler flex \
                    libelf-dev libncurses-dev libssl-dev lz4 make gcc \
                    python-is-python3 gcc-aarch64-linux-gnu qemu-user-static

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

cd kernel
make distclean
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- rockchip_linux_defconfig rockchip_linux_user.config
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- menuconfig
make ARCH=arm64 savedefconfig && mv defconfig arch/arm64/configs/rockchip_linux_defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- rk3399-blend.img KCFLAGS="-Wno-error" -j30
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- modules KCFLAGS="-Wno-error" -j30
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- modules_install INSTALL_MOD_PATH=../build/rootfs
cp boot.img ../build/image/kernel.img
cd -

# Download(使用 download(reboot loader)/rbrom 命令进入 Loader/Maskrom 模式
cat > parameter.txt <<'EOF'
FIRMWARE_VER: 1.0
MACHINE_MODEL: RK3399
MACHINE_ID: 007
MANUFACTURER: RK3399
MAGIC: 0x5041524B
ATAG: 0x00200800
MACHINE: 0xFFFFFFFF
CHECK_MASK: 0x80
PWR_HLD: 0,0,A,0,1
TYPE: GPT
CMDLINE: mtdparts=rk29xxnand:0x00002000@0x00004000(uboot),0x00002000@0x00006000(trust),0x00040000@0x00008000(boot:bootable),-@0x00048000(rootfs:grow)
uuid:rootfs=614e0000-0000-4b53-8000-1d28000054a9
EOF
upgrade_tool ul loader.bin -noreset
upgrade_tool di -p parameter.txt
upgrade_tool di -t trust.img
upgrade_tool di -u uboot.img
upgrade_tool di -b kernel.img
upgrade_tool di -rootfs rootfs.img
upgrade_tool rd