# AP6255 WiFi 固件获取指南

## 固件信息

- **模块型号**: AMPAK AP6255
- **芯片型号**: Broadcom BCM43455
- **接口**: SDIO
- **驱动**: Rockchip bcmdhd (CONFIG_BCMDHD=y, CONFIG_AP6XXX=m)

## 需要的固件文件

1. **fw_bcmdhd.bin** - 主固件文件
2. **nvram.txt** - NVRAM 配置文件（校准数据）
3. **brcmfmac43455-sdio.clm_blob** - CLM 文件（可选，用于国家/地区频率管理）

## 获取方法

### 方法 1: 从 linux-firmware 官方仓库（推荐）

#### 在线下载（需要网络）：

```bash
# 创建目录
mkdir -p /tmp/firmware && cd /tmp/firmware

# 下载固件文件
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/brcm/brcmfmac43455-sdio.bin
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/brcm/brcmfmac43455-sdio.txt
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/brcm/brcmfmac43455-sdio.clm_blob
```

#### 或使用 git 克隆：

```bash
cd /root/projects/embedded/rockchip/rk3399/linux-firmware
git remote add upstream https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
git pull upstream master
```

### 方法 2: 从 GitHub 镜像下载

```bash
mkdir -p /tmp/firmware && cd /tmp/firmware

# GitHub 镜像地址
GITHUB_BASE="https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/master/brcm"

wget ${GITHUB_BASE}/brcmfmac43455-sdio.bin
wget ${GITHUB_BASE}/brcmfmac43455-sdio.txt
wget ${GITHUB_BASE}/brcmfmac43455-sdio.clm_blob
```

### 方法 3: 从其他 Linux 系统复制

如果您有运行 Debian/Ubuntu/Fedora 的系统：

```bash
# Debian/Ubuntu
apt-get install firmware-brcm80211
# 固件位于: /lib/firmware/brcm/

# Fedora
dnf install linux-firmware
# 固件位于: /lib/firmware/brcm/
```

然后复制文件到您的开发环境。

### 方法 4: 从 Rockchip SDK 或开发板厂商获取

联系 EAIDK-610 的厂商（OPEN AI LAB）获取官方固件包。

## 安装固件

### 1. 标准 Linux 固件路径

```bash
sudo mkdir -p /lib/firmware/brcm
sudo cp brcmfmac43455-sdio.bin /lib/firmware/brcm/
sudo cp brcmfmac43455-sdio.txt /lib/firmware/brcm/
sudo cp brcmfmac43455-sdio.clm_blob /lib/firmware/brcm/
```

### 2. bcmdhd 驱动专用路径（根据内核配置）

```bash
sudo mkdir -p /vendor/etc/firmware
sudo cp brcmfmac43455-sdio.bin /vendor/etc/firmware/fw_bcmdhd.bin
sudo cp brcmfmac43455-sdio.txt /vendor/etc/firmware/nvram.txt
```

### 3. 创建设备特定配置（可选）

```bash
sudo cp /lib/firmware/brcm/brcmfmac43455-sdio.txt \
        /lib/firmware/brcm/brcmfmac43455-sdio.openailab,eaidk-610.txt
```

## 固件文件说明

### brcmfmac43455-sdio.bin
- 主固件文件，包含 WiFi 芯片的运行代码
- 大小约 500-700 KB
- 必需文件

### nvram.txt (brcmfmac43455-sdio.txt)
- NVRAM 配置文件，包含：
  - 射频校准数据
  - 功率设置
  - 天线配置
  - MAC 地址（如果没有会随机生成）
- 大小约 1-5 KB
- 必需文件

### brcmfmac43455-sdio.clm_blob
- Country Locale Matrix（国家/地区矩阵）
- 包含各国的频率和功率限制
- 大小约 10-50 KB
- 可选文件，但建议使用

## 验证固件

编译内核并启动后，检查固件是否正确加载：

```bash
# 查看固件加载日志
dmesg | grep -i brcm
dmesg | grep -i firmware

# 应该看到类似输出：
# brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43455-sdio for chip BCM4345/6
# brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4345/6 wl0: xxx

# 检查 WiFi 接口
ip link show
ifconfig -a

# 应该看到 wlan0 接口
```

## 如果固件加载失败

### 修改内核配置中的固件路径

如果固件在不同位置，可以修改内核配置：

```bash
cd /root/projects/embedded/rockchip/rk3399/kernel
make menuconfig

# 导航到:
# Device Drivers
#   -> Network device support
#     -> Wireless LAN
#       -> Rockchip Wireless LAN support
#         -> Broadcom Wireless Device Driver Support
#           -> Firmware path: 修改为您的路径
#           -> NVRAM path: 修改为您的路径
```

或直接修改 .config：

```bash
sed -i 's|CONFIG_BCMDHD_FW_PATH=.*|CONFIG_BCMDHD_FW_PATH="/lib/firmware/brcm/brcmfmac43455-sdio.bin"|' .config
sed -i 's|CONFIG_BCMDHD_NVRAM_PATH=.*|CONFIG_BCMDHD_NVRAM_PATH="/lib/firmware/brcm/brcmfmac43455-sdio.txt"|' .config
```

## 文件大小参考

正确的固件文件大小应该在以下范围内：

```
brcmfmac43455-sdio.bin      ~500-700 KB
brcmfmac43455-sdio.txt      ~1-5 KB
brcmfmac43455-sdio.clm_blob ~10-50 KB
```

如果文件大小明显不对（比如只有几百字节），说明下载不完整。

## 常见问题

### Q1: 固件找不到
- 检查固件路径是否与内核配置一致
- 检查文件权限（应该可读）
- 使用 `dmesg | grep firmware` 查看内核尝试加载的路径

### Q2: 固件版本不匹配
- 确保使用 BCM43455 的固件，不是其他型号
- AP6255 = BCM43455

### Q3: WiFi 接口不出现
- 检查设备树配置（sdio0 是否启用）
- 检查驱动是否编译（lsmod | grep bcmdhd）
- 检查 SDIO 总线（ls /sys/bus/sdio/devices/）

## 自动化脚本

我已经为您创建了自动下载脚本：

```bash
sudo /tmp/download_ap6255_firmware.sh
```

该脚本会自动：
1. 尝试从多个源下载固件
2. 安装到正确的位置
3. 创建必要的符号链接
4. 验证安装结果

## 参考链接

- Linux Firmware 仓库: https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
- GitHub 镜像: https://github.com/RPi-Distro/firmware-nonfree
- Broadcom 驱动文档: kernel/Documentation/networking/device_drivers/wifi/brcm80211.rst
