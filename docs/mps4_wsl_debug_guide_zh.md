# MPS4 HPI-0376B 在 WSL2 下调试 Cortex-M85

本文记录 Arm MPS4 HPI-0376B、FI101 SSE-320 FPGA 镜像在 Windows + WSL2 环境下使用板载 DEBUG USB、pyOCD 和 GDB 调试 Cortex-M85 的流程。

## 已验证的环境

- 板卡：MPS4 HPI-0376B
- FPGA 镜像：FI101 / SSE-320 / Cortex-M85 / Ethos-U85
- 主机：Windows + WSL2
- 调试器：DEBUG USB 对应的板载 Arm MPS4 USB Debug（ULINKplus Embedded）
- pyOCD：0.45.1
- GDB：`arm-none-eabi-gdb`
- 调试协议：SWD
- 调试端口：3333

## 调试链路

```text
MPS4 DEBUG USB
        |
Windows usbipd-win
        |
WSL2 USB/IP
        |
pyOCD 0.45.1
        |
GDB Remote Server :3333
        |
arm-none-eabi-gdb / VS Code Cortex-Debug
```

DEBUG USB 不仅提供调试器，还提供多个串口和板卡配置存储访问。串口可以继续由 Windows 使用；调试器本身需要转接给 WSL。

## 一、准备板卡

1. 连接 MPS4 的 12V 电源。
2. 使用 DEBUG USB 连接主机。
3. 确认板卡已经加载 FI101 FPGA 镜像并启动。
4. 如需查看启动日志，可在 Windows 串口终端打开对应的 MCC 串口，设置为：

```text
115200 baud
8 数据位
无校验
1 停止位
无硬件/软件流控
```

在当前主机上，Windows 曾识别出 COM3～COM6；端口编号可能因重新插拔而变化。通常 Serial Port 0 用于 MCC，Serial Port 1 用于 FPGA UART0。

## 二、安装 WSL 工具

在 WSL Ubuntu/Debian 中执行：

```bash
sudo apt update
sudo apt install python3-venv libusb-1.0-0 usbutils

python3 -m venv ~/.venvs/mps4-debug
source ~/.venvs/mps4-debug/bin/activate
python -m pip install --upgrade pip pyocd

pyocd --version
arm-none-eabi-gdb --version
```

本文使用 pyOCD 0.45.1。以后打开新的 WSL 终端时，先激活虚拟环境：

```bash
source ~/.venvs/mps4-debug/bin/activate
```

## 三、把 DEBUG USB 转接给 WSL

在管理员 PowerShell 中查看设备：

```powershell
usbipd list
```

确认设备名称为 `Arm MPS4 USB Debug`，并记下对应的 BUSID。当前环境中曾显示为 `4-4`、`0d28:0310`，但 BUSID 可能变化，不能固定写死。

在管理员 PowerShell 中共享设备：

```powershell
usbipd bind --busid <BUSID>
```

然后在普通 PowerShell 中附加到 WSL：

```powershell
usbipd attach --wsl --busid <BUSID>
```

在 WSL 中验证：

```bash
lsusb -d 0d28:0310
```

如果设备只被 root 看到，暂时使用 `sudo` 启动 pyOCD。调试器附加到 WSL 后，Windows 不能同时使用这个 USB 调试器；结束调试后可在 PowerShell 执行：

```powershell
usbipd detach --busid <BUSID>
```

## 四、为什么不能直接使用通用 pyOCD 目标

FI101 的调试拓扑有两个特殊点：

1. DPv3 返回的 BASEPTR 原始值为 `0x00014001`。pyOCD 0.45.1 的通用解析路径将日志中的地址表现为 `0x14`，导致首次访问根 ROM 表失败。
2. FI101 BSP 明确给出 CPU AHB5-APv2 地址 `0x4000`，但 Class 9 ROM 表中的两个表项低位为 `01`。pyOCD 将它们视为非存在项，因此不会自动发现 CPU AP。

因此需要使用项目中的用户脚本完成两项板级适配：

- 将根 ROM 表地址修正为 `0x00014000`。
- 按 FI101 BSP 指定的 `0x4000` 显式探测 CPU AP。

适配脚本位于：

[scripts/debug/mps4/pyocd_fi101.py](../scripts/debug/mps4/pyocd_fi101.py)

## 五、启动调试服务器

项目提供了快捷脚本：

[scripts/debug/mps4/debug.sh](../scripts/debug/mps4/debug.sh)

在 WSL 终端 1 中执行：

```bash
cd /home/xx/alif_ml-embedded-evaluation-kit
./scripts/debug/mps4/debug.sh server
```

脚本会使用 sudo 访问 USB 调试器，并启动 pyOCD GDB Server。正常日志应包含类似内容：

```text
CPU core #0: Cortex-M85 r1p1, v8.1-M architecture
8 hardware watchpoints
8 hardware breakpoints
GDB server listening on port 3333
```

如果 USB 权限已经通过 udev 配置好，可以不使用 sudo：

```bash
MPS4_NO_SUDO=1 ./scripts/debug/mps4/debug.sh server
```

## 六、自己的程序需要开启调试访问

Selftest 会在 `main()` 一开始执行 FI101 的调试使能。自己的应用如果没有这一步，pyOCD 可能只能读到 DP ID，而在访问 CPU AP 时返回 `FAULT ACK`。

在 [source/app/main/Main.cc](../source/app/main/Main.cc) 中保留以下开关和初始化：

```cpp
#define MPS4_FI101_DEBUG_ENABLED 1

static void EnableMps4Debug()
{
    *reinterpret_cast<volatile std::uint32_t*>(0x5802125CUL) = 0xAAAAAAAAUL;
    *reinterpret_cast<volatile std::uint32_t*>(0x500A0100UL) = 0x00005555UL;
}
```

并在 `main()` 的第一步调用：

```cpp
#if MPS4_FI101_DEBUG_ENABLED
    EnableMps4Debug();
#endif
```

该代码使用 `<cstdint>` 中的 `std::uint32_t`。两个寄存器的作用分别是 FI101 调试认证使能和 `LCM_DCU_FORCE_DISABLE`，写法与随板 Selftest 的 `dbg_ena_sbrom()` 一致。

这段代码必须在 Secure 特权启动路径执行。如果应用已经切换到 Non-secure 状态，不能指望 Non-secure 代码直接写入这两个寄存器。调试开关只针对 MPS4 FI101，其他平台或不需要调试时改为：

```cpp
#define MPS4_FI101_DEBUG_ENABLED 0
```

修改后必须重新编译、重新部署并重启板卡，使程序实际执行到 `main()` 中的初始化；然后再启动 pyOCD：

```bash
./scripts/debug/mps4/debug.sh server
```

成功日志应继续出现：

```text
CPU core #0: Cortex-M85 r1p1, v8.1-M architecture
GDB server listening on port 3333
```

也可以直接启动 pyOCD，适合排查问题：

```bash
sudo ~/.venvs/mps4-debug/bin/pyocd gdbserver \
  --script scripts/debug/mps4/pyocd_fi101.py \
  --target cortex_m \
  --frequency 1000000 \
  --port 3333 \
  --persist \
  -O connect_mode=attach \
  -O dap_protocol=swd \
  -O dap_swj_use_dormant=true \
  -O auto_unlock=false \
  -vv
```

这里的 `connect_mode=attach` 必须完整输入，不能被截断成 `connect_`。第一次验证建议使用 1 MHz 调试时钟。

## 七、使用 GDB 调试

在 WSL 终端 2 中启动不带符号的 GDB：

```bash
cd /home/xx/alif_ml-embedded-evaluation-kit
./scripts/debug/mps4/debug.sh gdb
```

或者直接连接：

```bash
arm-none-eabi-gdb
```

在 GDB 中执行：

```gdb
target extended-remote localhost:3333
monitor halt
info registers pc sp lr
x/8i $pc
stepi
info registers pc
continue
```

成功标准：

- 能读取 `PC`、`SP`、`LR`。
- 能看到当前地址的反汇编。
- `stepi` 执行后 PC 发生变化。
- `continue` 后目标继续运行。
- 运行时按 GDB 的 `Ctrl+C` 能再次暂停目标。

## 八、加载源码和断点

需要使用与板上运行程序相同、且包含调试信息的 `.axf` 或 `.elf` 文件。启动方式：

```bash
./scripts/debug/mps4/debug.sh gdb /absolute/path/to/program.axf
```

连接后常用命令：

```gdb
break main
continue
next
step
print variable_name
bt
info locals
info breakpoints
delete 1
```

如果程序已经运行过 `main()`，此时再设置 `break main` 不会重新命中；可以设置到下一个会执行的函数，或者先执行：

```gdb
monitor reset halt
break main
continue
```

`monitor reset halt` 会复位并停在入口附近。除非确定 AXF 的内存布局和板上启动流程一致，否则初次调试不要直接执行 GDB 的 `load`，避免覆盖当前板上程序。

## 九、常用调试命令

| GDB 命令 | 用途 |
|---|---|
| `monitor halt` | 暂停 Cortex-M85 |
| `continue` | 继续运行 |
| `stepi` | 单步执行一条机器指令 |
| `next` | 单步执行一行源码，不进入函数 |
| `step` | 单步执行并进入函数 |
| `break func` | 设置源码断点 |
| `hbreak func` | 设置硬件断点 |
| `watch var` | 变量变化时暂停 |
| `info registers` | 查看寄存器 |
| `x/8i $pc` | 查看 PC 附近反汇编 |
| `bt` | 查看调用栈 |
| `monitor show fault` | 查看 Cortex-M 异常信息 |
| `detach` | 断开 GDB，保留目标运行 |

日志显示该目标有 8 个硬件断点和 8 个硬件观察点。硬件断点数量有限，设置过多时应删除不需要的断点。

## 十、VS Code 图形调试

如果希望使用图形界面，可以在 Windows 安装 VS Code，并安装：

- Remote Development / WSL
- Cortex-Debug

在 WSL 项目目录中打开 VS Code，让 Cortex-Debug 连接到已经启动的 `localhost:3333` GDB Server。初次配置建议使用“外部 GDB Server”模式，保持 pyOCD 服务器由上述脚本启动，这样会继续使用 FI101 专用用户脚本。

核心配置关系是：

```text
servertype: external
gdbTarget: localhost:3333
executable: 与板上程序匹配的 .axf/.elf
```

## 十一、常见问题

### `unknown session option 'connect_'`

说明命令行参数被截断。应使用完整参数：

```text
-O connect_mode=attach
```

### `DP IDR` 能读到，但出现 `FAULT ACK`

这表示 USB 调试器和 DP 已经建立通信，但访问根 ROM 表失败。确认使用了 `pyocd_fi101.py`，并且日志中出现：

```text
BASEPTR0 raw=0x00014001: root address 0x00000014 -> 0x00014000
```

### `No cores were discovered!`

说明根 ROM 表可访问，但通用 ROM 表解析没有找到 CPU AP。确认使用的是包含显式 `0x4000` CPU AP 探测的脚本。成功日志应包含：

```text
CPU AP IDR=0x54770008
CPU core #0: Cortex-M85 r1p1
```

### Windows 能看到设备，WSL 中 `lsusb` 看不到

重新执行 `usbipd list`，确认设备 BUSID；然后执行 `bind` 和 `attach`。BUSID 可能在重新插拔后变化。

### GDB 连接不上 3333

确认服务器终端仍显示：

```text
GDB server listening on port 3333
```

再检查端口：

```bash
ss -ltnp | rg ':3333'
```

### Selftest 或程序无响应

先在 Windows MCC 串口发送 `REBOOT`。FI101 应用说明也建议在 Selftest 进入不稳定状态时通过 MCC UART0 重启；如果 Selftest 菜单不出现，可按文档发送 `RESET_ON`，再发送 `RESET_OFF`。

## 参考资料

- [MPS4 FPGA Prototyping Board Technical Reference Manual](https://documentation-service.arm.com/static/669a306a43b8ec1e18652768)
- [Corstone SSE-320 FPGA Image for MPS4 Application Note](</mnt/c/Users/MC/Downloads/FI101_SSE320_M85_NPU_U85_MALI_C55_FPGA_MPS4_V1.0/Docs/arm_corstone_sse_320_fpga_image_for_mps4_application_note_109762_0100_01_en.pdf>)
- [pyOCD GDB Server 文档](https://pyocd.io/docs/gdbserver.html)
- [pyOCD Target Support 文档](https://pyocd.io/docs/target_support.html)
- [Microsoft WSL USB 设备连接说明](https://learn.microsoft.com/en-us/windows/wsl/connect-usb)
