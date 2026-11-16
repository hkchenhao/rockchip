# RK3399 共享串口

`serial_bridge.py` 独占真实串口，把开发板输出同时发给 CLion 虚拟串口和本地 Unix socket 客户端。两边的输入都进入同一个开发板控制台，使用时轮流输入命令。

## 启动

在 Mac 本地执行，先断开 CLion 对真实串口的连接：

```sh
cd /Volumes/Embedded/rockchip
python3 -m venv build/serial-venv
build/serial-venv/bin/python -m pip install pyserial==3.5
build/serial-venv/bin/python user/scripts/tools/serial_bridge.py
```

前两条环境准备命令只需首次执行。保持转发进程运行；Ctrl+C 停止。默认真实端口为 `/dev/cu.usbserial-11410`，物理波特率为 1500000；可用 `--port`、`--baud` 更改。

启动时输出 JSON，其中包含虚拟端口、PTY 实际路径、socket 路径和 PID。插拔 USB 串口适配器后需要重新启动转发进程；开发板普通重启不需要。

## 终端连接

在 Mac 本地终端（或 CLion 的 **Local** Terminal）执行：

```sh
screen -S rk3399-shared -h 5000 -fn /private/tmp/rk3399-serial/user.tty 115200
```

Ctrl+A 后按 D 可断开终端显示；重新进入使用 `screen -x rk3399-shared`。转发进程继续运行。若会话已存在，直接使用 `screen -x rk3399-shared`，不要再次启动。多个终端可以接入同一个 screen 会话，但不要重复开启多个直接读取同一个 PTY 的客户端，后者会争抢输出；agent 使用独立的 socket，不受影响。

## CLion Serial Connections 的限制

当前 CLion 2026.3 的插件会将不在系统枚举列表中的 PTY 标记为 `Port is unavailable`，因此不能直接使用此虚拟端口。手动添加连接配置的名称，并不会更改真正的 Port 字段；即使改正 Port 字段，也仍会遇到枚举检查。

已核对 [JetBrains 串口插件源码](https://github.com/JetBrains/intellij-plugins/blob/master/serial-monitor/src/main/java/com/intellij/plugins/serialmonitor/service/SerialPortService.kt)：`portStatus()` 对不在 `portNames` 中的端口返回 `UNAVAILABLE`。此前仅用 pyserial 验证了 PTY 收发，这不代表 CLion 插件支持 PTY。

下面的参数用于支持手动 PTY 路径的串口客户端：

- 端口：`/private/tmp/rk3399-serial/user.tty`，也可以使用启动 JSON 中的 `pty` 实际路径。
- 波特率：115200；数据位 8、校验 None、停止位 1、流控 None。
- 发送行结束符：CR。

虚拟端口没有物理时钟，客户端中的 115200 不会改变真实串口的 1500000。不要同时连接真实串口。客户端断开、重新连接虚拟端口不会停止转发进程。转发进程重启后 PTY 实际路径可能变化，`user.tty` 别名保持相同。

## 本地控制接口

客户端连接 `/private/tmp/rk3399-serial/agent.sock`，收发原始字节，命令以 `\r` 结尾。socket 只允许当前 Mac 用户访问，不监听 TCP 端口。

输出仅实时转发，不自动保存串口日志。输入共用同一个 shell，包括 Ctrl+C、登录和重启等操作。

## 验证

```sh
PYTHONDONTWRITEBYTECODE=1 build/serial-venv/bin/python -m unittest discover -s user/scripts/tools -p test_serial_bridge.py
```

测试使用模拟开发板的 PTY，覆盖输出广播、双方输入、断开重连以及退出清理，不操作真实开发板。
