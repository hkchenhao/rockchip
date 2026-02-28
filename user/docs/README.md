# RK3399 EAIDK-610 文档中心

## 📚 文档目录

### WiFi 驱动相关

#### AP6255 brcmfmac 驱动
- **[AP6255 驱动完整加载流程](ap6255_driver_flow.md)** ⭐ 核心文档
  - 从设备树到驱动加载的完整流程
  - Pinctrl 子系统详解
  - Platform Device vs SDIO Device
  - Probe 延迟机制 (EPROBE_DEFER)
  - 包含 2900+ 行详细分析

- **[Platform Device 创建顺序详解](platform_device_creation_order.md)**
  - 三个设备的创建和初始化顺序
  - 设备树解析规则
  - SDIO 设备的特殊性
  - 完整时序图和验证方法

- **[AP6255 固件指南](AP6255_FIRMWARE_GUIDE.md)**
  - 固件获取和安装
  - 文件说明和验证

#### bcmdhd vs brcmfmac 对比
- **[驱动对比分析](bcmdhd_vs_brcmfmac_comparison.md)**
  - 功能特性对比
  - 适用场景推荐
  - 迁移指南

- **[性能对比测试](bcmdhd_vs_brcmfmac_performance.md)**
  - 实际测试数据
  - 性能优化建议
  - 综合评分

- **[设备树匹配机制](bcmdhd_device_tree_matching.md)**
  - SDIO 总线分析
  - 设备发现流程

#### 配置方式对比
- **[wireless-wlan vs mmc-pwrseq](wireless_wlan_vs_mmc_pwrseq.md)**
  - 两种配置方式对比
  - 工作流程分析
  - 使用建议

### Pinctrl 子系统

- **[Pinctrl 自动应用机制](pinctrl_auto_apply_mechanism.md)**
  - Pinctrl 工作原理
  - 自动应用流程
  - 三个应用阶段详解

- **[Pinctrl vs reset-gpios 分析](pinctrl_vs_reset_gpios_analysis.md)**
  - 两种方式的区别
  - 适用场景
  - 最佳实践

### 开发工具

#### CLion 内核代码索引
- **[快速开始指南](QUICK_START.md)** ⭐ 新手必读
  - CLion 配置步骤
  - 索引覆盖范围
  - 实用技巧

- **[全内核索引配置](full_kernel_indexing.md)**
  - 索引 24,819 个内核源文件
  - 性能优化建议
  - 故障排除

- **[CLion 详细配置](clion_setup.md)**
  - 详细配置步骤
  - 常见问题解决
  - 验证清单

- **[CMake 内核索引原理](cmake_kernel_indexing.md)**
  - CMake 配置原理
  - compile_commands.json 生成

### 更新日志

- **[文档修正说明](CORRECTIONS_SUMMARY.md)**
  - Platform Device vs SDIO Device 概念澄清
  - 设备创建顺序修正
  - 2026-02-28 第一次更新

- **[Probe 机制补充](UPDATE_20260228_2.md)**
  - Probe vs 上电区别
  - EPROBE_DEFER 延迟机制
  - 2026-02-28 第二次更新

## 🎯 快速导航

### 按使用场景

#### 我想理解 AP6255 驱动加载流程
1. 先看 [AP6255 驱动完整加载流程](ap6255_driver_flow.md)
2. 如有疑问查看 [Platform Device 创建顺序详解](platform_device_creation_order.md)
3. 深入理解 Pinctrl 查看 [Pinctrl 自动应用机制](pinctrl_auto_apply_mechanism.md)

#### 我想在 CLion 中浏览内核代码
1. 先看 [快速开始指南](QUICK_START.md)
2. 详细配置参考 [CLion 详细配置](clion_setup.md)
3. 了解原理查看 [CMake 内核索引原理](cmake_kernel_indexing.md)

#### 我想选择合适的 WiFi 驱动
1. 先看 [驱动对比分析](bcmdhd_vs_brcmfmac_comparison.md)
2. 关注性能查看 [性能对比测试](bcmdhd_vs_brcmfmac_performance.md)
3. 配置方式参考 [wireless-wlan vs mmc-pwrseq](wireless_wlan_vs_mmc_pwrseq.md)

#### 我遇到了配置问题
1. 检查 [AP6255 固件指南](AP6255_FIRMWARE_GUIDE.md)
2. 查看各文档的"故障排除"章节
3. 参考 [文档修正说明](CORRECTIONS_SUMMARY.md) 了解常见误解

### 按技术主题

#### 设备树和驱动
- [AP6255 驱动完整加载流程](ap6255_driver_flow.md)
- [Platform Device 创建顺序详解](platform_device_creation_order.md)
- [设备树匹配机制](bcmdhd_device_tree_matching.md)

#### Pinctrl 子系统
- [Pinctrl 自动应用机制](pinctrl_auto_apply_mechanism.md)
- [Pinctrl vs reset-gpios 分析](pinctrl_vs_reset_gpios_analysis.md)

#### 驱动选择
- [驱动对比分析](bcmdhd_vs_brcmfmac_comparison.md)
- [性能对比测试](bcmdhd_vs_brcmfmac_performance.md)
- [wireless-wlan vs mmc-pwrseq](wireless_wlan_vs_mmc_pwrseq.md)

#### 开发工具
- [快速开始指南](QUICK_START.md)
- [全内核索引配置](full_kernel_indexing.md)
- [CLion 详细配置](clion_setup.md)
- [CMake 内核索引原理](cmake_kernel_indexing.md)

## 📊 文档统计

| 类别 | 文档数 | 总大小 |
|------|--------|--------|
| WiFi 驱动 | 7 | ~160 KB |
| Pinctrl | 2 | ~30 KB |
| 开发工具 | 4 | ~30 KB |
| 更新日志 | 2 | ~15 KB |
| **总计** | **15** | **~235 KB** |

核心文档：
- `ap6255_driver_flow.md` - 102 KB (2900+ 行)
- `platform_device_creation_order.md` - 15 KB

## 📁 目录结构

```
rk3399/
├── user/                    # 用户目录
│   ├── docs/               # 文档目录 (当前位置)
│   │   ├── README.md       # 本文件 - 文档索引
│   │   ├── ap6255_driver_flow.md
│   │   ├── platform_device_creation_order.md
│   │   ├── QUICK_START.md
│   │   └── ... (其他文档)
│   ├── script/             # 用户脚本
│   └── build/              # 用户编译输出
│
├── kernel/                  # Linux 内核源码
├── uboot/                   # U-Boot 源码
├── loader/                  # RK3399 loader
├── build/                   # 编译输出
│   └── firmware/           # WiFi 固件文件
├── CMakeLists.txt          # CLion 索引配置
└── .gitignore              # Git 忽略配置
```

## 🔗 相关资源

### 外部链接

- Linux 内核文档: https://www.kernel.org/doc/html/latest/
- Rockchip 官方文档: http://opensource.rock-chips.com/
- brcmfmac 驱动源码: `kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/`
- Linux firmware: https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git

### 内核源码位置

```
brcmfmac 驱动：
  kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/

mmc-pwrseq：
  kernel/drivers/mmc/core/pwrseq_simple.c

设备树：
  kernel/arch/arm64/boot/dts/rockchip/rk3399-eaidk-610.dts
  kernel/arch/arm64/boot/dts/rockchip/rk3399.dtsi

Pinctrl：
  kernel/drivers/pinctrl/pinctrl-rockchip.c
```

## 📝 文档维护

### 文档版本

- 初始版本: 2026-02-27
- 最后更新: 2026-02-28
- 当前版本: v1.2

### 贡献者

- Claude Sonnet 4.6

### 文档规范

- 格式: Markdown
- 编码: UTF-8
- 行尾: LF (Unix)
- 缩进: 2 空格

### 更新记录

- 2026-02-28: 重命名文档目录为 `user/docs/`
- 2026-02-28: 移动文档目录从根目录 `docs/` 到 `user/` 下
- 2026-02-28: 移动文档目录从 `build/docs/` 到根目录 `docs/`
- 2026-02-28: 添加 Platform Device 创建顺序详解
- 2026-02-28: 补充 Probe 延迟机制说明
- 2026-02-27: 初始文档创建

## ⚠️ 重要说明

1. **CMakeLists.txt 配置仅用于 IDE 索引**
   - 不能用于实际编译内核
   - 实际编译使用内核的 Makefile 系统

2. **设备树修改需谨慎**
   - 修改前先备份
   - 理解每个属性的含义
   - 参考官方文档

3. **驱动选择建议**
   - 新项目优先使用 brcmfmac (主线驱动)
   - 性能要求高可考虑 bcmdhd
   - 参考对比文档做决策

## 🆘 获取帮助

### 常见问题

查看各文档的"常见问题"或"故障排除"章节。

### 报告问题

如发现文档错误或需要补充，请：
1. 检查是否已有相关说明
2. 查看更新日志了解最新修正
3. 提供详细的问题描述和环境信息

---

**文档位置**: `/root/projects/embedded/rockchip/rk3399/user/docs/`
**最后更新**: 2026-02-28
**维护者**: Claude Code
