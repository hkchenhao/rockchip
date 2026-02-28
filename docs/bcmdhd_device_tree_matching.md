# bcmdhd 驱动与设备树 "bcm4329-fmac" 的适配分析

## 问题

设备树中使用的 compatible 字符串是 `"brcm,bcm4329-fmac"`，但 bcmdhd 驱动中并没有直接匹配这个字符串。那么驱动是如何工作的？

---

## 答案：bcmdhd 不依赖设备树 compatible 匹配！

### 关键发现

**bcmdhd 驱动通过 SDIO 总线自动检测，而不是通过设备树 compatible 匹配！**

---

## 详细分析

### 1. 设备树中的 WiFi 节点

**文件：** `rk3399-eaidk-610.dts`

```dts
&sdio0 {
    /* WiFi & BT combo module AMPAK AP6255 */
    #address-cells = <1>;
    #size-cells = <0>;
    bus-width = <4>;
    clock-frequency = <50000000>;
    cap-sdio-irq;
    cap-sd-highspeed;
    keep-power-in-suspend;
    mmc-pwrseq = <&sdio_pwrseq>;
    non-removable;
    pinctrl-names = "default";
    pinctrl-0 = <&sdio0_bus4 &sdio0_cmd &sdio0_clk>;
    sd-uhs-sdr104;
    status = "okay";

    brcmf: wifi@1 {
        compatible = "brcm,bcm4329-fmac";    // ← 这个 compatible 字符串
        reg = <1>;
        interrupt-parent = <&gpio0>;
        interrupts = <RK_PA3 GPIO_ACTIVE_HIGH>;
        interrupt-names = "host-wake";
        pinctrl-names = "default";
        pinctrl-0 = <&wifi_host_wake_l>;
    };
};
```

**关键点：**
- `compatible = "brcm,bcm4329-fmac"` 是为 **brcmfmac 主线驱动** 准备的
- bcmdhd 驱动 **不使用** 这个 compatible 字符串
- WiFi 设备是 SDIO 总线的子设备（`reg = <1>`）

---

### 2. bcmdhd 驱动的设备匹配机制

#### 2.1 Platform 驱动层（不匹配 "bcm4329-fmac"）

**文件：** `dhd_linux_platdev.c`

```c
#define WIFI_PLAT_NAME    "bcmdhd_wlan"
#define WIFI_PLAT_NAME2   "bcm4329_wlan"

#ifdef CONFIG_DTS
static const struct of_device_id wifi_device_dt_match[] = {
    { .compatible = "android,bcmdhd_wlan", },    // ← 只匹配这个！
    {},
};
#endif

static struct platform_driver wifi_platform_dev_driver = {
    .probe          = wifi_plat_dev_drv_probe,
    .remove         = wifi_plat_dev_drv_remove,
    .driver         = {
        .name   = WIFI_PLAT_NAME,
#ifdef CONFIG_DTS
        .of_match_table = wifi_device_dt_match,
#endif
    }
};

static struct platform_driver wifi_platform_dev_driver_legacy = {
    .probe          = wifi_plat_dev_drv_probe,
    .remove         = wifi_plat_dev_drv_remove,
    .driver         = {
        .name   = WIFI_PLAT_NAME2,    // "bcm4329_wlan"
    }
};
```

**结论：**
- bcmdhd 的 platform 驱动只匹配 `"android,bcmdhd_wlan"`
- **不匹配** `"brcm,bcm4329-fmac"`
- 但这个 platform 驱动只是用于电源管理和 GPIO 控制

---

#### 2.2 SDIO 总线驱动层（真正的设备匹配）

**文件：** `bcmsdh_sdmmc_linux.c`

```c
/* devices we support, null terminated */
static const struct sdio_device_id bcmsdh_sdmmc_ids[] = {
    { SDIO_DEVICE(SDIO_VENDOR_ID_BROADCOM, SDIO_DEVICE_ID_BROADCOM_DEFAULT) },
    { SDIO_DEVICE(SDIO_VENDOR_ID_BROADCOM, BCM4362_CHIP_ID) },
    { SDIO_DEVICE(SDIO_VENDOR_ID_BROADCOM, BCM43751_CHIP_ID) },
    { SDIO_DEVICE(SDIO_VENDOR_ID_BROADCOM, BCM43752_CHIP_ID) },
    // ... 更多芯片 ID
    { SDIO_DEVICE(SDIO_VENDOR_ID_BROADCOM, SDIO_ANY_ID) },    // ← 匹配所有 Broadcom SDIO 设备！
    { SDIO_DEVICE_CLASS(SDIO_CLASS_NONE) },
    { 0, 0, 0, 0 /* end: all zeroes */ },
};

MODULE_DEVICE_TABLE(sdio, bcmsdh_sdmmc_ids);

static int
bcmsdh_sdmmc_probe(struct sdio_func *func,
                   const struct sdio_device_id *id)
{
    // SDIO 设备探测
}
```

**关键点：**
- bcmdhd 通过 **SDIO Vendor ID 和 Device ID** 匹配设备
- **不使用设备树 compatible 字符串**
- `SDIO_VENDOR_ID_BROADCOM = 0x02d0`（Broadcom 的 SDIO 厂商 ID）
- `SDIO_ANY_ID` 匹配所有 Broadcom SDIO 设备

---

### 3. 设备匹配流程

#### 完整的设备发现和匹配流程：

```
1. 内核启动，SDIO 主机控制器初始化（dwmmc_rockchip）
   ↓
2. 电源序列启动（sdio_pwrseq）
   - RK808 提供 32KHz 时钟
   - GPIO0_PB2 复位 WiFi 模块
   ↓
3. SDIO 总线扫描设备
   - 检测到 SDIO 设备在 slot 1
   ↓
4. 读取 SDIO 设备的 CIS（Card Information Structure）
   - Vendor ID: 0x02d0 (Broadcom)
   - Device ID: 0xa9bf (BCM43455/AP6255)
   ↓
5. SDIO 子系统匹配驱动
   - 遍历已注册的 SDIO 驱动
   - 找到 bcmdhd 的 bcmsdh_sdmmc_ids 表
   - 匹配成功：Vendor=0x02d0, Device=ANY
   ↓
6. 调用 bcmdhd 的 probe 函数
   - bcmsdh_sdmmc_probe()
   ↓
7. bcmdhd 初始化
   - 读取芯片 ID
   - 加载固件
   - 创建网络接口
```

**重要：设备树中的 `compatible = "brcm,bcm4329-fmac"` 在这个流程中没有被使用！**

---

### 4. 那么 "brcm,bcm4329-fmac" 有什么用？

#### 4.1 为 brcmfmac 主线驱动准备

如果使用 brcmfmac 驱动，它会匹配这个 compatible 字符串：

**brcmfmac 驱动中的匹配表：**

```c
// drivers/net/wireless/broadcom/brcm80211/brcmfmac/of.c
static const struct of_device_id brcmf_sdio_of_match[] = {
    { .compatible = "brcm,bcm4329-fmac" },
    { .compatible = "brcm,bcm4330-fmac" },
    { .compatible = "brcm,bcm4334-fmac" },
    { .compatible = "brcm,bcm43340-fmac" },
    { .compatible = "brcm,bcm4335-fmac" },
    { .compatible = "brcm,bcm43362-fmac" },
    { .compatible = "brcm,bcm4339-fmac" },
    { .compatible = "brcm,bcm43430-fmac" },
    { .compatible = "brcm,bcm43455-fmac" },
    { .compatible = "brcm,bcm4354-fmac" },
    { .compatible = "brcm,bcm4356-fmac" },
    { .compatible = "brcm,bcm4359-fmac" },
    {}
};
```

#### 4.2 提供 OOB 中断信息

设备树节点提供了 **Out-of-Band (OOB) 中断** 信息：

```dts
brcmf: wifi@1 {
    compatible = "brcm,bcm4329-fmac";
    interrupt-parent = <&gpio0>;
    interrupts = <RK_PA3 GPIO_ACTIVE_HIGH>;    // ← OOB 中断
    interrupt-names = "host-wake";
};
```

**bcmdhd 可以通过其他方式获取这个中断：**
- Rockchip RFKILL 框架
- Platform data
- 直接 GPIO 配置

---

### 5. bcmdhd 如何获取 GPIO 和电源信息？

bcmdhd 不从 `brcmf: wifi@1` 节点读取信息，而是从：

#### 5.1 Rockchip RFKILL 框架

```c
#ifdef CUSTOMER_HW_ROCKCHIP
#include <linux/rfkill-wlan.h>

rockchip_wifi_power(1);              // 电源控制
rockchip_wifi_set_carddetect(1);     // 卡检测
#endif
```

#### 5.2 Platform Data

如果定义了 `"android,bcmdhd_wlan"` 节点：

```dts
bcmdhd_wlan {
    compatible = "android,bcmdhd_wlan";
    gpio_wl_reg_on = <&gpio0 RK_PB2 GPIO_ACTIVE_HIGH>;
    gpio_wl_host_wake = <&gpio0 RK_PA3 GPIO_ACTIVE_HIGH>;
};
```

#### 5.3 SDIO 主控制器的电源序列

```dts
sdio_pwrseq: sdio-pwrseq {
    compatible = "mmc-pwrseq-simple";
    clocks = <&rk808 1>;
    clock-names = "ext_clock";
    reset-gpios = <&gpio0 RK_PB2 GPIO_ACTIVE_LOW>;
};

&sdio0 {
    mmc-pwrseq = <&sdio_pwrseq>;    // ← bcmdhd 通过 SDIO 子系统使用
};
```

---

## 6. 为什么设备树使用 "brcm,bcm4329-fmac"？

### 原因分析

1. **历史兼容性**
   - "bcm4329-fmac" 是标准的设备树绑定
   - Linux 内核文档中定义的标准 compatible 字符串

2. **驱动切换灵活性**
   - 可以轻松切换到 brcmfmac 主线驱动
   - 只需修改内核配置，不需要改设备树

3. **符合设备树规范**
   - 设备树应该描述硬件，而不是驱动
   - "brcm,bcm4329-fmac" 描述的是硬件兼容性

4. **OOB 中断信息**
   - 提供 host-wake 中断配置
   - brcmfmac 驱动需要这个信息

---

## 7. 实际设备匹配验证

### 查看系统日志验证匹配过程

```bash
# 查看 SDIO 设备信息
cat /sys/bus/sdio/devices/mmc0:0001:1/vendor
# 输出: 0x02d0 (Broadcom)

cat /sys/bus/sdio/devices/mmc0:0001:1/device
# 输出: 0xa9bf (BCM43455)

# 查看驱动绑定
ls -l /sys/bus/sdio/devices/mmc0:0001:1/driver
# 输出: -> ../../../../bus/sdio/drivers/bcmsdh_sdmmc

# 查看内核日志
dmesg | grep -i "bcm\|sdio\|wifi"
# 应该看到：
# [    2.xxx] bcmsdh_sdmmc: bcmsdh_sdmmc_probe: Enter
# [    2.xxx] bcmsdh_sdmmc: vendor=0x2d0, device=0xa9bf
```

---

## 8. 总结

### 关键结论

| 问题 | 答案 |
|------|------|
| **bcmdhd 是否匹配 "brcm,bcm4329-fmac"？** | ❌ **否**，bcmdhd 不使用这个 compatible |
| **bcmdhd 如何找到设备？** | ✅ 通过 **SDIO Vendor/Device ID** 自动检测 |
| **"brcm,bcm4329-fmac" 有什么用？** | ✅ 为 **brcmfmac 驱动** 和 **OOB 中断** 准备 |
| **bcmdhd 需要设备树节点吗？** | ⚠️ **不强制**，但需要电源序列和 GPIO 配置 |
| **可以删除 wifi@1 节点吗？** | ⚠️ **不建议**，会丢失 OOB 中断配置 |

### bcmdhd 设备匹配机制

```
bcmdhd 驱动的设备发现：

1. SDIO 总线层匹配
   ├─ 通过 SDIO Vendor ID (0x02d0 = Broadcom)
   ├─ 通过 SDIO Device ID (0xa9bf = BCM43455)
   └─ 不使用设备树 compatible 字符串

2. 电源和 GPIO 管理
   ├─ 通过 Rockchip RFKILL 框架
   ├─ 通过 SDIO 电源序列（mmc-pwrseq）
   └─ 可选：通过 "android,bcmdhd_wlan" 节点

3. 中断配置
   ├─ 可以从 "brcm,bcm4329-fmac" 节点读取（如果驱动支持）
   ├─ 或通过 Rockchip 平台代码配置
   └─ 或使用 SDIO 内置中断
```

---

## 9. 实际建议

### 对于 EAIDK-610 (RK3399)

**当前配置是合理的：**

1. ✅ 保留 `compatible = "brcm,bcm4329-fmac"`
   - 提供标准的设备描述
   - 方便将来切换到 brcmfmac 驱动
   - 提供 OOB 中断信息

2. ✅ 使用 bcmdhd 驱动
   - 通过 SDIO 总线自动匹配
   - 不依赖 compatible 字符串
   - 使用 Rockchip 平台集成

3. ✅ 保留电源序列配置
   - `sdio_pwrseq` 节点
   - RK808 时钟输出
   - GPIO 复位控制

### 如果要添加 bcmdhd 专用节点（可选）

```dts
// 可选：添加 bcmdhd 专用配置节点
bcmdhd_wlan {
    compatible = "android,bcmdhd_wlan";
    gpio_wl_reg_on = <&gpio0 RK_PB2 GPIO_ACTIVE_HIGH>;
    gpio_wl_host_wake = <&gpio0 RK_PA3 GPIO_ACTIVE_HIGH>;
};
```

但在 Rockchip 平台上，通常不需要这个节点，因为 bcmdhd 会使用 Rockchip RFKILL 框架。

---

## 10. 参考代码位置

### bcmdhd 驱动中的关键文件

```
drivers/net/wireless/rockchip_wlan/rkwifi/bcmdhd/
├── bcmsdh_sdmmc_linux.c      # SDIO 总线驱动（真正的设备匹配）
├── dhd_linux_platdev.c        # Platform 驱动（电源/GPIO 管理）
├── dhd_gpio.c                 # GPIO 和电源控制
└── dhd_sdio.c                 # SDIO 通信层
```

### 设备树文件

```
kernel/arch/arm64/boot/dts/rockchip/
└── rk3399-eaidk-610.dts       # EAIDK-610 设备树
```

---

## 附录：SDIO 设备 ID 定义

```c
// include/linux/mmc/sdio_ids.h
#define SDIO_VENDOR_ID_BROADCOM    0x02d0

// bcmdhd 驱动内部定义
#define BCM43455_CHIP_ID           0xa9bf  // AP6255 使用的芯片
#define BCM4345_CHIP_ID            0x4345
#define BCM4339_CHIP_ID            0x4339
// ... 更多芯片 ID
```

### SDIO 设备信息读取

SDIO 设备的 Vendor ID 和 Device ID 存储在设备的 **CIS (Card Information Structure)** 中，
SDIO 主机控制器在总线扫描时自动读取，不需要设备树提供。

---

## 结论

**bcmdhd 驱动通过 SDIO 总线的硬件 ID 自动检测设备，不依赖设备树的 compatible 字符串。**

设备树中的 `"brcm,bcm4329-fmac"` 节点主要用于：
1. brcmfmac 主线驱动
2. 提供 OOB 中断配置
3. 符合设备树规范
4. 方便驱动切换

对于 bcmdhd 驱动，真正重要的是：
1. SDIO 总线配置（sdio0 节点）
2. 电源序列（sdio_pwrseq）
3. Rockchip RFKILL 框架
4. 固件文件
