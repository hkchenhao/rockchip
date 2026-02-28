# Platform Device 创建顺序详解

## 问题

在设备树中定义了三个设备节点：
```
├─ sdio0 (SDIO控制器)
├─ sdio_pwrseq (电源序列)
└─ wifi@1 (WiFi设备节点)
```

这三个设备的 `platform_device` 创建和初始化顺序是什么？

## 简短答案

**创建顺序**（设备树解析阶段）：
1. **sdio_pwrseq** - 首先创建（根节点的直接子节点）
2. **sdio0** - 其次创建（根节点的直接子节点）
3. **wifi@1** - 不会被自动创建为 platform_device（SDIO 总线设备）

**驱动匹配和初始化顺序**（取决于驱动注册时机）：
1. **sdio_pwrseq** - 驱动先注册，立即匹配
2. **sdio0** - 驱动后注册，匹配后初始化
3. **wifi@1** - SDIO 总线扫描时动态创建为 sdio_device

---

## 详细分析

### 1. 设备树节点位置

```dts
/ {
    // 根节点

    sdio_pwrseq: sdio-pwrseq {
        compatible = "mmc-pwrseq-simple";
        clocks = <&rk808 1>;
        pinctrl-0 = <&wifi_enable_h>;
        reset-gpios = <&gpio0 RK_PB2 GPIO_ACTIVE_LOW>;
    };

    // ... 其他节点 ...
};

&sdio0 {
    // sdio0 是根节点的子节点
    status = "okay";
    mmc-pwrseq = <&sdio_pwrseq>;

    brcmf: wifi@1 {
        // wifi@1 是 sdio0 的子节点
        compatible = "brcm,bcm4329-fmac";
        interrupts = <RK_PA3 GPIO_ACTIVE_HIGH>;
        pinctrl-0 = <&wifi_host_wake_l>;
    };
};
```

**关键点**：
- `sdio_pwrseq` 和 `sdio0` 都是**根节点的直接子节点**
- `wifi@1` 是 `sdio0` 的**子节点**

---

### 2. Platform Device 创建时机

#### 2.1 内核启动流程

```c
// drivers/of/platform.c:517
static int __init of_platform_default_populate_init(void)
{
    // ... 省略部分代码 ...

    // 遍历根节点的所有子节点，创建 platform_device
    of_platform_default_populate(NULL, NULL, NULL);

    return 0;
}
arch_initcall_sync(of_platform_default_populate_init);  // ← 注意这个宏
```

**时机**：`arch_initcall_sync` 阶段（内核启动早期）

#### 2.2 创建过程

```c
// drivers/of/platform.c:465
int of_platform_populate(struct device_node *root, ...)
{
    struct device_node *child;

    // 遍历根节点的每个子节点
    for_each_child_of_node(root, child) {
        // 为每个子节点创建 platform_device
        rc = of_platform_bus_create(child, matches, lookup, parent, true);
        if (rc) {
            of_node_put(child);
            break;
        }
    }

    return rc;
}
```

**关键点**：
- **只遍历根节点的直接子节点**
- 按照设备树中的**节点顺序**依次创建
- `wifi@1` 不在根节点下，所以**不会被自动创建**

---

### 3. 三个设备的创建顺序

#### 3.1 sdio_pwrseq 的创建

```
时机：arch_initcall_sync 阶段
位置：根节点的直接子节点
过程：
  1. of_platform_populate() 扫描到 sdio_pwrseq 节点
  2. 调用 of_platform_device_create() 创建 platform_device
  3. 将设备注册到 platform_bus
  4. 如果 mmc-pwrseq-simple 驱动已注册，立即匹配
```

**结构**：
```c
struct platform_device {
    .name = "pwrseq_simple",
    .id = -1,
    .dev = {
        .of_node = &sdio_pwrseq_node,
        .parent = &platform_bus,
    },
};
```

#### 3.2 sdio0 的创建

```
时机：arch_initcall_sync 阶段（在 sdio_pwrseq 之后）
位置：根节点的直接子节点
过程：
  1. of_platform_populate() 扫描到 sdio0 节点
  2. 调用 of_platform_device_create() 创建 platform_device
  3. 将设备注册到 platform_bus
  4. 如果 dw_mmc_rockchip 驱动已注册，立即匹配
```

**结构**：
```c
struct platform_device {
    .name = "fe310000.mmc",  // 基于设备树地址
    .id = -1,
    .dev = {
        .of_node = &sdio0_node,
        .parent = &platform_bus,
    },
};
```

**注意**：`sdio0` 节点有 `mmc-pwrseq = <&sdio_pwrseq>` 属性，但这只是一个**引用**，不影响创建顺序。

#### 3.3 wifi@1 的创建

**关键**：`wifi@1` **不会被 of_platform_populate() 创建**！

**原因**：
1. `wifi@1` 不是根节点的直接子节点
2. `wifi@1` 是 SDIO 总线设备，不是 platform 设备
3. 它会在 SDIO 总线扫描时动态创建

**创建时机**：
```
时机：sdio0 驱动初始化后，SDIO 总线扫描阶段
类型：sdio_device（不是 platform_device）
过程：
  1. dw_mmc_rockchip_probe() 初始化 SDIO 控制器
  2. mmc_start_host() 启动 MMC/SDIO 主机
  3. mmc_rescan() 扫描 SDIO 总线
  4. sdio_read_cis() 读取 CIS（Card Information Structure）
  5. mmc_attach_sdio() 识别 SDIO 设备
  6. sdio_init_func() 为每个 SDIO function 创建 sdio_func
  7. sdio_add_func() 注册到 SDIO 总线
  8. brcmfmac 驱动匹配并初始化
```

**结构**：
```c
struct sdio_func {
    .vendor = 0x02d0,  // Broadcom
    .device = 0x4339,  // BCM4339
    .num = 1,
    .dev = {
        .of_node = &wifi_node,
        .parent = &mmc_host->dev,
        .bus = &sdio_bus_type,  // ← 注意：SDIO 总线
    },
};
```

---

### 4. 完整时序图

```
内核启动
    │
    ├─ [arch_initcall_sync] of_platform_default_populate_init()
    │       │
    │       ├─ 扫描根节点子节点
    │       │
    │       ├─ [1] 创建 sdio_pwrseq 的 platform_device
    │       │       ├─ 注册到 platform_bus
    │       │       └─ 等待驱动匹配
    │       │
    │       ├─ [2] 创建 sdio0 的 platform_device
    │       │       ├─ 注册到 platform_bus
    │       │       └─ 等待驱动匹配
    │       │
    │       └─ 不创建 wifi@1（不是根节点直接子节点）
    │
    ├─ [module_init] mmc_pwrseq_simple_driver 注册
    │       │
    │       └─ [匹配] mmc_pwrseq_simple_probe()
    │               ├─ 获取 reset-gpios (GPIO0_B2)
    │               ├─ 获取 clocks (RK808 CLK_OUT1)
    │               ├─ 应用 pinctrl-0 (wifi_enable_h)
    │               └─ mmc_pwrseq_register() 注册到全局列表
    │
    ├─ [module_init] dw_mci_rockchip_driver 注册
    │       │
    │       └─ [匹配] dw_mci_rockchip_probe()
    │               ├─ 初始化 DW MMC 控制器
    │               ├─ mmc_pwrseq_alloc() 查找并绑定 pwrseq
    │               ├─ mmc_add_host() 添加 MMC 主机
    │               └─ mmc_start_host()
    │                       │
    │                       └─ mmc_rescan_workqueue
    │                               │
    │                               ├─ mmc_pwrseq_pre_power_on() 上电前准备
    │                               ├─ mmc_power_up() 上电
    │                               ├─ mmc_pwrseq_post_power_on() 上电后延时
    │                               ├─ sdio_reset() 复位 SDIO
    │                               ├─ mmc_send_if_cond() 发送 CMD5
    │                               ├─ mmc_attach_sdio() 识别 SDIO 设备
    │                               │       │
    │                               │       ├─ sdio_read_cis() 读取 CIS
    │                               │       ├─ [3] sdio_init_func() 创建 sdio_func
    │                               │       └─ sdio_add_func() 注册到 SDIO 总线
    │                               │
    │                               └─ [匹配] brcmfmac_sdio_driver
    │                                       │
    │                                       └─ brcmfmac_sdio_probe()
    │                                               ├─ 读取设备树 wifi@1 节点
    │                                               ├─ 初始化 SDIO 通信
    │                                               ├─ 下载固件
    │                                               └─ 注册网络设备
    │
    └─ 系统运行
```

---

### 5. 为什么是这个顺序？

#### 5.1 设备树解析规则

**规则 1**：只有根节点的**直接子节点**会被自动创建为 platform_device
```
/ {
    device1 { };        ← 会被创建
    device2 {
        subdevice { };  ← 不会被创建（除非 device2 是总线）
    };
}
```

**规则 2**：子节点的创建由**父设备的驱动**负责
```
sdio0 (platform_device)
  └─ dw_mmc_rockchip 驱动负责扫描 SDIO 总线
      └─ wifi@1 在总线扫描时创建为 sdio_device
```

#### 5.2 SDIO 设备的特殊性

**SDIO 设备不是 platform_device**：
- Platform 设备：内存映射的硬件设备
- SDIO 设备：通过 SDIO 总线通信的设备

**创建方式**：
- Platform 设备：设备树静态创建
- SDIO 设备：总线扫描动态创建

**类比**：
```
USB 总线：
  USB 控制器 (platform_device) ← 设备树创建
    └─ USB 鼠标 (usb_device) ← 插入时动态创建

SDIO 总线：
  SDIO 控制器 (platform_device) ← 设备树创建
    └─ WiFi 模块 (sdio_device) ← 总线扫描时动态创建
```

---

### 6. 驱动匹配顺序

#### 6.1 情况 1：驱动先注册，设备后创建

如果驱动在 `of_platform_default_populate_init()` 之前注册（例如使用 `early_initcall`），那么：

```
1. 驱动注册到 platform_bus
2. 设备创建后立即匹配
3. 调用 probe() 函数
```

#### 6.2 情况 2：设备先创建，驱动后注册

如果驱动在 `of_platform_default_populate_init()` 之后注册（例如使用 `module_init`），那么：

```
1. 设备创建并注册到 platform_bus
2. 设备等待驱动
3. 驱动注册后触发匹配
4. 调用 probe() 函数
```

#### 6.3 实际情况

```c
// drivers/mmc/core/pwrseq_simple.c:163
module_platform_driver(mmc_pwrseq_simple_driver);  // module_init

// drivers/mmc/host/dw_mmc-rockchip.c:684
module_platform_driver(dw_mci_rockchip_pltfm_driver);  // module_init

// drivers/net/wireless/broadcom/brcm80211/brcmfmac/bcmsdh.c
module_sdio_driver(brcmfmac_sdio_driver);  // module_init
```

**结论**：三个驱动都使用 `module_init`，在设备创建之后才注册。

**匹配顺序**：
1. **sdio_pwrseq** - 设备已存在，驱动注册后立即匹配
2. **sdio0** - 设备已存在，驱动注册后立即匹配
3. **wifi@1** - 设备尚不存在，等待 SDIO 总线扫描后创建并匹配

---

### 7. 依赖关系

#### 7.1 创建依赖

```
sdio_pwrseq (独立) ─┐
                     ├─→ sdio0 (引用 pwrseq，但创建时不依赖)
sdio0 (独立) ────────┘
                     │
                     └─→ wifi@1 (依赖 sdio0 初始化完成)
```

**关键点**：
- `sdio_pwrseq` 和 `sdio0` 的**创建**是独立的
- `sdio0` 的**初始化**需要 `sdio_pwrseq` 已注册
- `wifi@1` 的**创建**需要 `sdio0` 初始化完成

#### 7.2 初始化依赖

```
1. sdio_pwrseq 驱动 probe()
   └─ mmc_pwrseq_register() 注册到全局链表

2. sdio0 驱动 probe()
   ├─ mmc_pwrseq_alloc() 查找 pwrseq（依赖步骤 1）
   └─ mmc_start_host() 启动 SDIO 总线扫描

3. wifi@1 设备创建
   └─ SDIO 总线扫描（依赖步骤 2）

4. wifi@1 驱动 probe()
   └─ brcmfmac_sdio_probe()
```

---

### 8. 验证方法

#### 8.1 查看 dmesg 日志

```bash
dmesg | grep -E "pwrseq|dwmmc|brcmfmac"
```

预期输出：
```
[    1.234567] pwrseq_simple sdio-pwrseq: GPIO lookup for consumer reset
[    1.234890] pwrseq_simple sdio-pwrseq: using device tree for GPIO lookup
[    1.345678] dwmmc_rockchip fe310000.mmc: IDMAC supports 32-bit address mode.
[    1.456789] dwmmc_rockchip fe310000.mmc: Using internal DMA controller.
[    1.567890] mmc_host mmc0: Bus speed (slot 0) = 400000Hz (slot req 400000Hz, actual 400000HZ div = 0)
[    2.123456] mmc0: new high speed SDIO card at address 0001
[    2.234567] brcmfmac: F1 signature read @0x18000000=0x1541a9a6
[    2.345678] brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac4339-sdio for chip BCM4339/2
```

**顺序**：
1. `pwrseq_simple` - 最早
2. `dwmmc_rockchip` - 其次
3. `brcmfmac` - 最后

#### 8.2 查看 /sys 目录

```bash
# 查看 platform 设备
ls /sys/bus/platform/devices/
# 应该看到：
# - sdio-pwrseq
# - fe310000.mmc (sdio0)

# 查看 SDIO 设备
ls /sys/bus/sdio/devices/
# 应该看到：
# - mmc0:0001:1 (wifi@1)

# 查看设备树节点
ls /sys/firmware/devicetree/base/
# 应该看到：
# - sdio-pwrseq/
# - sdio@fe310000/ (sdio0)
```

#### 8.3 添加调试打印

在驱动中添加打印：

```c
// drivers/mmc/core/pwrseq_simple.c
static int mmc_pwrseq_simple_probe(struct platform_device *pdev)
{
    pr_info("[PWRSEQ] probe start\n");
    // ...
}

// drivers/mmc/host/dw_mmc-rockchip.c
static int dw_mci_rockchip_probe(struct platform_device *pdev)
{
    pr_info("[SDIO0] probe start\n");
    // ...
}

// drivers/net/wireless/broadcom/brcm80211/brcmfmac/bcmsdh.c
static int brcmfmac_sdio_probe(struct sdio_func *func, ...)
{
    pr_info("[WIFI] probe start\n");
    // ...
}
```

---

### 9. 常见误解

#### 误解 1：设备树顺序决定创建顺序

**错误**：认为设备树中 `sdio_pwrseq` 在 `sdio0` 之前，所以先创建。

**正确**：虽然通常是按顺序创建，但**不保证**。内核遍历设备树节点时，顺序取决于设备树编译器的实现。

#### 误解 2：wifi@1 会被创建为 platform_device

**错误**：认为所有设备树节点都会创建 platform_device。

**正确**：只有根节点的直接子节点会被自动创建。`wifi@1` 是 SDIO 总线设备，由 SDIO 总线驱动动态创建。

#### 误解 3：mmc-pwrseq 引用会延迟 sdio0 创建

**错误**：认为 `mmc-pwrseq = <&sdio_pwrseq>` 会导致 `sdio0` 等待 `sdio_pwrseq` 创建完成。

**正确**：设备创建时不解析引用，只是记录 phandle。引用在驱动 probe 时才解析。

---

### 10. 总结

#### 创建顺序（设备树解析阶段）

| 序号 | 设备 | 类型 | 时机 | 总线 |
|------|------|------|------|------|
| 1 | sdio_pwrseq | platform_device | arch_initcall_sync | platform_bus |
| 2 | sdio0 | platform_device | arch_initcall_sync | platform_bus |
| 3 | wifi@1 | sdio_device | SDIO 总线扫描 | sdio_bus |

#### 驱动匹配顺序（驱动注册后）

| 序号 | 驱动 | 时机 | 依赖 |
|------|------|------|------|
| 1 | mmc-pwrseq-simple | module_init | 无 |
| 2 | dw_mmc_rockchip | module_init | pwrseq 已注册 |
| 3 | brcmfmac | module_init | SDIO 总线已扫描 |

#### 关键点

1. ✅ **设备创建不等于驱动初始化**
2. ✅ **platform_device 由设备树静态创建**
3. ✅ **sdio_device 由总线扫描动态创建**
4. ✅ **wifi@1 不是 platform_device**
5. ✅ **创建顺序 ≠ 初始化顺序**

---

**文档版本**: 1.0
**最后更新**: 2026-02-28
**相关文档**: `ap6255_driver_flow.md`
