#!/bin/bash -e

cd uboot
make distclean
make CROSS_COMPILE=aarch64-none-linux-gnu- rk3399_defconfig
make CROSS_COMPILE=aarch64-none-linux-gnu- menuconfig
make savedefconfig && mv defconfig ./configs/rk3399_defconfig
make CROSS_COMPILE=aarch64-none-linux-gnu- KCFLAGS="-Wno-error" -j16
./../loader/tools/loaderimage --pack --uboot u-boot.bin uboot.img 0x200000 --size 2048 2
mv uboot.img ../build/uboot.img
cd -