cmake_minimum_required(VERSION 3.13)
project("rk3399" C CXX)

# 导出compile_commands.json供IDE使用
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# 设置C标准
set(CMAKE_C_STANDARD 11)

# 定义内核源码路径
set(KERNEL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/kernel)

# 添加内核头文件包含路径
include_directories(
    # 内核主要头文件目录
    ${KERNEL_DIR}/include
    ${KERNEL_DIR}/include/uapi
    ${KERNEL_DIR}/arch/arm64/include
    ${KERNEL_DIR}/arch/arm64/include/generated
    ${KERNEL_DIR}/arch/arm64/include/uapi
    ${KERNEL_DIR}/arch/arm64/include/generated/uapi

    # asm头文件
    ${KERNEL_DIR}/arch/arm64/include/asm
    ${KERNEL_DIR}/include/asm-generic

    # 内核内部头文件
    ${KERNEL_DIR}/include/linux
    ${KERNEL_DIR}/include/dt-bindings

    # 驱动相关头文件
    ${KERNEL_DIR}/drivers/mmc/host
    ${KERNEL_DIR}/drivers/mmc/core
    ${KERNEL_DIR}/drivers/net/wireless/broadcom/brcm80211

    # 平台相关头文件
    ${KERNEL_DIR}/include/soc/rockchip
)

# 添加编译定义（模拟内核编译环境）
add_definitions(
    -D__KERNEL__
    -DMODULE
    -DCONFIG_ARM64
    -DCONFIG_64BIT
    -DCONFIG_OF
    -DCONFIG_MMC
    -DCONFIG_MMC_DW
    -DCONFIG_MMC_DW_ROCKCHIP
    -DCONFIG_BRCMFMAC
    -DCONFIG_BRCMFMAC_SDIO
    -DCONFIG_PINCTRL
    -DCONFIG_PINCTRL_ROCKCHIP
)

# 收集所有内核源文件（递归扫描）
file(GLOB_RECURSE KERNEL_SOURCES
    # 驱动源码
    ${KERNEL_DIR}/drivers/*.c

    # 架构相关源码
    ${KERNEL_DIR}/arch/arm64/kernel/*.c
    ${KERNEL_DIR}/arch/arm64/mm/*.c
    ${KERNEL_DIR}/arch/arm64/boot/dts/rockchip/*.dts
    ${KERNEL_DIR}/arch/arm64/boot/dts/rockchip/*.dtsi

    # 核心内核代码
    ${KERNEL_DIR}/kernel/*.c
    ${KERNEL_DIR}/mm/*.c
    ${KERNEL_DIR}/fs/*.c
    ${KERNEL_DIR}/net/*.c

    # 其他子系统
    ${KERNEL_DIR}/lib/*.c
    ${KERNEL_DIR}/block/*.c
    ${KERNEL_DIR}/crypto/*.c
    ${KERNEL_DIR}/security/*.c
)

# 排除一些不需要的文件（可选）
list(FILTER KERNEL_SOURCES EXCLUDE REGEX ".*\\.mod\\.c$")  # 排除.mod.c
list(FILTER KERNEL_SOURCES EXCLUDE REGEX ".*/\\..*")       # 排除隐藏文件

# 创建一个库目标（不链接，仅用于IDE索引）
# 使用OBJECT库，这样可以生成compile_commands.json但不会链接
add_library(kernel_index OBJECT ${KERNEL_SOURCES})

# 设置编译选项（禁用实际编译，只为索引）
target_compile_options(kernel_index PRIVATE
    -Wno-all
    -Wno-error
    -fsyntax-only  # 只做语法检查，不生成目标文件
)