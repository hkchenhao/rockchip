# pinctrl 配置自动应用机制详解

## 问题

pinctrl 配置是在设备探测到 `mmc-pwrseq-simple` 时自动应用的吗？具体的应用时机和机制是什么？

---

## 答案：在驱动 probe 之前自动应用

**pinctrl 配置由 Linux 设备驱动核心（Device Driver Core）在调用驱动的 probe 函数之前自动应用，不是由 `mmc-pwrseq-simple` 驱动自己处理的。**

---

## 详细分析

### 1. 自动应用的完整流程

```
设备匹配到驱动
    ↓
really_probe() 函数被调用
    ↓
【第 1 步】pinctrl_bind_pins(dev)  ← pinctrl 自动应用（在这里！）
    ├─ 解析设备树的 pinctrl-names 和 pinctrl-0
    ├─ 查找 "default" 状态
    ├─ 应用 pinctrl 配置
    └─ 配置 GPIO 的硬件属性
    ↓
【第 2 步】driver_sysfs_add(dev)
    ↓
【第 3 步】call_driver_probe(dev, drv)  ← 调用驱动的 probe 函数
    ├─ mmc_pwrseq_simple_probe()
    ├─ 驱动申请 reset-gpios
    └─ 驱动注册电源序列
    ↓
设备初始化完成
```

**关键点：**
- ✅ pinctrl 配置在驱动 probe **之前**自动应用
- ✅ 由设备驱动核心（dd.c）自动处理
- ✅ 驱动无需手动处理 pinctrl
- ✅ 当驱动 probe 执行时，GPIO 已经配置好了

---

## 2. 核心代码分析

### 2.1 设备驱动核心代码

**文件：** `drivers/base/dd.c`

```c
static int really_probe(struct device *dev, struct device_driver *drv)
{
    // ... 省略前面的代码

    dev->driver = drv;

    /* If using pinctrl, bind pins now before probing */
    ret = pinctrl_bind_pins(dev);  // ← 关键：在 probe 之前调用！
    if (ret)
        goto pinctrl_bind_failed;

    // ... DMA 配置等

    ret = driver_sysfs_add(dev);
    if (ret) {
        pr_err("%s: driver_sysfs_add(%s) failed\n",
               __func__, dev_name(dev));
        goto sysfs_failed;
    }

    // ... 电源域激活等

    ret = call_driver_probe(dev, drv);  // ← 这里才调用驱动的 probe
    if (ret) {
        // 错误处理
    }

    // ... 后续处理
}
```

**流程说明：**
1. `pinctrl_bind_pins(dev)` 先执行
2. 然后才调用 `call_driver_probe(dev, drv)`
3. `call_driver_probe` 会调用驱动的 probe 函数

---

### 2.2 pinctrl_bind_pins 函数

**文件：** `drivers/base/pinctrl.c`

```c
/**
 * pinctrl_bind_pins() - called by the device core before probe
 * @dev: the device that is just about to probe
 */
int pinctrl_bind_pins(struct device *dev)
{
    int ret;

    if (dev->of_node_reused)
        return 0;

    // 1. 分配 pinctrl 结构
    dev->pins = devm_kzalloc(dev, sizeof(*(dev->pins)), GFP_KERNEL);
    if (!dev->pins)
        return -ENOMEM;

    // 2. 获取设备的 pinctrl 句柄
    dev->pins->p = devm_pinctrl_get(dev);
    if (IS_ERR(dev->pins->p)) {
        dev_dbg(dev, "no pinctrl handle\n");
        ret = PTR_ERR(dev->pins->p);
        goto cleanup_alloc;
    }

    // 3. 查找 "default" 状态
    //    对应设备树的 pinctrl-names = "default"
    dev->pins->default_state = pinctrl_lookup_state(dev->pins->p,
                                    PINCTRL_STATE_DEFAULT);
    if (IS_ERR(dev->pins->default_state)) {
        dev_dbg(dev, "no default pinctrl state\n");
        ret = 0;
        goto cleanup_get;
    }

    // 4. 查找 "init" 状态（可选）
    dev->pins->init_state = pinctrl_lookup_state(dev->pins->p,
                                    PINCTRL_STATE_INIT);
    if (IS_ERR(dev->pins->init_state)) {
        /* Not supplying this state is perfectly legal */
        dev_dbg(dev, "no init pinctrl state\n");

        // 5. 应用 "default" 状态
        ret = pinctrl_select_state(dev->pins->p,
                                   dev->pins->default_state);
    } else {
        // 如果有 "init" 状态，先应用 "init"
        ret = pinctrl_select_state(dev->pins->p, dev->pins->init_state);
    }

    if (ret) {
        dev_dbg(dev, "failed to activate initial pinctrl state\n");
        goto cleanup_get;
    }

#ifdef CONFIG_PM
    // 6. 查找电源管理相关的状态（可选）
    dev->pins->sleep_state = pinctrl_lookup_state(dev->pins->p,
                                    PINCTRL_STATE_SLEEP);
    dev->pins->idle_state = pinctrl_lookup_state(dev->pins->p,
                                    PINCTRL_STATE_IDLE);
#endif

    return 0;

    // 错误处理
cleanup_get:
    devm_pinctrl_put(dev->pins->p);
cleanup_alloc:
    devm_kfree(dev, dev->pins);
    dev->pins = NULL;

    if (ret == -EPROBE_DEFER)
        return ret;
    if (ret == -EINVAL)
        return ret;

    return 0;
}
```

**函数功能：**
1. ✅ 解析设备树的 pinctrl 配置
2. ✅ 查找 "default" 状态（对应 `pinctrl-names = "default"`）
3. ✅ 应用 pinctrl 配置（调用 `pinctrl_select_state`）
4. ✅ 配置 GPIO 的硬件属性（引脚复用、上下拉等）

---

### 2.3 mmc-pwrseq-simple 驱动的 probe

**文件：** `drivers/mmc/core/pwrseq_simple.c`

```c
static int mmc_pwrseq_simple_probe(struct platform_device *pdev)
{
    struct mmc_pwrseq_simple *pwrseq;
    struct device *dev = &pdev->dev;

    // 注意：这里没有任何 pinctrl 相关的代码！
    // 因为 pinctrl 已经在 probe 之前自动应用了

    pwrseq = devm_kzalloc(dev, sizeof(*pwrseq), GFP_KERNEL);
    if (!pwrseq)
        return -ENOMEM;

    // 获取时钟
    pwrseq->ext_clk = devm_clk_get(dev, "ext_clock");
    if (IS_ERR(pwrseq->ext_clk) && PTR_ERR(pwrseq->ext_clk) != -ENOENT)
        return PTR_ERR(pwrseq->ext_clk);

    // 获取 reset GPIO
    // 此时 GPIO 的硬件属性已经由 pinctrl 配置好了
    pwrseq->reset_gpios = devm_gpiod_get_array(dev, "reset",
                                                GPIOD_OUT_HIGH);
    if (IS_ERR(pwrseq->reset_gpios) &&
        PTR_ERR(pwrseq->reset_gpios) != -ENOENT &&
        PTR_ERR(pwrseq->reset_gpios) != -ENOSYS) {
        return PTR_ERR(pwrseq->reset_gpios);
    }

    // 读取延迟参数
    device_property_read_u32(dev, "post-power-on-delay-ms",
                             &pwrseq->post_power_on_delay_ms);
    device_property_read_u32(dev, "power-off-delay-us",
                             &pwrseq->power_off_delay_us);

    // 注册电源序列
    pwrseq->pwrseq.dev = dev;
    pwrseq->pwrseq.ops = &mmc_pwrseq_simple_ops;
    pwrseq->pwrseq.owner = THIS_MODULE;
    platform_set_drvdata(pdev, pwrseq);

    return mmc_pwrseq_register(&pwrseq->pwrseq);
}
```

**关键观察：**
- ❌ 驱动代码中**没有任何 pinctrl 相关的代码**
- ✅ 驱动只需要处理 reset-gpios
- ✅ 当驱动执行 `devm_gpiod_get_array` 时，GPIO 的硬件属性已经配置好了

---

## 3. 设备树配置与内核的对应关系

### 3.1 设备树配置

```dts
sdio_pwrseq: sdio-pwrseq {
    compatible = "mmc-pwrseq-simple";
    clocks = <&rk808 1>;
    clock-names = "ext_clock";

    pinctrl-names = "default";        // ← 定义状态名称
    pinctrl-0 = <&wifi_enable_h>;     // ← "default" 状态的配置

    reset-gpios = <&gpio0 RK_PB2 GPIO_ACTIVE_LOW>;
};

&pinctrl {
    sdio-pwrseq {
        wifi_enable_h: wifi-enable-h {
            rockchip,pins = <0 RK_PB2 RK_FUNC_GPIO &pcfg_pull_none>;
        };
    };
};
```

### 3.2 内核处理流程

```
1. 设备树解析
   ├─ 找到 sdio_pwrseq 节点
   ├─ compatible = "mmc-pwrseq-simple" 匹配驱动
   └─ 创建 platform_device

2. 设备与驱动匹配
   ├─ mmc_pwrseq_simple_driver 匹配成功
   └─ 调用 really_probe()

3. really_probe() 执行
   ├─ 【第 1 步】pinctrl_bind_pins(dev)
   │   ├─ 解析 pinctrl-names = "default"
   │   ├─ 解析 pinctrl-0 = <&wifi_enable_h>
   │   ├─ 查找 wifi_enable_h 节点
   │   ├─ 读取 rockchip,pins = <0 RK_PB2 RK_FUNC_GPIO &pcfg_pull_none>
   │   ├─ 配置 GPIO0_PB2：
   │   │   ├─ 功能：GPIO 模式
   │   │   ├─ 上下拉：无
   │   │   └─ 驱动强度：默认
   │   └─ 应用配置到硬件寄存器
   │
   └─ 【第 2 步】call_driver_probe(dev, drv)
       └─ mmc_pwrseq_simple_probe()
           ├─ 获取时钟
           ├─ 申请 reset-gpios（GPIO0_PB2）
           │   └─ GPIO 硬件属性已经配置好了
           └─ 注册电源序列
```

---

## 4. pinctrl 状态管理

### 4.1 支持的状态

Linux 内核定义了多个标准的 pinctrl 状态：

```c
// include/linux/pinctrl/pinctrl-state.h

#define PINCTRL_STATE_DEFAULT "default"    // 默认状态
#define PINCTRL_STATE_INIT "init"          // 初始化状态（可选）
#define PINCTRL_STATE_IDLE "idle"          // 空闲状态（电源管理）
#define PINCTRL_STATE_SLEEP "sleep"        // 休眠状态（电源管理）
```

### 4.2 设备树配置示例

#### 基本配置（只有 default 状态）

```dts
sdio_pwrseq: sdio-pwrseq {
    compatible = "mmc-pwrseq-simple";

    pinctrl-names = "default";        // 只定义 default 状态
    pinctrl-0 = <&wifi_enable_h>;     // default 状态的配置

    reset-gpios = <&gpio0 RK_PB2 GPIO_ACTIVE_LOW>;
};
```

#### 高级配置（多状态）

```dts
sdio_pwrseq: sdio-pwrseq {
    compatible = "mmc-pwrseq-simple";

    pinctrl-names = "default", "sleep";  // 定义多个状态
    pinctrl-0 = <&wifi_enable_h>;        // default 状态
    pinctrl-1 = <&wifi_sleep>;           // sleep 状态

    reset-gpios = <&gpio0 RK_PB2 GPIO_ACTIVE_LOW>;
};

&pinctrl {
    sdio-pwrseq {
        wifi_enable_h: wifi-enable-h {
            // default 状态：GPIO 模式，无上下拉
            rockchip,pins = <0 RK_PB2 RK_FUNC_GPIO &pcfg_pull_none>;
        };

        wifi_sleep: wifi-sleep {
            // sleep 状态：GPIO 模式，下拉（省电）
            rockchip,pins = <0 RK_PB2 RK_FUNC_GPIO &pcfg_pull_down>;
        };
    };
};
```

### 4.3 状态切换

```c
// 驱动可以在运行时切换 pinctrl 状态

// 切换到 sleep 状态（电源管理）
pinctrl_pm_select_sleep_state(dev);

// 切换回 default 状态
pinctrl_pm_select_default_state(dev);

// 切换到 idle 状态
pinctrl_pm_select_idle_state(dev);
```

---

## 5. 应用时机总结

### 5.1 完整的时间线

```
时间线：设备初始化过程

T0: 内核启动，解析设备树
    ├─ 创建 platform_device (sdio_pwrseq)
    └─ 设备树信息保存在 device->of_node

T1: 设备与驱动匹配
    ├─ mmc_pwrseq_simple_driver 注册
    ├─ 匹配 compatible = "mmc-pwrseq-simple"
    └─ 调用 really_probe(dev, drv)

T2: pinctrl 自动应用  ← 【关键时刻】
    ├─ really_probe() 调用 pinctrl_bind_pins(dev)
    ├─ 解析 pinctrl-names 和 pinctrl-0
    ├─ 查找 &wifi_enable_h 节点
    ├─ 读取 rockchip,pins 配置
    ├─ 配置 GPIO0_PB2 的硬件属性
    │   ├─ 功能：GPIO 模式
    │   ├─ 上下拉：无
    │   └─ 驱动强度：默认
    └─ 写入硬件寄存器

T3: 驱动 probe 执行
    ├─ really_probe() 调用 call_driver_probe(dev, drv)
    ├─ 调用 mmc_pwrseq_simple_probe()
    ├─ 驱动申请 reset-gpios
    │   └─ GPIO 硬件属性已经配置好了
    └─ 驱动注册电源序列

T4: 设备初始化完成
    └─ 设备可以正常工作
```

**关键点：**
- T2 < T3：pinctrl 在驱动 probe 之前应用
- 驱动无需关心 pinctrl
- 当驱动执行时，GPIO 已经配置好了

---

### 5.2 谁负责什么？

| 组件 | 职责 | 时机 |
|------|------|------|
| **设备驱动核心** | 自动应用 pinctrl 配置 | 驱动 probe 之前 |
| **pinctrl 子系统** | 解析设备树，配置硬件 | 被设备驱动核心调用 |
| **设备驱动** | 处理设备逻辑功能 | probe 函数中 |

**驱动无需处理 pinctrl：**
- ❌ 驱动不需要调用 pinctrl API
- ❌ 驱动不需要解析 pinctrl 配置
- ✅ 驱动只需要处理设备的逻辑功能（如 reset-gpios）

---

## 6. 常见问题

### Q1: 驱动需要手动处理 pinctrl 吗？

**A:** 不需要！

**原因：**
- pinctrl 由设备驱动核心自动处理
- 在驱动 probe 之前自动应用
- 驱动无需任何 pinctrl 相关代码

**例外情况：**
- 如果驱动需要动态切换 pinctrl 状态（如电源管理）
- 可以使用 `pinctrl_pm_select_*_state()` API

---

### Q2: 如果没有配置 pinctrl 会怎样？

**A:** 设备可能无法正常工作。

**可能的问题：**
1. GPIO 可能处于错误的复用功能（如 UART）
2. 可能有不期望的上下拉电阻
3. 驱动强度可能不合适
4. 电平可能不稳定

**最佳实践：**
- 始终配置 pinctrl
- 确保 GPIO 处于正确的状态

---

### Q3: pinctrl-names 必须是 "default" 吗？

**A:** 不是必须，但强烈推荐。

**标准状态名称：**
- `"default"` - 默认状态（推荐使用）
- `"init"` - 初始化状态（可选）
- `"sleep"` - 休眠状态（电源管理）
- `"idle"` - 空闲状态（电源管理）

**如果使用 "default"：**
- ✅ 自动应用，无需驱动干预
- ✅ 符合 Linux 内核规范

**如果使用自定义名称：**
- ⚠️ 需要驱动手动切换
- ⚠️ 不推荐

---

### Q4: pinctrl 应用失败会怎样？

**A:** 驱动 probe 会失败。

**错误处理流程：**
```c
ret = pinctrl_bind_pins(dev);
if (ret)
    goto pinctrl_bind_failed;  // probe 失败

// 如果 pinctrl 应用失败，不会调用驱动的 probe
```

**常见失败原因：**
1. pinctrl 节点配置错误
2. GPIO 资源冲突
3. pinctrl 驱动未加载

---

### Q5: 可以在运行时修改 pinctrl 配置吗？

**A:** 可以切换状态，但不能修改配置。

**支持的操作：**
- ✅ 切换到不同的预定义状态（如 default → sleep）
- ❌ 动态修改 pinctrl 配置（需要重新加载设备树）

**示例：**
```c
// 切换到 sleep 状态
pinctrl_pm_select_sleep_state(dev);

// 切换回 default 状态
pinctrl_pm_select_default_state(dev);
```

---

## 7. 实际验证

### 7.1 查看内核日志

```bash
# 启用 pinctrl 调试信息
echo 8 > /proc/sys/kernel/printk

# 查看 pinctrl 应用日志
dmesg | grep -i pinctrl

# 应该看到类似输出：
# pinctrl core: registered pin 42 (GPIO0_PB2) on rockchip-pinctrl
# pwrseq_simple pwrseq_simple: no pinctrl handle  # 或者
# pwrseq_simple pwrseq_simple: no default pinctrl state  # 如果没有配置
```

### 7.2 查看 sysfs

```bash
# 查看设备的 pinctrl 状态
cat /sys/devices/platform/sdio-pwrseq/pinctrl/state

# 查看 GPIO 配置
cat /sys/kernel/debug/pinctrl/pinctrl-rockchip/pins | grep "pin 42"
# pin 42 (GPIO0_PB2) rockchip-pinctrl function: gpio, group: gpio0-b2
```

### 7.3 验证 GPIO 配置

```bash
# 导出 GPIO（如果可以）
echo 42 > /sys/class/gpio/export

# 查看 GPIO 方向
cat /sys/class/gpio/gpio42/direction
# 应该输出: out

# 查看 GPIO 值
cat /sys/class/gpio/gpio42/value
```

---

## 8. 总结

### 核心要点

1. ✅ **pinctrl 由设备驱动核心自动应用**
   - 在驱动 probe 之前
   - 由 `really_probe()` → `pinctrl_bind_pins()` 调用

2. ✅ **驱动无需处理 pinctrl**
   - 不需要 pinctrl 相关代码
   - 只需要处理设备逻辑功能

3. ✅ **应用时机明确**
   - T1: 设备与驱动匹配
   - T2: pinctrl 自动应用 ← **在这里**
   - T3: 驱动 probe 执行

4. ✅ **配置分层清晰**
   - pinctrl: 硬件属性（自动）
   - reset-gpios: 逻辑功能（驱动）

### 最终答案

**pinctrl 配置不是在探测到 `mmc-pwrseq-simple` 时自动应用的，而是在设备驱动核心调用驱动 probe 之前，由 `pinctrl_bind_pins()` 函数自动应用的。**

**流程：**
```
设备匹配驱动
    ↓
really_probe() 被调用
    ↓
pinctrl_bind_pins() 自动应用 pinctrl  ← 在这里！
    ↓
mmc_pwrseq_simple_probe() 被调用
    ↓
设备初始化完成
```

**驱动开发者无需关心 pinctrl，只需要在设备树中正确配置即可。**

---

## 9. 参考代码位置

```
设备驱动核心：
drivers/base/dd.c (really_probe 函数)

pinctrl 核心：
drivers/base/pinctrl.c (pinctrl_bind_pins 函数)

pinctrl 子系统：
drivers/pinctrl/pinctrl-rockchip.c

mmc-pwrseq-simple 驱动：
drivers/mmc/core/pwrseq_simple.c

设备树：
arch/arm64/boot/dts/rockchip/rk3399-eaidk-610.dts
```

---

**文档创建时间：** 2026-02-28
**文档版本：** v1.0
**维护者：** Claude Code
