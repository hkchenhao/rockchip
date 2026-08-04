# RK3399 产品 Defconfig guide

本文记录按 `make menuconfig` 顺序分析 RK3399 产品内核配置的过程。后续菜单项分析继续更新本文档。

## 1. 分析环境与约定

远程内核目录：`/root/projects/rockchip/kernel`

实际执行的菜单命令：

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- menuconfig
```

远程环境在分析前执行过 `make distclean`，因此不存在既有 `.config`。启动 `menuconfig` 时显示：

```text
# using defaults found in arch/arm64/configs/defconfig
```

这意味着当前菜单的选中状态来自 `arch/arm64/configs/defconfig` 的 ARM64 默认配置，**不是** `user/configs/rockchip_linux_rk3399_defconfig` 的选中状态。

本文使用以下判定标准：

- **启动必需**：缺少后无法形成正常可启动内核，或对应项目必须在候选项中选择一个。
- **标准 Linux 建议保留**：非内核早期启动必需，但 glibc、systemd 或常用用户态高度依赖。
- **按需求**：取决于 initramfs、Android、容器、调试、性能分析或实时性需求。
- **默认即可**：由 Kconfig 默认值自动选中，不必在干净 defconfig 中显式写入。

> 注意：后续生成干净的 `rockchip_linux_rk3399_product_defconfig` 时，遵循 `make menuconfig` 的菜单层级和顺序；不把旧 BSP defconfig 的显式值误作 Kconfig 默认值。

---

# 2. General setup

## 2.1 顶层构建与版本信息

### Compile also drivers which will not load

`CONFIG_COMPILE_TEST`

允许在当前架构上编译不可能实际加载的驱动，仅用于发现编译问题。

- 启动必需：否。
- 产品建议：关闭。
- 干净 defconfig：不写，采用默认 `n`。

### Compile kernel with warnings as errors

`CONFIG_WERROR`

将编译警告视为错误，对 C 编译增加 `-Werror`。

- 启动必需：否，仅影响构建阶段。
- 默认值：`default COMPILE_TEST`，不是无条件 `y`。当 `CONFIG_COMPILE_TEST=n` 时默认也是 `n`。
- 产品建议：通常关闭。旧 BSP 与新/旧 GCC 组合可能产生额外警告，打开后会使构建失败。
- 干净 defconfig：不写，默认 `n`。

原始 RK3399 配置虽显式写了 `CONFIG_WERROR=y`，但它并不代表 Kconfig 默认值；而且构建脚本实际传入 `KCFLAGS="-Wno-error"`，说明该 BSP 构建流程本身也在规避警告导致失败。

### Compile test UAPI headers

`CONFIG_UAPI_HEADER_TEST`

构建时检查导出的 UAPI 头文件是否能作为独立单元编译。

- 启动必需：否。
- 用途：内核开发与 CI。
- 产品建议：关闭。

### Local version - append to kernel release

`CONFIG_LOCALVERSION`

为 `uname -r` 追加固定版本后缀，例如：

```text
CONFIG_LOCALVERSION="-rk3399-product"
```

- 启动必需：否。
- 用途：区分产品版本以及模块目录。
- 建议：待发布命名规范确定后再设置；目前保持默认空字符串。

### Automatically append version information to the version string

`CONFIG_LOCALVERSION_AUTO`

根据 Git tag 或 commit 自动追加版本信息。

- 启动必需：否。
- 开发版本：可保留。
- 量产版本：通常关闭，避免同一产品因 Git 状态不同产生不同 `uname -r`。
- 建议：当前不写，发布阶段再明确决定。

### Build ID Salt

`CONFIG_BUILD_SALT`

向 ELF Build ID 计算加入自定义字符串。

- 启动必需：否。
- 用途：发行版区分不同构建的调试信息。
- 建议：保持默认空值。

---

## 2.2 Kernel compression mode

内核镜像必须在以下压缩格式中选择一个。

| 菜单项 | 配置 | 说明 |
|---|---|---|
| Gzip | `CONFIG_KERNEL_GZIP` | 压缩率与解压速度均衡。 |
| Bzip2 | `CONFIG_KERNEL_BZIP2` | 镜像略小，解压慢且内存需求高。 |
| LZMA | `CONFIG_KERNEL_LZMA` | 压缩率高，构建和解压慢。 |
| XZ | `CONFIG_KERNEL_XZ` | 镜像较小，启动解压时间偏长。 |
| LZO | `CONFIG_KERNEL_LZO` | 解压快，镜像较大。 |
| LZ4 | `CONFIG_KERNEL_LZ4` | 解压最快，镜像通常较大。 |
| ZSTD | `CONFIG_KERNEL_ZSTD` | 压缩率与解压性能折中。 |
| None | `CONFIG_KERNEL_UNCOMPRESSED` | 不压缩，主要用于仿真或特殊调试。 |

- 启动必需：是，必须选择一种。
- 当前 Kconfig 默认：`Gzip`。
- RK3399 产品建议：首版采用默认 `Gzip`。
- 干净 defconfig：无需显式写入，让 Kconfig 选择 `CONFIG_KERNEL_GZIP=y`。

---

## 2.3 Init、主机名与 IPC

### Default init path

`CONFIG_DEFAULT_INIT`

没有传入 `init=` 内核参数时，指定优先执行的 init 路径。

- 启动必需：否。
- 建议：保持空。内核会按默认候选路径依次尝试，例如 `/sbin/init`、`/etc/init`、`/bin/init`、`/bin/sh`。
- 除非产品 rootfs 使用特殊固定路径，否则不建议写死。

### Default hostname

`CONFIG_DEFAULT_HOSTNAME`

内核启动早期使用的初始主机名，之后可被用户态 `sethostname()` 覆盖。

- 启动必需：否。
- 建议：可保留：

```text
CONFIG_DEFAULT_HOSTNAME="localhost"
```

也可改为产品通用名称，例如 `"rk3399-product"`。

### System V IPC

`CONFIG_SYSVIPC`

提供传统的共享内存、信号量和消息队列接口，例如 `shmget()`、`semget()`、`msgget()`。

- 启动必需：否。
- 标准 Linux 建议：保留。
- 建议：

```text
CONFIG_SYSVIPC=y
```

### POSIX Message Queues

`CONFIG_POSIX_MQUEUE`

提供 `mq_open()`、`mq_send()`、`mq_receive()` 等 POSIX 消息队列接口；通常挂载到 `/dev/mqueue`。

- 启动必需：否。
- 标准 Linux 建议：通常保留。
- 建议：先保留：

```text
CONFIG_POSIX_MQUEUE=y
```

在确认全部应用不使用 `mq_*` 后，才考虑关闭。

### General notification queue

`CONFIG_WATCH_QUEUE`

通用内核到用户态通知队列，用于部分 keyring 或设备通知机制。

- 启动必需：否。
- 建议：默认关闭，不写。

### Enable process_vm_readv/writev syscalls

`CONFIG_CROSS_MEMORY_ATTACH`

提供 `process_vm_readv()` 和 `process_vm_writev()`，允许拥有权限的进程直接读写其他进程地址空间。

- 启动必需：否。
- 标准 Linux 建议：保留 Kconfig 默认值。
- 用途：调试器、性能分析工具、进程检查工具。
- 干净 defconfig：不写。

### uselib syscall (for libc5 and earlier)

`CONFIG_USELIB`

兼容 libc5 或更早用户态动态链接方式。

- 启动必需：否。
- RK3399 产品建议：不需要，默认关闭。

### Auditing support

`CONFIG_AUDIT`

Linux audit 基础设施，SELinux AVC 日志、`auditd` 和部分合规审计会使用。

- 启动必需：否。
- Android SELinux 或合规审计：按需求保留。
- 普通 BusyBox 嵌入式产品：通常关闭。

---

## 2.4 IRQ subsystem

当前内核的 `IRQ subsystem` 菜单中，**只有一个可人工选择、会显示在 menuconfig 界面的配置项**：

### Expose irq internals in debugfs

`CONFIG_GENERIC_IRQ_DEBUGFS`

在 debugfs 中暴露 IRQ 内部状态，主要用于定位中断路由、亲和性、丢中断等疑难问题。

- 启动必需：否。
- 前置依赖：`CONFIG_DEBUG_FS=y`。
- 默认值：`n`。
- 开发调试：遇到中断相关问题时可临时启用。
- 量产产品：保持默认关闭；当前干净 product defconfig 不写此项。

源码中虽然还定义了 `GENERIC_IRQ_PROBE`、`GENERIC_IRQ_SHOW`、`IRQ_DOMAIN`、`GENERIC_IRQ_IPI`、`HARDIRQS_SW_RESEND`、`IRQ_FORCED_THREADING` 等多个 IRQ 符号，但它们没有 menuconfig prompt，属于内部 Kconfig 符号。ARM64 架构与中断控制器驱动会通过 `select` 自动选择其中所需的能力，不能也不应人工逐项配置到产品 defconfig。

因此，IRQ 核心框架本身仍是启动所需的基础能力，但它不对应这个子菜单中的人工决策项；不要把 IRQ tracing、IRQ 延迟统计等位于其他菜单（主要是 `Kernel hacking`/tracing）的功能误认为本子菜单选项。

---

## 2.5 Timers subsystem

### Tickless System / Dynamic Ticks

通常涉及 `CONFIG_NO_HZ_*` 等动态 tick 策略。

- 启动必需：内核必须有有效的时钟 tick 与 clockevent 机制；但并不强制某一种 tickless 策略。
- RK3399 建议：使用 Kconfig 默认的 tickless idle 策略。

#### Old Idle dynticks config

通常对应旧兼容符号 `CONFIG_NO_HZ`。早期内核用它表示“CPU 进入 idle 后停止周期性 tick”；较新的内核已将实际策略拆分为更明确的选项。它主要用于兼容旧版 `.config`，不是新产品应主动选择的功能。

| 策略 | 配置 | 用途 | RK3399 产品建议 |
|---|---|---|---|
| Periodic timer ticks | `CONFIG_HZ_PERIODIC` | 即使 CPU 空闲也持续产生周期性 tick。 | 一般不选，除非有特殊时序/调试需求。 |
| Idle dynticks system (tickless idle) | `CONFIG_NO_HZ_IDLE` | CPU 空闲时按需停止周期 tick，减少无效唤醒和功耗。 | **推荐。** |
| Full dynticks system (tickless) | `CONFIG_NO_HZ_FULL` | 非 idle 的指定 CPU 也尽量停止 tick，面向 CPU 隔离、实时低抖动和 HPC。 | 普通产品不选；仅在明确采用 `nohz_full=`、CPU 隔离和配套 RCU 策略后启用。 |

- `(NEW)`：当前 `.config` 尚未记录该项，Kconfig 请求对新增/未回答项作出选择；**不表示必须启用**。
- `CONFIG_NO_HZ_IDLE=y`：通常能降低 RK3399 空闲功耗，且不会引入 `NO_HZ_FULL` 的上下文跟踪、RCU offload、CPU 隔离等额外复杂度。
- 干净 defconfig：不要手工写旧式聚合符号 `CONFIG_NO_HZ=y`；若产品需要固定该策略，则显式写入 `CONFIG_NO_HZ_IDLE=y`，否则让当前内核 Kconfig 默认值决定。
- 版本差异：本工作区内核已经不再定义 `Old Idle dynticks config`；若远程 menuconfig 仍显示它，说明远程内核版本或其补丁状态更旧，最终以远程源码中对应 Kconfig 的依赖关系和默认值为准。

### High Resolution Timer Support

`CONFIG_HIGH_RES_TIMERS`

启用高精度软件定时器。

- 启动必需：严格不是。
- 标准 Linux 建议：保留。
- 用途：音视频、网络协议、定时任务和现代用户态更准确的时间行为。
- 干净 defconfig：优先使用默认值；若当前 Kconfig 默认未开启，后续再显式评估。

### Timer frequency

选择 `CONFIG_HZ_100`、`CONFIG_HZ_250`、`CONFIG_HZ_300`、`CONFIG_HZ_1000` 等。

- 启动必需：是，必须有一个 HZ 值。
- 建议：采用 ARM64 默认值，不因裁剪而修改。
- 说明：高 HZ 有利于交互与延迟，低 HZ 可略减周期调度开销。

---

## 2.6 BPF subsystem

### Enable bpf() system call

`CONFIG_BPF_SYSCALL`

向用户态开放 `bpf()` 系统调用，用于加载 eBPF 程序、创建 map，并附着 tracing、网络或 cgroup BPF 程序。

- 启动必需：否。
- 需要场景：eBPF 网络策略、`bpftool`、`bpftrace`、BCC、Cilium、部分容器网络与可观测性系统。
- 普通产品建议：不加入，默认关闭。

### Enable BPF Just In Time compiler

`CONFIG_BPF_JIT`

将 BPF 字节码转换为原生 ARM64 指令，提高 BPF 性能。

- 启动必需：否。
- 建议：仅在启用 BPF 后再评估。

### Permanently enable BPF JIT and remove BPF interpreter

`CONFIG_BPF_JIT_ALWAYS_ON`

强制 BPF JIT 并移除解释器路径。

- 启动必需：否。
- 建议：一般不主动开启。

### Disable unprivileged BPF by default

`CONFIG_BPF_UNPRIV_DEFAULT_OFF`

默认禁止非特权用户加载 BPF，管理员仍可通过 sysctl 调整。

- 启动必需：否。
- 安全建议：若启用 `BPF_SYSCALL`，建议保持启用。
- Kconfig 默认：`y`。
- 干净 defconfig：不必显式写入。

### Enable BPF LSM Instrumentation

`CONFIG_BPF_LSM`

允许 BPF 挂接 LSM 安全钩子以实现动态安全策略。

- 启动必需：否。
- 建议：普通产品关闭。

---

## 2.7 Preemption Model

这是产品需要主动选择的关键项。

| 菜单项 | 配置 | 启动必需 | 适用场景 |
|---|---|---|---|
| No Forced Preemption (Server) | `CONFIG_PREEMPT_NONE` | 三选一 | 吞吐优先，可能有更长调度延迟。 |
| Voluntary Kernel Preemption (Desktop) | `CONFIG_PREEMPT_VOLUNTARY` | 三选一 | 延迟与吞吐折中。 |
| Preemptible Kernel (Low-Latency Desktop) | `CONFIG_PREEMPT` | 三选一 | 毫秒级延迟更敏感的嵌入式系统。 |
| Fully Preemptible Kernel (Real-Time) | `CONFIG_PREEMPT_RT` | 否 | 有明确实时保证要求的系统。 |
| Preemption behaviour defined on boot | `CONFIG_PREEMPT_DYNAMIC` | 否 | 一个通用内核镜像需支持多种负载时使用。 |

原始 RK3399 配置选用：

```text
CONFIG_PREEMPT_VOLUNTARY=y
```

建议当前继续使用它。`PREEMPT_RT` 不能仅因“希望低延迟”而打开，必须按实时需求与完整驱动行为验证。

### Core Scheduling for SMT

通常对应 `CONFIG_SCHED_CORE`，即 SMT（Simultaneous Multithreading，同时多线程）核心调度。SMT 的一个物理 CPU 核会提供多个逻辑 CPU，例如 Intel Hyper-Threading；这些 sibling 逻辑 CPU 会共享同一物理核心的执行单元、缓存、分支预测器及部分 TLB 等资源。

Core Scheduling 按物理核心协调任务调度：仅允许属于同一可信调度组（cookie）的任务同时运行在同一个物理核心的 SMT sibling 上。它用于降低不可信容器、虚拟机或不同安全域任务共享核心资源时的侧信道风险；不兼容任务会使另一个 sibling 空闲，可能牺牲部分吞吐。

- 启动必需：否。
- RK3399 硬件事实：`2 × Cortex-A72 + 4 × Cortex-A53` 共 6 个独立物理核心，**不支持 SMT**；一个物理核只对应一个逻辑 CPU。
- 产品建议：保持默认关闭，不写 `CONFIG_SCHED_CORE=y`；启用对 RK3399 无实际收益，只会增加调度器代码和验证负担。
- 说明：RK3399 的 big.LITTLE 是不同类型的独立物理核心，不是 SMT；大小核调度需求不能作为启用此项的理由。

---

## 2.8 CPU/Task time and stats accounting

### Cputime accounting

包括以下模式：

- `CONFIG_TICK_CPU_ACCOUNTING`：基于 tick 的传统 CPU 时间统计；
- `CONFIG_VIRT_CPU_ACCOUNTING_NATIVE`：在内核边界读取 CPU 计数器，更精确但有少量开销；
- `CONFIG_VIRT_CPU_ACCOUNTING_GEN`：适用于 full dynticks 的统计模式。

- 启动必需：内核会选择一种有效模式。
- 普通 RK3399 建议：默认 tick-based 模式。
- 干净 defconfig：不手工写。

### Fine granularity task level IRQ time accounting

`CONFIG_IRQ_TIME_ACCOUNTING`

统计任务受 IRQ 和 softirq 影响的时间。

- 启动必需：否。
- 建议：性能诊断时再开。

### BSD Process Accounting

`CONFIG_BSD_PROCESS_ACCT`

把退出进程的统计持续写入 accounting 文件。

- 启动必需：否。
- 建议：关闭。

### Export task/process statistics through netlink

`CONFIG_TASKSTATS`

通过 netlink 导出任务/进程统计。

- 启动必需：否。
- 建议：默认关闭，资源审计或性能诊断再开。

### Enable per-task delay accounting

`CONFIG_TASK_DELAY_ACCT`

统计任务等待 CPU、块 IO、swap-in 等资源的延迟。

- 启动必需：否。
- 建议：性能诊断时再开。

### Enable extended accounting over taskstats

`CONFIG_TASK_XACCT`

基于 taskstats 的扩展统计。

- 启动必需：否。
- 建议：默认关闭。

### Enable per-task storage I/O accounting

`CONFIG_TASK_IO_ACCOUNTING`

统计各任务产生的存储 IO 字节数。

- 启动必需：否。
- 建议：默认关闭。

### Pressure stall information tracking

`CONFIG_PSI`

提供 `/proc/pressure/cpu`、`memory`、`io`，统计资源争用导致的 stall。

- 启动必需：否。
- 适用：Android、容器、资源调度、性能监控。
- 普通固定功能产品：可不加。

### Require boot parameter to enable pressure stall information tracking

`CONFIG_PSI_DEFAULT_DISABLED`

保留 PSI，但只在命令行传入 `psi=1` 后开启。

- 启动必需：否。
- 建议：只在启用 PSI、但希望默认关闭采集时考虑。

### CPU isolation

`CONFIG_CPU_ISOLATION`

支持 `isolcpus=` 等机制，将指定 CPU 与普通内核背景工作隔离。

- 启动必需：否。
- 适用：实时任务、低抖动采集、专核计算。
- 建议：没有 CPU 隔离设计时不加。

---

## 2.9 RCU Subsystem

### Make expert-level adjustments to RCU configuration

`CONFIG_RCU_EXPERT`

仅用于开放 RCU 专家级参数，不是 RCU 功能本身。

- 启动必需：否。
- 干净产品建议：不加。

### Offload RCU callbacks from certain CPUs

`CONFIG_RCU_NOCB_CPU`

允许用 `rcu_nocbs=` 将指定 CPU 的 RCU callback 移交其他 CPU/kthread。

- 启动必需：否。
- 适用：CPU isolation、实时核、低延迟专核。
- 建议：没有 `rcu_nocbs=` 规划则不加。

### RCU CPU stall timeout

`CONFIG_RCU_CPU_STALL_TIMEOUT`

RCU CPU stall 警告前等待的秒数。

- 启动必需：否。
- 说明：仅诊断阈值。
- 建议：采用默认值。

Tree RCU、SRCU 等基础实现由 ARM64 SMP 和其他功能自动选择，不应手工裁掉内部 RCU 符号。

---

## 2.10 Scheduler features

### Enable utilization clamping for RT/FAIR tasks

`CONFIG_UCLAMP_TASK`

允许指定任务最小/最大 CPU 利用率，影响调频和调度策略。

- 启动必需：否。
- 适用：Android、性能/功耗策略、任务 QoS。
- 建议：非 Android 且无 uclamp 使用者时关闭。

### Number of supported utilization clamp buckets

`CONFIG_UCLAMP_BUCKETS_COUNT`

uclamp 的统计桶数量；数量越高，精度越细，运行时状态和开销略增。

- 启动必需：否。
- 依赖：`CONFIG_UCLAMP_TASK=y`。
- 建议：不开 uclamp 时不写；启用时先使用 Kconfig 默认 `5`，确认需要更细粒度再调高。

---

## 2.11 Control Group support

### Control Group support

`CONFIG_CGROUPS`

cgroup 总开关。

- 启动必需：否。
- 需要场景：Android、systemd 资源管理、Docker、Podman、Kubernetes、服务资源隔离。
- 普通单应用 BusyBox 产品：通常关闭。

以下 controller 均不是启动必需：

| 菜单项 | 配置 | 使用场景 |
|---|---|---|
| Memory controller | `CONFIG_MEMCG` | 内存限额、Android、容器。 |
| IO controller | `CONFIG_BLK_CGROUP` | 块设备 IO 分组和限速。 |
| CPU controller | `CONFIG_CGROUP_SCHED` | CPU 权重和带宽管理。 |
| CPU bandwidth provisioning | `CONFIG_CFS_BANDWIDTH` | cgroup CPU 配额。 |
| Group scheduling for SCHED_RR/FIFO | `CONFIG_RT_GROUP_SCHED` | RT 任务组带宽控制。 |
| Utilization clamping per group | `CONFIG_UCLAMP_TASK_GROUP` | Android/uclamp cgroup 策略。 |
| PIDs controller | `CONFIG_CGROUP_PIDS` | 容器限制进程数量。 |
| RDMA controller | `CONFIG_CGROUP_RDMA` | RDMA 系统。 |
| Freezer controller | `CONFIG_CGROUP_FREEZER` | cgroup v1 冻结任务。 |
| HugeTLB controller | `CONFIG_CGROUP_HUGETLB` | HugeTLB 页资源限制。 |
| Cpuset controller | `CONFIG_CPUSETS` | CPU 核绑定、Android、容器。 |
| Device controller | `CONFIG_CGROUP_DEVICE` | 容器设备白名单。 |
| Simple CPU accounting controller | `CONFIG_CGROUP_CPUACCT` | 统计 cgroup CPU 使用量。 |
| Perf controller | `CONFIG_CGROUP_PERF` | perf 按 cgroup 统计。 |
| eBPF programs attached to cgroups | `CONFIG_CGROUP_BPF` | BPF cgroup 网络/安全策略。 |
| Misc resource controller | `CONFIG_CGROUP_MISC` | 杂项资源控制。 |
| Debug controller | `CONFIG_CGROUP_DEBUG` | cgroup 开发调试。 |

---

## 2.12 Namespaces support

### Namespaces support

`CONFIG_NAMESPACES`

Linux namespace 总开关。

- 启动必需：否。
- 适用：容器、沙箱、隔离服务。
- 普通单一产品应用：可关闭。

| 菜单项 | 配置 | 用途 |
|---|---|---|
| UTS namespace | `CONFIG_UTS_NS` | 容器独立 hostname/domainname。 |
| TIME namespace | `CONFIG_TIME_NS` | 容器独立 boottime/monotonic 时间视图。 |
| IPC namespace | `CONFIG_IPC_NS` | 容器独立 SysV IPC/POSIX mqueue。 |
| User namespace | `CONFIG_USER_NS` | rootless 容器、UID 映射。 |
| PID Namespaces | `CONFIG_PID_NS` | 容器独立 PID 视图。 |
| Network namespace | `CONFIG_NET_NS` | 容器独立网络栈。 |
| Checkpoint/restore support | `CONFIG_CHECKPOINT_RESTORE` | CRIU 等进程迁移/恢复。 |

`CONFIG_USER_NS` 在无明确需求时不建议开启，因为它扩大权限隔离相关攻击面。

---

## 2.13 其余运行时与启动项

### Automatic process group scheduling

`CONFIG_SCHED_AUTOGROUP`

面向桌面交互负载自动创建调度任务组。

- 启动必需：否。
- RK3399 固定嵌入式产品：通常不需要。

### Enable deprecated sysfs features to support old userspace tools

`CONFIG_SYSFS_DEPRECATED`

兼容非常老的 sysfs 布局。

- 启动必需：否。
- 建议：关闭。

### Kernel-to-user space relay support

`CONFIG_RELAY`

高效把内核大量数据导出到用户态，部分 tracing/debug 机制使用。

- 启动必需：否。
- 建议：按 tracing 或驱动需求决定。

### Initial RAM filesystem and RAM disk (initramfs/initrd) support

`CONFIG_BLK_DEV_INITRD`

允许 bootloader 将 initramfs/initrd 交给内核，在挂载实际 rootfs 前运行早期用户态。

- 启动必需：取决于启动方案。
- 必须保留：Android ramdisk、initramfs、FIT 内嵌 ramdisk，或早期必须加载存储/rootfs 模块的系统。
- 可关闭：内核内建所有根文件系统驱动，U-Boot 直接传入 eMMC/NVMe/SATA 分区 `root=`，且不使用 initramfs/initrd。
- 当前建议：在启动介质和 rootfs 方案明确前不删除。

### Boot config support

`CONFIG_BOOT_CONFIG`

从 initramfs 尾部读取 bootconfig，作为传统内核命令行扩展。

- 启动必需：否。
- 适用：Android 新版启动链或明确使用 bootconfig 的系统。
- 普通 Linux 建议：不加。

### Preserve cpio archive mtimes in initramfs

`CONFIG_INITRAMFS_PRESERVE_MTIME`

保留 initramfs cpio 项中的时间戳。

- 启动必需：否。
- 依赖：使用 initramfs 时才有意义。
- 建议：默认即可。

### Compiler optimization level

| 选项 | 配置 | 建议 |
|---|---|---|
| Optimize for performance (`-O2`) | `CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE` | 默认且建议保留。 |
| Optimize for size (`-Os`) | `CONFIG_CC_OPTIMIZE_FOR_SIZE` | 极端空间受限时再测试。 |

- 启动必需：二选一。
- 建议：使用默认 `-O2`，不显式写入。

### Dead code and data elimination (EXPERIMENTAL)

`CONFIG_LD_DEAD_CODE_DATA_ELIMINATION`

链接时用 `--gc-sections` 回收未引用代码和数据。

- 启动必需：否。
- 风险：内核标记为实验特性，缺少必要保留标记时可能静默裁掉实际入口。
- 建议：产品首版不启用。

---

## 2.14 Configure standard kernel features (expert users)

`CONFIG_EMBEDDED=y` 会自动选择 `CONFIG_EXPERT=y`，从而使一些通常隐藏的标准内核功能可被关闭。

`CONFIG_EMBEDDED` 不等同于自动优化嵌入式系统；它只是开放更多可能破坏标准 Linux ABI 的配置项。

### 建议保留默认值的标准 Linux 能力

| 菜单项 | 配置 | 原因 |
|---|---|---|
| Multiple users, groups and capabilities support | `CONFIG_MULTIUSER` | 标准 Linux 权限模型。 |
| Posix Clocks & timers | `CONFIG_POSIX_TIMERS` | 现代用户态常用。 |
| Enable support for printk | `CONFIG_PRINTK` | 故障诊断基础。 |
| BUG() support | `CONFIG_BUG` | 避免静默忽略严重内核错误。 |
| Enable full-sized data structures for core | `CONFIG_BASE_FULL` | 正常数据结构规模与性能。 |
| Enable futex support | `CONFIG_FUTEX` | glibc/pthread 实际依赖。 |
| Enable eventpoll support | `CONFIG_EPOLL` | 现代事件循环基础。 |
| Enable signalfd system call | `CONFIG_SIGNALFD` | systemd/事件框架常用。 |
| Enable timerfd system call | `CONFIG_TIMERFD` | 现代事件循环常用。 |
| Enable eventfd system call | `CONFIG_EVENTFD` | systemd、异步框架常用。 |
| Use full shmem filesystem | `CONFIG_SHMEM` | tmpfs、POSIX shared memory 等依赖。 |
| Enable madvise/fadvise syscalls | `CONFIG_ADVISE_SYSCALLS` | 普通应用可能使用。 |
| Enable membarrier syscall | `CONFIG_MEMBARRIER` | 部分运行时、JIT、数据库使用。 |
| Enable rseq syscall | `CONFIG_RSEQ` | 新版用户态运行时可能使用。 |

这些项目多数已有 Kconfig 默认 `y`，因此干净 defconfig 中通常无需手工写入。

### 按需求保留的标准能力

| 菜单项 | 配置 | 建议 |
|---|---|---|
| Enable 16-bit UID system calls | `CONFIG_UID16` | ARM64 通常无需关注。 |
| Sysfs syscall support | `CONFIG_SYSFS_SYSCALL` | 遗留兼容，默认即可。 |
| open by fhandle syscalls | `CONFIG_FHANDLE` | NFS、文件服务或部分容器需求。 |
| Enable ELF core dumps | `CONFIG_ELF_CORE` | 开发阶段建议保留，量产可评估关闭。 |
| Enable AIO support | `CONFIG_AIO` | 数据库/异步 IO 程序需求。 |
| Enable IO uring support | `CONFIG_IO_URING` | 新版高性能应用需求。 |
| Load all symbols for debugging | `CONFIG_KALLSYMS` | 开发和现场故障定位建议保留。 |
| Include all symbols in kallsyms | `CONFIG_KALLSYMS_ALL` | 一般关闭，会明显增大镜像。 |
| Enable kcmp syscall | `CONFIG_KCMP` | CRIU 等特殊需求。 |
| PC/104 support | `CONFIG_PC104` | RK3399 产品通常关闭。 |

---

## 2.15 Kernel Performance Events And Counters

### Kernel performance events and counters

`CONFIG_PERF_EVENTS`

支持 `perf` 工具与 ARM PMU 性能计数器。

- 启动必需：否。
- 开发阶段：建议保留，便于 `perf stat`、`perf record`。
- 量产极简镜像：可关闭。

### Debug: use vmalloc to back perf mmap() buffers

`CONFIG_DEBUG_PERF_USE_VMALLOC`

perf/vmalloc 调试功能。

- 启动必需：否。
- 建议：关闭。

### Profiling support

`CONFIG_PROFILING`

启用扩展 profiling 机制，通常会带动 `PERF_EVENTS`。

- 启动必需：否。
- 建议：开发版保留；量产版根据是否需要现场性能分析决定。

### Rust support

`CONFIG_RUST`

允许内核和外部模块使用 Rust。

- 启动必需：否。
- 当前 RK3399 BSP：通常关闭。
- 建议：不写，采用默认关闭。

---

# 3. General setup 的启动必需项总结

严格来看，用户可见菜单中真正必须有有效选择的项目只有以下几类，且大部分可交给 Kconfig 默认处理：

1. Kernel compression mode：必须选择一种压缩格式；
2. Preemption Model：必须选择一种调度抢占模型；
3. Timer / HZ：必须存在有效的时钟 tick 策略与 HZ 选择；
4. Compiler optimization level：必须选择 `-O2` 或 `-Os`；
5. `CONFIG_BLK_DEV_INITRD`：仅在启动方案使用 initramfs/initrd 时必需。

以下是标准 Linux 用户态强烈建议保持默认启用的能力，但干净 defconfig 无需显式写入：

```text
CONFIG_MULTIUSER=y
CONFIG_POSIX_TIMERS=y
CONFIG_PRINTK=y
CONFIG_BUG=y
CONFIG_BASE_FULL=y
CONFIG_FUTEX=y
CONFIG_EPOLL=y
CONFIG_SIGNALFD=y
CONFIG_TIMERFD=y
CONFIG_EVENTFD=y
CONFIG_SHMEM=y
```

当前后续决策时需优先确认：

1. 产品是否使用 initramfs/ramdisk 启动；
2. 用户态是 BusyBox、systemd Linux、Android 还是容器系统；
3. 是否需要 Docker/Podman/Kubernetes 或应用沙箱；
4. 是否需要 eBPF、`perf` 或现场性能分析；
5. 是否有 CPU 核隔离、低延迟或实时任务需求。

---

# 4. Kernel type / Kernel Features（ARM64）

`General setup` 之后的 ARM64 顶层菜单在源码中称为 `Kernel Features`，在 menuconfig 中通常也表现为 Kernel type 或 ARM64 内核特性相关配置。该部分决定 SoC 平台、页表格式、CPU 数量、AArch32 兼容、CPU 勘误与 ARM 架构扩展。

## 4.1 Platform selection

### Rockchip Platforms

`CONFIG_ARCH_ROCKCHIP`

启用 Rockchip ARM64 平台支持，带出 Rockchip 的时钟、复位、pincontrol、电源域和相关平台基础设施。

- 启动必需：**是**，RK3399 必须启用。
- 产品配置：

```text
CONFIG_ARCH_ROCKCHIP=y
```

`Platform selection` 下其他厂商 SoC 项（Allwinner、Amlogic、MediaTek、NXP、Qualcomm、Samsung、TI 等）均不属于 RK3399 产品内核需求，干净 defconfig 不应主动选择。

## 4.2 ARM errata workarounds

该子菜单含大量 Cortex、Neoverse、Cavium 等 CPU 勘误规避代码。

- 启动必需：否；但针对实际 CPU revision 的勘误项可能影响稳定性或数据正确性。
- RK3399 CPU：`2 × Cortex-A72 + 4 × Cortex-A53`。
- 原则：**不要把不适用其他 CPU 的勘误逐项显式写为 `n`**；干净 defconfig 中只在已经由硬件 revision、芯片勘误文档和现网验证确认需要时显式保留对应项。

需要重点评估的 RK3399 相关项包括：

| 配置 | 对象 | 说明 | 建议 |
|---|---|---|---|
| `ARM64_ERRATUM_826319` | Cortex-A53 | 特定早期 A53 cache/interconnect 死锁 | 仅确认 CPU revision 受影响时保留。 |
| `ARM64_ERRATUM_827319` | Cortex-A53 | 特定 CHI interconnect cache 事务问题 | RK3399 不应仅因名称含 A53 而盲目启用。 |
| `ARM64_ERRATUM_824069` | Cortex-A53 | 特定 coherent interconnect cache 状态问题 | 按 revision/互连确认。 |
| `ARM64_ERRATUM_819472` | Cortex-A53 | 特定 exclusive 操作可能数据错误 | 按 revision 确认。 |
| `ARM64_ERRATUM_1742098` | Cortex-A72 | AArch32 AES 指令中断相关问题 | 仅 `COMPAT=y` 且芯片受影响时考虑。 |
| `ARM64_ERRATUM_845719` | Cortex-A53 | AArch32 用户态 load 可能返回错误数据 | 仅 `COMPAT=y` 且芯片受影响时考虑。 |
| `ARM64_ERRATUM_1319367` | Cortex-A72 | speculative AT / TLB 问题，主要与虚拟化上下文有关 | 不使用 KVM 时价值有限，按上游/BSP 建议确认。 |

其余 A55、A57、A76、A77、A510、A520、A710、Neoverse、Ampere、Cavium 等条目不对应 RK3399。它们的 Kconfig `default y` 多用于通用 ARM64 内核；是否编译支持与启动时是否实际打补丁是两回事。固定 RK3399 产品配置可保持精简，不需要把每一项都复制进 defconfig。

## 4.3 Page size

| 菜单项 | 配置 | RK3399 建议 |
|---|---|---|
| 4KB | `CONFIG_ARM64_4K_PAGES` | **使用默认，推荐。** 与常见 ARM64 Linux 用户态和 32 位兼容最好。 |
| 16KB | `CONFIG_ARM64_16K_PAGES` | 不建议；会影响 AArch32 ELF 段对齐和部分用户态兼容性。 |
| 64KB | `CONFIG_ARM64_64K_PAGES` | 不建议；对小内存碎片、驱动 DMA 缓冲和用户态兼容性需完整验证。 |

- 启动必需：必须三选一。
- 产品决策：采用默认 4KB，但干净 defconfig 不必显式写入。

## 4.4 Virtual / Physical address space 与字节序

| 选项 | 默认 | RK3399 建议 |
|---|---|---|
| Virtual address space size | 4KB 页时默认 `39-bit` | 保持默认。RK3399 不需要 48/52-bit VA。 |
| Physical address space size | `48-bit` | 保持默认；RK3399 实际物理地址能力远低于 48-bit。 |
| Endianness | little-endian | 保持 `CPU_LITTLE_ENDIAN` 默认。 |

- 启动必需：每个 choice 都必须有一个有效值。
- 干净 defconfig：不显式写，避免无必要固定内部实现参数。

## 4.5 Scheduler topology、CPU 上限与热插拔

### Multi-core scheduler support

`CONFIG_SCHED_MC`

使调度器感知多核拓扑并优化任务放置。

- 启动必需：否。
- RK3399 建议：可保留。RK3399 是六核 big.LITTLE SoC，代价很小。

### Cluster / SMT scheduler support

`CONFIG_SCHED_CLUSTER`、`CONFIG_SCHED_SMT`

- `SCHED_CLUSTER`：对共享中间/末级缓存的 cluster 拓扑优化，是否有效取决于调度域描述与产品测试。
- `SCHED_SMT`：用于同时多线程 CPU；RK3399 无 SMT，不需要。

### Maximum number of CPUs

`CONFIG_NR_CPUS`

表示内核支持的 CPU 数量上限，不是当前实际物理核数量。

- RK3399 实际：6 核。
- 原 BSP：`CONFIG_NR_CPUS=8`。
- 启动必需：需要有效值，但 Kconfig 默认 `256` 也能启动。
- 产品建议：当前不在干净 defconfig 中写入，先使用默认值；若后续需要固定内存占用并确认只有 RK3399，可按产品决策设为 `6` 或保守保留 `8`。不能把它误解为必须等于物理核数。

### Support for hot-pluggable CPUs

`CONFIG_HOTPLUG_CPU`

允许通过 sysfs 使 CPU online/offline，并被 suspend、某些 cpuidle/cpufreq 和电源策略使用。

- 启动必需：否。
- RK3399 建议：若使用系统 suspend、big.LITTLE 核管理或 Android 电源策略，通常保留；固定高性能 Linux 设备且不下线 CPU 时可评估关闭。

### NUMA

`CONFIG_NUMA`

RK3399 为 UMA 单内存节点系统。

- 启动必需：否。
- 产品建议：关闭/不写。

## 4.6 HZ、虚拟化、kexec 和安全基础

### Timer frequency

`CONFIG_HZ_100`、`CONFIG_HZ_250`、`CONFIG_HZ_300`、`CONFIG_HZ_1000`

- 启动必需：是，必须选择一个。
- 建议：先使用 Kconfig 默认；不要为“精简”而改动。实时/音视频产品要结合调度延迟实测决定。

### Paravirtualization / Xen / KVM

`CONFIG_PARAVIRT`、`CONFIG_XEN`、`CONFIG_KVM`

- 启动必需：否。
- RK3399 作为普通裸机 Linux：不需要。
- 仅在 RK3399 运行 Xen guest、KVM 虚拟机或需要虚拟化宿主能力时启用。

### kexec / crash dump

`CONFIG_KEXEC`、`CONFIG_KEXEC_FILE`、`CONFIG_CRASH_DUMP`

- 启动必需：否。
- 适用：无固件重启、kdump 崩溃转储、受控升级。
- 产品建议：无现场 crash kernel 方案时不加。

### KPTI、Spectre、RODATA 和 tagged ABI

`CONFIG_UNMAP_KERNEL_AT_EL0`、`CONFIG_MITIGATE_SPECTRE_BRANCH_HISTORY`、`CONFIG_RODATA_FULL_DEFAULT_ENABLED`、`CONFIG_ARM64_TAGGED_ADDR_ABI`

这些均为默认安全/ABI行为，固定 RK3399 产品不应为了缩小配置盲目关闭。

- 启动必需：否。
- 建议：让 Kconfig 默认值决定；安全评估后才做显式覆盖。

## 4.7 32-bit EL0 compatibility

### Kernel support for 32-bit EL0

`CONFIG_COMPAT`

允许 ARM64 内核运行 AArch32 用户态程序。

- 启动必需：否。
- 需要：系统内有 32 位 ARM 可执行文件、32 位闭源库或旧 Android userspace。
- 不需要：根文件系统及所有应用均为 aarch64。
- 产品建议：不要预设；待确认用户态架构后决定。

`CONFIG_COMPAT=y` 时会带出 `KUSER_HELPERS`、`COMPAT_VDSO` 和旧 AArch32 指令模拟等子项。若决定不支持 32 位用户态，整个 `COMPAT` 子菜单均无需进入产品配置。

## 4.8 Deprecated ARMv8 instruction emulation

`CONFIG_ARMV8_DEPRECATED`、`CONFIG_SWP_EMULATION`、`CONFIG_CP15_BARRIER_EMULATION`、`CONFIG_SETEND_EMULATION`

用于运行包含废弃 AArch32 指令的旧软件。

- 启动必需：否。
- 依赖：通常仅在 `CONFIG_COMPAT=y` 时有意义。
- 产品建议：仅在需要兼容遗留 32 位二进制时保留；纯 64 位产品不需要。

## 4.9 ARMv8.x architecture extensions

主要包括 `ARM64_HW_AFDBM`、`ARM64_PAN`、LSE atomics、RAS、CNP、PAC、AMU、TLBI range、BTI、E0PD、MTE、SVE/SME 等。

- 启动必需：否。
- RK3399：Cortex-A53/A72 属于早期 ARMv8-A，不能使用 PAC、AMU、TLBI range、BTI、E0PD、MTE、SVE/SME 等较新扩展。
- 处理原则：这些支持项默认 `y` 时通常会在运行时检测 CPU feature register，硬件不支持便不启用；因此它们并非启动错误来源。
- 干净 defconfig 建议：不为这些通用默认项逐条写 `is not set`；除非产品要求严格锁定配置、或工具链/固件因某个扩展导致构建或启动问题。

---

# 5. Boot options

## 5.1 ARM64 ACPI parking protocol

`CONFIG_ARM64_ACPI_PARKING_PROTOCOL`

仅对通过 ACPI parking protocol 启动辅助 CPU 的 ARM64 服务器平台有效。

- 启动必需：否。
- RK3399 DT/PSCI 启动：不需要。

## 5.2 Default kernel command string

`CONFIG_CMDLINE`

编译进内核的默认 command line。

- 启动必需：否；正常由 U-Boot 传递 `bootargs`。
- 产品建议：保持空，避免把 `root=`、console、分区等板级策略写死在通用内核配置。

若设置 `CMDLINE`，还需选择：

| 配置 | 含义 | 建议 |
|---|---|---|
| `CMDLINE_FROM_BOOTLOADER` | 有 bootloader 参数则使用它，否则退回默认字符串 | 推荐。 |
| `CMDLINE_FORCE` | 忽略 bootloader 参数，强制使用内建字符串 | 仅受控封闭启动链才考虑。 |

## 5.3 UEFI runtime support 与 DMI

`CONFIG_EFI`、`CONFIG_DMI`

- 启动必需：否。
- RK3399 常规 U-Boot + Device Tree：不需要。
- 只有板子采用 UEFI 启动、需要 EFI variable/runtime service 或 SMBIOS/DMI 时才启用。

---

# 6. Power management options 与 CPU Power Management

## 6.1 System suspend / hibernation

| 配置 | 含义 | 启动必需 | RK3399 产品建议 |
|---|---|---|---|
| `SUSPEND` | Suspend-to-RAM / standby | 否 | 需要待机/低功耗恢复时保留。 |
| `HIBERNATION` | Suspend-to-disk，依赖 swap | 否 | 嵌入式 RK3399 通常不需要。 |
| `PM_AUTOSLEEP` | 内核无 wakeup source 时自动全局睡眠 | 否 | Android 或严格电源管理系统才考虑。 |
| `PM_USERSPACE_AUTOSLEEP` | 为 Android 类频繁用户态 autosleep 优化 | 否 | 非 Android 不要启用。 |
| `PM_WAKELOCKS` | 用户态 wake lock sysfs 接口 | 否 | Android/特定用户态电源管理需要。 |
| `PM_DEBUG` / `PM_ADVANCED_DEBUG` | PM 调试属性 | 否 | 开发期可留，量产可关。 |

`SUSPEND=y` 会通过 `PM_SLEEP_SMP` 选择 CPU hotplug 等能力；因此电源管理裁剪必须和实际 suspend/resume 测试一起进行，不能只看镜像体积。

## 6.2 Device power management core

`CONFIG_PM`

提供设备 runtime PM、设备 suspend/resume、电源域等通用框架。

- 启动必需：对纯理论最小系统不是；但 `ARCH_ROCKCHIP` 会选择 PM，RK3399 绝大多数驱动和电源域需要。
- 产品建议：保留其自动选择结果，不手动关闭。

## 6.3 CPU idle

典型配置：`CONFIG_CPU_IDLE`、`CONFIG_ARM_PSCI_CPUIDLE`。

- 启动必需：否。
- RK3399 建议：保留。它允许空闲 CPU 进入 PSCI 控制的低功耗状态，降低待机功耗。
- 仅在调试早期 suspend/idle 问题时可临时关闭排障，不能作为常规裁剪。

## 6.4 CPU frequency

典型配置：`CONFIG_CPU_FREQ`、`CONFIG_CPUFREQ_DT`、`CONFIG_ARM_ROCKCHIP_CPUFREQ` 和 governors。

| 配置 | 作用 | 建议 |
|---|---|---|
| `CPU_FREQ` | cpufreq 总开关 | RK3399 产品通常保留。 |
| `CPUFREQ_DT` | 按设备树 OPP 表调频 | RK3399 通常需要。 |
| `ARM_ROCKCHIP_CPUFREQ` | Rockchip cpufreq 协同驱动 | 按当前 BSP DTS/驱动实际依赖保留。 |
| `CPU_FREQ_STAT` | 导出调频统计 | 非必需，调试/性能分析时保留。 |
| powersave/userspace/ondemand/conservative/interative/schedutil governors | 调频策略 | 只保留产品实际使用的 governor。 |

启动必需性：CPU 能以固定频率运行，所以 cpufreq 不是启动必需；但对 RK3399 的性能、功耗、温度行为影响非常大。后续需根据产品选择 governor，而不是一次性保留所有 BSP governor。

---

# 7. Memory Management options

## 7.1 Swap 与 zswap

| 配置 | 含义 | 建议 |
|---|---|---|
| `SWAP` | swap 分区/文件支持 | 有 swap 或需要 hibernation 时保留；否则可关闭。 |
| `ZSWAP` | swap 页的压缩内存缓存 | 仅启用 swap 且内存压力策略需要时评估。 |
| `ZRAM` | 压缩 RAM block device（位于 Device Drivers） | Android/低内存系统常用；与 zswap 是不同方案。 |

`SWAP` 不是 initramfs 启动必需。若使用 hibernation，则 `SWAP=y` 和有效 resume 分区是必要条件。

## 7.2 SLAB allocator

`SLAB`、`SLUB`、`SLOB` 三选一。

- 启动必需：是。
- 默认：`SLUB`。
- RK3399 建议：保持 `SLUB` 默认；不要为极小体积盲选 SLOB，后者性能和兼容性代价明显。

## 7.3 Memory model 与稀疏内存

ARM64 会自动选择适合的 sparse memory/vmemmap 机制。

- 启动必需：底层内存模型必需。
- 产品建议：不手动写内部 `SPARSEMEM_*` 项。

## 7.4 Contiguous Memory Allocator

`CONFIG_CMA`

为需要连续物理内存的设备预留/分配 CMA 区域。

- 启动必需：不绝对。
- RK3399 常见依赖：DRM 显示、VPU 编解码、Camera、部分 DMA 外设。
- 建议：只要产品有 MIPI DSI/显示、视频编解码或摄像头，通常应保留；具体 CMA 大小通过设备树 `linux,cma` 或 kernel command line 决定。

## 7.5 Transparent Hugepage、hugetlb 与 memory hotplug

| 配置类别 | 启动必需 | 建议 |
|---|---|---|
| `TRANSPARENT_HUGEPAGE` | 否 | 数据库/大内存性能需求再评估；嵌入式可关闭或运行时禁用。 |
| `HUGETLBFS` / HugeTLB | 否 | 专用大页应用才需要。 |
| `MEMORY_HOTPLUG` | 否 | RK3399 固定内存板通常关闭。 |
| `MEMORY_FAILURE` | 否 | 服务器 RAS 场景，普通 RK3399 不需要。 |
| `DAMON` | 否 | 内存访问监控/调优需求才开。 |

---

# 8. Networking support

## 8.1 Networking support 总开关

`CONFIG_NET`

- 启动必需：否。
- 产品建议：只要存在以太网、Wi-Fi、蓝牙网络、USB 网络、PCIe NTB 虚拟网卡、NFS rootfs 或网络管理，就必须保留。

## 8.2 基础 socket 协议

| 配置 | 含义 | 建议 |
|---|---|---|
| `PACKET` | AF_PACKET 原始报文 socket | 抓包、DHCP、部分网络工具需要；一般保留。 |
| `UNIX` | AF_UNIX 本地 socket | 标准 Linux 用户态强烈建议保留。 |
| `INET` | IPv4 协议栈 | 普通网络产品必需。 |
| `IPV6` | IPv6 协议栈 | 取决于网络要求；现代产品通常建议保留。 |
| `TLS` | kTLS | 高性能 TLS offload 场景才需要。 |
| `XFRM` / `NET_KEY` | IPsec/XFRM | IPsec/VPN 才需要。 |

## 8.3 IPv4 / IPv6 子菜单

IPv4 下按需求选择：DHCP 使用的基础 IP/UDP/TCP、路由、组播、IPsec、策略路由、隧道等。IPv6 同理。

- `IP_MULTICAST`：组播发现、音视频组播或特定工业协议需要。
- `IP_ADVANCED_ROUTER`：设备作为路由器、多路由表/策略路由时需要。
- `IP_MROUTE`：组播路由器才需要。
- `SYN_COOKIES`：公网 TCP 服务安全建议保留。
- 各种 tunnel（SIT、GRE、VXLAN、GENEVE、WireGuard 等）：只保留产品明确使用的协议。

## 8.4 Netfilter / firewall / NAT

`CONFIG_NETFILTER` 是防火墙、NAT、conntrack 的总开关。

- 启动必需：否。
- 需要：iptables/nftables、防火墙、Docker 网络、路由/NAT 网关。
- 普通单网口终端：可不启用，显著减少大量 `NETFILTER_XT_*` 项。

若需要 netfilter，优先根据用户态实际使用 `iptables-legacy`、iptables-nft 或 nftables 选择最小集合；不要沿用 BSP 中所有 match/target 模块。

## 8.5 L2 与网络设备功能

| 功能 | 典型配置 | 需要场景 |
|---|---|---|
| Bridge | `BRIDGE` | 双口桥接、Docker、软件交换。 |
| VLAN | `VLAN_8021Q` | 802.1Q VLAN。 |
| Traffic control | `NET_SCHED` | QoS、限速、tc。 |
| CAN | `CAN` | 有 CAN/CAN-FD 外设。 |
| Bluetooth | `BT` | 有蓝牙模块。 |
| Wireless | `WLAN` / `CFG80211` / `MAC80211` | Wi-Fi。 |
| PPP/L2TP | 对应协议 | 蜂窝拨号/VPN。 |
| Open vSwitch | `OPENVSWITCH` | SDN/虚拟化。 |
| MPTCP | `MPTCP` | 多链路 TCP。 |

网络协议栈与具体网卡 MAC/PHY、Wi-Fi/BT 驱动分属后续 `Device Drivers` 菜单，必须一起按硬件清单配置。

---

# 9. Device Drivers：按层次的产品裁剪方法

`Device Drivers` 是最大菜单。这里不应以“全部关闭后逐个补回”的方式直接生成产品配置；应先从硬件原理图、DTS、启动链和用户态服务得到设备清单，再按以下层次选择。

## 9.1 必须的基础设备模型

| 类别 | 典型配置 | 必要性 |
|---|---|---|
| Device Tree | `OF` 等 | ARM64/RK3399 启动必需，多数由架构选择。 |
| Pin control | Rockchip pinctrl | `ARCH_ROCKCHIP` 自动关联，板级外设必需。 |
| GPIO | `GPIOLIB`、Rockchip GPIO | 复位、使能、中断、按键等常用。 |
| Clock / reset / regulator / power domain | Rockchip CRU、reset、regulator、genpd | RK3399 外设驱动运行必需。 |
| devtmpfs | `DEVTMPFS`、`DEVTMPFS_MOUNT` | 标准 initramfs/用户态强烈建议。 |

大部分基础符号会被平台驱动选择，不应手工填内部 `HAVE_*`、`ARCH_*` 或 `*_CORE` 项。

## 9.2 启动存储链

因为本产品依赖 initramfs，仍需确认 initramfs 后切换真实 rootfs 所需的存储栈。

| 根文件系统位置 | 典型必需驱动类别 |
|---|---|
| eMMC | MMC block、DW MMC/Rockchip host、分区表、目标文件系统。 |
| SD 卡 | SDHCI/DW MMC、MMC block、分区表、目标文件系统。 |
| SPI-NOR/NAND | MTD、SPI controller、SPI NOR/NAND、UBI/UBIFS 或对应文件系统。 |
| NVMe | PCI、Rockchip PCIe host、NVMe core、目标文件系统。 |
| SATA | AHCI/SATA host、SCSI disk、目标文件系统。 |
| NFS root | Ethernet MAC/PHY、IP、NFS client、RPC、root= 参数。 |

关键规则：**若 initramfs 内的 `/init` 需要访问某个真实 rootfs 驱动，首阶段应将该驱动内建为 `y`，不要依赖尚未挂载 rootfs 中的模块。**

## 9.3 总线与外设

- PCI/PCIe：仅产品使用 PCIe endpoint、NVMe、网卡、采集卡或其他 PCIe 设备时保留；RC 与 EP 角色的配置不同。
- I2C：触摸、PMIC、传感器、EDID、摄像头等常用；依据 DTS 具体设备保留 controller 和 client driver。
- SPI：SPI flash、触摸、传感器、外置 ADC/DAC 等按原理图保留。
- UART：至少保留启动 console 所在控制器；其他 UART 按外设需求。
- USB：USB host/device/OTG、DWC3、Type-C、USB gadget 根据产品接口角色选择。
- PWM、ADC、RTC、watchdog、hwmon、thermal：按硬件和产品可靠性策略选择。

## 9.4 多媒体与显示

- DRM/KMS、Rockchip VOP、MIPI DSI、panel/bridge、backlight、PHY：产品有 MIPI DSI 显示时需要。
- V4L2、Rockchip ISP、MIPI CSI、camera sensor：产品有摄像头时需要。
- VPU/RGA：视频编解码、图像缩放或 Android 多媒体链使用时需要。
- ALSA/ASoC：产品有音频 codec、HDMI audio、I2S/PDM 时需要。

这些必须与实际 DTS 的 `compatible`、`status = "okay"` 节点一一核对，不能只根据 SoC 能力选择。

---

# 10. File systems

## 10.1 根文件系统必须项

必须保留的文件系统取决于最终 rootfs：

| rootfs 格式 | 配置类别 |
|---|---|
| ext4 | `EXT4_FS` 与所需 JBD2。 |
| f2fs | `F2FS_FS`。 |
| UBIFS | `UBIFS_FS`、UBI、MTD。 |
| squashfs + overlay | `SQUASHFS`、`OVERLAY_FS`、底层可写文件系统。 |
| NFS root | `NFS_FS`、sunrpc、网络协议。 |

initramfs 本身不是通过此菜单的 ext4/f2fs 驱动挂载，而是内核解包 cpio；但 initramfs 中切换真实 rootfs 后，真实根文件系统驱动必须可用。

## 10.2 标准 pseudo filesystems

| 配置 | 建议 |
|---|---|
| `PROC_FS` | 标准 Linux 用户态几乎必需。 |
| `SYSFS` | 设备模型、电源、驱动管理几乎必需。 |
| `TMPFS` | `/tmp`、`/run`、共享内存等常用，建议保留。 |
| `DEVTMPFS` | 设备节点自动创建，建议保留。 |
| `CONFIGFS_FS` | 仅 gadget、PCI endpoint configfs、部分动态内核对象需要。 |
| `DEBUG_FS` | 开发调试建议保留，量产安全策略再评估。 |

## 10.3 可移动介质与网络文件系统

FAT/exFAT/NTFS、ISO/UDF、NFS/CIFS/9P/FUSE/OverlayFS 等都不是启动必需。

- USB/SD 用户数据盘：按需保留 FAT/exFAT 或 ext4。
- Android/容器只读根：常见 squashfs/erofs/overlayfs。
- 用户态 FUSE 文件系统：保留 `FUSE_FS`。
- 网络挂载：按 NFS/CIFS 实际协议保留。

---

# 11. Security options

## 11.1 基础建议

- `KEYS`：模块签名、fscrypt、网络认证、可信 keyring 等功能可能依赖；按功能链自动选择为主。
- `SECCOMP`：应用沙箱、容器常用；普通终端可按需求。
- `SECURITY` / LSM：安全框架总开关，使用 SELinux/AppArmor/landlock 等时需要。

## 11.2 SELinux / AppArmor / Yama / Landlock

| 配置类别 | 适用场景 |
|---|---|
| SELinux | Android 常常必需；普通 Linux 需结合发行版策略。 |
| AppArmor | Ubuntu 类发行版常用。 |
| Yama | ptrace 等额外访问控制，通用 Linux 安全增强。 |
| Landlock | 应用自限制 sandbox，按用户态需求。 |

- 启动必需：均否。
- 产品原则：Android 不可擅自裁掉 SELinux 相关项；非 Android 不应无需求把所有 LSM 一起打开。

## 11.3 Integrity、module signature、verified boot

IMA/EVM、module signing、firmware signature、dm-verity/fs-verity 属于可信启动和完整性方案的一部分。

- 启动必需：仅当产品安全启动链明确要求时。
- 配置原则：必须与 U-Boot/ATF、镜像签名、rootfs 验证、密钥注入流程整体设计；不能单独只开某个内核选项。

---

# 12. Cryptographic API

`CONFIG_CRYPTO` 是算法与加密框架总开关。

- 启动必需：否。
- 下列需求会带出 crypto：dm-crypt、fscrypt、Wi-Fi、IPsec、TLS、Bluetooth、模块签名、verified boot、zswap 等。
- ARM64 crypto extensions：可使用 Cortex-A53/A72 的 AES/SHA/CRC 硬件指令优化；保留方式应由所选上层功能和 ARM64 crypto 子菜单的依赖自动决定。
- 干净产品配置：不为每一种算法盲目启用；从实际协议、加密存储与安全启动需求反推。

---

# 13. Library routines 与 Kernel hacking / Debug

## 13.1 Library routines

`Library routines` 多数是其他子系统自动选择的压缩、CRC、数学和 DMA helper。

- 启动必需：其中被依赖的项目必需。
- 产品建议：不手工裁剪通用库；先裁掉上层功能，Kconfig 会自然去除不再需要的库。

## 13.2 Kernel hacking / Debugging

调试、tracing、KASAN/KCSAN/KFENCE、lockdep、debugfs、ftrace、kprobe、kgdb、panic-on-warn 等一般不是产品启动必需。

建议分两套策略：

1. **开发/Bring-up 内核**：保留串口日志、KALLSYMS、debugfs、ftrace、必要的 DRM/V4L2/PCIe 调试项。
2. **量产内核**：在稳定后按安全和镜像大小策略关闭高开销 sanitizer、过多 tracing、调试写接口；但保留足够 Oops 符号、pstore 或现场诊断能力。

---

# 14. 后续生成产品 defconfig 的顺序

后续按 menuconfig 顶层菜单逐段填写，而不是把所有分析结论立即写入：

1. General setup：已确认 `CONFIG_BLK_DEV_INITRD=y`；
2. Kernel Features：下一步确认 `ARCH_ROCKCHIP`、页大小、COMPAT、SMP/CPU 上限和电源策略；
3. Boot options：确认 U-Boot command line 与是否需要 EFI；
4. Power/CPU Power：确认 suspend、cpuidle、cpufreq governor；
5. Memory Management：确认 CMA、swap、hugepage；
6. Networking：按实际网口/Wi-Fi/网关/容器需求；
7. Device Drivers：严格对照原理图和 DTS；
8. File systems：按 initramfs 后真实 rootfs 格式；
9. Security/Crypto/Debug：按产品安全与运维需求。

对于任何默认 `y` 的通用能力，除非有明确的产品理由覆盖默认值，否则不要在干净 defconfig 中重复写入；对于启动链、硬件驱动和根文件系统所需能力，则应显式记录和保留。

