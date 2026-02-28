# bcmdhd vs brcmfmac 驱动详细对比

## 概述

两个驱动都支持 Broadcom FullMAC WiFi 芯片（如 BCM43455/AP6255），但来源、架构和优化方向不同。

---

## 1. 基本信息对比

| 项目 | bcmdhd (Rockchip) | brcmfmac (主线) |
|------|-------------------|-----------------|
| **来源** | Broadcom 官方 DHD（Dongle Host Driver），Rockchip 定制 | Linux 内核主线 |
| **维护者** | Rockchip + Broadcom | Linux 社区 + Broadcom |
| **位置** | `drivers/net/wireless/rockchip_wlan/rkwifi/bcmdhd/` | `drivers/net/wireless/broadcom/brcm80211/brcmfmac/` |
| **代码规模** | ~312,000 行代码，267 个文件 | ~33,000 行代码，54 个文件 |
| **许可证** | GPL-2.0 / Broadcom 专有 | ISC (更宽松) |
| **版权年份** | 2022 | 2010-2023 |

---

## 2. 架构差异

### bcmdhd 架构
- **完整的 Broadcom 官方驱动**
- 包含大量 Android 特定代码
- 支持多种总线接口（SDIO/PCIe/USB）
- 包含完整的调试和诊断功能
- 更接近 Broadcom 原始设计

### brcmfmac 架构
- **精简的社区维护版本**
- 遵循 Linux 内核编码规范
- 使用标准 cfg80211/mac80211 接口
- 代码更清晰，易于审查
- 更好的跨平台兼容性

---

## 3. Rockchip 平台特定优化

### bcmdhd 中的 Rockchip 定制

根据代码分析，bcmdhd 包含以下 Rockchip 特定功能：

```c
#ifdef CUSTOMER_HW_ROCKCHIP
#include <linux/rfkill-wlan.h>
#endif
```

**特定功能：**

1. **电源管理集成**
   - `rockchip_wifi_power(1/0)` - Rockchip 平台电源控制
   - 集成 Rockchip RFKILL 框架
   - 与 RK 电源管理子系统深度集成

2. **GPIO 控制**
   - 使用 Rockchip 特定的 GPIO 接口
   - `rockchip_wifi_set_carddetect()` - 卡检测控制
   - 支持 Rockchip DTS 配置

3. **PCIe 特殊处理**
   - `rk_pcie_power_on_atu_fixup()` - RK PCIe ATU 修复
   - Rockchip PCIe 控制器特定的初始化

4. **内存预分配**
   - 支持 Rockchip 静态内存分配方案
   - 优化 DMA 性能

5. **时钟管理**
   - 与 RK808 PMIC 的时钟输出集成
   - 32KHz LPO 时钟支持

### brcmfmac 的通用实现

- 使用标准 Linux 设备树绑定
- 通用的 MMC/SDIO 子系统接口
- 标准的 regulator 框架
- 标准的 GPIO 框架
- 需要额外的平台适配层

---

## 4. 功能特性对比

| 功能 | bcmdhd | brcmfmac |
|------|--------|----------|
| **SDIO 支持** | ✅ 完整支持 | ✅ 完整支持 |
| **PCIe 支持** | ✅ 完整支持 | ✅ 完整支持 |
| **USB 支持** | ✅ 完整支持 | ✅ 完整支持 |
| **SoftAP 模式** | ✅ | ✅ |
| **P2P 支持** | ✅ | ✅ |
| **WPA3 支持** | ✅ | ✅ (较新版本) |
| **Android 优化** | ✅ 深度优化 | ⚠️ 基本支持 |
| **电源管理** | ✅ 高度优化 | ✅ 标准实现 |
| **调试功能** | ✅ 非常丰富 | ⚠️ 基本调试 |
| **固件加载** | 灵活配置路径 | 标准 firmware 框架 |
| **MAC 地址** | 支持随机生成 | 从 NVRAM 读取 |
| **多驱动实例** | ✅ 支持 | ❌ 不支持 |

---

## 5. 配置和使用差异

### bcmdhd 配置

```makefile
# 内核配置
CONFIG_WL_ROCKCHIP=y
CONFIG_BCMDHD=y
CONFIG_AP6XXX=m
CONFIG_BCMDHD_SDIO=y
CONFIG_BCMDHD_FW_PATH="/vendor/etc/firmware/fw_bcmdhd.bin"
CONFIG_BCMDHD_NVRAM_PATH="/vendor/etc/firmware/nvram.txt"
```

**特点：**
- 固件路径可在编译时配置
- 支持多种编译选项
- 可以选择性启用功能

### brcmfmac 配置

```makefile
# 内核配置
CONFIG_BRCMFMAC=m
CONFIG_BRCMFMAC_SDIO=y
```

**特点：**
- 配置简单
- 固件路径固定在 `/lib/firmware/brcm/`
- 使用标准命名规则

---

## 6. 固件文件差异

### bcmdhd 固件

```
/vendor/etc/firmware/fw_bcmdhd.bin    # 可配置路径
/vendor/etc/firmware/nvram.txt         # 可配置路径
```

- 固件路径在内核配置中指定
- 支持运行时动态选择固件
- 可以为不同模块使用不同固件

### brcmfmac 固件

```
/lib/firmware/brcm/brcmfmac43455-sdio.bin
/lib/firmware/brcm/brcmfmac43455-sdio.txt
/lib/firmware/brcm/brcmfmac43455-sdio.clm_blob
/lib/firmware/brcm/brcmfmac43455-sdio.openailab,eaidk-610.txt  # 设备特定
```

- 固件路径固定
- 根据芯片 ID 自动选择
- 支持设备树 compatible 匹配设备特定配置

---

## 7. 性能和稳定性

### bcmdhd 优势

1. **经过 Rockchip 平台深度测试**
   - 在 RK3399 等平台上有大量实际部署
   - 针对 Rockchip 硬件优化

2. **更完整的 Android 支持**
   - 支持 Android WiFi HAL
   - 集成 Android 电源管理

3. **更丰富的调试选项**
   - 详细的日志输出
   - 性能监控和统计

4. **厂商支持**
   - Rockchip 提供技术支持
   - 定期更新和补丁

### brcmfmac 优势

1. **内核主线维护**
   - 跟随内核版本更新
   - 安全补丁及时

2. **代码质量**
   - 符合内核编码规范
   - 更容易审查和维护

3. **跨平台兼容性**
   - 可在任何 Linux 系统使用
   - 不依赖特定平台 API

4. **社区支持**
   - 广泛的社区支持
   - 大量在线文档

---

## 8. 已知问题和限制

### bcmdhd 问题

1. **代码复杂度高**
   - 包含大量 Android 特定代码
   - 不易理解和修改

2. **许可证问题**
   - 部分代码可能有 Broadcom 专有许可限制

3. **内核版本依赖**
   - 可能需要针对新内核版本移植

4. **代码冗余**
   - 包含大量未使用的功能代码

### brcmfmac 问题

1. **平台特定功能缺失**
   - 需要额外的平台代码
   - 电源管理可能不如 bcmdhd 完善

2. **调试功能有限**
   - 调试选项较少
   - 问题诊断可能较困难

3. **固件兼容性**
   - 某些 Broadcom 固件可能不兼容

---

## 9. 适用场景推荐

### 推荐使用 bcmdhd 的场景

✅ **Rockchip 平台产品开发**
- RK3399、RK3588 等 Rockchip SoC
- 需要与 Rockchip BSP 深度集成

✅ **Android 产品**
- Android 平板、电视盒子
- 需要完整的 Android WiFi 功能

✅ **需要厂商支持**
- 商业产品
- 需要技术支持和维护

✅ **已有成熟方案**
- 已经在使用 bcmdhd
- 有成熟的配置和测试

### 推荐使用 brcmfmac 的场景

✅ **标准 Linux 系统**
- 桌面 Linux
- 服务器应用

✅ **跨平台需求**
- 需要在多种平台运行
- 不依赖特定 BSP

✅ **代码审查要求**
- 需要清晰的代码
- 安全审计要求

✅ **社区项目**
- 开源项目
- 需要社区支持

---

## 10. 迁移指南

### 从 brcmfmac 迁移到 bcmdhd

1. **禁用 brcmfmac**
   ```bash
   CONFIG_BRCMFMAC=n
   ```

2. **启用 bcmdhd**
   ```bash
   CONFIG_WL_ROCKCHIP=y
   CONFIG_BCMDHD=y
   CONFIG_AP6XXX=m
   CONFIG_BCMDHD_SDIO=y
   ```

3. **调整固件路径**
   - 复制固件到 `/vendor/etc/firmware/`
   - 或修改内核配置指定路径

4. **验证设备树**
   - 确保 SDIO 配置正确
   - 检查 GPIO、电源序列

### 从 bcmdhd 迁移到 brcmfmac

1. **禁用 bcmdhd**
   ```bash
   CONFIG_WL_ROCKCHIP=n
   CONFIG_BCMDHD=n
   ```

2. **启用 brcmfmac**
   ```bash
   CONFIG_BRCMFMAC=m
   CONFIG_BRCMFMAC_SDIO=y
   ```

3. **标准化固件路径**
   ```bash
   cp fw_bcmdhd.bin /lib/firmware/brcm/brcmfmac43455-sdio.bin
   cp nvram.txt /lib/firmware/brcm/brcmfmac43455-sdio.txt
   ```

4. **可能需要的调整**
   - 添加平台电源管理代码
   - 调整设备树兼容字符串

---

## 11. 总结建议

### 对于 EAIDK-610 (RK3399) 平台

**强烈推荐使用 bcmdhd 驱动**，原因：

1. ✅ **已经配置好** - 您的内核已经启用并配置了 bcmdhd
2. ✅ **Rockchip 优化** - 针对 RK3399 平台深度优化
3. ✅ **成熟稳定** - 在 Rockchip 平台有大量部署经验
4. ✅ **电源管理** - 与 RK808 PMIC 完美集成
5. ✅ **技术支持** - Rockchip 提供支持

### 何时考虑 brcmfmac

仅在以下情况考虑切换到 brcmfmac：

- 需要运行标准 Linux 发行版（非 Android）
- 需要跟随内核主线更新
- 有特殊的许可证要求
- bcmdhd 遇到无法解决的问题

---

## 12. 参考资源

### bcmdhd 相关
- Rockchip Wiki: https://opensource.rock-chips.com/
- 驱动源码: `drivers/net/wireless/rockchip_wlan/rkwifi/bcmdhd/`
- 配置文件: `drivers/net/wireless/rockchip_wlan/Kconfig`

### brcmfmac 相关
- 内核文档: `Documentation/networking/device_drivers/wifi/brcm80211.rst`
- 驱动源码: `drivers/net/wireless/broadcom/brcm80211/brcmfmac/`
- Wireless Wiki: https://wireless.wiki.kernel.org/en/users/drivers/brcm80211

### 固件下载
- linux-firmware: https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
- GitHub 镜像: https://github.com/RPi-Distro/firmware-nonfree

---

## 附录：代码对比示例

### 电源管理对比

**bcmdhd (Rockchip 特定):**
```c
#ifdef CUSTOMER_HW_ROCKCHIP
    rockchip_wifi_power(1);  // 使用 Rockchip 电源 API
#endif
```

**brcmfmac (标准实现):**
```c
    ret = mmc_power_restore_host(sdiodev->func1->card->host);
    // 使用标准 MMC 子系统 API
```

### 固件加载对比

**bcmdhd:**
```c
// 固件路径在编译时配置
#define FIRMWARE_PATH "/vendor/etc/firmware/fw_bcmdhd.bin"
```

**brcmfmac:**
```c
// 固件路径由芯片 ID 决定
snprintf(fw_name, sizeof(fw_name), "brcm/brcmfmac%d-sdio.bin", chipid);
```
