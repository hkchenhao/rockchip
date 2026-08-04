# RK3399 MIPI DSI 驱动完整流程分析

## 1. 文档目的与适用范围

本文基于本仓库的 Linux 内核源码，梳理 RK3399 平台 MIPI DSI 显示输出从设备树描述、内核驱动匹配、DRM 组件绑定、VOP 路由、Synopsys DesignWare DSI 控制器初始化、DPHY 配置，到面板初始化及关断的完整执行路径。

本文关注的是 **RK3399 的传统 DW MIPI DSI 控制器驱动**，核心代码如下：

| 模块 | 源码位置 | 职责 |
| --- | --- | --- |
| Rockchip DRM 主驱动 | `kernel/drivers/gpu/drm/rockchip/rockchip_drm_drv.c` | 聚合 VOP、DSI、HDMI 等 component，创建 DRM 设备 |
| Rockchip DSI 平台适配层 | `kernel/drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c` | RK3399 时钟、GRF、VOP 路由、DPHY PLL 与时序 |
| 通用 DW DSI 层 | `kernel/drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c` | DSI host、bridge、视频/命令模式及寄存器配置 |
| VOP 驱动 | `kernel/drivers/gpu/drm/rockchip/rockchip_drm_vop.c` | 图层混合、像素数据输出至 MIPI0/MIPI1 接口 |
| 通用面板驱动 | `kernel/drivers/gpu/drm/panel/panel-simple.c` | `simple-panel-dsi` 面板时序、供电、背光与 MIPI attach |
| RK3399 SoC DTSI | `kernel/arch/arm64/boot/dts/rockchip/rk3399.dtsi` | DSI0/DSI1、VOP、时钟、复位及端点拓扑 |

> 本文不以某一产品板为前提，而是以仓库中已实际启用 DSI 的 `rk3399-evb-rev3-android-mipi-edp.dts` 为主例，说明 DTS 属性如何被 Linux 设备模型、MIPI DSI 框架和 DRM 框架逐层消费。EAIDK-610 的 `rk3399-eaidk-610.dts` 当前没有启用 DSI，仅作为“为什么没有 DSI probe 日志”的反例在文末说明。

---

## 2. 硬件与软件总体链路

RK3399 有两个显示处理器：VOP BIG（`vopb`）和 VOP LIT（`vopl`）；同时有两个 DesignWare MIPI DSI 控制器：DSI0 与 DSI1。单屏通常使用一个 DSI 控制器和最多 4 条数据 Lane；特定高分辨率屏幕可采用双 DSI 左右分屏模式。

```text
用户态（Weston / Android SurfaceFlinger / modetest）
                     │
                     ▼
Linux DRM/KMS Atomic Commit
                     │
                     ▼
Rockchip VOP（vopb 或 vopl）
  图层混合、缩放、色彩处理、产生 DPI 像素流
                     │
      GRF 选择 VOP 到 DSI 的输入路由
                     ▼
RK3399 DSI0 或 DSI1（Synopsys DW MIPI DSI Host）
  DPI 像素流 -> DSI 视频包；或处理命令模式 DCS/GEN 包
                     │
                     ▼
RK3399 DPHY
  Clock Lane + 1~4 Data Lanes，LP/HS 状态切换
                     │
                     ▼
MIPI DSI 面板 / 外接 DSI-to-LVDS、DSI-to-eDP Bridge
```

这里存在两条不同性质的数据通路：

1. **视频数据通路**：VOP 持续输出像素数据，DSI 将其封装成视频模式数据包后，经 PHY 以高速差分信号送给屏幕。
2. **控制命令通路**：面板驱动使用 MIPI DSI DCS 或 Generic 命令发送初始化序列、休眠唤醒、亮度和显示开关等命令；读屏幕 ID 或状态时还会走 DSI 读事务。

---

## 3. RK3399 的 DSI 资源与 DTS 拓扑

### 3.1 DSI0 / DSI1 节点

`rk3399.dtsi` 定义了两个控制器：

| 控制器 | DTS 标签 | 寄存器基址 | IRQ | 主要 VOP 输出接口 |
| --- | --- | ---: | ---: | --- |
| DSI0 | `dsi` / `mipi_dsi` | `0xff960000` | 45 | `VOP_OUTPUT_IF_MIPI0` |
| DSI1 | `dsi1` / `mipi_dsi1` | `0xff968000` | 46 | `VOP_OUTPUT_IF_MIPI1` |

两者都使用 compatible：

```text
compatible = "rockchip,rk3399-mipi-dsi", "snps,dw-mipi-dsi";
```

第一个字符串使平台设备匹配 Rockchip 扩展驱动；第二个表示底层控制器 IP 是 Synopsys DesignWare MIPI DSI。

DSI 节点默认均为：

```text
status = "disabled";
```

板级 DTS 必须显式改为 `okay`，否则 platform device 不会创建，驱动也不会 probe。

### 3.2 时钟、复位与电源域

以 DSI0 为例，设备树描述了以下资源：

| DTS 时钟名 | RK3399 时钟 | 作用 |
| --- | --- | --- |
| `ref` | `SCLK_DPHY_PLL` | DPHY PLL 参考时钟 |
| `pclk` | `PCLK_MIPI_DSI0` | DSI APB 寄存器访问时钟 |
| `phy_cfg` | `SCLK_DPHY_TX0_CFG` | PHY 配置时钟 |
| `grf` | `PCLK_VIO_GRF` | 访问显示相关 GRF 寄存器所需总线时钟 |

复位为 `SRST_P_MIPI_DSI0`，名字是 `apb`。DSI 与 VOP 同处在 `RK3399_PD_VIO` 视频 I/O 电源域，电源域关闭或未正确上电时，寄存器访问、时钟与 PHY 均无法正常工作。

### 3.3 VOP 到 DSI 的输入端点

DSI 的 `port@0` 是输入端，预定义了两个 endpoint：

```text
DSI0:
  dsi_in_vopb <-> vopb_out_dsi
  dsi_in_vopl <-> vopl_out_dsi

DSI1:
  dsi1_in_vopb <-> vopb_out_dsi1
  dsi1_in_vopl <-> vopl_out_dsi1
```

这意味着每个 DSI 控制器理论上可以选择 VOP BIG 或 VOP LIT 作为像素源。实际生效的 VOP 不仅由 endpoint 图决定，也由 Rockchip DSI 平台驱动在 enable 阶段写入 GRF 路由寄存器决定。

### 3.4 DSI1 与 ISP1 的资源冲突

`rk3399.dtsi` 中，`isp1` 的 `phys = <&mipi_dsi1>` 表明 DSI1 相关 DPHY 还可能被 ISP1 作为 MIPI CSI 接收 PHY 使用。`mipi_dphy_tx1rx1` 也描述了这个 TX1/RX1 复用 PHY。

因此，设计硬件或修改 DTS 时需要确认：

- DSI1 作为显示发送端时，不能同时让 ISP1 占用同一物理 DPHY；
- 相关节点的 `status`、`phys` 和电源域状态必须避免互相竞争；
- 若只使用 DSI0 显示，通常不需要启用 DSI1。

---

## 4. 编译配置与对象关系

### 4.1 必需 Kconfig

与 DSI 最直接相关的配置位于 `drivers/gpu/drm/rockchip/Kconfig`：

```text
CONFIG_DRM_ROCKCHIP=y
CONFIG_ROCKCHIP_DW_MIPI_DSI=y
CONFIG_DRM_PANEL_SIMPLE=y       # 使用 simple-panel-dsi 时需要
```

其中：

- `CONFIG_DRM_ROCKCHIP`：Rockchip DRM/KMS 主驱动；
- `CONFIG_ROCKCHIP_DW_MIPI_DSI`：构建 RK3399 特有的 DSI 平台扩展；
- `CONFIG_DRM_DW_MIPI_DSI`：由 Rockchip DRM 的 Kconfig 依赖自动选择，构建通用 Synopsys DW MIPI DSI 层；
- `CONFIG_DRM_PANEL_SIMPLE`：DTS 使用 `compatible = "simple-panel-dsi"` 时需要。

当前 `arch/arm64/configs/rockchip_linux_defconfig` 已启用上述相关配置，因此对 EAIDK-610 而言，当前阻止 DSI 驱动实例化的主要因素是 DTS 未启用，而不是内核缺少 DSI 驱动代码。

### 4.2 编译对象

`drivers/gpu/drm/rockchip/Makefile` 的配置关系：

```makefile
rockchipdrm-$(CONFIG_ROCKCHIP_DW_MIPI_DSI) += dw-mipi-dsi-rockchip.o
```

`drivers/gpu/drm/bridge/synopsys/Makefile` 中，通用层由 `CONFIG_DRM_DW_MIPI_DSI` 构建：

```makefile
obj-$(CONFIG_DRM_DW_MIPI_DSI) += dw-mipi-dsi.o
```

因此完整驱动并不是一个单独文件，而是 **Rockchip 平台层 + 通用 DW DSI 层 + DRM bridge/panel 框架** 的组合。

---

## 5. 推荐的单 DSI 面板 DTS 结构

下面是根据仓库中 `rk3399-evb-rev3-android-mipi-edp.dts` 归纳的结构示意。时序、GPIO、电源和面板初始化命令必须替换为实际屏幕规格，不能原样照搬。

```text
/* 1. 选择 VOPB 作为 DSI0 的像素来源 */
&dsi_in_vopb {
    status = "okay";
};

&dsi_in_vopl {
    status = "disabled";
};

/* 2. 启用 DSI0 并挂接 MIPI DSI 面板 */
&dsi {
    status = "okay";

    panel@0 {
        compatible = "simple-panel-dsi";
        reg = <0>;
        backlight = <&backlight>;
        enable-gpios = <&gpio1 13 GPIO_ACTIVE_HIGH>;

        dsi,lanes = <4>;
        dsi,format = <MIPI_DSI_FMT_RGB888>;
        dsi,flags = <(MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_VIDEO_BURST)>;

        display-timings {
            native-mode = <&timing0>;
            timing0: timing0 {
                clock-frequency = <160000000>;
                hactive = <1200>;
                vactive = <1920>;
                hback-porch = <21>;
                hfront-porch = <120>;
                hsync-len = <20>;
                vback-porch = <18>;
                vfront-porch = <21>;
                vsync-len = <3>;
            };
        };

        ports {
            port@0 {
                reg = <0>;
                panel_in_dsi: endpoint {
                    remote-endpoint = <&dsi_out_panel>;
                };
            };
        };
    };

    ports {
        port@1 {
            reg = <1>;
            dsi_out_panel: endpoint {
                remote-endpoint = <&panel_in_dsi>;
            };
        };
    };
};

/* 某些 BSP DTS 还以 route 节点明确描述 VOP 输出连接 */
&route_dsi {
    status = "okay";
    connect = <&vopb_out_dsi>;
};
```

### 5.1 关键属性说明

| 属性 | 作用 | 常见错误 |
| --- | --- | --- |
| `dsi,lanes` | 数据 Lane 数，通常 1/2/3/4 | 超过面板实际 Lane 数会导致无显示或链路不稳定 |
| `dsi,format` | 像素格式，如 RGB565/RGB666/RGB888 | 面板与 VOP 输出格式不一致会花屏或颜色错误 |
| `dsi,flags` | 视频/命令模式、burst、同步方式、连续时钟等 | 使用与面板时序要求不符的模式 |
| `display-timings` | 分辨率、像素时钟、前后肩、同步宽度及极性 | 抄错屏参是黑屏、抖动、偏移的常见原因 |
| `enable-gpios` | 面板使能脚 | 极性错误使面板持续处于 reset/disable |
| `backlight` | 背光控制器 phandle | DSI 正常但背光未开，表象为黑屏 |
| `panel-init-sequence` | BSP 常用的 DCS/GEN 初始化指令序列 | 不同屏幕不能共用；延时与包类型必须匹配规格书 |
| `route_dsi` | BSP 路由描述 | 若 BSP 依赖该节点而遗漏，VOP 输出可能未正确连接 |

对于需要专属寄存器初始化、ESD 检测、读 ID、休眠恢复或复杂背光控制的屏幕，不宜只依赖 `panel-simple`，应增加专用 `drm_panel` 驱动。

---

## 6. DTS 如何变成 DSI 与面板驱动实例（RK3399 EVB 实例）

本节以仓库中的 `rk3399-evb-rev3-android-mipi-edp.dts` 为准。虽然文件名中同时出现 `mipi-edp`，其中的 DSI 配置本身完整启用了一个 **1200×1920、4 Lane、RGB888、video burst 模式**的 `simple-panel-dsi` 面板，因此适合作为 MIPI DSI DTS 到驱动加载的例子。

### 6.1 DTS 中必须存在的三层节点

第一层是 SoC 公共 `rk3399.dtsi` 定义的 DSI0 控制器节点。它提供：

- `compatible = "rockchip,rk3399-mipi-dsi", "snps,dw-mipi-dsi"`；
- 寄存器地址、中断、`ref/pclk/phy_cfg/grf` 时钟、`apb` 复位及 GRF phandle；
- `port@0` 输入端及 `dsi_in_vopb`、`dsi_in_vopl` 两个 VOP endpoint；
- 默认 `status = "disabled"`。

第二层是板级 DTS 对公共节点的覆盖：

```text
&dsi_in_vopb { status = "okay"; };
&dsi_in_vopl { status = "disabled"; };

&dsi {
    status = "okay";
    // panel@0 与 port@1 定义在这里
};

&route_dsi {
    status = "okay";
    connect = <&vopb_out_dsi>;
};
```

这说明像素源选 VOP BIG，DSI0 设备启用，并将 DSI route 连接到 `vopb_out_dsi`。端点图与 route 信息共同约束 VOP→DSI 的逻辑路径；实际使能时 Rockchip DSI 驱动还会写 GRF 选择器。

第三层是 `&dsi` 内的 `panel@0` 子节点。它既是面板描述，也是 MIPI DSI child device 的来源：

```text
panel@0 {
    compatible = "simple-panel-dsi";
    reg = <0>;
    dsi,flags = <(MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_VIDEO_BURST)>;
    dsi,format = <MIPI_DSI_FMT_RGB888>;
    dsi,lanes = <4>;

    display-timings { /* 1200x1920, 160 MHz 等时序 */ };

    ports {
        port@0 {
            reg = <0>;
            panel_in_dsi: endpoint {
                remote-endpoint = <&dsi_out_panel>;
            };
        };
    };
};
```

注意 `reg = <0>` 的两个不同含义：在 `panel@0` 中，它是 MIPI DSI virtual channel（VC）；在 `port@0` 中，它是图端口编号。两者不要混淆。

### 6.2 为什么 `panel@0` 与 `&dsi` 都需要 `ports`

这是设备树 OF graph 的双向端点描述，并不是重复配置。DSI 控制器是一个同时具有上游像素输入和下游 MIPI 输出的节点；面板是下游设备，只具有来自 DSI 的输入端。因此，DSI 和 panel 必须分别定义属于自己的端口。

```text
VOP BIG / VOP LIT
        │
        ▼
DSI port@0（输入）
        │
        ▼
DSI port@1（输出） ───────> panel port@0（输入）
     dsi_out_panel          panel_in_dsi
```

`&dsi` 的端口职责如下：

| DSI 端口 | 方向 | 对端 | 作用 |
| --- | --- | --- | --- |
| `port@0` | 输入 | `vopb_out_dsi` 或 `vopl_out_dsi` | VOP 向 DSI 提供 DPI 像素流 |
| `port@1` | 输出 | panel 或 DSI-to-LVDS/eDP bridge | DSI 向下游显示设备输出 MIPI 数据 |

在 EVB 示例中，DSI 输出端的 endpoint 是：

```text
&dsi {
    ports {
        port@1 {
            reg = <1>;
            dsi_out_panel: endpoint {
                remote-endpoint = <&panel_in_dsi>;
            };
        };
    };
};
```

面板作为下游输入端，也必须定义自己的 endpoint：

```text
panel@0 {
    ports {
        port@0 {
            reg = <0>;
            panel_in_dsi: endpoint {
                remote-endpoint = <&dsi_out_panel>;
            };
        };
    };
};
```

两条 `remote-endpoint` 构成同一物理链路的双向引用：

```text
dsi_out_panel.remote-endpoint -> panel_in_dsi
panel_in_dsi.remote-endpoint -> dsi_out_panel
```

这种写法的意义：

1. **完整表达显示图**：每个节点只描述自己的端口，DSI 输出连到 panel 输入；
2. **驱动可按任意方向查询**：DW DSI host 使用 `drm_of_find_panel_or_bridge(dsi_node, 1, ...)` 从 DSI 的 `port@1` 查找下游 panel/bridge；其他驱动或调试代码可以从 panel 反查上游；
3. **支持下游 bridge 扩展**：未来变为 `DSI -> DSI-to-LVDS/eDP bridge -> panel` 时，仍是每个设备各自维护输入、输出端口；
4. **避免绑定不完整**：只配置单向关系可能让部分 OF graph / DRM 查询失败或出现 deferred probe。

特别注意：`panel@0` 中两个都写作 `<0>` 的 `reg` 含义不同：

| 位置 | 含义 | 驱动中的用途 |
| --- | --- | --- |
| `panel@0/reg = <0>` | MIPI DSI Virtual Channel 0 | `mipi_dsi_host_register()` 创建 channel 为 0 的 `mipi_dsi_device`；决定 DSI packet header 中的 VC |
| `panel@0/ports/port@0/reg = <0>` | OF graph 的面板输入端口编号 | 仅用于描述面板图端口，与 DSI 协议 Virtual Channel 无关 |

因此 `panel@0` 作为 DSI host 的直接子节点负责生成 MIPI DSI device，而其 `ports` 子节点则负责描述 DRM 显示链路图；它们服务于不同内核框架，缺一不可。

### 6.3 DSI 控制器的 compatible 如何触发平台驱动

内核启动时会展开 DTB，所有状态为 `okay` 的 SoC 节点被创建为 platform device。`&dsi` 覆盖后，`dsi@ff960000` 可用，它的首个 compatible `rockchip,rk3399-mipi-dsi` 与 `dw_mipi_dsi_rockchip_dt_ids[]` 匹配，进而调用：

```text
dw_mipi_dsi_rockchip_probe()
```

该 probe 从 **DSI 控制器节点本身**读取资源，而不是从 `panel@0` 读取：

| DTS 字段 | probe 中的消费方式 | 用途 |
| --- | --- | --- |
| `reg` | `platform_get_resource()`、`devm_ioremap_resource()` | 映射 DSI 寄存器 |
| 控制器物理地址 | 与 RK3399 chip-data 的 `.reg` 比较 | 区分 DSI0/DSI1、加载对应 GRF/PHY 参数 |
| `clocks` / `clock-names` | `devm_clk_get(dev, "pclk"/"ref"/...)` | 时钟资源 |
| `resets` / `reset-names` | 通用层获取 `apb` reset | DSI APB 复位 |
| `rockchip,grf` | `syscon_regmap_lookup_by_phandle()` | VOP 选择与 PHY 专用配置 |
| `port@0` | 后续 encoder 查询 active endpoint | VOP 输入关系 |

`dw_mipi_dsi_rockchip_probe()` 随后调用通用 `dw_mipi_dsi_probe()`；通用层注册 `mipi_dsi_host`。

### 6.4 `panel@0` 为什么会变成 MIPI DSI device

这是 DTS 到面板驱动加载中最容易忽略的一步。通用层在 `dw_mipi_dsi_probe()` 中调用：

```text
mipi_dsi_host_register(&dsi->dsi_host)
```

MIPI DSI 框架实现位于 `drivers/gpu/drm/drm_mipi_dsi.c`。`mipi_dsi_host_register()` 对 host 节点，即 DSI 的 `of_node`，调用 `for_each_available_child_of_node()` 遍历所有状态可用的直接子节点：

```text
DSI host：dsi@ff960000
└── child：panel@0
    └── reg = <0>
```

对于带 `reg` 的子节点，它调用 `of_mipi_dsi_device_add()`：

1. `of_modalias_node()` 从 `compatible = "simple-panel-dsi"` 生成 MIPI DSI 设备的 modalias/type；
2. 读取 `reg = <0>`，将其设为 `mipi_dsi_device.channel`；
3. 调用 `mipi_dsi_device_register_full()` 和 `device_add()`；
4. Linux driver core 随即按 OF compatible 匹配已注册的 MIPI DSI driver。

所以，`panel@0` **不是 platform device**；它是 DSI host 注册时动态创建的 `mipi_dsi_device`。将面板节点放在 DSI 节点下、并配置 `reg`，正是触发此创建流程的关键。

### 6.5 `compatible = "simple-panel-dsi"` 如何匹配面板驱动

`panel-simple.c` 注册 `panel_simple_dsi_driver`，其 `of_match_table` 是 `dsi_of_match[]`，表中包含：

```text
compatible = "simple-panel-dsi"
```

因此上一步新建的 DSI device 会进入：

```text
panel_simple_dsi_probe(struct mipi_dsi_device *dsi)
```

该函数的 DTS 消费关系如下：

| `panel@0` DTS 信息 | `panel_simple_dsi_probe()` / 相关函数的处理 |
| --- | --- |
| `compatible` | 用 `of_match_node()` 匹配 `dsi_of_match[]` |
| `dsi,flags` | `panel_simple_dsi_of_get_desc_data()` 读入 `desc->flags` |
| `dsi,format` | 读入 `desc->format` |
| `dsi,lanes` | 读入 `desc->lanes` |
| `display-timings` | `panel_simple_of_get_desc_data()` 解析为 DRM mode |
| `backlight`、`enable-gpios`、供电/延时相关属性 | `panel_simple_probe()` 解析，用于 prepare/enable 阶段 |
| `panel-init-sequence`（若配置） | panel simple 的命令序列处理逻辑在 prepare 时下发 |

probe 的最后三行具有决定性作用：

```text
dsi->mode_flags = desc->flags;
dsi->format = desc->format;
dsi->lanes = desc->lanes;
mipi_dsi_attach(dsi);
```

即 DTS 填写的 lanes、format 和 flags 并不会直接写入 DSI 硬件；它们先成为 `mipi_dsi_device` 属性，再由 `mipi_dsi_attach()` 交给 DSI host。

### 6.6 面板参数如何抵达 DW DSI host

`mipi_dsi_attach()` 回调通用 DW DSI host 的：

```text
dw_mipi_dsi_host_attach()
```

这个函数将参数拷贝到 `struct dw_mipi_dsi`：

```text
dsi->lanes      = device->lanes;
dsi->channel    = device->channel;
dsi->format     = device->format;
dsi->mode_flags = device->mode_flags;
```

同一函数还调用：

```text
drm_of_find_panel_or_bridge(dsi-node, 1, -1, &panel, &next_bridge)
```

它从 DSI 的 **输出端 `port@1`** 沿 `dsi_out_panel -> panel_in_dsi` 的 `remote-endpoint` 找到已经 probe 的 panel，并将 DSI bridge 放入 DRM bridge 链。

这解释了为什么本例同时需要两类 DTS 关系：

- `panel@0` 是 DSI host 的直接 child：负责生成 `mipi_dsi_device`，触发面板 MIPI driver probe 与 `mipi_dsi_attach()`；
- `port@1` 的 endpoint 图：供 DRM 使用 `drm_of_find_panel_or_bridge()` 找到下游 panel/bridge，建立显示 bridge chain。

只有第一种关系时，面板能 attach 但 DRM 未必能正确建立输出链；只有第二种关系时，DRM 能找到节点但不会自动把 child 创建为 MIPI DSI device。两者都应存在。

### 6.7 完整加载调用链

```text
DTB 展开
  -> dsi@ff960000 status = "okay"
  -> platform device 与 "rockchip,rk3399-mipi-dsi" 匹配
  -> dw_mipi_dsi_rockchip_probe()
  -> dw_mipi_dsi_probe()
  -> mipi_dsi_host_register()
       -> 遍历 dsi@ff960000 的可用 child
       -> 发现 panel@0（有 reg = <0>）
       -> of_mipi_dsi_device_add()
       -> 创建 mipi_dsi_device：channel 0，OF node 为 panel@0
       -> compatible "simple-panel-dsi" 匹配 panel_simple_dsi_driver
       -> panel_simple_dsi_probe()
            -> 读取 dsi,lanes / dsi,format / dsi,flags / timing 等
            -> mipi_dsi_attach()
                 -> dw_mipi_dsi_host_attach()
                 -> 保存面板链路参数，添加 DSI DRM bridge
  -> Rockchip DSI component_add()
  -> Rockchip DRM master component bind
       -> dw_mipi_dsi_rockchip_bind()
       -> drm_of_find_panel_or_bridge(port@1)
       -> 创建 encoder，绑定 DW DSI bridge
  -> 后续 atomic commit 使用已保存的 lanes/format/flags/mode
```

### 6.8 延迟 probe 是正常现象

DSI、panel、backlight、regulator、VOP 之间存在依赖。如果在 DSI probe 或 bind 时，下游 panel、backlight、regulator 或 DRM component 尚未准备好，内核可能返回 `-EPROBE_DEFER`，之后自动重试。

因此启动日志中出现一次或多次 deferred probe 不一定是故障；持续无法完成 probe 才需要检查：节点 `status`、`compatible`、`reg`、endpoint 双向链接、供电/GPIO phandle、Kconfig 以及最终烧录 DTB。

---

## 7. 驱动加载与 DRM 组件绑定

### 7.1 设备树匹配与平台 probe

当 `&dsi` 的状态为 `okay` 后，platform bus 使用 `rockchip,rk3399-mipi-dsi` 匹配 `dw_mipi_dsi_rockchip_driver`。入口函数为：

```text
kernel/drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c
  dw_mipi_dsi_rockchip_probe()
```

该函数的主要工作：

1. 分配 `struct dw_mipi_dsi_rockchip`；
2. 映射 DSI MMIO 寄存器；
3. 根据资源物理地址识别 DSI0 或 DSI1，绑定 RK3399 chip data；
4. 获取 `pclk`、`ref`、`phy_cfg`、`grf` 时钟；
5. 通过 `rockchip,grf` 获取 regmap；
6. 创建/注册 RK3399 所需 DPHY provider；
7. 调用 `dw_mipi_dsi_probe()` 初始化通用 DW DSI 实例；
8. 通过 component 框架登记为 Rockchip DRM 的子组件。

RK3399 chip data 中明确给出单控制器最多 4 条数据 Lane、每 Lane 最大 1.5 Gbps。实际可用速率还取决于屏幕、PCB 信号质量、时钟设置和 BSP PHY 参数。

### 7.2 通用 DW DSI 初始化

通用层的 probe 在：

```text
kernel/drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c
  __dw_mipi_dsi_probe() / dw_mipi_dsi_probe()
```

通用层完成：

- 记录平台层传入的 MMIO 基址和 PHY 回调；
- 获取 `apb` reset 和 `pclk`；
- 初始化 `drm_bridge`；
- 注册 `mipi_dsi_host`，以便面板或 bridge 驱动调用 `mipi_dsi_attach()`；
- 打开 runtime PM 管理。

### 7.3 component bind

Rockchip DRM 主驱动完成组件匹配后，调用：

```text
kernel/drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c
  dw_mipi_dsi_rockchip_bind()
```

关键步骤如下：

1. 检测是否配置 `rockchip,dual-channel`；若配置则查找 DSI1 并建立 master/slave 关系；
2. slave DSI 不独立创建 DRM encoder；master 负责链路控制；
3. 用 `drm_of_find_panel_or_bridge(dsi-node, 1, -1, ...)` 从 DSI 的 `port@1` 查找下游 panel 或 bridge；
4. 使能 DPHY `ref` 时钟；
5. 创建 `DRM_MODE_ENCODER_DSI` encoder；
6. 调用 `dw_mipi_dsi_bind()`，把 DSI bridge 接入 encoder 的 bridge 链；
7. 注册 connector 相关的 Rockchip 子设备能力。

### 7.4 面板 mipi_dsi_attach

`panel-simple.c` 中的 `panel_simple_dsi_driver` 会匹配 `simple-panel-dsi`。其 probe 从 DTS 读取 `dsi,lanes`、`dsi,format` 和 `dsi,flags`，并调用 `mipi_dsi_attach()`。

Host 对应回调是：

```text
kernel/drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c
  dw_mipi_dsi_host_attach()
```

该回调把面板要求保存到 DW DSI 实例：

```text
lanes、channel、format、mode_flags
```

然后再次解析 DSI `port@1` 的下游节点，并把 DSI bridge 加入 DRM bridge 链。至此，DRM 已具备 `CRTC -> encoder -> DSI bridge -> panel` 的逻辑链路。

---

## 8. Atomic Modeset 与 VOP 路由

### 8.1 Atomic check：将面板参数传给 VOP

在一次 DRM atomic commit 中，DSI encoder 的：

```text
 dw_mipi_dsi_encoder_atomic_check()
```

会把 DSI 端参数写入 `rockchip_crtc_state`：

- RGB888 / RGB666 / RGB565 分别映射到 VOP 的 `ROCKCHIP_OUT_MODE_P888/P666/P565`；
- 设置 `output_type = DRM_MODE_CONNECTOR_DSI`；
- DSI0 使用 `VOP_OUTPUT_IF_MIPI0`，DSI1 使用 `VOP_OUTPUT_IF_MIPI1`；
- 命令模式会附加 `ROCKCHIP_OUTPUT_MIPI_DS_MODE`；
- 双通道模式会设置 `ROCKCHIP_OUTPUT_DUAL_CHANNEL_LEFT_RIGHT_MODE`；
- RK3399 的 DSI1/双通道场景可能需设置 `ROCKCHIP_OUTPUT_DATA_SWAP`。

VOP 驱动随后依据这些状态配置其接口、像素打包方式及输出时序。

### 8.2 GRF 路由：选择 VOP BIG 或 VOP LIT

encoder enable 阶段调用：

```text
 dw_mipi_dsi_encoder_enable()
   -> dw_mipi_dsi_rockchip_vop_routing()
```

`dw_mipi_dsi_rockchip_vop_routing()` 使用 `drm_of_encoder_active_endpoint_id()` 获取当前激活的输入 endpoint：

- endpoint 0：选择 VOP BIG；
- endpoint 1：选择 VOP LIT。

然后向 RK3399 的 `GRF_SOC_CON20` 写入对应掩码值，选择 DSI 接收哪一路 VOP 的 DPI 像素流。即使 DTS 中建立了 endpoint 连接，若 VOP endpoint、route 节点或 GRF 选择不一致，也会出现 DSI 已初始化但无像素输出的问题。

---

## 9. DSI 启动时序：从预使能到屏幕亮起

下面按 DRM bridge 回调的实际顺序描述启动过程。

### 9.1 `mode_set`

`dw_mipi_dsi_bridge_mode_set()` 保存 DRM 计算得到的 `adjusted_mode`。后续 DSI 的 DPI 计时器、视频包配置、PHY 速率计算都使用该模式。

### 9.2 `atomic_pre_enable`

入口为：

```text
 dw_mipi_dsi_bridge_atomic_pre_enable()
   -> dw_mipi_dsi_pre_enable()
```

核心过程：

1. **APB 复位**：短暂 assert/deassert `apb` reset，保证 DSI 寄存器处于已知状态；
2. **计算每 Lane 速率**：调用 Rockchip 回调 `dw_mipi_dsi_get_lane_mbps()`；
3. **runtime PM 上电**：`pm_runtime_get_sync()` 使平台层恢复 `phy_cfg`、`pclk` 与 `grf` 等时钟；
4. **配置 DW DSI 控制器**：
   - `dw_mipi_dsi_init()`：控制器基础初始化；
   - `dw_mipi_dsi_dpi_config()`：配置 DPI 输入颜色格式、极性；
   - `dw_mipi_dsi_packet_handler_config()`：ECC/CRC/包处理；
   - `dw_mipi_dsi_video_mode_config()`：配置 burst、sync pulse/event 等视频模式；
   - `dw_mipi_dsi_video_packet_config()`：配置视频包大小；
   - `dw_mipi_dsi_command_mode_config()`：配置命令模式包类型；
   - `dw_mipi_dsi_line_timer_config()` 与 `dw_mipi_dsi_vertical_timing_config()`：把显示时序换算为 DSI 计时寄存器；
5. **配置 DW DPHY 接口寄存器**：初始化、时序配置和 Lane 数配置；
6. **调用 RK3399 PHY 回调**：`dw_mipi_dsi_phy_init()` 对 RK3399 专有 DPHY PLL、模拟参数、HS timing 等进行配置；
7. **PHY 上电**：`dw_mipi_dsi_phy_power_on()` 退出 shutdown/reset 等状态；
8. **使能 DPHY**：`dw_mipi_dsi_dphy_enable()`；
9. **等待两个帧周期**：等待 PHY 与时钟稳定；
10. **暂时切到命令模式**：让 panel prepare 可以安全发送初始化命令。

随后，`atomic_pre_enable` 调用 `drm_panel_prepare()`。面板驱动一般在此阶段按如下顺序执行：准备 regulator、拉高 enable GPIO、延时、通过 `mipi_dsi_dcs_write*()` 或 Generic Write 下发初始化指令。

### 9.3 `atomic_enable`

入口为：

```text
 dw_mipi_dsi_bridge_atomic_enable()
   -> dw_mipi_dsi_enable()
```

主要动作：

1. 配置 `DSI_LPCLK_CTRL`，请求高速时钟 Lane；若设置 `MIPI_DSI_CLOCK_NON_CONTINUOUS` 则允许非连续时钟；
2. 若带 `MIPI_DSI_MODE_VIDEO` 标志，调用 `dw_mipi_dsi_set_mode(..., MIPI_DSI_MODE_VIDEO)` 进入连续视频输出；
3. 若是命令模式，设置 eDPI 命令大小并维持命令模式；
4. 调用 `drm_panel_enable()`，面板通常在这里打开背光或解除显示关闭状态；
5. 打印最终 DSI 链路带宽日志：`final DSI-Link bandwidth: <Mbps> x <lanes> Mbps`。

### 9.4 启动时序图

```text
DRM atomic commit
  │
  ├─ VOP atomic_check：确认输出格式、接口和时序
  ├─ DSI encoder atomic_check：写入 MIPI0/MIPI1 输出信息
  ├─ DSI encoder enable：写 GRF，选择 VOP BIG/LIT
  │
  ├─ DSI bridge pre_enable
  │    ├─ APB reset
  │    ├─ runtime PM / 开 pclk、phy_cfg、grf
  │    ├─ 计算 lane Mbps
  │    ├─ 配置 DW DSI / DPI / video packet / timing
  │    ├─ 配置并上电 RK3399 DPHY
  │    ├─ 等待稳定，切命令模式
  │    └─ drm_panel_prepare()：供电、复位、初始化 DCS 命令
  │
  └─ DSI bridge enable
       ├─ 请求 HS clock lane
       ├─ 切换 video 或 command mode
       └─ drm_panel_enable()：打开显示/背光
```

---

## 10. Lane 速率与带宽评估

### 10.1 理论估算

对 RGB888、无 DSC 压缩的视频模式，可以用以下公式估算原始像素数据带宽：

```text
raw_bitrate = pixel_clock_hz × bits_per_pixel
lane_bitrate ≈ raw_bitrate / lane_count × protocol_margin
```

其中 RGB888 的 `bits_per_pixel = 24`。`protocol_margin` 用于覆盖 DSI 包头、blanking、burst/non-burst 模式及实现余量；实际取值需以驱动计算和屏幕规格为准，不能只按理论下限设置。

示例：1200 × 1920、像素时钟 160 MHz、RGB888、4 Lane：

```text
raw_bitrate = 160,000,000 × 24 = 3.84 Gbps
ideal_per_lane = 3.84 / 4 = 0.96 Gbps per lane
```

再考虑协议与时序余量，4 Lane 方案通常仍可落在 RK3399 每 Lane 1.5 Gbps 的硬件上限内，但是否可稳定工作取决于屏幕要求与实际板级信号质量。

### 10.2 驱动中的实际计算

实际计算入口在：

```text
kernel/drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c
  dw_mipi_dsi_get_lane_mbps()
```

通用层在 pre-enable 前调用这个回调，并把结果保存到 `dsi->lane_mbps`。PHY 初始化随后据此选择 PLL 分频、VCO 范围和 DPHY timing 参数。

需要注意：

- 不能只依靠屏幕 datasheet 的最小速率；DSI 传输模式与 blanking 设置会改变所需带宽；
- 若驱动报 `MODE_CLOCK_HIGH` 或链路带宽超过平台上限，应降低刷新率/像素时钟、增加 Lane 数、启用 DSC（硬件及面板支持时）或采用双 DSI；
- 速率在临界值附近时，优先核对 panel 规格和时序，而不是盲目修改 PHY 表项。

---

## 11. MIPI DSI 命令发送流程

面板初始化命令通常由面板驱动通过 `mipi_dsi_dcs_write*()`、`mipi_dsi_generic_write()` 等接口触发，最终进入：

```text
 dw_mipi_dsi_host_transfer()
```

执行流程为：

1. `mipi_dsi_create_packet()` 按消息类型生成 DSI 包头和 payload；
2. `dw_mipi_message_config()` 根据 `MIPI_DSI_MSG_USE_LPM`、ACK 请求等配置 LP/HS 命令传输；
3. `dw_mipi_dsi_write()` 将 payload 按 32 bit 写入 `DSI_GEN_PLD_DATA` FIFO；
4. 写 `DSI_GEN_HDR` 提交包头；
5. 轮询 `DSI_CMD_PKT_STATUS`，等待 FIFO 可写和写入完成；
6. 对读请求，`dw_mipi_dsi_read()` 从 read FIFO 取回响应数据；
7. 双 DSI 模式下，写命令会同步下发给 master 与 slave。

常见的报错位置及含义：

| 日志 | 一般含义 |
| --- | --- |
| `failed to get available command FIFO` | 命令 FIFO 长时间满，控制器未正常处理命令 |
| `failed to write command FIFO` | 包头或 payload 提交后 FIFO 未清空 |
| `Timeout during read operation` | BTA 读响应未到达，可能屏幕不支持、Lane/LP 配置错误或物理链路异常 |
| `Read payload FIFO is empty` | 主机期望读响应，但没有收到有效 payload |

---

### 11.1 命令在哪个阶段发送

对于本仓库的 `panel-simple` 实现，面板命令序列来自 DTS 的 `panel-init-sequence` 与 `panel-exit-sequence`。在 panel probe 阶段，`panel_simple_parse_cmd_seq()` 将字节数组解析为多个 `panel_cmd_desc`；每条描述包含 data type、发送后等待时间 `delay`、payload 长度和 payload。

真正发送初始化命令不是在 panel probe，而是在一次 DRM enable 的 `drm_panel_prepare()` 阶段：

```text
dw_mipi_dsi_bridge_atomic_pre_enable()
  -> dw_mipi_dsi_pre_enable()
       -> 初始化 DW DSI 与 DPHY
       -> dw_mipi_dsi_set_mode(dsi, 0)  // 先切到 command mode
  -> drm_panel_prepare()
       -> panel_simple_prepare()
            -> 打开 regulator
            -> 拉起 enable GPIO
            -> reset GPIO 时序与等待
            -> panel_simple_xfer_dsi_cmd_seq(init_seq)
```

这是先让 DSI/PHY 可用、再执行面板上电/复位、最后发送厂商初始化命令的原因。若在 PHY 未上电或屏幕尚在复位状态时写 DCS 命令，常见结果是 FIFO 超时或屏幕对命令无响应。

`panel_simple_prepare()` 还会在 `panel-exit-sequence` 的反向场景中，由 `panel_simple_unprepare()` 调用 `panel_simple_xfer_dsi_cmd_seq(exit_seq)`。如果面板需要标准的 Display Off、Sleep In、等待时间等关机序列，应放入退出序列或由专用 panel 驱动实现。

### 11.2 DTS 初始化序列的解析与逐条派发

`panel_simple_xfer_dsi_cmd_seq()` 循环处理每个 `panel_cmd_desc`，依据 `header.data_type` 选择不同 MIPI API：

| DTS 序列 data type | 发送 API | 典型用途 |
| --- | --- | --- |
| `MIPI_DSI_GENERIC_SHORT_WRITE_0/1/2_PARAM` | `mipi_dsi_generic_write()` | 厂商 Generic 短写 |
| `MIPI_DSI_GENERIC_LONG_WRITE` | `mipi_dsi_generic_write()` | 厂商寄存器页、Gamma、长参数表 |
| `MIPI_DSI_DCS_SHORT_WRITE` | `mipi_dsi_dcs_write_buffer()` | 仅一个 DCS 命令字节，如 Display On |
| `MIPI_DSI_DCS_SHORT_WRITE_PARAM` | `mipi_dsi_dcs_write_buffer()` | 一个 DCS 命令 + 一个参数 |
| `MIPI_DSI_DCS_LONG_WRITE` | `mipi_dsi_dcs_write_buffer()` | DCS 命令 + 多字节参数 |
| `MIPI_DSI_COMPRESSION_MODE` | `mipi_dsi_compression_mode()` | 使能/关闭 DSC 压缩模式 |
| `MIPI_DSI_PICTURE_PARAMETER_SET` | `mipi_dsi_picture_parameter_set()` | 发送 DSC PPS |

每条命令执行完成后，驱动按照 header 中的 `delay` 调用 `panel_simple_msleep()`。这个延时是**上一条命令发送完成后到下一条命令前**的间隔，常用于 Reset 后等待、Sleep Out 后等待面板内部时钟稳定、Display On 前后的时序要求。

当前 `panel_simple_xfer_dsi_cmd_seq()` 对单条命令失败只打印 `failed to write dcs cmd`，随后仍会继续处理后续序列，并在末尾返回 0。因此调试初始化失败时不能只看最终 `prepare()` 返回值，还要逐条查看内核日志；对关键命令有严格失败处理要求的产品，建议使用专用 panel 驱动并在出错后终止初始化。

### 11.3 Generic 与 DCS：API 如何选择 data type

面板驱动调用的 Generic/DCS API 会创建 `struct mipi_dsi_msg`，并根据 payload 长度自动选择协议 data type。

| API | payload 长度 | 最终 type |
| --- | ---: | --- |
| `mipi_dsi_generic_write()` | 0 | `MIPI_DSI_GENERIC_SHORT_WRITE_0_PARAM` |
| `mipi_dsi_generic_write()` | 1 | `MIPI_DSI_GENERIC_SHORT_WRITE_1_PARAM` |
| `mipi_dsi_generic_write()` | 2 | `MIPI_DSI_GENERIC_SHORT_WRITE_2_PARAM` |
| `mipi_dsi_generic_write()` | 大于 2 | `MIPI_DSI_GENERIC_LONG_WRITE` |
| `mipi_dsi_dcs_write_buffer()` | 1 | `MIPI_DSI_DCS_SHORT_WRITE` |
| `mipi_dsi_dcs_write_buffer()` | 2 | `MIPI_DSI_DCS_SHORT_WRITE_PARAM` |
| `mipi_dsi_dcs_write_buffer()` | 大于 2 | `MIPI_DSI_DCS_LONG_WRITE` |

DCS payload 的第一个字节是 DCS command，例如常见的 `0x11`（Sleep Out）、`0x29`（Display On）、`0x28`（Display Off）、`0x10`（Sleep In）；后续字节才是该命令参数。Generic packet 没有这层标准 DCS 语义，通常用于厂商私有命令。具体命令集和顺序必须以屏幕 IC 规格书为准。

### 11.4 从 `mipi_dsi_msg` 到协议包头

Generic/DCS API 最终通过 `mipi_dsi_device_transfer()` 调到 host 的 `dw_mipi_dsi_host_transfer()`。该函数先调用 `mipi_dsi_create_packet()`：

```text
mipi_dsi_dcs_write_buffer() / mipi_dsi_generic_write()
  -> mipi_dsi_device_transfer()
  -> dw_mipi_dsi_host_transfer()
  -> mipi_dsi_create_packet()
```

`mipi_dsi_create_packet()` 生成 4 字节 packet header：

```text
header[0] = (virtual_channel << 6) | data_type
header[1..2] = short packet 的最多两个参数
             或 long packet 的 Word Count（payload 字节数，小端）
header[3] = ECC 相关字节；本控制器硬件负责相关处理
```

- virtual channel 来自 `panel@0 { reg = <0>; }`，合法范围是 0 到 3；
- short packet 不带独立 payload，参数直接编码在 header 的第 1、2 字节；
- long packet 的 header[1..2] 是 Word Count，实际 payload 随后通过 payload FIFO 发送；
- 数据包在线路上的 CRC、ECC 等由 DSI 控制器协议硬件处理，不应由 panel DTS 直接填写。

例如 DCS `Sleep Out` 只有一个字节 `0x11`，属于 short write；而 `0xB0, 0x04, 0x12, ...` 之类的厂商配置命令一般是 long write。

### 11.5 LP/HS 命令模式选择

`dw_mipi_dsi_host_transfer()` 首先调用 `dw_mipi_message_config()`。该函数检查 `mipi_dsi_msg.flags` 中的 `MIPI_DSI_MSG_USE_LPM`：

- 设置该 flag：配置 `DSI_CMD_MODE_CFG` 的 `CMD_MODE_ALL_LP`，设置视频模式寄存器的 `ENABLE_LOW_POWER_CMD`，并清除 `DSI_LPCLK_CTRL` 的 `PHY_TXREQUESTCLKHS`，命令经 LP（Low-Power）状态传输；
- 未设置：清除上述 LP 配置并请求 `PHY_TXREQUESTCLKHS`，命令经 HS（High-Speed）状态传输；
- 设置 `MIPI_DSI_MSG_REQ_ACK` 时，置 `ACK_RQST_EN`，要求外设返回 ACK。

在本实现中，`panel_simple_xfer_dsi_cmd_seq()` 调用 Generic/DCS 写 API 时没有额外设置 `MIPI_DSI_MSG_USE_LPM`，因此命令采用该 host 的默认非 LP 路径。若某个屏幕明确要求初始化命令走 LP，`panel-simple` 的现有序列接口不足以表达这一 per-command flag；应在专用 panel 驱动中构造 `mipi_dsi_msg`，或确认 BSP 是否提供了相应扩展。

不要将“DSI 控制器暂时处于 command mode”与“某条命令走 LP/HS 物理状态”混为一谈：前者由 `DSI_MODE_CFG` 选择视频/命令的工作模型，后者由消息 flags 和 `DSI_LPCLK_CTRL` 决定命令在线路上的低功耗或高速传输状态。

### 11.6 DW 控制器 FIFO 写入顺序

DW host 的 `dw_mipi_dsi_host_transfer()` 按如下顺序操作：

```text
1. mipi_dsi_create_packet()：形成 header 与 payload 指针
2. dw_mipi_message_config()：选择 LP/HS、ACK 等传输属性
3. dw_mipi_dsi_write()：写入一个控制器
   a. long packet：按 4 字节分组写 DSI_GEN_PLD_DATA
   b. 轮询 DSI_CMD_PKT_STATUS，确认 GEN_PLD_W_FULL 未置位
   c. 将 4 字节 header 写入 DSI_GEN_HDR，提交该 packet
   d. 轮询到 GEN_CMD_EMPTY 与 GEN_PLD_W_EMPTY 同时置位
4. 若为双 DSI：对 slave 重复第 2、3 步
5. 若有 rx_buf/rx_len：进入 dw_mipi_dsi_read()；否则返回 packet.size
```

核心寄存器如下：

| 寄存器 | 地址偏移 | 作用 |
| --- | ---: | --- |
| `DSI_GEN_HDR` | `0x6c` | Generic/DCS 包头写入口；写入即提交一条命令 |
| `DSI_GEN_PLD_DATA` | `0x70` | 长包 payload FIFO；按 32 bit 写入，最后不足 4 字节补零 |
| `DSI_CMD_PKT_STATUS` | `0x74` | 命令、读写 payload FIFO 状态 |

关键状态位：

| 状态位 | 含义 | 超时日志 |
| --- | --- | --- |
| `GEN_PLD_W_FULL` | 写 payload FIFO 已满 | `failed to get available write payload FIFO` |
| `GEN_CMD_FULL` | command FIFO 已满 | `failed to get available command FIFO` |
| `GEN_CMD_EMPTY` | command FIFO 已清空 | 与 `GEN_PLD_W_EMPTY` 一起用于确认提交结束 |
| `GEN_PLD_W_EMPTY` | 写 payload FIFO 已清空 | 与 `GEN_CMD_EMPTY` 一起用于确认提交结束 |
| `GEN_RD_CMD_BUSY` | 正在等待读响应 | `Timeout during read operation` |
| `GEN_PLD_R_EMPTY` | 读 payload FIFO 为空 | `Read payload FIFO is empty` |

驱动使用 `readl_poll_timeout()` 轮询，间隔约 1 ms，命令 FIFO 相关总超时为 `CMD_PKT_STATUS_TIMEOUT_US = 20000`（20 ms）。这表示超时往往不是“命令内容无效”本身，而是控制器无法推进 FIFO 状态：例如 DSI 未上电、未退出 reset、时钟/PHY 未正常工作、LP/HS 状态不匹配或链路被异常占用。

### 11.7 读命令与 BTA 响应

读操作（例如 Generic Read 或 DCS Read）会同时设置 `msg.rx_buf` 与 `msg.rx_len`。host 先像写命令一样提交 read request，再执行：

```text
dw_mipi_dsi_read()
  -> 等待 GEN_RD_CMD_BUSY 清零
  -> 每次从 DSI_GEN_PLD_DATA 读 32 bit
  -> 将低到高的 4 个字节依次复制至 rx_buf
  -> 重复直到取得 rx_len 字节
```

读取要求从 host 到 panel 的方向切换为 panel 返回 host 的方向（BTA，Bus Turn-Around）。因此读失败通常比写失败更依赖物理连接和时序：Data Lane 是否支持返回、面板是否已完成上电/初始化、是否要求 LP read、read request 的 type/参数是否符合面板规格，都会影响结果。

### 11.8 video mode 运行中的命令

对于 video mode 屏幕，正常显示后控制器运行在 `MIPI_DSI_MODE_VIDEO`。此时仍可能发送亮度、AOD、TE、ESD 状态读取等命令。`dw_mipi_message_config()` 会临时调整 `DSI_VID_MODE_CFG` 的 `ENABLE_LOW_POWER_CMD` 以及 `DSI_LPCLK_CTRL` 的 HS 请求，从而让命令能够在视频链路条件下传输。

不过，不同 panel IC 对 video blanking 区发送命令、LP command、HS command、是否允许 BTA read 的约束不同。频繁在显示过程中直接读写寄存器可能造成闪屏或视频 underflow。量产实现应遵循屏幕规格，并在 panel 专用驱动中串行化命令、处理失败重试和显示状态。

### 11.9 命令发送调试建议

1. **先确认时机**：命令必须发生在 `drm_panel_prepare()` 之后、面板电源和 reset 时序满足规格后；不要只在 probe 内发送初始化命令。
2. **区分 DCS 和 Generic**：先按屏幕 IC 文档确认每条命令的 data type；把 DCS 厂商命令误发为 Generic 可能无响应。
3. **保留每条延时**：不要随意删去 `Sleep Out`、page switch、reset 后的等待；这些延时是屏幕内部模拟电路/寄存器生效时间，不是 CPU 延迟。
4. **观察 FIFO 日志**：FIFO full/empty 超时优先排查时钟、PHY、reset、LP/HS 配置和物理连线；若 FIFO 正常但显示异常，再核查命令内容和时序。
5. **使用示波器或协议分析仪**：确认 Clock Lane、Data Lane 是否有 LP11、LP01/LP00 及 HS burst，验证实际包序列是否符合规格书。
6. **读 ID 时单独验证**：先在初始化完成后以最小读请求验证 BTA；不要把读失败简单归因于面板损坏。
7. **双 DSI 场景**：当前 host 会将写包依次写入 master/slave；确认两个 half-panel 对命令是否都需要接收，以及左右链路的 reset、电源和 Lane 状态一致。

---

## 12. 双 DSI 模式

RK3399 支持 DSI0 + DSI1 组合输出。主 DSI 节点使用：

```text
rockchip,dual-channel;
```

可选：

```text
rockchip,data-swap;
```

平台层在 `dw_mipi_dsi_rockchip_find_second()` 发现双通道属性后查找 ID 为 1 的 DSI，并在 bind 期间调用 `dw_mipi_dsi_set_slave()` 建立通用层 master/slave 关系。

双 DSI 下的关键行为：

- 主控制器创建 encoder 和 connector，slave 不单独对外建立显示管线；
- VOP atomic state 同时打开 MIPI0 与 MIPI1 输出接口；
- 标记 `ROCKCHIP_OUTPUT_DUAL_CHANNEL_LEFT_RIGHT_MODE`，VOP 按左右半屏分发像素；
- 两个控制器都需要配置 PHY、时序和 VOP 路由；
- 控制命令写入通常同时发送到两端；
- Lane 数、左右数据顺序和 panel 具体 dual-link 接线必须与屏幕规格严格一致。

双 DSI 的调试复杂度明显更高。首次点屏应优先完成单 DSI 验证，再迁移到双链路。

---

## 13. 关闭与运行时电源管理

DRM 关闭显示时的回调顺序与启动相反：

1. `dw_mipi_dsi_bridge_atomic_disable()`：先 `drm_panel_disable()`，关闭背光/显示，再将 stream 置 standby，最后关闭 DSI 数据通路；
2. `dw_mipi_dsi_bridge_post_atomic_disable()`：调用 `drm_panel_unprepare()`，进行面板休眠、复位和 regulator 下电；
3. 通用 DSI 层关闭 DPHY 并 `pm_runtime_put()`；
4. Rockchip runtime suspend 关闭 `grf`、`pclk`、`phy_cfg` 等时钟。

平台 runtime PM 回调位于 `dw-mipi-dsi-rockchip.c`，因此排查待机恢复黑屏时，应同时检查：面板 resume 初始化序列、DSI/PHY runtime resume、VOP 时钟恢复以及背光电源恢复。

---

## 14. EAIDK-610 当前状态（反例）与接入建议

### 14.1 当前状态

`kernel/arch/arm64/boot/dts/rockchip/rk3399-eaidk-610.dts`：

- 启用了 `vopb`、`vopl` 及其 MMU；
- 启用了 HDMI；
- 没有引用 `&dsi`、`&dsi1`、`&dsi_in_vopb`、`&dsi_in_vopl`；
- 没有 DSI 面板、DSI bridge、`route_dsi` 或 DSI 时序节点。

所以当前启动日志中看不到 DSI probe 或 DSI connector，是符合设计预期的。

### 14.2 建议的接入步骤

1. 获取面板完整规格：分辨率、刷新率、像素时钟、Lane 数、格式、video/command mode、clock lane 连续性、初始化/休眠命令、供电时序；
2. 原理图确认 DSI 使用 DSI0 还是 DSI1、实际 Lane 数、屏幕 reset/enable/backlight GPIO、I2C 背光/触控资源；
3. 先以单 DSI、RGB888、4 Lane、视频模式实现最小 DTS；
4. 正确设置 VOP 输入 endpoint 与 `route_dsi`，确保只有一路 VOP 路由到 DSI；
5. 选择 `simple-panel-dsi` 或编写专用 panel 驱动；
6. 配置内核并编译 DTB；
7. 使用串口日志、DRM debug 和示波器/逻辑分析仪逐层验证；
8. 稳定点亮后再完善 ESD、待机恢复、背光、旋转、色彩校准、DSC 或双通道功能。

---

## 15. 调试清单

### 15.1 DTS 与驱动加载

```bash
# 检查最终运行配置是否开启 DSI 驱动
zcat /proc/config.gz | grep -E 'DRM_ROCKCHIP|ROCKCHIP_DW_MIPI_DSI|DRM_PANEL_SIMPLE'

# 查看 DSI、面板、VOP 的启动日志
dmesg | grep -iE 'mipi|dsi|drm|panel|vop'

# 查看 DRM connector 和 mode
cat /sys/class/drm/card0-*/status
cat /sys/class/drm/card0-*/modes
```

若未启用 `CONFIG_IKCONFIG_PROC`，则没有 `/proc/config.gz`；此时应检查实际参与构建的 `.config` 或 defconfig。

### 15.2 常见现象定位

| 现象 | 优先排查项 |
| --- | --- |
| 完全没有 DSI probe 日志 | `&dsi` 是否为 `okay`；最终烧录 DTB 是否正确；Kconfig 是否启用 |
| 有 DSI probe，但没有 connector | `port@1` 与 panel endpoint 是否双向连接；panel 驱动是否匹配 |
| connector 存在但屏幕纯黑 | 背光、enable/reset GPIO、电源 regulator、panel init sequence、VOP route |
| 背光亮但无图像 | VOP/DSI GRF 路由、display timing、pixel clock、format、lane 数 |
| 图像抖动或偶发花屏 | lane Mbps、PHY timing、MIPI 时钟模式、PCB 信号完整性、供电噪声 |
| 图像颜色异常 | RGB565/666/888 配置、VOP output mode、面板 RGB/BGR 顺序 |
| 初始化命令超时 | 面板上电/复位延时、LP/HS 模式、DSI clock lane、DSI 物理连线 |
| 休眠恢复后黑屏 | panel prepare/enable 是否可重复执行、runtime PM、背光和 regulator 恢复 |

### 15.3 建议的内核日志参数

开发阶段可以在 bootargs 中增加：

```text
drm.debug=0x1ff loglevel=8
```

`drm.debug=0x1ff` 会输出大量 DRM/KMS 调试信息，仅建议调试阶段使用。量产时应移除或降低日志等级。

### 15.4 需要重点观察的日志

```text
final DSI-Link bandwidth: <lane_mbps> x <lanes> Mbps
```

该日志来自 DW DSI bridge enable 阶段，可直接确认驱动实际选择的速率和 Lane 数。还应关注：

- `failed to find panel or bridge`：DTS 图连接或驱动匹配问题；
- `Phy get_lane_mbps() failed`：带宽/模式不支持；
- `Phy init() failed`：RK3399 PHY PLL 或时序配置失败；
- DSI FIFO 超时：命令链路或面板状态问题；
- VOP underflow：VOP 带宽、时钟、内存或显示时序配置问题。

---

## 16. 关键函数索引

| 阶段 | 函数 | 文件 |
| --- | --- | --- |
| 平台 probe | `dw_mipi_dsi_rockchip_probe()` | `drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c` |
| DRM component bind | `dw_mipi_dsi_rockchip_bind()` | `drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c` |
| VOP 路由 | `dw_mipi_dsi_rockchip_vop_routing()` | `drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c` |
| encoder 状态检查 | `dw_mipi_dsi_encoder_atomic_check()` | `drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c` |
| RK3399 PHY 初始化 | `dw_mipi_dsi_phy_init()` | `drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c` |
| Lane Mbps 计算 | `dw_mipi_dsi_get_lane_mbps()` | `drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c` |
| 通用 host attach | `dw_mipi_dsi_host_attach()` | `drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c` |
| DSI 命令收发 | `dw_mipi_dsi_host_transfer()` | `drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c` |
| 保存显示模式 | `dw_mipi_dsi_bridge_mode_set()` | `drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c` |
| DSI/PHY 预初始化 | `dw_mipi_dsi_pre_enable()` | `drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c` |
| 进入 video/command 模式 | `dw_mipi_dsi_enable()` | `drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c` |
| bridge pre-enable | `dw_mipi_dsi_bridge_atomic_pre_enable()` | `drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c` |
| bridge enable | `dw_mipi_dsi_bridge_atomic_enable()` | `drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c` |
| simple DSI 面板匹配 | `panel_simple_dsi_driver` | `drivers/gpu/drm/panel/panel-simple.c` |

---

## 17. 结论

RK3399 MIPI DSI 的核心不是单一驱动，而是以下层级协作：

```text
DTS 图与资源描述
  -> Rockchip DRM component
  -> VOP 输出状态与 GRF 路由
  -> Rockchip DW DSI 平台/PHY 适配
  -> 通用 DW MIPI DSI host/bridge
  -> DRM panel 或下游 bridge
  -> 物理 MIPI DPHY 和面板
```

当前 EAIDK-610 的 DTS 未启用 DSI，故现有系统不会创建 DSI 显示链路。后续接入屏幕时，应优先保证 **面板硬件参数、DTS endpoint 图、VOP 路由和面板初始化时序** 四项一致；在此基础上，再通过 DRM atomic 和 DSI/PHY 日志分析带宽、时钟、命令传输和低功耗恢复问题。

