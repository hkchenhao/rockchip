# wireless-wlan vs mmc-pwrseq：两种 WiFi 配置方式对比

## 问题

为什么 EAIDK-610 的设备树没有使用 Rockchip 官方文档中的 `wireless-wlan` 节点，而是使用 `mmc-pwrseq-simple`？

---

## 答案：两种不同的配置方式

EAIDK-610 使用的是 **标准 Linux 内核方式**（mmc-pwrseq），而不是 **Rockchip 专有方式**（wireless-wlan）。

---

## 1. 两种配置方式对比

### 方式一：Rockchip 专有方式（wireless-wlan）

**配置示例：**

```dts
wireless-wlan {
    compatible = "wlan-platdata";
    rockchip,grf = <&grf>;
    clocks = <&rk809 1>;
    clock-names = "ext_clock";
    wifi_chip_type = "ap6255";
    WIFI,host_wake_irq = <&gpio0 RK_PA0 GPIO_ACTIVE_HIGH>;
    status = "okay";
};
```

**驱动支持：**
- 文件：`net/rfkill/rfkill-wlan.c`
- 内核配置：`CONFIG_RFKILL_RK=y`
- 匹配：`compatible = "wlan-platdata"`

**特点：**
- ✅ Rockchip 专有实现
- ✅ 提供 `rockchip_wifi_power()` 等 API
- ✅ 支持更多 Rockchip 特定功能
- ✅ 可以指定 `wifi_chip_type`
- ⚠️ 非标准 Linux 实现
- ⚠️ 依赖 Rockchip RFKILL 驱动

---

### 方式二：标准 Linux 方式（mmc-pwrseq）

**配置示例（EAIDK-610 使用的）：**

```dts
sdio_pwrseq: sdio-pwrseq {
    compatible = "mmc-pwrseq-simple";
    clocks = <&rk808 1>;
    clock-names = "ext_clock";
    pinctrl-names = "default";
    pinctrl-0 = <&wifi_enable_h>;
    reset-gpios = <&gpio0 RK_PB2 GPIO_ACTIVE_LOW>;
};

&sdio0 {
    mmc-pwrseq = <&sdio_pwrseq>;
    // ... WiFi 配置
};
```

**驱动支持：**
- 文件：`drivers/mmc/core/pwrseq_simple.c`
- 内核配置：`CONFIG_PWRSEQ_SIMPLE=y`
- 匹配：`compatible = "mmc-pwrseq-simple"`

**特点：**
- ✅ Linux 内核标准实现
- ✅ 跨平台兼容性好
- ✅ 代码更简洁
- ✅ 主线内核支持
- ⚠️ 功能相对简单
- ⚠️ 不提供 Rockchip 特定 API

---

## 2. 详细对比

| 对比项 | wireless-wlan (Rockchip) | mmc-pwrseq-simple (标准) |
|--------|-------------------------|-------------------------|
| **兼容性** | `wlan-platdata` | `mmc-pwrseq-simple` |
| **驱动位置** | `net/rfkill/rfkill-wlan.c` | `drivers/mmc/core/pwrseq_simple.c` |
| **内核配置** | `CONFIG_RFKILL_RK=y` | `CONFIG_PWRSEQ_SIMPLE=y` |
| **标准化** | ❌ Rockchip 专有 | ✅ Linux 标准 |
| **跨平台** | ❌ 仅 Rockchip | ✅ 所有平台 |
| **功能丰富度** | ✅ 丰富 | ⚠️ 基本 |
| **API 支持** | ✅ `rockchip_wifi_power()` 等 | ❌ 无专用 API |
| **芯片类型** | ✅ 可指定 `wifi_chip_type` | ❌ 不支持 |
| **主线支持** | ❌ 非主线 | ✅ 主线支持 |
| **代码复杂度** | ⚠️ 复杂（~1000 行） | ✅ 简单（~200 行） |

---

## 3. EAIDK-610 的实际配置

### 当前配置（mmc-pwrseq 方式）

```dts
/ {
    // 定义电源序列
    sdio_pwrseq: sdio-pwrseq {
        compatible = "mmc-pwrseq-simple";
        clocks = <&rk808 1>;              // RK808 PMIC 的 32KHz 时钟输出
        clock-names = "ext_clock";
        pinctrl-names = "default";
        pinctrl-0 = <&wifi_enable_h>;

        /*
         * 复位 GPIO：
         * - GPIO0_PB2 (SDIO_RESET_L_WL_REG_ON)
         * - GPIO_ACTIVE_LOW：低电平有效
         */
        reset-gpios = <&gpio0 RK_PB2 GPIO_ACTIVE_LOW>;
    };
};

&sdio0 {
    /* WiFi & BT combo module AMPAK AP6255 */
    #address-cells = <1>;
    #size-cells = <0>;
    bus-width = <4>;
    clock-frequency = <50000000>;
    cap-sdio-irq;
    cap-sd-highspeed;
    keep-power-in-suspend;
    mmc-pwrseq = <&sdio_pwrseq>;      // ← 引用电源序列
    non-removable;
    pinctrl-names = "default";
    pinctrl-0 = <&sdio0_bus4 &sdio0_cmd &sdio0_clk>;
    sd-uhs-sdr104;
    status = "okay";

    brcmf: wifi@1 {
        compatible = "brcm,bcm4329-fmac";
        reg = <1>;
        interrupt-parent = <&gpio0>;
        interrupts = <RK_PA3 GPIO_ACTIVE_HIGH>;
        interrupt-names = "host-wake";
        pinctrl-names = "default";
        pinctrl-0 = <&wifi_host_wake_l>;
    };
};
```

---

## 4. 如果使用 wireless-wlan 方式

### 配置示例

```dts
/ {
    wireless-wlan {
        compatible = "wlan-platdata";
        rockchip,grf = <&grf>;

        /* 时钟配置 */
        clocks = <&rk808 1>;              // RK808 的 32KHz 时钟
        clock-names = "ext_clock";

        /* WiFi 芯片类型 */
        wifi_chip_type = "ap6255";

        /* Host Wake 中断 */
        WIFI,host_wake_irq = <&gpio0 RK_PA3 GPIO_ACTIVE_HIGH>;

        /* SDIO 参考电压（可选） */
        sdio_vref = <1800>;

        status = "okay";
    };
};

&sdio0 {
    /* 基本 SDIO 配置 */
    bus-width = <4>;
    clock-frequency = <50000000>;
    cap-sdio-irq;
    cap-sd-highspeed;
    keep-power-in-suspend;
    non-removable;
    pinctrl-names = "default";
    pinctrl-0 = <&sdio0_bus4 &sdio0_cmd &sdio0_clk>;
    sd-uhs-sdr104;
    status = "okay";

    // 注意：不需要 mmc-pwrseq
    // 也不需要 wifi@1 子节点
};
```

---

## 5. 两种方式的工作流程

### mmc-pwrseq 方式（EAIDK-610 当前使用）

```
1. 内核启动
   ↓
2. MMC 核心初始化 pwrseq_simple 驱动
   ↓
3. 解析 sdio_pwrseq 节点
   - 获取 reset-gpios (GPIO0_PB2)
   - 获取 clocks (RK808 32KHz)
   ↓
4. SDIO 主机控制器初始化 (sdio0)
   - 调用 mmc_pwrseq_pre_power_on()
     ├─ 启用 32KHz 时钟
     ├─ 拉低 reset GPIO (复位)
     └─ 延迟
   - 调用 mmc_pwrseq_post_power_on()
     └─ 拉高 reset GPIO (释放复位)
   ↓
5. SDIO 总线扫描
   - 检测到 WiFi 设备
   ↓
6. bcmdhd 驱动匹配并初始化
```

### wireless-wlan 方式（Rockchip 官方）

```
1. 内核启动
   ↓
2. RFKILL WLAN 驱动初始化
   ↓
3. 解析 wireless-wlan 节点
   - 获取 wifi_chip_type
   - 获取 WIFI,host_wake_irq
   - 获取 clocks
   ↓
4. 注册 rockchip_wifi_* API
   - rockchip_wifi_power()
   - rockchip_wifi_set_carddetect()
   - rockchip_wifi_get_oob_irq()
   ↓
5. bcmdhd 驱动调用 Rockchip API
   - 通过 rockchip_wifi_power(1) 上电
   - 通过 rockchip_wifi_set_carddetect(1) 触发扫描
   ↓
6. SDIO 总线扫描
   - 检测到 WiFi 设备
   ↓
7. bcmdhd 驱动匹配并初始化
```

---

## 6. 为什么 EAIDK-610 选择 mmc-pwrseq？

### 可能的原因

1. **标准化考虑**
   - 使用 Linux 内核标准方式
   - 更好的跨平台兼容性
   - 符合主线内核规范

2. **简化设计**
   - 不依赖 Rockchip 专有驱动
   - 代码更简洁
   - 减少维护负担

3. **驱动兼容性**
   - 同时支持 bcmdhd 和 brcmfmac
   - mmc-pwrseq 是两个驱动都支持的标准方式

4. **历史原因**
   - EAIDK-610 可能基于上游主线设备树
   - 主线内核不包含 rfkill-wlan 驱动

---

## 7. 两种方式的优缺点

### mmc-pwrseq 方式

**优点：**
- ✅ Linux 内核标准实现
- ✅ 跨平台兼容性好
- ✅ 代码简洁，易于维护
- ✅ 主线内核支持
- ✅ 同时支持多种 WiFi 驱动

**缺点：**
- ⚠️ 功能相对简单
- ⚠️ 不提供 Rockchip 特定 API
- ⚠️ bcmdhd 需要通过其他方式获取配置

---

### wireless-wlan 方式

**优点：**
- ✅ Rockchip 平台深度集成
- ✅ 提供丰富的 API
- ✅ 支持更多功能（芯片类型识别等）
- ✅ bcmdhd 可以直接使用 Rockchip API

**缺点：**
- ❌ Rockchip 专有，非标准
- ❌ 不在主线内核中
- ❌ 代码复杂（~1000 行）
- ❌ 跨平台兼容性差

---

## 8. bcmdhd 如何适配两种方式？

### bcmdhd 适配 mmc-pwrseq

```c
// dhd_gpio.c

// 方式 1：通过 SDIO 子系统的 pwrseq
// SDIO 主机控制器会自动调用 pwrseq 的上下电函数
// bcmdhd 不需要做任何事情

// 方式 2：如果需要手动控制，可以通过 GPIO
int gpio_wl_reg_on = of_get_named_gpio(np, "reset-gpios", 0);
if (gpio_is_valid(gpio_wl_reg_on)) {
    gpio_request(gpio_wl_reg_on, "WL_REG_ON");
    gpio_direction_output(gpio_wl_reg_on, 1);
}
```

### bcmdhd 适配 wireless-wlan

```c
// dhd_gpio.c

#ifdef CUSTOMER_HW_ROCKCHIP
#include <linux/rfkill-wlan.h>

// 直接使用 Rockchip API
rockchip_wifi_power(1);              // 上电
rockchip_wifi_set_carddetect(1);     // 触发卡检测
int irq = rockchip_wifi_get_oob_irq(); // 获取 OOB 中断
#endif
```

---

## 9. 当前配置是否正确？

### EAIDK-610 的配置完全正确！✅

**理由：**

1. ✅ **使用标准 Linux 方式**
   - `mmc-pwrseq-simple` 是主线内核标准
   - 符合设备树规范

2. ✅ **功能完整**
   - 电源序列配置完整
   - 时钟配置正确（RK808）
   - 复位 GPIO 配置正确

3. ✅ **驱动兼容性好**
   - bcmdhd 可以正常工作
   - brcmfmac 也可以工作
   - 不依赖 Rockchip 专有驱动

4. ✅ **内核配置支持**
   ```
   CONFIG_PWRSEQ_SIMPLE=y  ← 已启用
   CONFIG_RFKILL_RK=y      ← 已启用（但不强制需要）
   ```

---

## 10. 是否需要添加 wireless-wlan？

### 答案：不需要！❌

**理由：**

1. **当前配置已经工作**
   - mmc-pwrseq 提供了完整的电源管理
   - bcmdhd 可以正常工作

2. **添加 wireless-wlan 会冲突**
   - 两种方式会同时管理电源
   - 可能导致冲突和问题

3. **没有额外好处**
   - bcmdhd 不依赖 wireless-wlan
   - 通过 SDIO 总线自动检测设备

4. **增加复杂度**
   - 需要维护两套配置
   - 增加调试难度

---

## 11. 什么时候需要使用 wireless-wlan？

### 推荐使用 wireless-wlan 的场景

1. **使用 Rockchip 官方 BSP**
   - Rockchip 官方 SDK
   - Rockchip 官方开发板

2. **需要 Rockchip 特定功能**
   - 芯片类型自动识别
   - 特殊的电源管理
   - 调试和诊断功能

3. **Android 系统**
   - Android HAL 可能依赖 Rockchip API
   - 更好的 Android 集成

4. **多 WiFi 模块支持**
   - 需要根据 `wifi_chip_type` 动态配置
   - 不同模块使用不同参数

---

## 12. 配置对比总结

### EAIDK-610 当前配置（推荐）✅

```dts
优点：
✅ 标准 Linux 方式
✅ 简洁清晰
✅ 跨平台兼容
✅ 主线内核支持
✅ 驱动无关

适用场景：
- 标准 Linux 发行版
- 开源项目
- 需要主线内核支持
- 不依赖 Rockchip 专有功能
```

### 添加 wireless-wlan（可选）⚠️

```dts
优点：
✅ Rockchip 深度集成
✅ 功能更丰富
✅ API 支持更好

缺点：
❌ 非标准实现
❌ 代码复杂
❌ 可能与 mmc-pwrseq 冲突

适用场景：
- Rockchip 官方 BSP
- Android 系统
- 需要 Rockchip 特定功能
```

---

## 13. 最终建议

### 对于 EAIDK-610

**保持当前配置，不要添加 wireless-wlan！**

**理由：**

1. ✅ 当前配置完全正确且工作正常
2. ✅ 使用标准 Linux 方式更好
3. ✅ bcmdhd 驱动可以正常工作
4. ✅ 不需要依赖 Rockchip 专有驱动
5. ❌ 添加 wireless-wlan 没有额外好处
6. ❌ 可能引入冲突和问题

### 如果确实需要 wireless-wlan

如果您确实需要使用 wireless-wlan（比如需要 Rockchip 特定功能），建议：

1. **删除 mmc-pwrseq 配置**
   ```dts
   // 删除或禁用
   // sdio_pwrseq: sdio-pwrseq { ... };
   ```

2. **添加 wireless-wlan 节点**
   ```dts
   wireless-wlan {
       compatible = "wlan-platdata";
       rockchip,grf = <&grf>;
       clocks = <&rk808 1>;
       clock-names = "ext_clock";
       wifi_chip_type = "ap6255";
       WIFI,host_wake_irq = <&gpio0 RK_PA3 GPIO_ACTIVE_HIGH>;
       status = "okay";
   };
   ```

3. **修改 sdio0 节点**
   ```dts
   &sdio0 {
       // 删除 mmc-pwrseq 引用
       // mmc-pwrseq = <&sdio_pwrseq>;

       // 其他配置保持不变
   };
   ```

但是，**强烈不推荐**这样做，除非有明确的需求。

---

## 14. 参考文档

### 内核源码位置

```
mmc-pwrseq 驱动：
drivers/mmc/core/pwrseq_simple.c
Documentation/devicetree/bindings/mmc/mmc-pwrseq-simple.txt

wireless-wlan 驱动：
net/rfkill/rfkill-wlan.c
include/linux/rfkill-wlan.h

bcmdhd 驱动：
drivers/net/wireless/rockchip_wlan/rkwifi/bcmdhd/
```

### 设备树示例

```
标准方式（mmc-pwrseq）：
arch/arm64/boot/dts/rockchip/rk3399-eaidk-610.dts

Rockchip 方式（wireless-wlan）：
arch/arm64/boot/dts/rockchip/rk3399-firefly-linux.dts
arch/arm64/boot/dts/rockchip/rk3399pro-evb-v11-linux.dts
```

---

## 总结

| 问题 | 答案 |
|------|------|
| **为什么没有 wireless-wlan？** | 使用了标准 Linux 的 mmc-pwrseq 方式 |
| **是否需要添加？** | ❌ 不需要，当前配置已经正确 |
| **两种方式哪个更好？** | mmc-pwrseq 更标准，wireless-wlan 功能更丰富 |
| **bcmdhd 需要哪种？** | 两种都支持，不强制要求 |
| **会有冲突吗？** | 同时使用会冲突，只能选一种 |

**最终建议：保持 EAIDK-610 当前的 mmc-pwrseq 配置，不要添加 wireless-wlan。**
