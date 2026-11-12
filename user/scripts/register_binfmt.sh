#!/bin/bash
# 以 root 执行；只管理 qemu-aarch64 规则，不 reset 共享注册表。
# 已有静态 QEMU 时直接复用；缺失时下载校验并安装已验证的 10.2.1。
# 宿主机重启或容器迁移后，制作 rootfs 前重新执行即可。
set -euo pipefail

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

[[ $(uname -s) == Linux ]] || fail '需要在 Linux 开发机上执行。'
[[ $EUID -eq 0 ]] || fail '请使用 sudo 或 root 执行本脚本。'

qemu=/usr/local/bin/qemu-aarch64
registry=/proc/sys/fs/binfmt_misc
handler=qemu-aarch64
magic_hex=7f454c460201010000000000000000000200b700
mask_hex=ffffffffffffff00fffffffffffffffffeffffff

command -v readelf >/dev/null || fail '需要 binutils 提供的 readelf 命令。'

validate_qemu() {
    local binary=$1
    version=$("$binary" --version)
    [[ $version == 'qemu-aarch64 version '* ]] || fail "$binary 不是 qemu-aarch64。"
    if readelf -l "$binary" | grep -q 'INTERP'; then
        fail "$binary 依赖动态加载器，需要静态链接的 QEMU。"
    fi
    if readelf -d "$binary" | grep -q 'NEEDED'; then
        fail "$binary 依赖共享库，需要静态链接的 QEMU。"
    fi
}

download_dir=
staged=
cleanup() {
    [[ -z "$staged" ]] || rm -f -- "$staged"
    [[ -z "$download_dir" ]] || rm -rf -- "$download_dir"
}
trap cleanup EXIT

if [[ ! -x "$qemu" ]]; then
    [[ ! -e "$qemu" ]] || fail "$qemu 已存在但不可执行，请先检查。"
    existing=
    for candidate in /usr/local/bin/qemu-aarch64-static "$(command -v qemu-aarch64 || true)" "$(command -v qemu-aarch64-static || true)"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            existing=$(readlink -f "$candidate")
            break
        fi
    done

    if [[ -n "$existing" ]]; then
        validate_qemu "$existing"
        install -d -m 0755 /usr/local/bin
        ln -sfn -- "$existing" "$qemu"
        printf '复用已有 QEMU：%s\n' "$existing"
    else
        [[ $(uname -m) == x86_64 ]] || fail '自动下载仅支持当前 x86_64 开发机。'
        for tool in curl python3 ar sha256sum; do
            command -v "$tool" >/dev/null || fail "自动安装需要 $tool，请先安装对应工具。"
        done
        # 官方 Ubuntu 包；固定版本和 SHA-256，不依赖 /tmp 中的旧下载或验证目录。
        url=https://archive.ubuntu.com/ubuntu/pool/universe/q/qemu/qemu-user_10.2.1+ds-1ubuntu3.3_amd64.deb
        sha256=a00c7fdf34c913b799f8d1cc556d3fdd9f9fd695167a17baf86123a9cfaefb22
        python3 -c 'import ctypes; ctypes.CDLL("libzstd.so.1")' || fail '解包需要 libzstd.so.1。'
        download_dir=$(mktemp -d /tmp/qemu-aarch64-install.XXXXXX)
        printf '未找到 QEMU，下载并安装 10.2.1。\n'
        curl -fL --retry 2 --connect-timeout 15 --max-time 600 -o "$download_dir/qemu-user.deb" "$url"
        printf '%s  %s\n' "$sha256" "$download_dir/qemu-user.deb" | sha256sum -c -

        # CentOS 7 的 tar 没有 zstd 支持；借助已有 libzstd 解包，仅提取所需二进制。
        python3 - "$download_dir" <<'EXTRACT_QEMU'
import ctypes
import os
import subprocess
import sys
import tarfile

directory = sys.argv[1]

class Input(ctypes.Structure):
    _fields_ = [('src', ctypes.c_void_p), ('size', ctypes.c_size_t), ('pos', ctypes.c_size_t)]

class Output(ctypes.Structure):
    _fields_ = [('dst', ctypes.c_void_p), ('size', ctypes.c_size_t), ('pos', ctypes.c_size_t)]

zstd = ctypes.CDLL('libzstd.so.1')
zstd.ZSTD_createDStream.restype = ctypes.c_void_p
zstd.ZSTD_initDStream.argtypes = [ctypes.c_void_p]
zstd.ZSTD_initDStream.restype = ctypes.c_size_t
zstd.ZSTD_decompressStream.argtypes = [ctypes.c_void_p, ctypes.POINTER(Output), ctypes.POINTER(Input)]
zstd.ZSTD_decompressStream.restype = ctypes.c_size_t
zstd.ZSTD_isError.argtypes = [ctypes.c_size_t]
zstd.ZSTD_isError.restype = ctypes.c_uint
zstd.ZSTD_freeDStream.argtypes = [ctypes.c_void_p]

data = subprocess.check_output(['ar', 'p', directory + '/qemu-user.deb', 'data.tar.zst'])
source = ctypes.create_string_buffer(data)
buffer = ctypes.create_string_buffer(1024 * 1024)
input_buffer = Input(ctypes.cast(source, ctypes.c_void_p), len(data), 0)
stream = zstd.ZSTD_createDStream()
if not stream:
    raise RuntimeError('Unable to allocate zstd decoder')
try:
    if zstd.ZSTD_isError(zstd.ZSTD_initDStream(stream)):
        raise RuntimeError('Unable to initialize zstd decoder')
    with open(directory + '/data.tar', 'wb') as output:
        while True:
            output_buffer = Output(ctypes.cast(buffer, ctypes.c_void_p), len(buffer), 0)
            previous_position = input_buffer.pos
            remaining = zstd.ZSTD_decompressStream(stream, ctypes.byref(output_buffer), ctypes.byref(input_buffer))
            if zstd.ZSTD_isError(remaining):
                raise RuntimeError('Invalid zstd package data')
            output.write(buffer.raw[:output_buffer.pos])
            if remaining == 0 and input_buffer.pos == input_buffer.size:
                break
            if input_buffer.pos == previous_position and output_buffer.pos == 0:
                raise RuntimeError('Truncated zstd package data')
finally:
    zstd.ZSTD_freeDStream(stream)

with tarfile.open(directory + '/data.tar') as archive:
    member = next(m for m in archive.getmembers() if m.name.lstrip('./') == 'usr/bin/qemu-aarch64')
    with archive.extractfile(member) as source, open(directory + '/qemu-aarch64', 'wb') as output:
        output.write(source.read())
os.chmod(directory + '/qemu-aarch64', 0o755)
EXTRACT_QEMU

        validate_qemu "$download_dir/qemu-aarch64"
        install -d -m 0755 /usr/local/bin
        staged=/usr/local/bin/.qemu-aarch64-install-$$
        install -o root -g root -m 0755 "$download_dir/qemu-aarch64" "$staged"
        mv -f -- "$staged" "$qemu"
        staged=
    fi
else
    printf '已找到 QEMU，跳过下载和安装。\n'
fi
validate_qemu "$qemu"

# 提供旧命令名；已有的可执行入口保持不变。
if [[ ! -e /usr/local/bin/qemu-aarch64-static ]]; then
    ln -sfn qemu-aarch64 /usr/local/bin/qemu-aarch64-static
fi
[[ -x /usr/local/bin/qemu-aarch64-static ]] || fail 'qemu-aarch64-static 入口存在但不可执行，请检查。'

mountpoint -q "$registry" || mount -t binfmt_misc binfmt_misc "$registry"
grep -qx 'enabled' "$registry/status" || fail 'binfmt_misc 全局处于禁用状态，请先检查平台配置。'

if [[ ! -e "$registry/$handler" ]]; then
    magic=$(printf '%s' "$magic_hex" | sed 's/../\\x&/g')
    mask=$(printf '%s' "$mask_hex" | sed 's/../\\x&/g')
    printf ':%s:M::%s:%s:%s:F\n' "$handler" "$magic" "$mask" "$qemu" > "$registry/register"
fi

# 同名规则必须与本脚本一致；不覆盖其他解释器或二进制匹配规则。
entry="$registry/$handler"
if ! grep -Fqx "interpreter $qemu" "$entry" ||
   ! grep -Fqx "magic $magic_hex" "$entry" ||
   ! grep -Fqx "mask $mask_hex" "$entry" ||
   ! grep -Fqx 'offset 0' "$entry" ||
   ! grep -q '^flags:.*F' "$entry"; then
    cat "$entry" >&2
    fail '同名规则与预期不一致，已保留原规则，请人工检查。'
fi

# 只启用本条已核对的规则，不改变全局开关。
if ! grep -qx 'enabled' "$entry"; then
    printf '1\n' > "$entry"
fi
grep -qx 'enabled' "$entry" || fail 'ARM64 处理器未成功启用。'

printf '%s\n' "${version%%$'\n'*}"
printf 'ARM64 binfmt 规则已就绪，可直接 chroot 进入 ARM64 rootfs。\n'
cat "$entry"
