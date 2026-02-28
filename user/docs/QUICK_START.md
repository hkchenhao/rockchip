# RK3399 内核源码索引快速开始指南

## ✅ 配置状态

当前 CMakeLists.txt 已配置完成，可以索引 **整个内核源码树**（24,819个文件）。

## 🚀 在 CLion 中使用

### 步骤 1: 打开项目

```bash
# 在 CLion 中打开
File -> Open -> 选择 /root/projects/embedded/rockchip/rk3399
```

### 步骤 2: 重新加载 CMake

```
Tools -> CMake -> Reload CMake Project
```

或者点击右上角的 🔄 图标。

### 步骤 3: 等待索引完成

右下角会显示进度：
```
Indexing... (12345/24819 files)
```

**预计时间**: 5-15分钟（取决于机器性能）

### 步骤 4: 验证功能

随机打开一个内核文件，例如：
```
kernel/drivers/mmc/host/dw_mmc-rockchip.c
```

测试以下功能：
- ✅ **Ctrl+B**: 跳转到定义
- ✅ **Alt+F7**: 查找引用
- ✅ **Ctrl+Space**: 代码补全
- ✅ **Double Shift**: 全局搜索符号

## 📁 索引覆盖范围

```
kernel/
├── drivers/              ✅ 所有驱动 (~20,000 文件)
│   ├── mmc/             MMC/SD/SDIO
│   ├── net/             网络驱动
│   ├── gpio/            GPIO驱动
│   ├── pinctrl/         引脚控制
│   ├── clk/             时钟驱动
│   └── ... (所有其他驱动)
│
├── arch/arm64/          ✅ ARM64 架构代码 (~2,000 文件)
│   ├── kernel/          架构核心
│   ├── mm/              内存管理
│   └── boot/dts/        设备树
│
├── kernel/              ✅ 内核核心 (~1,500 文件)
│   ├── sched/           进程调度
│   ├── irq/             中断处理
│   └── ... (其他核心代码)
│
├── mm/                  ✅ 内存管理子系统
├── fs/                  ✅ 文件系统
├── net/                 ✅ 网络协议栈
├── lib/                 ✅ 内核库函数
├── block/               ✅ 块设备层
├── crypto/              ✅ 加密子系统
└── security/            ✅ 安全框架
```

## 🔍 实用技巧

### 1. 全局搜索函数/结构体

```
Double Shift -> 输入名称
```

例如：搜索 `platform_device`

### 2. 查看函数调用关系

```
Ctrl+Alt+H (在函数名上)
```

### 3. 查找文件

```
Ctrl+Shift+N -> 输入文件名
```

例如：输入 `dw_mmc` 会列出所有相关文件

### 4. 查看最近文件

```
Ctrl+E
```

### 5. 查看类型层次

```
Ctrl+H (在结构体名上)
```

## ⚡ 性能优化

### 如果索引很慢

1. **增加 CLion 内存**

编辑 `Help -> Edit Custom VM Options`:
```
-Xmx4096m
-Xms2048m
```

2. **关闭其他程序**

索引期间关闭其他占用资源的程序。

3. **使用 SSD**

将项目放在 SSD 上可以显著提升速度。

## ⚠️ 注意事项

### 1. 仅用于 IDE 索引

这个配置 **不能用于实际编译内核**！

实际编译内核请使用：
```bash
cd kernel
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
```

### 2. 首次索引较慢

首次索引需要 5-15 分钟，后续增量索引会很快。

### 3. 内存占用

- **索引缓存**: ~2-4GB
- **建议配置**: 至少 8GB RAM

### 4. Git 忽略

已在 `.gitignore` 中添加：
```
cmake-build-*/
.idea/
compile_commands.json
```

## 🐛 故障排除

### 问题 1: 头文件显示红色波浪线

**解决方案**:
```
File -> Invalidate Caches / Restart -> Invalidate and Restart
```

### 问题 2: compile_commands.json 未生成

**检查**:
```bash
ls -lh cmake-build-debug/compile_commands.json
```

**解决**: 重新加载 CMake 项目

### 问题 3: CLion 卡顿

**原因**: 内存不足

**解决**:
1. 增加 JVM 内存: `-Xmx6144m`
2. 重启 CLion
3. 清除缓存: `File -> Invalidate Caches / Restart`

### 问题 4: 索引一直不完成

**解决**:
1. 增加 CLion 内存
2. 关闭其他程序
3. 等待更长时间（可能需要 10-20 分钟）

## 📚 相关文档

- `full_kernel_indexing.md` - 全内核索引详细说明
- `clion_setup.md` - CLion 配置详细指南
- `cmake_kernel_indexing.md` - CMake 配置原理
- `ap6255_driver_flow.md` - AP6255 驱动加载流程

## 📊 配置统计

- **索引文件数**: 24,819
- **compile_commands.json**: ~145KB
- **覆盖范围**: 整个内核源码树
- **配置文件**: `CMakeLists.txt`

## ✅ 验证清单

配置完成后，检查以下功能：

- [ ] 头文件没有红色波浪线
- [ ] Ctrl+B 可以跳转到定义
- [ ] Alt+F7 可以查找引用
- [ ] 代码补全正常工作
- [ ] 宏定义正确识别
- [ ] 结构体成员可以补全

---

**版本**: 1.0
**最后更新**: 2026-02-28
**项目路径**: `/root/projects/embedded/rockchip/rk3399`
