# AP6255 brcmfmac驱动完整加载流程详解

## 目录

1. [概述](#一概述)
2. [设备树配置层](#二设备树配置层)
3. [Pinctrl子系统详解](#三pinctrl子系统详解)
4. [内核驱动加载流程](#四内核驱动加载流程)
5. [运行时数据流](#五运行时数据流)
6. [关键dmesg日志](#六关键dmesg日志)
7. [完整流程图](#七完整流程图)
8. [关键数据结构](#八关键数据结构)
9. [调试技巧](#九调试技巧)
10. [常见问题](#十常见问题)
11. [性能优化](#十一性能优化)
12. [总结](#十二总结)

---

## 一、概述

AP6255是正基科技(AMPAK)推出的WiFi+BT combo模块，内部使用Broadcom BCM4339芯片。在RK3399平台上通过SDIO接口连接，使用主线内核的brcmfmac驱动。

### ⚠️ 重要概念说明

**Platform Device vs SDIO Device**

在设备树中定义的三个设备节点有不同的创建方式：

1. **sdio_pwrseq** (根节点子节点) → **platform_device**
   - 在 `arch_initcall_sync` 阶段由 `of_platform_default_populate_init()` 自动创建
   - 类型：platform_device
   - 总线：platform_bus

2. **sdio0** (根节点子节点) → **platform_device**
   - 在 `arch_initcall_sync` 阶段由 `of_platform_default_populate_init()` 自动创建
   - 类型：platform_device
   - 总线：platform_bus

3. **wifi@1** (sdio0的子节点) → **sdio_device**
   - **不会被自动创建为 platform_device**
   - 在 SDIO 总线扫描时动态创建为 **sdio_func**
   - 类型：sdio_device (不是 platform_device)
   - 总线：sdio_bus (不是 platform_bus)
   - 创建时机：mmc_attach_sdio() → sdio_init_func()

**设备创建规则**：
- 只有**根节点的直接子节点**会被自动创建为 platform_device
- 总线设备的子节点由**对应的总线驱动**负责创建
- SDIO 设备类似于 USB 设备，是动态枚举的

详细分析请参考：`platform_device_creation_order.md`

### 1.1 硬件连接

```
RK3399 SoC                          AP6255 Module
┌─────────────────┐                ┌──────────────────┐
│                 │                │                  │
│  SDIO0          │◄──────────────►│  SDIO Interface  │
│  - CLK          │                │  - CLK           │
│  - CMD          │                │  - CMD           │
│  - DAT[0:3]     │                │  - DAT[0:3]      │
│                 │                │                  │
│  GPIO0_B2 ──────┼───────────────►│  WL_REG_ON       │
│  (WL_REG_ON)    │                │  (Power Enable)  │
│                 │                │                  │
│  GPIO0_A3 ◄─────┼────────────────│  WL_HOST_WAKE    │
│  (OOB IRQ)      │                │  (Interrupt Out) │
│                 │                │                  │
│  32.768KHz ─────┼───────────────►│  LPO_IN          │
│  (from RK808)   │                │  (Low Power Osc) │
└─────────────────┘                └──────────────────┘
```

### 1.2 关键组件

| 组件 | 作用 | 文件位置 |
|------|------|----------|
| 设备树 | 硬件描述 | `arch/arm64/boot/dts/rockchip/rk3399-eaidk-610.dts` |
| SDIO控制器驱动 | dw-mshc | `drivers/mmc/host/dw_mmc-rockchip.c` |
| MMC核心 | SDIO协议栈 | `drivers/mmc/core/` |
| brcmfmac驱动 | WiFi驱动 | `drivers/net/wireless/broadcom/brcm80211/brcmfmac/` |
| 固件 | WiFi协议栈 | `/lib/firmware/brcm/brcmfmac4339-sdio.bin` |

---

## 二、设备树配置层

### 2.1 SDIO0控制器定义 (rk3399.dtsi)

#### 2.1.1 基础定义 (行320-334)

```dts
sdio0: mmc@fe310000 {
    compatible = "rockchip,rk3399-dw-mshc", "rockchip,rk3288-dw-mshc";
    reg = <0x0 0xfe310000 0x0 0x4000>;
    interrupts = <GIC_SPI 64 IRQ_TYPE_LEVEL_HIGH 0>;
    max-frequency = <150000000>;
    clocks = <&cru HCLK_SDIO>, <&cru SCLK_SDIO>,
             <&cru SCLK_SDIO_DRV>, <&cru SCLK_SDIO_SAMPLE>;
    clock-names = "biu", "ciu", "ciu-drive", "ciu-sample";
    fifo-depth = <0x100>;
    power-domains = <&power RK3399_PD_SDIOAUDIO>;
    resets = <&cru SRST_SDIO0>;
    reset-names = "reset";
    status = "disabled";
};
```

**关键属性说明**：

- `compatible`: 驱动匹配标识，指定使用dw-mshc控制器驱动
- `reg`: SDIO0控制器寄存器基地址 0xfe310000，大小 0x4000
- `interrupts`: SDIO0中断号 64，高电平触发
- `max-frequency`: 最大时钟频率 150MHz
- `clocks`: 4个时钟源
  - `HCLK_SDIO`: 总线时钟 (AHB)
  - `SCLK_SDIO`: SDIO卡时钟 (CIU)
  - `SCLK_SDIO_DRV`: 输出驱动时钟 (用于时钟相位调整)
  - `SCLK_SDIO_SAMPLE`: 采样时钟 (用于时钟相位调整)
- `power-domains`: 电源域 RK3399_PD_SDIOAUDIO
- `status = "disabled"`: 默认禁用，需要板级dts覆盖启用

#### 2.1.2 Pinctrl定义 (行2883-2918)

```dts
sdio0 {
    sdio0_bus1: sdio0-bus1 {
        rockchip,pins =
            <2 RK_PC4 1 &pcfg_pull_up>;
    };

    sdio0_bus4: sdio0-bus4 {
        rockchip,pins =
            <2 RK_PC4 1 &pcfg_pull_up>,  // SDIO0_D0
            <2 RK_PC5 1 &pcfg_pull_up>,  // SDIO0_D1
            <2 RK_PC6 1 &pcfg_pull_up>,  // SDIO0_D2
            <2 RK_PC7 1 &pcfg_pull_up>;  // SDIO0_D3
    };

    sdio0_cmd: sdio0-cmd {
        rockchip,pins =
            <2 RK_PD0 1 &pcfg_pull_up>;  // SDIO0_CMD
    };

    sdio0_clk: sdio0-clk {
        rockchip,pins =
            <2 RK_PD1 1 &pcfg_pull_none>; // SDIO0_CLK
    };

    sdio0_cd: sdio0-cd {
        rockchip,pins =
            <2 RK_PD2 1 &pcfg_pull_up>;
    };

    sdio0_pwr: sdio0-pwr {
        rockchip,pins =
            <2 RK_PD3 1 &pcfg_pull_up>;
    };

    sdio0_bkpwr: sdio0-bkpwr {
        rockchip,pins =
            <2 RK_PD4 1 &pcfg_pull_up>;
    };

    sdio0_wp: sdio0-wp {
        rockchip,pins =
            <0 RK_PA3 1 &pcfg_pull_up>;
    };

    sdio0_int: sdio0-int {
        rockchip,pins =
            <0 RK_PA4 1 &pcfg_pull_up>;
    };
};
```

**Pinctrl配置说明**：

| 引脚组 | GPIO | 功能 | 上下拉 |
|--------|------|------|--------|
| sdio0_bus4 | GPIO2_C4-C7 | SDIO数据线D0-D3 | 上拉 |
| sdio0_cmd | GPIO2_D0 | SDIO命令线 | 上拉 |
| sdio0_clk | GPIO2_D1 | SDIO时钟线 | 无上下拉 |

### 2.2 板级配置 (rk3399-eaidk-610.dts)

#### 2.2.1 电源序列配置 (行154-168)

```dts
sdio_pwrseq: sdio-pwrseq {
    compatible = "mmc-pwrseq-simple";
    clocks = <&rk808 1>;
    clock-names = "ext_clock";
    pinctrl-names = "default";
    pinctrl-0 = <&wifi_enable_h>;
    reset-gpios = <&gpio0 RK_PB2 GPIO_ACTIVE_LOW>;
};
```

**配置解析**：

- `compatible = "mmc-pwrseq-simple"`: 使用简单电源序列驱动
  - 驱动位置: `drivers/mmc/core/pwrseq_simple.c`
  - 功能: 自动管理WiFi模块的上电/下电时序
  
- `clocks = <&rk808 1>`: 32.768KHz时钟源
  - 来自RK808 PMIC的CLK32K_OUT2输出
  - AP6255需要此时钟才能正常工作
  
- `pinctrl-0 = <&wifi_enable_h>`: 关联pinctrl配置
  - 在pwrseq初始化时自动应用
  
- `reset-gpios = <&gpio0 RK_PB2 GPIO_ACTIVE_LOW>`: WL_REG_ON控制
  - GPIO0_B2控制WiFi芯片电源使能
  - `GPIO_ACTIVE_LOW`: 低电平复位，高电平工作
  - pwrseq会自动控制此GPIO

**上电时序**：
```
pwrseq_simple_pre_power_on():
  1. clk_prepare_enable(clk)        // 使能32KHz时钟
  2. mdelay(1)                       // 延时1ms
  3. gpiod_set_value_cansleep(reset_gpio, 1)  // 拉高WL_REG_ON
  4. msleep(post_power_on_delay)    // 延时(默认0)
```

#### 2.2.2 Pinctrl自定义配置 (行718-744)

```dts
pinctrl {
    sdio-pwrseq {
        wifi_enable_h: wifi-enable-h {
            rockchip,pins = <0 RK_PB2 RK_FUNC_GPIO &pcfg_pull_none>;
        };
    };

    wifi {
        wifi_host_wake_l: wifi-host-wake-l {
            rockchip,pins = <0 RK_PA3 RK_FUNC_GPIO &pcfg_pull_none>;
        };
    };

    bt {
        bt_enable_h: bt-enable-h {
            rockchip,pins = <0 RK_PB1 RK_FUNC_GPIO &pcfg_pull_none>;
        };

        bt_host_wake_l: bt-host-wake-l {
            rockchip,pins = <0 RK_PA4 RK_FUNC_GPIO &pcfg_pull_none>;
        };

        bt_wake_l: bt-wake-l {
            rockchip,pins = <2 RK_PD2 RK_FUNC_GPIO &pcfg_pull_none>;
        };
    };
};
```

**引脚功能映射**：

| 引脚名称 | GPIO | 方向 | 功能 | 关联节点 |
|----------|------|------|------|----------|
| wifi_enable_h | GPIO0_B2 | OUT | WL_REG_ON | sdio_pwrseq |
| wifi_host_wake_l | GPIO0_A3 | IN | OOB中断 | sdio0/wifi@1 |
| bt_enable_h | GPIO0_B1 | OUT | BT_REG_ON | uart0/bluetooth |
| bt_host_wake_l | GPIO0_A4 | IN | BT唤醒主机 | uart0/bluetooth |
| bt_wake_l | GPIO2_D2 | OUT | 主机唤醒BT | uart0/bluetooth |

#### 2.2.3 SDIO0节点配置 (行756-781)

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

**属性详解**：

**SDIO控制器属性**：
- `bus-width = <4>`: 4位SDIO总线
- `clock-frequency = <50000000>`: 初始时钟50MHz
- `cap-sdio-irq`: 支持SDIO中断
- `cap-sd-highspeed`: 支持高速模式
- `keep-power-in-suspend`: 休眠时保持供电
- `mmc-pwrseq = <&sdio_pwrseq>`: 关联电源序列
- `non-removable`: 不可移除设备
- `sd-uhs-sdr104`: 支持SDR104模式(最高104MHz)
- `pinctrl-0 = <&sdio0_bus4 &sdio0_cmd &sdio0_clk>`: SDIO引脚配置

**WiFi子节点属性**：
- `compatible = "brcm,bcm4329-fmac"`: 驱动匹配标识
- `reg = <1>`: SDIO Function 1地址
- `interrupt-parent = <&gpio0>`: 中断控制器
- `interrupts = <RK_PA3 GPIO_ACTIVE_HIGH>`: GPIO0_A3高电平触发
- `interrupt-names = "host-wake"`: 中断名称
- `pinctrl-0 = <&wifi_host_wake_l>`: OOB中断引脚配置

---

## 三、Pinctrl子系统详解

### 3.1 Pinctrl工作原理

Pinctrl子系统负责管理SoC的引脚复用和配置。在设备probe时自动应用pinctrl配置。

#### 3.1.1 Pinctrl数据结构

```c
// include/linux/pinctrl/consumer.h
struct pinctrl {
    struct list_head node;
    struct device *dev;
    struct list_head states;
    struct pinctrl_state *state;
};

struct pinctrl_state {
    struct list_head node;
    const char *name;
    struct list_head settings;
};
```

#### 3.1.2 自动应用机制

```c
// drivers/base/dd.c: really_probe()
int really_probe(struct device *dev, struct device_driver *drv)
{
    // ...
    
    // 1. 获取设备的pinctrl句柄
    dev->pins = devm_kzalloc(dev, sizeof(*(dev->pins)), GFP_KERNEL);
    dev->pins->p = devm_pinctrl_get(dev);
    
    // 2. 查找"default"状态
    dev->pins->default_state = pinctrl_lookup_state(dev->pins->p, PINCTRL_STATE_DEFAULT);
    
    // 3. 自动应用"default"状态
    ret = pinctrl_select_state(dev->pins->p, dev->pins->default_state);
    
    // 4. 调用驱动的probe函数
    ret = drv->probe(dev);
    
    // ...
}
```

### 3.2 AP6255相关Pinctrl应用时机

#### 3.2.1 SDIO控制器Pinctrl

**应用时机**: dw-mshc驱动probe时

```
dw_mci_probe()
  └─ platform_get_resource()
  └─ devm_pinctrl_get() + pinctrl_select_state("default")
       └─ 应用 sdio0_bus4, sdio0_cmd, sdio0_clk
            └─ GPIO2_C4-C7, GPIO2_D0-D1 配置为SDIO功能
```

**配置内容**：
```dts
pinctrl-0 = <&sdio0_bus4 &sdio0_cmd &sdio0_clk>;
```

**实际效果**：
- GPIO2_C4: 配置为SDIO0_D0，上拉
- GPIO2_C5: 配置为SDIO0_D1，上拉
- GPIO2_C6: 配置为SDIO0_D2，上拉
- GPIO2_C7: 配置为SDIO0_D3，上拉
- GPIO2_D0: 配置为SDIO0_CMD，上拉
- GPIO2_D1: 配置为SDIO0_CLK，无上下拉

#### 3.2.2 电源序列Pinctrl

**应用时机**: mmc-pwrseq-simple驱动probe时

```
mmc_pwrseq_simple_alloc()
  └─ devm_pinctrl_get_select_default(dev)
       └─ 应用 wifi_enable_h
            └─ GPIO0_B2 配置为GPIO输出
```

**配置内容**：
```dts
sdio_pwrseq: sdio-pwrseq {
    pinctrl-names = "default";
    pinctrl-0 = <&wifi_enable_h>;
};
```

**实际效果**：
- GPIO0_B2: 配置为GPIO模式，输出，无上下拉
- 由pwrseq驱动控制高低电平

#### 3.2.3 WiFi OOB中断Pinctrl

**应用时机**: brcmfmac驱动probe时

```
brcmf_ops_sdio_probe()
  └─ brcmf_of_probe()
       └─ 解析设备树wifi@1节点
            └─ 自动应用pinctrl-0
                 └─ 应用 wifi_host_wake_l
                      └─ GPIO0_A3 配置为GPIO输入
```

**配置内容**：
```dts
brcmf: wifi@1 {
    pinctrl-names = "default";
    pinctrl-0 = <&wifi_host_wake_l>;
};
```

**实际效果**：
- GPIO0_A3: 配置为GPIO模式，输入，无上下拉
- 作为OOB中断输入引脚

### 3.3 Pinctrl配置格式

#### 3.3.1 Rockchip Pinctrl格式

```dts
<bank pin function config>
```

**参数说明**：
- `bank`: GPIO bank编号 (0-4对应GPIO0-GPIO4)
- `pin`: 引脚编号 (RK_PA0-RK_PD7)
- `function`: 功能编号
  - 0: GPIO
  - 1-7: 复用功能1-7
- `config`: 配置参数指针 (&pcfg_xxx)

**示例**：
```dts
<0 RK_PB2 RK_FUNC_GPIO &pcfg_pull_none>
// GPIO0_B2, GPIO功能, 无上下拉

<2 RK_PC4 1 &pcfg_pull_up>
// GPIO2_C4, 功能1(SDIO0_D0), 上拉
```

#### 3.3.2 配置参数类型

```dts
// arch/arm64/boot/dts/rockchip/rk3399.dtsi

pcfg_pull_up: pcfg-pull-up {
    bias-pull-up;
};

pcfg_pull_down: pcfg-pull-down {
    bias-pull-down;
};

pcfg_pull_none: pcfg-pull-none {
    bias-disable;
};

pcfg_pull_none_12ma: pcfg-pull-none-12ma {
    bias-disable;
    drive-strength = <12>;
};
```

### 3.4 完整Pinctrl应用流程

```
系统启动
    ↓
设备树解析 (arch_initcall_sync)
    ↓
创建platform_device
    ├─ sdio_pwrseq (根节点子节点)
    └─ sdio0 (根节点子节点)
注意: wifi@1不会被创建(是sdio0的子节点，等待SDIO总线扫描)
    ↓
┌─────────────────────────────────────────────┐
│ 1. SDIO控制器Pinctrl应用                    │
│    (dw-mshc驱动probe)                       │
│    ├─ devm_pinctrl_get(&pdev->dev)          │
│    ├─ pinctrl_lookup_state("default")       │
│    └─ pinctrl_select_state()                │
│         └─ 配置GPIO2_C4-C7,D0-D1为SDIO功能 │
└─────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────┐
│ 2. 电源序列驱动probe                        │
│    (mmc-pwrseq-simple驱动probe)             │
│    ├─ devm_pinctrl_get_select_default()     │
│    │    └─ 配置GPIO0_B2为GPIO输出           │
│    ├─ 获取reset-gpios (不操作)              │
│    ├─ 获取clocks (不使能)                   │
│    └─ mmc_pwrseq_register() 注册到链表      │
│  ⚠️ 注意: 只准备资源，不执行上电            │
└─────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────┐
│ 3. SDIO控制器驱动probe                      │
│    (dw-mshc驱动)                            │
│    ├─ mmc_pwrseq_alloc() 查找并绑定pwrseq   │
│    │    └─ 如找不到返回-EPROBE_DEFER        │
│    └─ mmc_start_host() 触发mmc_rescan       │
└─────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────┐
│ 4. 执行电源序列 (在mmc_rescan中)            │
│    mmc_pwrseq_pre_power_on()                │
│    ├─ clk_prepare_enable(32KHz时钟) ← 首次 │
│    └─ gpiod_set_value(GPIO0_B2, 1) ← 首次  │
│  ⚠️ 这里才真正上电                          │
└─────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────┐
│ 5. SDIO总线扫描 (mmc_rescan继续)            │
│    └─ 发现AP6255 (Vendor:0x02d0, Dev:0x4339)│
└─────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────┐
│ 6. brcmfmac驱动probe                        │
│    (brcmf_ops_sdio_probe)                   │
│    └─ 自动应用wifi@1节点的pinctrl-0         │
│         └─ 配置GPIO0_A3为GPIO输入           │
└─────────────────────────────────────────────┘
    ↓
WiFi驱动初始化完成
```

### 3.5 Probe延迟机制 (EPROBE_DEFER)

**问题**: `mmc_rescan` 执行时，`mmc_pwrseq_simple_probe` 有可能还没执行吗？

**答案**: 不可能。内核通过 **probe 延迟机制**保证依赖顺序。

#### 3.5.1 工作原理

```c
// drivers/mmc/host/dw_mmc.c
static int dw_mci_probe(struct platform_device *pdev)
{
    struct mmc_host *host;

    // ... 初始化硬件 ...

    // 查找并绑定电源序列
    ret = mmc_pwrseq_alloc(host);
    if (ret) {
        // 如果 pwrseq 未注册，返回 -EPROBE_DEFER
        return ret;  // ← 驱动 probe 失败，稍后重试
    }

    // 只有 pwrseq 已注册，才会执行到这里
    mmc_add_host(host);
    mmc_start_host(host);  // ← 触发 mmc_rescan

    return 0;
}
```

#### 3.5.2 执行流程

```
场景1: pwrseq 先注册 (正常情况)
  1. mmc_pwrseq_simple_probe()
      └─ mmc_pwrseq_register() ✓

  2. dw_mci_probe()
      ├─ mmc_pwrseq_alloc() ✓ 找到 pwrseq
      └─ mmc_start_host()
           └─ mmc_rescan()
                └─ mmc_pwrseq_pre_power_on() ✓ 执行上电

场景2: pwrseq 未注册 (延迟probe)
  1. dw_mci_probe()
      ├─ mmc_pwrseq_alloc() ✗ 找不到 pwrseq
      └─ return -EPROBE_DEFER  ← probe 失败

  2. mmc_pwrseq_simple_probe()
      └─ mmc_pwrseq_register() ✓

  3. dw_mci_probe() (重试)
      ├─ mmc_pwrseq_alloc() ✓ 找到 pwrseq
      └─ mmc_start_host()
           └─ mmc_rescan()
                └─ mmc_pwrseq_pre_power_on() ✓ 执行上电
```

#### 3.5.3 关键代码

```c
// drivers/mmc/core/pwrseq.c
int mmc_pwrseq_alloc(struct mmc_host *host)
{
    struct device_node *np;
    struct mmc_pwrseq *p;

    np = of_parse_phandle(host->parent->of_node, "mmc-pwrseq", 0);
    if (!np)
        return 0;  // 没有配置 pwrseq，不需要

    // 遍历全局链表查找匹配的 pwrseq
    mutex_lock(&pwrseq_list_mutex);
    list_for_each_entry(p, &pwrseq_list, pwrseq_node) {
        if (p->dev->of_node == np) {
            // 找到匹配的 pwrseq
            host->pwrseq = p;
            mutex_unlock(&pwrseq_list_mutex);
            of_node_put(np);
            return 0;
        }
    }
    mutex_unlock(&pwrseq_list_mutex);

    of_node_put(np);
    return -EPROBE_DEFER;  // ← 未找到，延迟 probe
}
```

#### 3.5.4 总结

| 阶段 | pwrseq probe | sdio0 probe | 上电操作 |
|------|-------------|-------------|---------|
| 准备 | 获取资源，注册到链表 | - | ❌ 未上电 |
| 绑定 | - | 查找并绑定 pwrseq | ❌ 未上电 |
| 扫描 | - | 触发 mmc_rescan | ✅ 真正上电 |

**关键点**：
- ✅ `mmc_rescan` 执行时，`pwrseq` 一定已注册
- ✅ Probe 失败会自动重试，直到依赖满足
- ✅ 上电操作在 `mmc_rescan` 中，不在 `probe` 中
```

---
## 四、内核驱动加载流程

### 4.1 模块初始化阶段

#### 4.1.1 模块入口 (common.c:527)

```c
static int __init brcmfmac_module_init(void)
{
    int err;

    /* Get the platform data (if available) for our devices */
    err = platform_driver_probe(&brcmf_pd, brcmf_common_pd_probe);
    if (err == -ENODEV)
        brcmf_dbg(INFO, "No platform data available.\n");

    /* Initialize global module paramaters */
    brcmf_mp_attach();

    /* Continue the initialization by registering the different busses */
    err = brcmf_core_init();
    if (err) {
        if (brcmfmac_pdata)
            platform_driver_unregister(&brcmf_pd);
    }

    return err;
}

module_init(brcmfmac_module_init);
```

**执行流程**：
1. `platform_driver_probe()`: 查找平台数据(通常不存在)
2. `brcmf_mp_attach()`: 初始化模块参数
3. `brcmf_core_init()`: 注册各总线驱动

#### 4.1.2 核心初始化 (core.c:1520)

```c
int __init brcmf_core_init(void)
{
    int err;

    err = brcmf_sdio_register();
    if (err)
        return err;

    err = brcmf_usb_register();
    if (err)
        goto error_usb_register;

    err = brcmf_pcie_register();
    if (err)
        goto error_pcie_register;

    return 0;

error_pcie_register:
    brcmf_usb_exit();
error_usb_register:
    brcmf_sdio_exit();
    return err;
}
```

**关键点**：
- 注册SDIO、USB、PCIe三种总线驱动
- AP6255使用SDIO接口，重点关注`brcmf_sdio_register()`

#### 4.1.3 SDIO驱动注册 (bcmsdh.c:1231)

```c
int brcmf_sdio_register(void)
{
    return sdio_register_driver(&brcmf_sdmmc_driver);
}

static struct sdio_driver brcmf_sdmmc_driver = {
    .probe = brcmf_ops_sdio_probe,
    .remove = brcmf_ops_sdio_remove,
    .name = KBUILD_MODNAME,
    .id_table = brcmf_sdmmc_ids,
    .drv = {
        .owner = THIS_MODULE,
        .pm = pm_sleep_ptr(&brcmf_sdio_pm_ops),
        .coredump = brcmf_dev_coredump,
    },
};
```

**支持的设备ID表** (bcmsdh.c:966):

```c
static const struct sdio_device_id brcmf_sdmmc_ids[] = {
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_43143),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_43241),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_4329),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_4330),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_4334),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_43340),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_43341),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_43362),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_43364),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_4335_4339),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_4339),  // ← AP6255匹配
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_43430),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_4345),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_43455),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_4354),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_4356),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_4359),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_CYPRESS_4373),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_CYPRESS_43012),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_CYPRESS_43439),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_CYPRESS_43752),
    BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_CYPRESS_89359),
    { /* end: all zeroes */ }
};
MODULE_DEVICE_TABLE(sdio, brcmf_sdmmc_ids);
```

### 4.2 MMC/SDIO子系统扫描

#### 4.2.1 SDIO控制器初始化

```
dw_mci_rockchip_probe()
  ├─ 解析设备树资源
  │    ├─ reg: 寄存器基地址
  │    ├─ interrupts: 中断号
  │    ├─ clocks: 4个时钟
  │    └─ power-domains: 电源域
  │
  ├─ Pinctrl自动应用 ★
  │    └─ devm_pinctrl_get_select_default()
  │         └─ 配置SDIO引脚: GPIO2_C4-C7,D0-D1
  │
  ├─ 时钟初始化
  │    ├─ clk_prepare_enable(HCLK_SDIO)
  │    ├─ clk_prepare_enable(SCLK_SDIO)
  │    ├─ clk_prepare_enable(SCLK_SDIO_DRV)
  │    └─ clk_prepare_enable(SCLK_SDIO_SAMPLE)
  │
  ├─ 电源域使能
  │    └─ pm_runtime_get_sync() → RK3399_PD_SDIOAUDIO上电
  │
  ├─ 控制器复位
  │    └─ reset_control_assert/deassert(SRST_SDIO0)
  │
  ├─ 注册MMC host
  │    └─ mmc_add_host(mmc)
  │
  └─ 触发设备扫描
       └─ mmc_start_host()
```

#### 4.2.2 电源序列执行

```
mmc_start_host()
  └─ _mmc_detect_change()
       └─ mmc_rescan()
            ├─ mmc_power_off()  // 确保初始状态
            │
            ├─ mmc_pwrseq_pre_power_on(host->pwrseq) ★
            │    └─ mmc_pwrseq_simple_pre_power_on()
            │         ├─ Pinctrl自动应用 ★
            │         │    └─ 配置GPIO0_B2为GPIO输出
            │         │
            │         ├─ clk_prepare_enable(pwrseq->ext_clk)
            │         │    └─ 使能RK808的32KHz时钟
            │         │
            │         ├─ mdelay(1)  // 延时1ms
            │         │
            │         └─ gpiod_set_value_cansleep(reset_gpio, 1)
            │              └─ 拉高GPIO0_B2 (WL_REG_ON)
            │
            ├─ mmc_power_up()  // SDIO供电
            │    ├─ 设置VDD电压
            │    ├─ 延时等待稳定
            │    └─ 使能SDIO时钟
            │
            └─ mmc_pwrseq_post_power_on(host->pwrseq)
                 └─ msleep(post_power_on_delay)  // 默认0
```

**时序图**：
```
时间轴
  │
  ├─ T0: Pinctrl配置GPIO0_B2
  │
  ├─ T1: 使能32KHz时钟
  │
  ├─ T2: 延时1ms
  │
  ├─ T3: GPIO0_B2拉高 (AP6255上电)
  │      ┌────────────────────────────┐
  │      │ AP6255内部上电复位         │
  │      │ - 内部LDO稳定              │
  │      │ - 复位电路释放             │
  │      │ - SDIO接口初始化           │
  │      └────────────────────────────┘
  │
  ├─ T4: SDIO VDD供电
  │
  ├─ T5: SDIO时钟使能
  │
  └─ T6: 开始SDIO枚举
```

#### 4.2.3 SDIO设备枚举

```
mmc_rescan()
  └─ mmc_attach_sdio()
       ├─ mmc_send_io_op_cond()  // CMD5: 识别SDIO设备
       │    └─ 读取OCR寄存器
       │
       ├─ mmc_sdio_init_card()
       │    ├─ mmc_send_relative_addr()  // CMD3: 获取RCA
       │    ├─ mmc_select_card()         // CMD7: 选择卡
       │    ├─ mmc_sd_setup_card()
       │    │    └─ sdio_read_cis()  // 读取CIS
       │    │         ├─ Vendor ID: 0x02d0 (Broadcom)
       │    │         ├─ Device ID: 0x4339 (BCM4339)
       │    │         └─ Function数量: 3 (F0, F1, F2)
       │    │
       │    └─ sdio_init_func()  // 初始化Function
       │         ├─ Function 0: 公共寄存器
       │         ├─ Function 1: 控制通道
       │         └─ Function 2: 数据通道
       │
       └─ mmc_add_card()  // 添加到设备模型
            └─ device_add()
                 └─ bus_probe_device()
                      └─ sdio_bus_probe()
                           ├─ 遍历已注册的SDIO驱动
                           ├─ 匹配brcmf_sdmmc_driver
                           └─ 调用brcmf_ops_sdio_probe() ★
```

**dmesg日志**：
```
[    1.234] dwmmc_rockchip fe310000.mmc: IDMAC supports 32-bit address mode.
[    1.235] dwmmc_rockchip fe310000.mmc: Using internal DMA controller.
[    1.236] dwmmc_rockchip fe310000.mmc: Version ID is 270a
[    1.456] mmc_host mmc1: Bus speed (slot 0) = 400000Hz (slot req 400000Hz)
[    1.567] mmc1: new high speed SDIO card at address 0001
```

### 4.3 SDIO驱动Probe阶段

#### 4.3.1 Probe入口 (bcmsdh.c:1025)

```c
static int brcmf_ops_sdio_probe(struct sdio_func *func,
                                const struct sdio_device_id *id)
{
    int err;
    struct brcmf_sdio_dev *sdiodev;
    struct brcmf_bus *bus_if;

    brcmf_dbg(SDIO, "Enter\n");
    brcmf_dbg(SDIO, "Class=%x\n", func->class);
    brcmf_dbg(SDIO, "sdio vendor ID: 0x%04x\n", func->vendor);
    brcmf_dbg(SDIO, "sdio device ID: 0x%04x\n", func->device);
    brcmf_dbg(SDIO, "Function#: %d\n", func->num);

    /* Set MMC_QUIRK_LENIENT_FN0 for this card */
    func->card->quirks |= MMC_QUIRK_LENIENT_FN0;

    /* Consume func num 1 but dont do anything with it. */
    if (func->num == 1)
        return 0;

    /* Ignore anything but func 2 */
    if (func->num != 2)
        return -ENODEV;

    /* 分配设备结构 */
    bus_if = kzalloc(sizeof(struct brcmf_bus), GFP_KERNEL);
    if (!bus_if)
        return -ENOMEM;
    
    sdiodev = kzalloc(sizeof(struct brcmf_sdio_dev), GFP_KERNEL);
    if (!sdiodev) {
        kfree(bus_if);
        return -ENOMEM;
    }

    /* store refs to functions used. mmc_card does
     * not hold the F0 function pointer.
     */
    sdiodev->func1 = func->card->sdio_func[0];
    sdiodev->func2 = func;

    sdiodev->bus_if = bus_if;
    bus_if->bus_priv.sdio = sdiodev;
    bus_if->proto_type = BRCMF_PROTO_BCDC;
    dev_set_drvdata(&func->dev, bus_if);
    dev_set_drvdata(&sdiodev->func1->dev, bus_if);
    sdiodev->dev = &sdiodev->func1->dev;

    brcmf_sdiod_acpi_save_power_manageable(sdiodev);
    brcmf_sdiod_change_state(sdiodev, BRCMF_SDIOD_DOWN);

    brcmf_dbg(SDIO, "F2 found, calling brcmf_sdiod_probe...\n");
    err = brcmf_sdiod_probe(sdiodev);
    if (err) {
        brcmf_err("F2 error, probe failed %d...\n", err);
        goto fail;
    }

    brcmf_dbg(SDIO, "F2 init completed...\n");
    return 0;

fail:
    dev_set_drvdata(&func->dev, NULL);
    dev_set_drvdata(&sdiodev->func1->dev, NULL);
    kfree(sdiodev);
    kfree(bus_if);
    return err;
}
```

**关键点**：
- SDIO WiFi芯片有3个Function: F0(公共), F1(控制), F2(数据)
- Probe会被调用2次: func->num=1和func->num=2
- func->num=1时直接返回0，只记录不处理
- func->num=2时才执行真正的初始化

#### 4.3.2 设备树参数解析 (of.c:68)

```c
void brcmf_of_probe(struct device *dev, enum brcmf_bus_type bus_type,
                    struct brcmf_mp_device *settings)
{
    struct brcmfmac_sdio_pd *sdio = &settings->bus.sdio;
    struct device_node *root, *np = dev->of_node;
    const char *prop;
    int irq;
    int err;
    u32 irqf;
    u32 val;

    /* Apple ARM64 platforms have their own idea of board type */
    err = of_property_read_string(np, "brcm,board-type", &prop);
    if (!err)
        settings->board_type = prop;

    if (!of_property_read_string(np, "apple,antenna-sku", &prop))
        settings->antenna_sku = prop;

    /* Set board-type to the first string of the machine compatible prop */
    root = of_find_node_by_path("/");
    if (root && err) {
        char *board_type;
        const char *tmp;

        of_property_read_string_index(root, "compatible", 0, &tmp);

        /* get rid of '/' in the compatible string to be able to find the FW */
        board_type = devm_kstrdup(dev, tmp, GFP_KERNEL);
        if (!board_type) {
            of_node_put(root);
            return;
        }
        strreplace(board_type, '/', '-');
        settings->board_type = board_type;

        of_node_put(root);
    }

    if (!np || !of_device_is_compatible(np, "brcm,bcm4329-fmac"))
        return;

    err = brcmf_of_get_country_codes(dev, settings);
    if (err)
        brcmf_err("failed to get OF country code map (err=%d)\n", err);

    of_get_mac_address(np, settings->mac);

    if (bus_type != BRCMF_BUSTYPE_SDIO)
        return;

    if (of_property_read_u32(np, "brcm,drive-strength", &val) == 0)
        sdio->drive_strength = val;

    /* make sure there are interrupts defined in the node */
    if (!of_find_property(np, "interrupts", NULL))
        return;

    irq = irq_of_parse_and_map(np, 0);  // ★ 解析GPIO0_A3中断
    if (!irq) {
        brcmf_err("interrupt could not be mapped\n");
        return;
    }
    irqf = irqd_get_trigger_type(irq_get_irq_data(irq));

    sdio->oob_irq_supported = true;
    sdio->oob_irq_nr = irq;
    sdio->oob_irq_flags = irqf;
}
```

**解析内容**：
1. `board_type`: 从根节点compatible获取，用于固件路径
2. `brcm,drive-strength`: SDIO驱动强度
3. `interrupts`: OOB中断配置
   - 从wifi@1节点解析
   - GPIO0_A3 → 转换为IRQ号
   - 获取触发类型(高电平/上升沿)

**Pinctrl自动应用**：
- wifi@1节点的`pinctrl-0 = <&wifi_host_wake_l>`
- 在设备probe时自动应用
- GPIO0_A3配置为GPIO输入模式

#### 4.3.3 SDIO设备初始化 (bcmsdh.c:895)

```c
int brcmf_sdiod_probe(struct brcmf_sdio_dev *sdiodev)
{
    int ret = 0;
    unsigned int f2_blksz = SDIO_FUNC2_BLOCKSIZE;

    sdio_claim_host(sdiodev->func1);

    ret = sdio_set_block_size(sdiodev->func1, SDIO_FUNC1_BLOCKSIZE);
    if (ret) {
        brcmf_err("Failed to set F1 blocksize\n");
        sdio_release_host(sdiodev->func1);
        return ret;
    }
    
    switch (sdiodev->func2->device) {
    case SDIO_DEVICE_ID_BROADCOM_CYPRESS_4373:
        f2_blksz = SDIO_4373_FUNC2_BLOCKSIZE;
        break;
    case SDIO_DEVICE_ID_BROADCOM_4359:
    case SDIO_DEVICE_ID_BROADCOM_4354:
    case SDIO_DEVICE_ID_BROADCOM_4356:
        f2_blksz = SDIO_435X_FUNC2_BLOCKSIZE;
        break;
    case SDIO_DEVICE_ID_BROADCOM_4329:
        f2_blksz = SDIO_4329_FUNC2_BLOCKSIZE;
        break;
    default:
        break;
    }

    ret = sdio_set_block_size(sdiodev->func2, f2_blksz);
    if (ret) {
        brcmf_err("Failed to set F2 blocksize\n");
        sdio_release_host(sdiodev->func1);
        return ret;
    } else {
        brcmf_dbg(SDIO, "set F2 blocksize to %d\n", f2_blksz);
    }

    /* increase F2 timeout */
    sdiodev->func2->enable_timeout = SDIO_WAIT_F2RDY;

    /* Enable Function 1 */
    ret = sdio_enable_func(sdiodev->func1);
    sdio_release_host(sdiodev->func1);
    if (ret) {
        brcmf_err("Failed to enable F1: err=%d\n", ret);
        goto out;
    }

    ret = brcmf_sdiod_freezer_attach(sdiodev);
    if (ret)
        goto out;

    /* try to attach to the target device */
    sdiodev->bus = brcmf_sdio_probe(sdiodev);
    if (!sdiodev->bus) {
        ret = -ENODEV;
        goto out;
    }
    brcmf_sdiod_host_fixup(sdiodev->func2->card->host);
out:
    if (ret)
        brcmf_sdiod_remove(sdiodev);

    return ret;
}
```

**执行步骤**：
1. 设置F1块大小: 64字节
2. 设置F2块大小: 512字节(BCM4339)
3. 增加F2超时: 3000ms
4. 使能Function 1
5. 附加freezer(电源管理)
6. 调用`brcmf_sdio_probe()`

### 4.4 SDIO总线层初始化

#### 4.4.1 总线Probe (sdio.c:4435)

```c
struct brcmf_sdio *brcmf_sdio_probe(struct brcmf_sdio_dev *sdiodev)
{
    int ret;
    struct brcmf_sdio *bus;
    struct workqueue_struct *wq;
    struct brcmf_fw_request *fwreq;

    brcmf_dbg(TRACE, "Enter\n");

    /* Allocate private bus interface state */
    bus = kzalloc(sizeof(struct brcmf_sdio), GFP_ATOMIC);
    if (!bus)
        goto fail;

    bus->sdiodev = sdiodev;
    sdiodev->bus = bus;
    skb_queue_head_init(&bus->glom);
    bus->txbound = BRCMF_TXBOUND;
    bus->rxbound = BRCMF_RXBOUND;
    bus->txminmax = BRCMF_TXMINMAX;
    bus->tx_seq = SDPCM_SEQ_WRAP - 1;

    /* single-threaded workqueue */
    wq = alloc_workqueue("brcmf_wq/%s", WQ_HIGHPRI | WQ_MEM_RECLAIM |
                         WQ_UNBOUND, 1, dev_name(&sdiodev->func1->dev));
    if (!wq) {
        brcmf_err("insufficient memory to create txworkqueue\n");
        goto fail;
    }
    brcmf_sdiod_freezer_count(sdiodev);
    INIT_WORK(&bus->datawork, brcmf_sdio_dataworker);
    bus->brcmf_wq = wq;

    /* attempt to attach to the dongle */
    if (!(brcmf_sdio_probe_attach(bus))) {
        brcmf_err("brcmf_sdio_probe_attach failed\n");
        goto fail;
    }

    spin_lock_init(&bus->rxctl_lock);
    spin_lock_init(&bus->txq_lock);
    init_waitqueue_head(&bus->ctrl_wait);
    init_waitqueue_head(&bus->dcmd_resp_wait);

    /* Set up the watchdog timer */
    timer_setup(&bus->timer, brcmf_sdio_watchdog, 0);
    /* Initialize watchdog thread */
    init_completion(&bus->watchdog_wait);
    bus->watchdog_tsk = kthread_run(brcmf_sdio_watchdog_thread,
                                     bus, "brcmf_wdog/%s",
                                     dev_name(&sdiodev->func1->dev));
    if (IS_ERR(bus->watchdog_tsk)) {
        pr_warn("brcmf_watchdog thread failed to start\n");
        bus->watchdog_tsk = NULL;
    }

    /* Initialize DPC thread */
    bus->dpc_triggered = false;
    bus->dpc_running = false;

    /* Assign bus interface call back */
    bus->sdiodev->bus_if->ops = &brcmf_sdio_bus_ops;
    bus->sdiodev->bus_if->chip = bus->ci->chip;
    bus->sdiodev->bus_if->chiprev = bus->ci->chiprev;

    /* Prepare for firmware download */
    fwreq = brcmf_sdio_prepare_fw_request(bus);
    if (!fwreq) {
        ret = -ENOMEM;
        goto fail;
    }

    /* default firmware path */
    ret = brcmf_fw_get_firmwares(sdiodev->dev, fwreq,
                                   brcmf_sdio_firmware_callback);
    if (ret != 0) {
        brcmf_err("async firmware request failed: %d\n", ret);
        brcmf_fw_request_done(fwreq);
        goto fail;
    }

    return bus;

fail:
    brcmf_sdio_remove(bus);
    return NULL;
}
```

**关键步骤**：
1. 分配总线结构
2. 创建高优先级工作队列
3. 调用`brcmf_sdio_probe_attach()`识别芯片
4. 初始化看门狗线程
5. 准备固件请求
6. 异步加载固件

#### 4.4.2 芯片识别 (sdio.c:3949)

```c
static bool brcmf_sdio_probe_attach(struct brcmf_sdio *bus)
{
    struct brcmf_sdio_dev *sdiodev;
    u8 clkctl = 0;
    int err = 0;
    int reg_addr;
    u32 reg_val;
    u32 drivestrength;
    u32 enum_base;

    sdiodev = bus->sdiodev;

    sdio_claim_host(sdiodev->func1);

    pr_debug("F1 signature read @0x18000000=0x%4x\n",
             brcmf_sdiod_readl(sdiodev, SI_ENUM_BASE, NULL));

    /*
     * Force PLL off until brcmf_chip_attach()
     * programs PLL control regs
     */

    brcmf_sdiod_writeb(sdiodev, SBSDIO_FUNC1_CHIPCLKCSR,
                        BRCMF_INIT_CLKCTL1, &err);
    if (!err)
        clkctl = brcmf_sdiod_readb(sdiodev,
                                    SBSDIO_FUNC1_CHIPCLKCSR, &err);

    if (err || ((clkctl & ~SBSDIO_AVBITS) != BRCMF_INIT_CLKCTL1)) {
        brcmf_err("ChipClkCSR access: err %d wrote 0x%02x read 0x%02x\n",
                  err, BRCMF_INIT_CLKCTL1, clkctl);
        goto fail;
    }

    /* SDIO register access works - attach chip module */
    err = brcmf_chip_attach(sdiodev, &bus->ci);
    if (err) {
        brcmf_err("brcmf_chip_attach failed!\n");
        goto fail;
    }

    /* Pick up the SDIO core info struct from chip.c */
    sdiodev->cc_core = brcmf_chip_get_core(bus->ci, BCMA_CORE_SDIO_DEV);
    if (!sdiodev->cc_core) {
        brcmf_err("Can't find SDIO core!\n");
        goto fail;
    }

    /* Pick up the CHIPCOMMON core info struct */
    sdiodev->cc_core = brcmf_chip_get_core(bus->ci, BCMA_CORE_CHIPCOMMON);
    if (!sdiodev->cc_core) {
        brcmf_err("Can't find CHIPCOMMON core!\n");
        goto fail;
    }

    /* Set core control so an SDIO reset does a backplane reset */
    reg_addr = sdiodev->cc_core->base + offsetof(struct sdpcmd_regs, corecontrol);
    reg_val = brcmf_sdiod_readl(sdiodev, reg_addr, &err);
    brcmf_sdiod_writel(sdiodev, reg_addr, reg_val | CC_BPRESEN, &err);

    brcmu_pktq_init(&bus->txq, (PRIOMASK + 1), TXQLEN);

    /* Locate an appropriately-aligned portion of hdrbuf */
    bus->rxhdr = (u8 *) roundup((unsigned long)&bus->hdrbuf[0],
                                 BRCMF_SDALIGN);

    /* Set the poll and/or interrupt flags */
    bus->intr = true;
    bus->poll = false;
    if (bus->poll)
        bus->pollrate = 1;

    /* Query drive strength from device tree */
    if (sdiodev->settings->bus.sdio.drive_strength)
        drivestrength = sdiodev->settings->bus.sdio.drive_strength;
    else
        drivestrength = DEFAULT_SDIO_DRIVE_STRENGTH;
    brcmf_sdio_drivestrengthinit(sdiodev, bus->ci, drivestrength);

    /* Set card control so an SDIO card reset does a WLAN backplane reset */
    reg_val = brcmf_sdiod_func0_rb(sdiodev, SDIO_CCCR_BRCM_CARDCTRL, &err);
    if (err)
        goto fail;

    reg_val |= SDIO_CCCR_BRCM_CARDCTRL_WLANRESET;

    brcmf_sdiod_func0_wb(sdiodev, SDIO_CCCR_BRCM_CARDCTRL, reg_val, &err);
    if (err)
        goto fail;

    /* set PMUControl so a backplane reset does PMU state reload */
    reg_addr = sdiodev->cc_core->base + offsetof(struct chipcregs, pmucontrol);
    reg_val = brcmf_sdiod_readl(sdiodev, reg_addr, &err);
    if (err)
        goto fail;

    reg_val |= (BCMA_CC_PMU_CTL_RES_RELOAD << BCMA_CC_PMU_CTL_RES_SHIFT);

    brcmf_sdiod_writel(sdiodev, reg_addr, reg_val, &err);
    if (err)
        goto fail;

    sdio_release_host(sdiodev->func1);

    brcmf_sdio_sr_init(bus);

    return true;

fail:
    sdio_release_host(sdiodev->func1);
    return false;
}
```

**执行流程**：
1. 读取芯片签名(0x18000000地址)
2. 强制使能ALP时钟
3. `brcmf_chip_attach()`: 识别芯片
   - 读取ChipID: 0x4339
   - 读取ChipRev: 0x01
   - 识别cores: SDIO DEV, CHIPCOMMON, ARM CR4等
4. 配置SDIO驱动强度
5. 使能Function 2
6. 分配scatter-gather表

**dmesg输出**：
```
[    2.234] brcmfmac: F1 signature read @0x18000000=0x16044339
[    2.235] brcmfmac: brcmf_chip_recognition: chip 0x4339 rev 1
```

### 4.5 固件加载阶段

#### 4.5.1 固件路径构建 (firmware.c)

```c
static int brcmf_fw_alloc_request(struct brcmf_fw *fwctx,
                                   struct brcmf_fw_request *req)
{
    struct brcmf_fw_item *items = req->items;
    const char *mp_path;
    size_t mp_path_len;
    int i;

    for (i = 0; i < req->n_items; i++) {
        items[i].path = brcmf_fw_get_full_path(fwctx->dev->driver->name,
                                                 items[i].path);
        if (!items[i].path)
            goto fail;
    }

    return 0;

fail:
    for (--i; i >= 0; i--)
        kfree(items[i].path);
    return -ENOMEM;
}
```

**固件文件名格式**：
```
brcmfmac{chipid}{chiprev}-{bus}.{board_type}.bin
```

**AP6255固件搜索路径**（按优先级）：
1. `/lib/firmware/brcm/brcmfmac4339-sdio.openailab,eaidk-610.bin`
2. `/lib/firmware/brcm/brcmfmac4339-sdio.bin`

**NVRAM文件**：
- `/lib/firmware/brcm/brcmfmac4339-sdio.openailab,eaidk-610.txt`
- `/lib/firmware/brcm/brcmfmac4339-sdio.txt`

**CLM文件**（可选）：
- `/lib/firmware/brcm/brcmfmac4339-sdio.clm_blob`

#### 4.5.2 固件异步加载

```c
int brcmf_fw_get_firmwares(struct device *dev,
                            struct brcmf_fw_request *req,
                            void (*fw_cb)(struct device *dev, int err,
                                         struct brcmf_fw_request *req))
{
    struct brcmf_fw *fwctx;

    fwctx = kzalloc(sizeof(*fwctx), GFP_KERNEL);
    if (!fwctx)
        return -ENOMEM;

    fwctx->dev = dev;
    fwctx->req = req;
    fwctx->done = fw_cb;

    brcmf_fw_request_firmware(fwctx);
    return 0;
}

static void brcmf_fw_request_firmware(const struct firmware **fw, void *ctx)
{
    struct brcmf_fw *fwctx = ctx;

    ret = request_firmware_nowait(THIS_MODULE, true, fw_name,
                                    fwctx->dev, GFP_KERNEL, fwctx,
                                    brcmf_fw_request_done);
}
```

**异步加载优点**：
- 不阻塞系统启动
- 允许固件从文件系统加载(可能还未挂载)
- 提高启动速度

#### 4.5.3 固件回调 (sdio.c)

```c
static void brcmf_sdio_firmware_callback(struct device *dev, int err,
                                          struct brcmf_fw_request *fwreq)
{
    struct brcmf_bus *bus_if = dev_get_drvdata(dev);
    struct brcmf_sdio_dev *sdiodev = bus_if->bus_priv.sdio;
    struct brcmf_sdio *bus = sdiodev->bus;
    struct brcmf_core *core = bus->sdiodev->cc_core;
    const struct firmware *code;
    void *nvram;
    u32 nvram_len;
    u8 saveclk;

    brcmf_dbg(TRACE, "Enter: dev=%s, err=%d\n", dev_name(dev), err);

    if (err)
        goto fail;

    code = fwreq->items[BRCMF_SDIO_FW_CODE].binary;
    nvram = fwreq->items[BRCMF_SDIO_FW_NVRAM].nv_data.data;
    nvram_len = fwreq->items[BRCMF_SDIO_FW_NVRAM].nv_data.len;
    kfree(fwreq);

    /* Download firmware */
    sdio_claim_host(sdiodev->func1);
    brcmf_sdio_clkctl(bus, CLK_AVAIL, false);

    /* Download firmware to device */
    err = brcmf_sdio_download_firmware(bus, code, nvram, nvram_len);

    sdio_release_host(sdiodev->func1);
    if (err)
        goto fail;

    /* Register interrupt handler */
    err = brcmf_sdiod_intr_register(sdiodev);
    if (err) {
        brcmf_err("intr registration failed: %d\n", err);
        goto fail;
    }

    /* Attach bus */
    err = brcmf_bus_started(dev, bus_if);
    if (err != 0) {
        brcmf_err("dongle is not responding: err=%d\n", err);
        goto fail;
    }

    return;

fail:
    brcmf_dbg(TRACE, "failed: dev=%s, err=%d\n", dev_name(dev), err);
    device_release_driver(&sdiodev->func2->dev);
    device_release_driver(dev);
}
```

**执行步骤**：
1. 下载固件到芯片RAM
2. 注册中断处理
3. 启动总线(`brcmf_bus_started`)

#### 4.5.4 固件下载 (sdio.c)

```c
static int brcmf_sdio_download_firmware(struct brcmf_sdio *bus,
                                         const struct firmware *fw,
                                         void *nvram, u32 nvlen)
{
    int err;

    brcmf_dbg(TRACE, "Enter\n");

    /* Download firmware */
    brcmf_sdio_clkctl(bus, CLK_AVAIL, false);

    /* Keep arm in reset */
    if (bus->ci->chip == BRCM_CC_43430_CHIP_ID ||
        bus->ci->chip == BRCM_CC_4345_CHIP_ID ||
        bus->ci->chip == BRCM_CC_4356_CHIP_ID)
        brcmf_chip_set_passive(bus->ci);

    err = brcmf_sdio_download_code_file(bus, fw);
    if (err)
        return err;

    err = brcmf_sdio_download_nvram(bus, nvram, nvlen);
    if (err)
        return err;

    /* Take arm out of reset */
    if (!brcmf_chip_set_active(bus->ci, fw->size))
        return -EINVAL;

    return 0;
}
```

**固件下载流程**：
```
1. 复位ARM核心
   └─ brcmf_chip_set_passive()

2. 下载固件代码
   └─ brcmf_sdio_download_code_file()
        ├─ 通过SDIO写入固件到RAM
        └─ 地址从0开始，按块写入

3. 下载NVRAM配置
   └─ brcmf_sdio_download_nvram()
        ├─ 解析.txt文件
        ├─ 写入到RAM末尾
        └─ 设置NVRAM指针

4. 启动固件
   └─ brcmf_chip_set_active()
        ├─ 释放ARM复位
        └─ 跳转到固件入口点
```

### 4.6 中断注册阶段

#### 4.6.1 OOB中断注册 (bcmsdh.c:97)

```c
int brcmf_sdiod_intr_register(struct brcmf_sdio_dev *sdiodev)
{
    struct brcmfmac_sdio_pd *pdata;
    int ret = 0;
    u8 data;
    u32 addr, gpiocontrol;

    pdata = &sdiodev->settings->bus.sdio;
    if (pdata->oob_irq_supported) {
        brcmf_dbg(SDIO, "Enter, register OOB IRQ %d\n",
                  pdata->oob_irq_nr);
        spin_lock_init(&sdiodev->irq_en_lock);
        sdiodev->irq_en = true;

        ret = request_irq(pdata->oob_irq_nr, brcmf_sdiod_oob_irqhandler,
                          pdata->oob_irq_flags, "brcmf_oob_intr",
                          &sdiodev->func1->dev);
        if (ret != 0) {
            brcmf_err("request_irq failed %d\n", ret);
            return ret;
        }
        sdiodev->oob_irq_requested = true;

        ret = enable_irq_wake(pdata->oob_irq_nr);
        if (ret != 0) {
            brcmf_err("enable_irq_wake failed %d\n", ret);
            return ret;
        }
        disable_irq_wake(pdata->oob_irq_nr);

        sdio_claim_host(sdiodev->func1);

        if (sdiodev->bus_if->chip == BRCM_CC_43362_CHIP_ID) {
            /* assign GPIO to SDIO core */
            addr = brcmf_chip_enum_base(sdiodev->func1->device);
            addr = CORE_CC_REG(addr, gpiocontrol);
            gpiocontrol = brcmf_sdiod_readl(sdiodev, addr, &ret);
            gpiocontrol |= 0x2;
            brcmf_sdiod_writel(sdiodev, addr, gpiocontrol, &ret);

            brcmf_sdiod_writeb(sdiodev, SBSDIO_GPIO_SELECT,
                               0xf, &ret);
            brcmf_sdiod_writeb(sdiodev, SBSDIO_GPIO_OUT, 0, &ret);
            brcmf_sdiod_writeb(sdiodev, SBSDIO_GPIO_EN, 0x2, &ret);
        }

        /* must configure SDIO_CCCR_IENx to enable irq */
        data = brcmf_sdiod_func0_rb(sdiodev, SDIO_CCCR_IENx, &ret);
        data |= SDIO_CCCR_IEN_FUNC1 | SDIO_CCCR_IEN_FUNC2 |
                SDIO_CCCR_IEN_FUNC0;
        brcmf_sdiod_func0_wb(sdiodev, SDIO_CCCR_IENx, data, &ret);

        /* redirect, configure and enable io for interrupt signal */
        data = SDIO_CCCR_BRCM_SEPINT_MASK | SDIO_CCCR_BRCM_SEPINT_OE;
        if (pdata->oob_irq_flags & IRQF_TRIGGER_HIGH)
            data |= SDIO_CCCR_BRCM_SEPINT_ACT_HI;
        brcmf_sdiod_func0_wb(sdiodev, SDIO_CCCR_BRCM_SEPINT,
                             data, &ret);
        sdio_release_host(sdiodev->func1);
    } else {
        brcmf_dbg(SDIO, "Entering\n");
        sdio_claim_host(sdiodev->func1);
        sdio_claim_irq(sdiodev->func1, brcmf_sdiod_ib_irqhandler);
        sdio_claim_irq(sdiodev->func2, brcmf_sdiod_dummy_irqhandler);
        sdio_release_host(sdiodev->func1);
        sdiodev->sd_irq_requested = true;
    }

    return 0;
}
```

**OOB中断配置步骤**：
1. 请求GPIO中断(GPIO0_A3)
2. 使能中断唤醒
3. 配置SDIO CCCR寄存器
   - 使能F0/F1/F2中断
   - 配置OOB中断重定向
   - 设置触发类型(高电平)

**OOB vs SDIO内置中断**：

| 特性 | OOB中断 | SDIO内置中断 |
|------|---------|-------------|
| 引脚 | 独立GPIO | SDIO DAT1 |
| 延迟 | 低 | 较高 |
| 功耗 | 低(可唤醒) | 较高 |
| 配置 | 需要设备树 | 自动 |
| 适用场景 | 高性能、低功耗 | 通用 |

#### 4.6.2 中断处理流程

```c
static irqreturn_t brcmf_sdiod_oob_irqhandler(int irq, void *dev_id)
{
    struct brcmf_bus *bus_if = dev_get_drvdata(dev_id);
    struct brcmf_sdio_dev *sdiodev = bus_if->bus_priv.sdio;

    brcmf_dbg(INTR, "OOB intr triggered\n");

    /* out-of-band interrupt is level-triggered which won't
     * be cleared until dpc
     */
    if (sdiodev->irq_en) {
        disable_irq_nosync(irq);
        sdiodev->irq_en = false;
    }

    brcmf_sdio_isr(sdiodev->bus, true);

    return IRQ_HANDLED;
}

void brcmf_sdio_isr(struct brcmf_sdio *bus, bool in_isr)
{
    brcmf_dbg(TRACE, "Enter\n");

    if (!bus) {
        brcmf_err("bus is null pointer, exiting\n");
        return;
    }

    /* Count the interrupt call */
    bus->sdcnt.intrcount++;
    if (in_isr)
        atomic_set(&bus->ipend, 1);
    else
        if (brcmf_sdio_intr_rstatus(bus))
            brcmf_err("failed backplane access\n");

    /* Disable additional interrupts (must be after ipend check) */
    brcmf_sdio_bus_sleep(bus, false, false);

    /* Make sure backplane clock is on */
    brcmf_sdio_bus_sleep(bus, false, true);

    if (bus->ctrl_frame_stat && (bus->clkstate == CLK_AVAIL)) {
        sdio_claim_host(bus->sdiodev->func1);
        if (bus->ctrl_frame_stat) {
            bus->ctrl_frame_err = brcmf_sdio_hdparse(bus, bus->rxhdr,
                                                       &bus->cur_read);
        }
        sdio_release_host(bus->sdiodev->func1);
    }

    queue_work(bus->brcmf_wq, &bus->datawork);
}
```

**中断处理流程**：
```
GPIO0_A3产生中断
    ↓
brcmf_sdiod_oob_irqhandler() (硬中断)
    ├─ disable_irq_nosync()  // 禁用中断
    └─ brcmf_sdio_isr()
         ├─ 设置ipend标志
         ├─ 禁用SDIO中断
         ├─ 确保backplane时钟
         └─ queue_work(brcmf_wq, &datawork)  // 调度工作队列
              ↓
brcmf_sdio_dataworker() (软中断/工作队列)
    └─ brcmf_sdio_dpc()
         ├─ brcmf_sdio_readframes()  // 读取数据
         ├─ brcmf_sdio_sendfromq()   // 发送数据
         └─ enable_irq()              // 重新使能中断
```

### 4.7 总线启动阶段

#### 4.7.1 总线启动 (core.c)

```c
int brcmf_bus_started(struct device *dev, struct brcmf_bus *bus_if)
{
    int ret = -1;
    struct brcmf_pub *drvr = bus_if->drvr;
    struct brcmf_if *ifp;
    struct brcmf_if *p2p_ifp;

    brcmf_dbg(TRACE, "\n");

    /* add primary networking interface */
    ifp = brcmf_add_if(drvr, 0, 0, false, "wlan", NULL);
    if (IS_ERR(ifp))
        return PTR_ERR(ifp);

    p2p_ifp = NULL;

    /* signal bus ready */
    brcmf_bus_change_state(bus_if, BRCMF_BUS_UP);

    /* Bus is ready, do any initialization */
    ret = brcmf_c_preinit_dcmds(ifp);
    if (ret < 0)
        goto fail;

    brcmf_feat_attach(drvr);

    ret = brcmf_proto_init_done(drvr);
    if (ret < 0)
        goto fail;

    brcmf_proto_add_if(drvr, ifp);

    ret = brcmf_net_attach(ifp, false);
    if (ret < 0) {
        brcmf_err("failed: %d\n", ret);
        if (ret == -ENOLINK) {
            brcmf_net_detach(ifp->ndev, false);
            goto fail;
        }
    }

    /* attach firmware event handler */
    brcmf_fweh_attach(drvr);

    ret = brcmf_bus_started_attach_pciedev(drvr);
    if (ret < 0)
        goto fail;

    ret = brcmf_cfg80211_attach(drvr, bus_if->dev, drvr->settings->p2p_enable);
    if (ret < 0) {
        brcmf_err("failed: %d\n", ret);
        goto fail;
    }

    ret = brcmf_net_p2p_attach(ifp);
    if (ret < 0) {
        brcmf_err("failed: %d\n", ret);
        goto fail;
    }

    ret = brcmf_btcoex_attach(drvr);
    if (ret < 0) {
        brcmf_err("BT-coex initialisation failed\n");
        goto fail;
    }

    ret = brcmf_pno_attach(ifp);
    if (ret < 0) {
        brcmf_err("PNO initialisation failed\n");
        goto fail;
    }

    brcmf_debugfs_add_entry(drvr, "revinfo", brcmf_revinfo_read);

    return 0;

fail:
    brcmf_err("failed: %d\n", ret);
    brcmf_bus_started_detach(drvr);
    return ret;
}
```

**启动步骤**：
1. 添加主网络接口(wlan0)
2. 执行预初始化命令
   - 查询固件版本
   - 读取MAC地址
   - 配置默认参数
3. 检测固件功能
4. 注册网络设备
5. 附加固件事件处理
6. 注册cfg80211
7. 初始化P2P
8. 初始化蓝牙共存
9. 初始化PNO(网络离线扫描)

## 五、运行时数据流

### 5.1 发送数据流 (TX)

```
应用层
  │ socket send()
  ↓
TCP/IP协议栈
  │ ip_output() → tcp_transmit_skb()
  ↓
网络设备层
  │ dev_queue_xmit()
  ↓
brcmf_netdev_start_xmit() (core.c)
  │ 检查接口状态
  │ 检查队列状态
  ↓
brcmf_proto_txdata() (bcdc.c)
  │ 添加BCDC协议头
  │ 设置优先级
  ↓
brcmf_sdio_txdata() (sdio.c)
  │ 加入TX队列
  │ 触发DPC
  ↓
brcmf_sdio_dpc() (工作队列)
  │ 检查TX队列
  ↓
brcmf_sdio_sendfromq()
  │ 从队列取包
  │ 构造SDIO帧头
  ↓
brcmf_sdiod_send_pkt() (bcmsdh.c)
  │ SDIO写操作
  ↓
sdio_memcpy_toio() (MMC核心)
  │ 准备SDIO命令
  ↓
dw_mci_request() (dw-mshc驱动)
  │ 配置DMA
  │ 发送CMD53
  ↓
[硬件] SDIO总线传输
  ↓
AP6255接收数据
```

### 5.2 接收数据流 (RX)

```
AP6255有数据到达
  │ 拉高GPIO0_A3 (OOB中断)
  ↓
硬中断处理
  │ brcmf_sdiod_oob_irqhandler()
  │   ├─ disable_irq_nosync()
  │   └─ 调度工作队列
  ↓
软中断/工作队列
  │ brcmf_sdio_dataworker()
  ↓
brcmf_sdio_dpc()
  │ 检查中断状态
  ↓
brcmf_sdio_readframes()
  │ 读取帧头
  │ 确定数据长度
  ↓
brcmf_sdiod_recv_chain() (bcmsdh.c)
  │ SDIO读操作
  ↓
sdio_readsb() (MMC核心)
  │ 准备SDIO命令
  ↓
dw_mci_request() (dw-mshc驱动)
  │ 配置DMA
  │ 发送CMD53
  ↓
[硬件] SDIO总线传输
  ↓
brcmf_rx_frame() (core.c)
  │ 解析协议头
  │ 检查校验和
  ↓
brcmf_proto_rxreorder()
  │ 重排序(如果需要)
  ↓
brcmf_netif_rx()
  │ 转换为skb
  ↓
netif_rx_ni() (内核网络栈)
  │ 上送协议栈
  ↓
TCP/IP协议栈处理
  │ ip_rcv() → tcp_v4_rcv()
  ↓
应用层接收
  │ socket recv()
```

## 六、关键dmesg日志

### 6.1 完整启动日志

```bash
# 1. MMC控制器初始化
[    1.234567] dwmmc_rockchip fe310000.mmc: IDMAC supports 32-bit address mode.
[    1.234890] dwmmc_rockchip fe310000.mmc: Using internal DMA controller.
[    1.235123] dwmmc_rockchip fe310000.mmc: Version ID is 270a
[    1.235456] dwmmc_rockchip fe310000.mmc: DW MMC controller at irq 64,32 bit host data width,256 deep fifo
[    1.235789] dwmmc_rockchip fe310000.mmc: allocated mmc-pwrseq
[    1.236012] mmc_host mmc1: card is non-removable.

# 2. Pinctrl应用
[    1.236345] pinctrl-rockchip pinctrl: pin gpio0-10 already requested by sdio-pwrseq; cannot claim for fe310000.mmc

# 3. 电源序列执行
[    1.456789] mmc_host mmc1: Bus speed (slot 0) = 400000Hz (slot req 400000Hz, actual 400000HZ div = 0)

# 4. SDIO设备检测
[    1.567890] mmc1: new high speed SDIO card at address 0001

# 5. brcmfmac驱动probe
[    2.123456] brcmfmac: brcmf_ops_sdio_probe: Enter
[    2.123789] brcmfmac: brcmf_ops_sdio_probe: Class=0
[    2.124012] brcmfmac: brcmf_ops_sdio_probe: sdio vendor ID: 0x02d0
[    2.124345] brcmfmac: brcmf_ops_sdio_probe: sdio device ID: 0x4339
[    2.124678] brcmfmac: brcmf_ops_sdio_probe: Function#: 1
[    2.234567] brcmfmac: brcmf_ops_sdio_probe: Function#: 2
[    2.234890] brcmfmac: brcmf_ops_sdio_probe: F2 found, calling brcmf_sdiod_probe...

# 6. 芯片识别
[    2.345678] brcmfmac: F1 signature read @0x18000000=0x16044339
[    2.345901] brcmfmac: brcmf_chip_recognition chip 0x4339 rev 1
[    2.346234] brcmfmac: brcmf_chip_get_raminfo: RAM: base=0x0 size=524288 (512KB) sr=0

# 7. 固件加载
[    2.456789] brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac4339-sdio for chip BCM4339/1
[    2.567890] brcmfmac: brcmf_fw_get_firmwares: firmware request scheduled
[    2.678901] brcmfmac: brcmf_sdio_download_firmware: firmware download started
[    2.789012] brcmfmac: brcmf_sdio_download_code_file: download 417796 bytes
[    2.890123] brcmfmac: brcmf_sdio_download_nvram: download 1234 bytes NVRAM
[    2.901234] brcmfmac: brcmf_sdio_download_firmware: firmware download completed

# 8. OOB中断注册
[    2.912345] brcmfmac: brcmf_sdiod_intr_register: Enter, register OOB IRQ 123
[    2.923456] brcmfmac: brcmf_sdiod_intr_register: OOB irq flags 0x4 (ACTIVE_HIGH)

# 9. 固件启动
[    3.012345] brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4339/1 wl0: Nov  7 2014 16:03:45 version 6.37.32.RC23.34.40 (r581243) FWID 01-8e14b897
[    3.123456] brcmfmac: brcmf_c_preinit_dcmds: CLM version = API: 12.2 Data: 9.10.39 Compiler: 1.29.1 ClmImport: 1.36.3 Creation: 2016-07-06 17:42:37 Inc Data: 9.10.0

# 10. 功能检测
[    3.234567] brcmfmac: brcmf_feat_attach: Features: 0x0001c006
[    3.234890] brcmfmac: brcmf_feat_attach: [ MBSS PSK RSDB ]
[    3.235123] brcmfmac: brcmf_feat_iovar_data_get: feat_iovar_data_get err=-23

# 11. MAC地址获取
[    3.345678] brcmfmac: brcmf_c_preinit_dcmds: Firmware mac=a0:f3:c1:12:34:56

# 12. 网络接口创建
[    3.456789] brcmfmac: brcmf_cfg80211_reg_notifier: not a ISO3166 code (0x00 0x00)
[    3.567890] brcmfmac mmc1:0001:1 wlan0: renamed from wlan0

# 13. 初始化完成
[    3.678901] brcmfmac: brcmf_bus_started: bus started
```

### 6.2 调试日志开启

```bash
# 方法1: 内核启动参数
brcmfmac.debug=0x146

# 方法2: 运行时修改
echo 0x146 > /sys/module/brcmfmac/parameters/debug

# Debug级别定义 (debug.h)
# define BRCMF_TRACE_VAL    0x00000002
# define BRCMF_INFO_VAL     0x00000004
# define BRCMF_DATA_VAL     0x00000008
# define BRCMF_CTL_VAL      0x00000010
# define BRCMF_TIMER_VAL    0x00000020
# define BRCMF_HDRS_VAL     0x00000040
# define BRCMF_BYTES_VAL    0x00000080
# define BRCMF_INTR_VAL     0x00000100
# define BRCMF_GLOM_VAL     0x00000200
# define BRCMF_EVENT_VAL    0x00000400
# define BRCMF_BTA_VAL      0x00000800
# define BRCMF_FIL_VAL      0x00001000
# define BRCMF_USB_VAL      0x00002000
# define BRCMF_SCAN_VAL     0x00004000
# define BRCMF_CONN_VAL     0x00008000
# define BRCMF_BCDC_VAL     0x00010000
# define BRCMF_SDIO_VAL     0x00020000
# define BRCMF_PCIE_VAL     0x00040000
# define BRCMF_FWCON_VAL    0x00080000
# define BRCMF_MSGBUF_VAL   0x00100000

# 常用组合
# 0x146 = TRACE + INFO + SDIO (基本信息)
# 0x14E = TRACE + INFO + SDIO + DATA (包含数据)
# 0x1CE = TRACE + INFO + SDIO + DATA + INTR (包含中断)
```

## 七、完整流程图

### 7.1 系统启动到驱动加载

```
┌────────────────────────────────────────────────────────────────┐
│                       系统启动                                  │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│          设备树解析 (DTB加载) - arch_initcall_sync             │
│  of_platform_default_populate_init()                           │
│  ├─ 解析rk3399.dtsi: sdio0控制器定义                           │
│  ├─ 解析rk3399-eaidk-610.dts: 板级配置                         │
│  └─ 创建platform_device (仅根节点的直接子节点)                 │
│       ├─ sdio_pwrseq (电源序列) ✓                              │
│       └─ sdio0 (SDIO控制器) ✓                                  │
│  注意: wifi@1不会被创建 (sdio0的子节点，由SDIO总线动态创建)    │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│         驱动注册阶段 (module_init) - 在设备创建之后             │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ 1. mmc-pwrseq-simple驱动注册                             │ │
│  │    module_platform_driver(mmc_pwrseq_simple_driver)      │ │
│  │    └─ 匹配sdio_pwrseq设备，调用probe                     │ │
│  └──────────────────────────────────────────────────────────┘ │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ 2. dw_mmc_rockchip驱动注册                               │ │
│  │    module_platform_driver(dw_mci_rockchip_pltfm_driver)  │ │
│  │    └─ 匹配sdio0设备，调用probe                           │ │
│  └──────────────────────────────────────────────────────────┘ │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ 3. brcmfmac驱动注册                                      │ │
│  │    brcmfmac_module_init()                                │ │
│  │    ├─ platform_driver_probe() - 查找平台数据             │ │
│  │    ├─ brcmf_mp_attach() - 初始化模块参数                 │ │
│  │    └─ brcmf_core_init()                                  │ │
│  │         └─ brcmf_sdio_register()                         │ │
│  │              └─ sdio_register_driver(&brcmf_sdmmc_driver)│ │
│  │                   └─ 注册到SDIO总线，等待设备匹配        │ │
│  └──────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│        电源序列驱动初始化 (mmc-pwrseq-simple)                  │
│  mmc_pwrseq_simple_probe()                                     │
│    ├─ Pinctrl自动应用 ★                                       │
│    │    └─ devm_pinctrl_get_select_default()                  │
│    │         └─ 应用 pinctrl-0 = <&wifi_enable_h>             │
│    │              └─ GPIO0_B2 → GPIO输出模式                   │
│    │                                                            │
│    ├─ 获取reset-gpios (GPIO0_B2)                              │
│    │    └─ devm_gpiod_get() - 只获取，不操作                  │
│    │                                                            │
│    ├─ 获取clocks (RK808 32KHz)                                │
│    │    └─ devm_clk_get() - 只获取，不使能                    │
│    │                                                            │
│    └─ mmc_pwrseq_register() - 注册到全局pwrseq链表            │
│         └─ 加入 pwrseq_list，供 mmc_pwrseq_alloc() 查找       │
│                                                                 │
│  ⚠️ 注意: probe 阶段只做准备，不执行上电/复位操作              │
│  真正的上电操作在 mmc_rescan() 中调用 pwrseq 的回调函数       │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│          SDIO控制器初始化 (dw-mshc驱动)                        │
│  dw_mci_rockchip_probe()                                       │
│    ├─ 解析设备树资源                                            │
│    │    ├─ reg: 0xfe310000                                     │
│    │    ├─ interrupts: 64                                      │
│    │    ├─ clocks: HCLK_SDIO, SCLK_SDIO等                     │
│    │    ├─ power-domains: RK3399_PD_SDIOAUDIO                 │
│    │    └─ mmc-pwrseq: 引用sdio_pwrseq                        │
│    │                                                            │
│    ├─ Pinctrl自动应用 ★                                       │
│    │    └─ devm_pinctrl_get_select_default()                  │
│    │         └─ 应用 pinctrl-0 = <&sdio0_bus4 &sdio0_cmd...>  │
│    │              └─ GPIO2_C4-C7,D0-D1 → SDIO功能             │
│    │                                                            │
│    ├─ 时钟初始化                                                │
│    │    ├─ clk_prepare_enable(HCLK_SDIO)                      │
│    │    ├─ clk_prepare_enable(SCLK_SDIO)                      │
│    │    ├─ clk_prepare_enable(SCLK_SDIO_DRV)                  │
│    │    └─ clk_prepare_enable(SCLK_SDIO_SAMPLE)               │
│    │                                                            │
│    ├─ 电源域使能                                                │
│    │    └─ pm_runtime_get_sync() → RK3399_PD_SDIOAUDIO上电    │
│    │                                                            │
│    ├─ 控制器复位                                                │
│    │    └─ reset_control_assert/deassert(SRST_SDIO0)          │
│    │                                                            │
│    ├─ 查找并绑定电源序列 ★★★                                   │
│    │    └─ mmc_pwrseq_alloc()                                  │
│    │         ├─ 遍历全局 pwrseq_list 链表                      │
│    │         ├─ 根据 mmc-pwrseq phandle 匹配                   │
│    │         ├─ 如果找到: 绑定到 host->pwrseq                  │
│    │         └─ 如果未找到: 返回 -EPROBE_DEFER                 │
│    │              └─ 内核稍后重试 probe                         │
│    │                                                            │
│    └─ 注册MMC host并触发扫描                                    │
│         └─ mmc_add_host() → mmc_start_host()                  │
│              └─ 调度 mmc_rescan() 工作队列                     │
│                                                                 │
│  ⚠️ 关键依赖: 此步骤要求 pwrseq 必须已注册                     │
│  如果 pwrseq 未注册，probe 会返回 -EPROBE_DEFER 并稍后重试    │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│    电源序列执行 (mmc_rescan工作队列中调用) - ★★★ 真正上电     │
│  mmc_rescan()                                                  │
│    └─ mmc_pwrseq_pre_power_on()                               │
│         └─ pwrseq->ops->pre_power_on()                        │
│              └─ mmc_pwrseq_simple_pre_power_on()              │
│                   ├─ clk_prepare_enable(pwrseq->ext_clk)      │
│                   │    └─ 使能RK808的32KHz时钟 ← 首次使能     │
│                   │                                            │
│                   ├─ mdelay(1) - 延时1ms                       │
│                   │                                            │
│                   └─ gpiod_set_value_cansleep(reset_gpio, 1)  │
│                        └─ 拉高GPIO0_B2 (WL_REG_ON) ← 首次上电 │
│                             └─ AP6255上电                      │
│                                                                 │
│  ⚠️ 重要: 这是真正的上电操作，不是在 probe 阶段                │
│  - probe 阶段: 只获取资源，注册到链表                          │
│  - rescan 阶段: 才真正操作硬件 (使能时钟、拉高GPIO)            │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│        SDIO设备枚举 (MMC核心) - 动态创建SDIO设备               │
│  mmc_rescan() → mmc_attach_sdio()                              │
│    ├─ mmc_send_io_op_cond() - CMD5识别SDIO设备                │
│    ├─ mmc_sdio_init_card()                                    │
│    │    ├─ CMD3: 获取RCA                                       │
│    │    ├─ CMD7: 选择卡                                        │
│    │    └─ sdio_read_cis() - 读取CIS                          │
│    │         ├─ Vendor ID: 0x02d0 (Broadcom)                  │
│    │         ├─ Device ID: 0x4339 (BCM4339)                   │
│    │         └─ Functions: F0, F1, F2                         │
│    │                                                            │
│    └─ sdio_init_func() - 为每个Function创建sdio_func设备      │
│         ├─ 创建 Function 1 (sdio_func)                        │
│         ├─ 创建 Function 2 (sdio_func) ← 对应wifi@1节点       │
│         └─ sdio_add_func() 注册到SDIO总线                     │
│  ★ 关键: wifi@1节点信息会关联到Function 2的sdio_func设备      │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│              驱动匹配 (SDIO总线)                                │
│  sdio_bus_probe()                                              │
│    ├─ 遍历已注册的SDIO驱动                                      │
│    ├─ 匹配 brcmf_sdmmc_driver                                  │
│    │    └─ Vendor: 0x02d0, Device: 0x4339                     │
│    │                                                            │
│    └─ 调用 probe: brcmf_ops_sdio_probe() ★★★                  │
│         ├─ Function 1: 返回0 (只记录)                          │
│         └─ Function 2: 执行初始化                              │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│           brcmfmac驱动Probe (bcmsdh.c)                         │
│  brcmf_ops_sdio_probe()                                        │
│    ├─ 分配设备结构                                              │
│    │    ├─ brcmf_bus                                           │
│    │    └─ brcmf_sdio_dev                                      │
│    │                                                            │
│    ├─ 保存Function指针                                          │
│    │    ├─ func1 = card->sdio_func[0]                         │
│    │    └─ func2 = func                                        │
│    │                                                            │
│    ├─ 解析设备树 wifi@1 节点                                    │
│    │    └─ brcmf_of_probe()                                    │
│    │         ├─ Pinctrl自动应用 ★★★                           │
│    │         │    └─ 应用 pinctrl-0 = <&wifi_host_wake_l>     │
│    │         │         └─ GPIO0_A3 → GPIO输入模式              │
│    │         │                                                  │
│    │         ├─ 解析compatible "brcm,bcm4329-fmac"             │
│    │         ├─ 解析OOB中断                                     │
│    │         │    ├─ irq = irq_of_parse_and_map(np, 0)        │
│    │         │    │    └─ GPIO0_A3 → IRQ号                    │
│    │         │    └─ irqf = irqd_get_trigger_type()           │
│    │         │         └─ GPIO_ACTIVE_HIGH                     │
│    │         │                                                  │
│    │         ├─ 解析 brcm,drive-strength                       │
│    │         └─ 解析MAC地址                                     │
│    │                                                            │
│    └─ brcmf_sdiod_probe()                                      │
│         ├─ 设置F1块大小: 64B                                    │
│         ├─ 设置F2块大小: 512B                                   │
│         ├─ 增加F2超时: 3000ms                                   │
│         ├─ sdio_enable_func(func1)                             │
│         └─ brcmf_sdio_probe()                                  │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│            SDIO总线层初始化 (sdio.c)                            │
│  brcmf_sdio_probe()                                            │
│    ├─ 分配总线结构 brcmf_sdio                                  │
│    ├─ 创建工作队列 brcmf_wq (WQ_HIGHPRI)                       │
│    ├─ brcmf_sdio_probe_attach() - 芯片识别 ★★★                │
│    │    ├─ 读取芯片签名 @0x18000000                            │
│    │    ├─ 强制使能ALP时钟                                      │
│    │    ├─ brcmf_chip_attach()                                 │
│    │    │    └─ 识别: BCM4339 rev 1                           │
│    │    ├─ 配置SDIO驱动强度                                     │
│    │    ├─ sdio_enable_func(func2)                             │
│    │    └─ brcmf_sdiod_sgtable_alloc()                        │
│    │                                                            │
│    ├─ 初始化看门狗线程                                           │
│    ├─ 准备固件请求                                              │
│    │    └─ brcmf_sdio_prepare_fw_request()                    │
│    │                                                            │
│    └─ 异步加载固件 ★★★                                         │
│         └─ brcmf_fw_get_firmwares()                            │
│              └─ request_firmware_nowait()                      │
└────────────────────────────────────────────────────────────────┘
                              ↓
                      [等待固件加载]
                              ↓
┌────────────────────────────────────────────────────────────────┐
│              固件加载完成回调 (sdio.c)                          │
│  brcmf_sdio_firmware_callback()                                │
│    ├─ brcmf_sdio_download_firmware() - 下载固件 ★★★           │
│    │    ├─ brcmf_chip_set_passive() - 复位ARM核心              │
│    │    ├─ brcmf_sdio_download_code_file()                    │
│    │    │    └─ 通过SDIO写入固件到RAM (~400KB)                │
│    │    ├─ brcmf_sdio_download_nvram()                        │
│    │    │    └─ 写入NVRAM配置到RAM末尾                         │
│    │    └─ brcmf_chip_set_active() - 启动固件                  │
│    │         └─ 释放ARM复位，跳转到入口点                       │
│    │                                                            │
│    ├─ brcmf_sdiod_intr_register() - 注册中断 ★★★              │
│    │    └─ 如果oob_irq_supported:                             │
│    │         ├─ request_irq(GPIO0_A3, brcmf_sdiod_oob_irqhandler) │
│    │         ├─ enable_irq_wake()                              │
│    │         ├─ 配置SDIO CCCR寄存器                            │
│    │         │    ├─ 使能F0/F1/F2中断                          │
│    │         │    └─ 配置OOB中断重定向                         │
│    │         └─ 设置触发类型(高电平)                            │
│    │                                                            │
│    └─ brcmf_bus_started() - 启动总线 ★★★                      │
│         ├─ brcmf_add_if() - 添加wlan0接口                      │
│         ├─ brcmf_c_preinit_dcmds() - 预初始化                  │
│         │    ├─ 查询固件版本                                    │
│         │    ├─ 读取MAC地址                                     │
│         │    └─ 配置默认参数                                    │
│         ├─ brcmf_feat_attach() - 检测功能                      │
│         ├─ brcmf_net_attach() - 注册网络设备                   │
│         ├─ brcmf_cfg80211_attach() - 注册cfg80211             │
│         ├─ brcmf_net_p2p_attach() - 初始化P2P                 │
│         ├─ brcmf_btcoex_attach() - 蓝牙共存                    │
│         └─ brcmf_pno_attach() - 网络离线扫描                   │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│                   驱动加载完成                                  │
│  wlan0接口可用，可以使用iw/wpa_supplicant连接WiFi              │
└────────────────────────────────────────────────────────────────┘
```

### 7.2 Pinctrl应用时序图

```
时间轴
  │
  ├─ T0: 系统启动，解析设备树
  │
  ├─ T1: SDIO控制器驱动probe
  │      └─ Pinctrl自动应用: sdio0_bus4, sdio0_cmd, sdio0_clk
  │           └─ GPIO2_C4-C7, D0-D1 → SDIO功能
  │
  ├─ T2: 电源序列驱动probe
  │      └─ Pinctrl自动应用: wifi_enable_h
  │           └─ GPIO0_B2 → GPIO输出模式
  │
  ├─ T3: 电源序列执行
  │      ├─ 使能32KHz时钟
  │      └─ GPIO0_B2拉高 (AP6255上电)
  │
  ├─ T4: SDIO总线扫描
  │      └─ 发现AP6255 (Vendor:0x02d0, Device:0x4339)
  │
  ├─ T5: brcmfmac驱动probe (Function 2)
  │      ├─ 解析wifi@1节点
  │      └─ Pinctrl自动应用: wifi_host_wake_l
  │           └─ GPIO0_A3 → GPIO输入模式 (OOB中断)
  │
  ├─ T6: 固件加载并启动
  │
  ├─ T7: 中断注册
  │      └─ request_irq(GPIO0_A3, ...)
  │
  └─ T8: 驱动初始化完成
         └─ wlan0接口可用
```

## 八、关键数据结构

### 8.1 brcmf_sdio_dev

```c
// drivers/net/wireless/broadcom/brcm80211/brcmfmac/sdio.h
struct brcmf_sdio_dev {
    struct sdio_func *func1;        // SDIO Function 1 (控制通道)
    struct sdio_func *func2;        // SDIO Function 2 (数据通道)
    u32 sbwad;                      // backplane窗口地址
    struct brcmf_sdio *bus;         // 总线层指针
    struct brcmf_bus *bus_if;       // 总线接口
    struct brcmf_mp_device *settings; // 配置参数
    struct device *dev;             // 设备指针
    struct brcmf_core *cc_core;    // ChipCommon核心
    bool oob_irq_requested;         // OOB中断是否已注册
    bool sd_irq_requested;          // SDIO内置中断是否已注册
    bool irq_en;                    // 中断是否使能
    spinlock_t irq_en_lock;         // 中断使能锁
    bool sg_support;                // 是否支持scatter-gather
    struct sg_table sgtable;        // scatter-gather表
    uint max_segment_count;         // 最大段数
    uint max_segment_size;          // 最大段大小
    uint max_request_size;          // 最大请求大小
    u32 txglomsz;                   // TX聚合大小
    enum brcmf_sdiod_state state;   // 设备状态
    struct brcmf_sdiod_freezer *freezer; // 电源管理
};
```

### 8.2 brcmf_sdio

```c
// drivers/net/wireless/broadcom/brcm80211/brcmfmac/sdio.c
struct brcmf_sdio {
    struct brcmf_sdio_dev *sdiodev; // SDIO设备
    struct brcmf_chip *ci;          // 芯片信息
    struct workqueue_struct *brcmf_wq; // 工作队列
    struct work_struct datawork;    // 数据处理work
    struct sk_buff_head txq;        // 发送队列
    struct sk_buff_head glom;       // 聚合队列
    struct timer_list timer;        // 看门狗定时器
    struct task_struct *watchdog_tsk; // 看门狗线程
    struct completion watchdog_wait; // 看门狗等待
    
    u8 tx_seq;                      // 发送序列号
    u8 tx_max;                      // 最大发送窗口
    u8 hdrbuf[MAX_HDR_READ + BRCMF_SDALIGN];
    u8 *rxhdr;                      // RX头指针
    
    bool intr;                      // 中断使能
    bool poll;                      // 轮询模式
    uint pollrate;                  // 轮询速率
    
    uint clkstate;                  // 时钟状态
    int idletime;                   // 空闲时间
    int idlecount;                  // 空闲计数
    
    atomic_t ipend;                 // 中断pending
    bool dpc_triggered;             // DPC已触发
    bool dpc_running;               // DPC正在运行
    
    struct brcmf_sdio_count sdcnt;  // 统计计数
};
```

### 8.3 brcmf_bus

```c
// drivers/net/wireless/broadcom/brcm80211/brcmfmac/bus.h
struct brcmf_bus {
    union {
        struct brcmf_sdio_dev *sdio;
        struct brcmf_usbdev *usb;
        struct brcmf_pciedev *pcie;
    } bus_priv;
    enum brcmf_bus_protocol_type proto_type;
    struct device *dev;
    struct brcmf_pub *drvr;
    enum brcmf_bus_state state;
    uint maxctl;
    u32 chip;
    u32 chiprev;
    bool always_use_fws_queue;
    const struct brcmf_bus_ops *ops;
};
```

### 8.4 设备树绑定关系

```
/sys/devices/platform/
    └─ fe310000.mmc (SDIO0控制器)
         ├─ driver -> dw_mmc_rockchip
         ├─ pinctrl-0 -> sdio0_bus4, sdio0_cmd, sdio0_clk
         ├─ mmc_host/mmc1/
         │    └─ mmc1:0001/ (SDIO卡)
         │         ├─ mmc1:0001:1 (Function 1)
         │         │    ├─ driver -> brcmfmac
         │         │    └─ of_node -> wifi@1
         │         │         ├─ compatible = "brcm,bcm4329-fmac"
         │         │         ├─ interrupts = <GPIO0_A3 HIGH>
         │         │         └─ pinctrl-0 -> wifi_host_wake_l
         │         │
         │         └─ mmc1:0001:2 (Function 2)
         │              └─ driver -> brcmfmac
         │
         └─ pwrseq/ (电源序列)
              ├─ compatible = "mmc-pwrseq-simple"
              ├─ clocks = <&rk808 1> (32KHz)
              ├─ reset-gpios = <GPIO0_B2 ACTIVE_LOW>
              └─ pinctrl-0 -> wifi_enable_h
```

## 九、调试技巧

### 9.1 使能调试信息

```bash
# 方法1: 内核启动参数
# 在bootargs中添加
brcmfmac.debug=0x146

# 方法2: 运行时修改
echo 0x146 > /sys/module/brcmfmac/parameters/debug

# 查看当前设置
cat /sys/module/brcmfmac/parameters/debug
```

### 9.2 检查SDIO设备

```bash
# 1. 查看MMC设备
ls -l /sys/bus/mmc/devices/
# 应该看到:
# mmc1:0001:1 -> Function 1
# mmc1:0001:2 -> Function 2

# 2. 查看SDIO信息
cat /sys/kernel/debug/mmc1/ios
# 输出:
# clock:          50000000 Hz
# vdd:            21 (3.3 ~ 3.4 V)
# bus mode:       2 (push-pull)
# chip select:    0 (don't care)
# power mode:     2 (on)
# bus width:      2 (4 bits)
# timing spec:    2 (sd high-speed)
# signal voltage: 0 (3.30 V)
# driver type:    0 (driver type B)

# 3. 查看SDIO Function信息
cat /sys/bus/sdio/devices/mmc1:0001:1/vendor
# 输出: 0x02d0

cat /sys/bus/sdio/devices/mmc1:0001:1/device
# 输出: 0x4339

# 4. 查看驱动绑定
ls -l /sys/bus/sdio/devices/mmc1:0001:1/driver
# 输出: -> ../../../../bus/sdio/drivers/brcmfmac
```

### 9.3 检查GPIO和中断

```bash
# 1. 查看GPIO状态
cat /sys/kernel/debug/gpio
# 找到相关GPIO:
# gpio-10  (                    |WL_REG_ON           ) out hi
# gpio-3   (                    |host-wake           ) in  lo

# 2. 查看中断统计
cat /proc/interrupts | grep brcmf
# 输出:
# 123:       1234  gpio0  3 Edge      brcmf_oob_intr

# 3. 查看中断详情
cat /sys/kernel/debug/gpio | grep -A2 "gpio-3"
# 输出:
# gpio-3   (                    |host-wake           ) in  lo IRQ-123

# 4. 实时监控中断
watch -n 1 'cat /proc/interrupts | grep brcmf'
```

### 9.4 检查固件

```bash
# 1. 查看固件搜索路径
dmesg | grep "using brcm"
# 输出:
# brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac4339-sdio for chip BCM4339/1

# 2. 检查固件文件
ls -lh /lib/firmware/brcm/brcmfmac4339*
# 输出:
# -rw-r--r-- 1 root root 408K brcmfmac4339-sdio.bin
# -rw-r--r-- 1 root root 1.2K brcmfmac4339-sdio.txt

# 3. 查看固件版本
dmesg | grep "Firmware:"
# 输出:
# brcmfmac: Firmware: BCM4339/1 wl0: Nov  7 2014 16:03:45 version 6.37.32.RC23.34.40

# 4. 查看CLM版本
dmesg | grep "CLM version"
# 输出:
# brcmfmac: CLM version = API: 12.2 Data: 9.10.39
```

### 9.5 检查Pinctrl

```bash
# 1. 查看设备的pinctrl状态
cat /sys/kernel/debug/pinctrl/pinctrl-rockchip/pinmux-pins | grep sdio
# 输出:
# pin 84 (gpio2-20): fe310000.mmc (GPIO UNCLAIMED) function sdio0 group sdio0-bus4
# pin 85 (gpio2-21): fe310000.mmc (GPIO UNCLAIMED) function sdio0 group sdio0-bus4
# ...

# 2. 查看GPIO功能
cat /sys/kernel/debug/pinctrl/pinctrl-rockchip/pinmux-pins | grep "gpio0-10"
# 输出:
# pin 10 (gpio0-10): sdio-pwrseq (GPIO UNCLAIMED) function gpio0 group wifi-enable-h

# 3. 查看引脚配置
cat /sys/kernel/debug/pinctrl/pinctrl-rockchip/pinconf-pins | grep "pin 10"
# 输出:
# pin 10 (gpio0-10): bias-disable
```

### 9.6 手动测试WiFi

```bash
# 1. 查看接口
ip link show wlan0
# 输出:
# 3: wlan0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT
#     link/ether a0:f3:c1:12:34:56 brd ff:ff:ff:ff:ff:ff

# 2. 启动接口
ip link set wlan0 up

# 3. 扫描WiFi
iw dev wlan0 scan | grep SSID
# 或
iwlist wlan0 scan | grep ESSID

# 4. 查看接口信息
iw dev wlan0 info
# 输出:
# Interface wlan0
#     ifindex 3
#     wdev 0x1
#     addr a0:f3:c1:12:34:56
#     type managed
#     wiphy 0

# 5. 查看驱动信息
ethtool -i wlan0
# 输出:
# driver: brcmfmac
# version: 6.37.32.RC23.34.40
# firmware-version: 01-8e14b897
# bus-info: mmc1:0001:1

# 6. 查看统计信息
ethtool -S wlan0
```

### 9.7 性能监控

```bash
# 1. 查看SDIO传输速率
cat /sys/kernel/debug/mmc1/ios
# 关注 clock 字段

# 2. 监控中断频率
watch -n 1 'cat /proc/interrupts | grep brcmf | awk "{print \$2}"'

# 3. 查看工作队列
cat /proc/workqueues | grep brcmf

# 4. 查看内存使用
cat /proc/slabinfo | grep brcmf

# 5. 监控网络流量
ifconfig wlan0
# 或
ip -s link show wlan0
```

## 十、常见问题

### 10.1 固件加载失败

**现象**：
```
brcmfmac: brcmf_sdio_download_firmware: dongle image file download failed
```

**可能原因**：
1. 固件文件不存在或路径错误
2. 固件文件损坏
3. SDIO通信错误
4. 芯片复位失败

**解决方法**：
```bash
# 1. 确认固件文件存在
ls -l /lib/firmware/brcm/brcmfmac4339-sdio.bin
ls -l /lib/firmware/brcm/brcmfmac4339-sdio.txt

# 2. 检查文件权限
chmod 644 /lib/firmware/brcm/brcmfmac4339-sdio.*

# 3. 验证固件完整性
md5sum /lib/firmware/brcm/brcmfmac4339-sdio.bin

# 4. 检查SDIO通信
dmesg | grep "mmc1"
# 应该看到: mmc1: new high speed SDIO card at address 0001

# 5. 检查GPIO状态
cat /sys/kernel/debug/gpio | grep WL_REG_ON
# 应该是: out hi

# 6. 重新加载驱动
rmmod brcmfmac
modprobe brcmfmac debug=0x146
dmesg | tail -50
```

### 10.2 OOB中断不工作

**现象**：
```
cat /proc/interrupts | grep brcmf
# 中断计数不增长或为0
```

**可能原因**：
1. GPIO配置错误
2. 中断触发类型不匹配
3. 设备树配置错误
4. Pinctrl未正确应用

**解决方法**：
```bash
# 1. 检查GPIO方向和电平
cat /sys/kernel/debug/gpio | grep -A2 "gpio-3"
# 应该是: in (输入模式)

# 2. 检查中断是否注册
cat /proc/interrupts | grep gpio
# 应该看到 brcmf_oob_intr

# 3. 检查设备树配置
# 修改 rk3399-eaidk-610.dts:
interrupts = <RK_PA3 IRQ_TYPE_LEVEL_HIGH>;
# 或尝试边沿触发:
interrupts = <RK_PA3 IRQ_TYPE_EDGE_RISING>;

# 4. 检查Pinctrl
cat /sys/kernel/debug/pinctrl/pinctrl-rockchip/pinmux-pins | grep "gpio0-3"

# 5. 手动测试GPIO中断
# 安装 evtest 工具
evtest /dev/input/eventX

# 6. 降级使用SDIO内置中断
# 在设备树中删除 interrupts 属性，驱动会自动使用SDIO中断
```

### 10.3 wlan0接口不出现

**现象**：
```bash
ip link show wlan0
# Device "wlan0" does not exist.
```

**可能原因**：
1. 驱动probe失败
2. 固件启动失败
3. MAC地址无效
4. 网络接口注册失败

**解决方法**：
```bash
# 1. 查看详细日志
dmesg | grep brcmfmac

# 2. 检查驱动是否加载
lsmod | grep brcmfmac

# 3. 检查SDIO设备
ls -l /sys/bus/sdio/devices/

# 4. 检查驱动绑定
ls -l /sys/bus/sdio/devices/mmc1:0001:1/driver

# 5. 手动加载驱动
rmmod brcmfmac
modprobe brcmfmac debug=0x14E
dmesg | tail -100

# 6. 检查是否有错误
dmesg | grep -i "error\|fail\|warn" | grep brcmf
```

### 10.4 WiFi连接不稳定

**现象**：
- 频繁断线重连
- 速度慢
- 丢包严重

**可能原因**：
1. SDIO时钟频率过高/过低
2. 中断延迟高
3. 电源不稳定
4. 信号干扰

**解决方法**：
```bash
# 1. 调整SDIO时钟
# 在设备树中修改:
clock-frequency = <25000000>;  // 降低到25MHz试试

# 2. 检查中断延迟
cat /proc/interrupts | grep brcmf
# 观察中断频率是否正常

# 3. 检查电源
cat /sys/kernel/debug/regulator/regulator_summary | grep sdio

# 4. 调整功率管理
iw dev wlan0 set power_save off

# 5. 固定信道
iw dev wlan0 set channel 6

# 6. 调整TX power
iw dev wlan0 set txpower fixed 2000  # 20dBm
```

### 10.5 休眠唤醒失败

**现象**：
- 系统休眠后WiFi无法唤醒
- 唤醒后wlan0消失

**可能原因**：
1. 休眠时未保持供电
2. OOB中断唤醒未配置
3. 电源序列错误

**解决方法**：
```bash
# 1. 检查设备树配置
# 确保有:
keep-power-in-suspend;

# 2. 检查OOB中断唤醒
cat /sys/devices/platform/fe310000.mmc/power/wakeup
# 应该是: enabled

# 3. 测试唤醒
echo mem > /sys/power/state
# 然后通过WiFi流量唤醒

# 4. 查看唤醒源
cat /sys/kernel/debug/wakeup_sources | grep brcmf
```

## 十一、性能优化

### 11.1 SDIO时钟优化

```dts
&sdio0 {
    clock-frequency = <150000000>;  // 提升到150MHz
    sd-uhs-sdr104;                   // 使能SDR104模式
};
```

**效果**：
- 理论带宽从50MB/s提升到104MB/s
- 实际吞吐量提升30-50%

### 11.2 中断亲和性

```bash
# 将WiFi中断绑定到CPU1
IRQ_NUM=$(cat /proc/interrupts | grep brcmf_oob | awk '{print $1}' | tr -d ':')
echo 2 > /proc/irq/$IRQ_NUM/smp_affinity
# 2 = 0b0010 = CPU1

# 或绑定到大核(CPU4-5)
echo 30 > /proc/irq/$IRQ_NUM/smp_affinity
# 30 = 0b110000 = CPU4-5
```

### 11.3 工作队列优先级

brcmfmac已使用`WQ_HIGHPRI`创建高优先级工作队列，无需额外配置。

### 11.4 NVRAM调优

编辑 `/lib/firmware/brcm/brcmfmac4339-sdio.txt`:

```ini
# 提高发送功率
maxp2ga0=74
maxp2ga1=74
cckpwroffset0=0

# 调整聚合参数
ampdu_ba_wsize=64
ampdu_mpdu=32

# 使能STBC
stbc_tx=1
stbc_rx=1

# 调整RX buffer
sd_rxchain=1
sd_f2_blocksize=512

# 电源管理
pm2_sleep_ret_time=100
pm2_radio_shutoff_dly=2000
```

### 11.5 内核参数

```bash
# /etc/sysctl.conf
# 增加网络缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# 调整TCP参数
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
```

## 十二、总结

### 12.1 关键流程

AP6255驱动加载的10个关键步骤：

1. **设备树配置** - 定义硬件资源(SDIO、GPIO、中断、Pinctrl)
2. **Pinctrl配置** - 在各阶段自动应用引脚配置
3. **电源管理** - mmc-pwrseq控制上电时序和32KHz时钟
4. **驱动注册** - brcmfmac注册到MMC子系统
5. **设备枚举** - MMC核心扫描SDIO总线，识别设备
6. **驱动匹配** - 根据Vendor/Device ID匹配驱动
7. **芯片识别** - 读取芯片ID和版本信息
8. **固件加载** - 异步加载并下载固件到芯片RAM
9. **中断配置** - 注册OOB中断或SDIO内置中断
10. **接口创建** - 创建wlan0并注册到cfg80211

### 12.2 Pinctrl关键点

Pinctrl在3个阶段自动应用：

1. **SDIO控制器probe** - 配置SDIO引脚(GPIO2_C4-C7,D0-D1)
2. **电源序列probe** - 配置WL_REG_ON(GPIO0_B2)
3. **WiFi驱动probe** - 配置OOB中断引脚(GPIO0_A3)

### 12.3 涉及的内核子系统

- **设备树子系统** - 硬件描述和参数传递
- **Pinctrl子系统** - 引脚复用和配置管理
- **MMC/SDIO子系统** - SDIO协议栈和总线管理
- **GPIO子系统** - GPIO控制和中断
- **中断子系统** - 中断注册和处理
- **时钟子系统** - 时钟管理(32KHz, SDIO时钟)
- **电源子系统** - 电源域和电源序列
- **固件子系统** - 固件加载
- **网络子系统** - 网络接口管理
- **cfg80211子系统** - 无线管理框架

### 12.4 调试建议

1. **分阶段调试** - 从硬件→驱动→固件→网络逐层排查
2. **使能调试日志** - `brcmfmac.debug=0x146`
3. **检查关键节点** - GPIO、中断、SDIO通信、固件加载
4. **使用系统工具** - debugfs、sysfs、procfs
5. **对比参考实现** - 查看其他成功案例的配置

### 12.5 性能优化要点

1. **SDIO时钟** - 提升到150MHz/SDR104
2. **中断机制** - 优先使用OOB中断
3. **中断亲和性** - 绑定到合适的CPU
4. **NVRAM参数** - 根据实际情况调优
5. **系统参数** - 网络缓冲区、TCP参数

---

## 附录

### A. 参考文档

- Linux内核文档: `Documentation/devicetree/bindings/mmc/`
- Rockchip文档: `Documentation/devicetree/bindings/pinctrl/rockchip,pinctrl.txt`
- brcmfmac驱动: `drivers/net/wireless/broadcom/brcm80211/brcmfmac/`
- **Platform Device创建顺序详解**: `platform_device_creation_order.md`
- **CMake内核索引配置**: `full_kernel_indexing.md`
- **CLion配置指南**: `clion_setup.md`

### B. 相关命令速查

```bash
# 驱动管理
lsmod | grep brcmfmac
modprobe brcmfmac debug=0x146
rmmod brcmfmac

# 设备查看
ls -l /sys/bus/sdio/devices/
cat /sys/kernel/debug/mmc1/ios
cat /sys/kernel/debug/gpio

# 网络管理
ip link show wlan0
iw dev wlan0 scan
iwconfig wlan0

# 调试
dmesg | grep brcmfmac
cat /proc/interrupts | grep brcmf
ethtool -i wlan0
```

### C. 常用路径

```
# 固件路径
/lib/firmware/brcm/brcmfmac4339-sdio.bin
/lib/firmware/brcm/brcmfmac4339-sdio.txt

# 设备树路径
/proc/device-tree/
/sys/firmware/devicetree/

# 调试接口
/sys/kernel/debug/mmc1/
/sys/kernel/debug/gpio
/sys/kernel/debug/pinctrl/

# 设备节点
/sys/bus/sdio/devices/
/sys/class/net/wlan0/
```

---

**文档版本**: 1.0  
**最后更新**: 2026-02-28  
**作者**: Claude Code Analysis  
**适用平台**: RK3399 + AP6255 + 主线内核

