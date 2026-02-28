# AP6255驱动加载流程文档修正说明

## 修正日期
2026-02-28

## 问题描述

原文档在"系统启动到驱动加载"部分存在概念错误，错误地将 `wifi@1` 节点列为会被创建的 `platform_device`。

## 错误内容

### 原文档错误描述

```
创建platform_device (sdio0, sdio_pwrseq, wifi@1)
```

这个描述暗示三个设备都会被创建为 `platform_device`，这是**不正确**的。

## 正确概念

### Platform Device vs SDIO Device

Linux 内核中设备的创建遵循以下规则：

#### 1. Platform Device 创建规则

**只有根节点的直接子节点**会被 `of_platform_default_populate_init()` 自动创建为 `platform_device`：

```c
// drivers/of/platform.c:517
static int __init of_platform_default_populate_init(void)
{
    // 在 arch_initcall_sync 阶段执行
    of_platform_default_populate(NULL, NULL, NULL);
    return 0;
}
arch_initcall_sync(of_platform_default_populate_init);
```

**创建的设备**：
- ✅ `sdio_pwrseq` - 根节点的直接子节点 → platform_device
- ✅ `sdio0` - 根节点的直接子节点 → platform_device
- ❌ `wifi@1` - sdio0 的子节点 → **不会被创建**

#### 2. SDIO Device 创建规则

SDIO 设备不是 platform_device，而是由 SDIO 总线在扫描时**动态创建**的 `sdio_func` 设备：

```
SDIO 总线扫描流程:
  mmc_rescan()
    └─ mmc_attach_sdio()
        ├─ sdio_read_cis() - 读取卡信息
        └─ sdio_init_func() - 为每个 Function 创建 sdio_func
            ├─ Function 1 → sdio_func 设备
            └─ Function 2 → sdio_func 设备 (对应 wifi@1 节点)
```

**wifi@1 节点的作用**：
- 不会被创建为独立的设备
- 在 SDIO Function 2 创建时，其设备树信息会被关联到 sdio_func 设备
- 提供 OOB 中断、pinctrl 等配置信息

#### 3. 设备类型对比

| 设备节点 | 设备类型 | 总线类型 | 创建时机 | 创建方式 |
|---------|---------|---------|---------|---------|
| sdio_pwrseq | platform_device | platform_bus | arch_initcall_sync | 设备树静态创建 |
| sdio0 | platform_device | platform_bus | arch_initcall_sync | 设备树静态创建 |
| wifi@1 | sdio_device | sdio_bus | SDIO总线扫描 | 总线动态枚举 |

## 已修正内容

### 1. 概述章节

添加了"重要概念说明"部分，详细解释了 Platform Device 和 SDIO Device 的区别。

### 2. Pinctrl 应用流程图

**修正前**：
```
创建platform_device (sdio0, sdio_pwrseq, wifi@1)
```

**修正后**：
```
创建platform_device
    ├─ sdio_pwrseq (根节点子节点)
    └─ sdio0 (根节点子节点)
注意: wifi@1不会被创建(是sdio0的子节点，等待SDIO总线扫描)
```

### 3. 系统启动流程图

**修正前**：
```
│  └─ 创建platform_device                                        │
│       ├─ sdio0 (SDIO控制器)                                    │
│       ├─ sdio_pwrseq (电源序列)                                │
│       └─ wifi@1 (WiFi设备节点)                                 │
```

**修正后**：
```
│          设备树解析 (DTB加载) - arch_initcall_sync             │
│  of_platform_default_populate_init()                           │
│  ├─ 解析rk3399.dtsi: sdio0控制器定义                           │
│  ├─ 解析rk3399-eaidk-610.dts: 板级配置                         │
│  └─ 创建platform_device (仅根节点的直接子节点)                 │
│       ├─ sdio_pwrseq (电源序列) ✓                              │
│       └─ sdio0 (SDIO控制器) ✓                                  │
│  注意: wifi@1不会被创建 (sdio0的子节点，由SDIO总线动态创建)    │
```

### 4. 驱动注册阶段

添加了清晰的分段，说明三个驱动的注册顺序：
1. mmc-pwrseq-simple 驱动注册
2. dw_mmc_rockchip 驱动注册
3. brcmfmac 驱动注册

### 5. SDIO 设备枚举

**修正前**：
```
│    └─ sdio_init_func() - 初始化Function                       │
│         └─ 创建sdio_func设备                                   │
```

**修正后**：
```
│    └─ sdio_init_func() - 为每个Function创建sdio_func设备      │
│         ├─ 创建 Function 1 (sdio_func)                        │
│         ├─ 创建 Function 2 (sdio_func) ← 对应wifi@1节点       │
│         └─ sdio_add_func() 注册到SDIO总线                     │
│  ★ 关键: wifi@1节点信息会关联到Function 2的sdio_func设备      │
```

### 6. 添加参考文档

在附录中添加了指向 `platform_device_creation_order.md` 的链接，该文档详细解释了设备创建顺序。

## 相关文档

- **主文档**: `ap6255_driver_flow.md` (已修正)
- **详细解释**: `platform_device_creation_order.md` (新建)
- **快速参考**: `QUICK_START.md`

## 技术要点总结

### Platform Device 创建

```c
// 内核启动流程
start_kernel()
  └─ rest_init()
      └─ kernel_init()
          └─ do_initcalls()
              └─ arch_initcall_sync
                  └─ of_platform_default_populate_init()
                      └─ of_platform_populate()
                          └─ for_each_child_of_node(root, child)
                              └─ of_platform_device_create(child)
```

**关键点**：
- 只遍历根节点的**直接子节点**
- 创建 `platform_device` 并注册到 `platform_bus`
- 不递归处理子节点的子节点

### SDIO Device 创建

```c
// SDIO 总线扫描流程
dw_mci_probe()
  └─ mmc_add_host()
      └─ mmc_start_host()
          └─ mmc_rescan()
              └─ mmc_attach_sdio()
                  ├─ mmc_sdio_init_card()
                  │    └─ sdio_read_cis() - 读取设备信息
                  └─ sdio_init_func()
                      ├─ sdio_alloc_func() - 分配 sdio_func
                      ├─ 关联设备树节点信息
                      └─ sdio_add_func() - 注册到 sdio_bus
```

**关键点**：
- 动态枚举，类似 USB 设备
- 创建 `sdio_func` 设备（不是 platform_device）
- 注册到 `sdio_bus`（不是 platform_bus）
- 设备树节点信息会关联到 sdio_func

## 验证方法

### 查看 Platform 设备

```bash
ls /sys/bus/platform/devices/
# 应该看到:
# - sdio-pwrseq
# - fe310000.mmc (sdio0)
# 不会看到 wifi@1
```

### 查看 SDIO 设备

```bash
ls /sys/bus/sdio/devices/
# 应该看到:
# - mmc0:0001:1 (Function 1)
# - mmc0:0001:2 (Function 2, 对应 wifi@1)
```

### 查看设备树节点

```bash
ls /sys/firmware/devicetree/base/
# 应该看到:
# - sdio-pwrseq/
# - sdio@fe310000/ (sdio0)
#   └─ wifi@1/  (作为 sdio0 的子节点存在)
```

## 常见误解

### 误解 1: 所有设备树节点都会创建 platform_device

**错误**: 认为设备树中的所有节点都会被创建为 platform_device。

**正确**: 只有根节点的直接子节点会被自动创建为 platform_device。子节点的处理由父设备的驱动负责。

### 误解 2: wifi@1 会被创建为 platform_device

**错误**: 认为 wifi@1 节点会被创建为独立的 platform_device。

**正确**: wifi@1 是 SDIO 总线设备，在总线扫描时动态创建为 sdio_func，其设备树信息会关联到该设备。

### 误解 3: 设备树顺序决定创建顺序

**错误**: 认为设备树中节点的顺序严格决定设备创建顺序。

**正确**: 虽然通常按顺序创建，但不保证。驱动的 probe 顺序还取决于驱动注册时机和依赖关系。

## 修正影响

这次修正：
- ✅ 纠正了对 Linux 设备模型的理解
- ✅ 澄清了 platform_device 和 sdio_device 的区别
- ✅ 明确了设备创建的时机和方式
- ✅ 提供了准确的技术参考

## 修正人员

Claude Sonnet 4.6

## 审核状态

待用户确认

---

**文档版本**: 1.0
**最后更新**: 2026-02-28
**相关文档**:
- `ap6255_driver_flow.md`
- `platform_device_creation_order.md`
