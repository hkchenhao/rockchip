# RK3399 EAIDK-610 WiFi 驱动文档

## 📚 核心文档

### **[AP6255_WIFI_COMPLETE_GUIDE.md](AP6255_WIFI_COMPLETE_GUIDE.md)** ⭐

**AP6255 WiFi 完整指南** - 唯一的完整参考文档

- **大小**: 210 KB
- **行数**: 7,483 行
- **版本**: v2.0
- **更新**: 2026-02-28

**包含全部内容：**

### 📑 文档结构

#### 第一部分：概述
1. 硬件连接和系统架构
2. 关键概念说明（Platform Device vs SDIO Device）

#### 第二部分：设备树配置详解
3. SDIO 控制器配置
4. 电源序列配置
5. WiFi 设备节点配置
6. Pinctrl 配置详解
7. 配置方式对比（wireless-wlan vs mmc-pwrseq）

#### 第三部分：驱动加载流程
8. Platform Device 创建顺序
9. Pinctrl 自动应用机制
10. 驱动注册和匹配
11. SDIO 总线扫描
12. brcmfmac 驱动初始化
13. Probe 延迟机制（EPROBE_DEFER）

#### 第四部分：驱动选择指南
14. bcmdhd vs brcmfmac 详细对比
15. 架构差异分析
16. 性能深度对比（吞吐量、延迟、CPU效率）
17. 适用场景推荐

#### 第五部分：设备匹配机制
18. bcmdhd 设备匹配机制
19. SDIO 总线匹配详解
20. 设备树 compatible 的作用

#### 第六部分：固件配置
21. 固件文件获取（多种方式）
22. 固件安装和验证
23. 固件加载流程
24. 常见问题排查

#### 第七部分：调试和故障排除
25. 调试技巧
26. 常见问题解答
27. dmesg 日志分析

#### 第八部分：附录
28. 关键数据结构
29. 完整流程图
30. 修正说明
31. 更新日志

---

## 🎯 快速导航

### 我想了解...

| 需求 | 跳转到 |
|------|--------|
| **WiFi 驱动工作原理** | 第一、二、三部分 |
| **选择哪个驱动** | 第四部分 - 驱动对比 |
| **设备树如何配置** | 第二部分 - 设备树配置 |
| **固件如何安装** | 第六部分 - 固件配置 |
| **遇到问题如何调试** | 第七部分 - 故障排除 |
| **性能优化** | 第四部分 - 性能对比 |
| **Pinctrl 机制** | 第二部分 - Pinctrl 详解 |

---

## 📊 文档统计

| 项目 | 数值 |
|------|------|
| **总文档数** | 1 个 |
| **总大小** | 210 KB |
| **总行数** | 7,483 行 |
| **章节数** | 31 个 |
| **部分数** | 8 个 |

---

## 📝 文档整合说明

**v2.0 (2026-02-28)** - 完全整合版

原有的 **12 个独立文档** 已全部整合为 **1 个完整指南**：

### 已整合的文档：

1. ✅ ap6255_driver_flow.md - 驱动加载流程
2. ✅ bcmdhd_vs_brcmfmac_comparison.md - 驱动对比
3. ✅ bcmdhd_vs_brcmfmac_performance.md - 性能对比
4. ✅ bcmdhd_device_tree_matching.md - 设备匹配
5. ✅ wireless_wlan_vs_mmc_pwrseq.md - 配置对比
6. ✅ pinctrl_auto_apply_mechanism.md - Pinctrl 机制
7. ✅ pinctrl_vs_reset_gpios_analysis.md - Pinctrl 分析
8. ✅ platform_device_creation_order.md - 设备创建顺序
9. ✅ **AP6255_FIRMWARE_GUIDE.md - 固件指南**
10. ✅ CORRECTIONS_SUMMARY.md - 修正说明
11. ✅ UPDATE_20260228_2.md - 更新日志
12. ✅ CLion 相关文档 - 已删除

### 整合结果：

- ✅ **内容完整**：所有技术细节无遗漏
- ✅ **结构清晰**：8 大部分，31 个章节
- ✅ **便于查阅**：单一文档，快速定位
- ✅ **易于维护**：统一版本管理

---

## 📁 目录结构

```
user/docs/
├── README.md                      # 本文件 - 文档导航
└── AP6255_WIFI_COMPLETE_GUIDE.md  # 完整指南（唯一文档）⭐
```

---

## 🔗 相关资源

### 内核源码位置

```
WiFi 驱动：
  kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/
  kernel/drivers/net/wireless/rockchip_wlan/rkwifi/bcmdhd/

设备树：
  kernel/arch/arm64/boot/dts/rockchip/rk3399-eaidk-610.dts
  kernel/arch/arm64/boot/dts/rockchip/rk3399.dtsi

电源序列：
  kernel/drivers/mmc/core/pwrseq_simple.c

Pinctrl：
  kernel/drivers/pinctrl/pinctrl-rockchip.c
```

### 外部链接

- Linux 内核文档: https://www.kernel.org/doc/html/latest/
- Rockchip 官方: http://opensource.rock-chips.com/
- Linux Firmware: https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
- Broadcom 驱动文档: kernel/Documentation/networking/device_drivers/wifi/brcm80211.rst

---

## ⚠️ 重要说明

1. **唯一文档**
   - 所有 WiFi 驱动相关内容都在 `AP6255_WIFI_COMPLETE_GUIDE.md` 中
   - 无需查看其他文档

2. **推荐阅读顺序**
   - 新手：按照文档顺序从第一部分开始
   - 有经验：直接跳转到感兴趣的章节
   - 遇到问题：查看第七部分故障排除

3. **文档特点**
   - 完整性：涵盖所有技术细节
   - 准确性：经过多次修正和验证
   - 实用性：包含大量实际案例和调试技巧

---

**文档位置**: `/root/projects/embedded/rockchip/rk3399/user/docs/`
**最后更新**: 2026-02-28
**版本**: v2.0
**维护者**: Claude Code
