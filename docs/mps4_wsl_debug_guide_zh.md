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

## 十、VS Code 图形调试：添加 AXF 与完整示例

### 10.1 在正确的环境打开工程

1. Windows 的 VS Code 安装 WSL 扩展；连接 WSL 后，在 **WSL 扩展环境**安装
   Cortex-Debug（`marus25.cortex-debug`）。
2. 在 WSL 终端执行：

   ```bash
   cd /home/xx/alif_ml-embedded-evaluation-kit
   code .
   ```

3. 确认 VS Code 左下角显示 WSL，打开的根目录是本仓库，而不是 `build-*` 子目录。
   本文中的 `${workspaceFolder}` 就是这个仓库根目录。
4. 在 VS Code 的 WSL 集成终端检查 GDB：

   ```bash
   ./scripts/debug/mps4/gdb-with-compat.sh --version
   ```

当前 [launch.json](../.vscode/launch.json) 使用 Linux 工具链路径
`/usr/local/bin/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi/bin`。
如果你的安装位置不同，需要修改 `armToolchainPath`，并让 `gdbPath` 指向可运行的
`arm-none-eabi-gdb` 或兼容包装脚本。现有包装脚本默认要求
`~/.local/share/arm-gdb-compat/lib/x86_64-linux-gnu/` 下同时存在
`libncursesw.so.5` 和 `libtinfo.so.5`；即使系统中的另一套 GDB 可以直接运行，包装脚本
仍会检查这两个文件。无需兼容库的 GDB 可以直接填入 `gdbPath`。

### 10.2 三种配置怎么选

按 `Ctrl+Shift+D` 打开“运行和调试”，顶部下拉框中的配置来自
[.vscode/launch.json](../.vscode/launch.json)：

| 配置 | 目标与端口 | 启动前准备 | AXF 的用途 |
|---|---|---|---|
| `MPS4 ❘ 选择模块（下载并调试）` | 真板，3333 | 手动启动 pyOCD，确认板卡及内存布局匹配 | 下载程序并加载符号，运行到 `main` |
| `MPS4 ❘ 选择模块（只连接，不下载）` | 真板，3333 | 板上已运行对应程序，手动启动 pyOCD | 加载符号并暂停当前程序 |
| `FVP ❘ Fast Models GDBServer（源码调试）` | 仿真，10000 | 安装 FVP 与 Fast Models GDBServer 插件 | 自动启动 FVP，再由 GDB 下载程序并加载符号 |

表格中的 `❘` 对应界面名称中的 `|`。两种 MPS4 配置均不会自动启动 pyOCD。
FVP 配置通过 [tasks.json](../.vscode/tasks.json) 的 `preLaunchTask` 启动服务器。
**这三种配置都没有编译任务，按 F5 不会重新编译。**

`launch` 默认使用 `executable` 下载程序，`attach` 用于连接已有程序；
`runToEntryPoint` 在首次 attach 时不会让程序重新运行到 `main`。
参数定义见 [Cortex-Debug 官方配置说明](https://github.com/Marus/cortex-debug/blob/master/debug_attributes.md)。

### 10.3 把新编译好的 AXF 加入选择列表

假设新文件是：

```text
/home/xx/alif_ml-embedded-evaluation-kit/build-fvp320-yolov8-debug-example/bin/mlek_yolov8_detection.axf
```

不需要把 AXF 复制进 `.vscode`，也不需要改名为 `.elf`。先确认文件存在：

```bash
ls -lh build-fvp320-yolov8-debug-example/bin/mlek_yolov8_detection.axf
```

打开 `.vscode/launch.json`，找到底部 `inputs` 中 `id` 为 `mps4Program` 的对象。
在它的 `options` 数组中增加一项，保留已有项；例如修改后可以是：

```json
{
    "id": "mps4Program",
    "type": "pickString",
    "description": "选择已经编译好的 AXF 模块",
    "options": [
        "build-fvp320-yolov8-debug-example/bin/mlek_yolov8_detection.axf",
        "build-fvp320-yolov8-best-new-debug/bin/mlek_yolov8_detection.axf",
        "build-fvp320-yolov8-best-new/bin/mlek_yolov8_detection.axf",
        "build-fvp320-yolov8-best/bin/mlek_yolov8_detection.axf",
        "build-fvp320-face-detection/bin/mlek_object_detection.axf",
        "build-fvp320-yolov8-best/bin/uart-hello-test.axf"
    ],
    "default": "build-fvp320-yolov8-debug-example/bin/mlek_yolov8_detection.axf"
}
```

上面是 **inputs 中的一个对象**，不要用它替换整个 `launch.json`。
`default` 可选，用于指定默认项，必须与某个选项一致。

现有三个配置都写了：

```json
"executable": "${workspaceFolder}/${input:mps4Program}"
```

因此这里的选项必须使用**相对仓库根目录的路径**，不能填 `/home/...` 绝对路径，
也不要再加 `${workspaceFolder}/`。虽然输入 ID 叫 `mps4Program`，FVP 也使用它。
列表不会自动扫描磁盘，显示在列表中也不代表文件一定存在或适合当前目标。

保存后，选择调试配置并按 F5，在弹出的 AXF 选择框中选择新路径。
以后在相同路径重新编译，只需结束旧调试会话再 F5，无需重复添加。

如果只想固定调试一个文件，可以复制 `configurations` 中对应的配置对象，修改
`name`，并把 `executable` 改成固定路径：

```json
"name": "FVP | 我的 YOLOv8 Debug",
"executable": "${workspaceFolder}/build-fvp320-yolov8-debug-example/bin/mlek_yolov8_detection.axf"
```

其余字段保留原配置。仓库外的 AXF 则直接使用 WSL 绝对路径，如
`"executable": "/tmp/my-build/bin/program.axf"`，不要再加工作区前缀。
固定路径配置不会弹出文件选择框。

### 10.4 完整示例：编译 YOLOv8 → 加入 VS Code → FVP 断点调试

此示例使用 `best_int8`、Ethos-U85 256 MACs，与当前 FVP 调试脚本的
`mps4_board.subsystem.ethosu.num_macs=256` 一致。前提是仓库的编译工具、依赖及
资源已经准备好；脚本会检查以下输入：

- 模型：`vela_output/best_int8_z256/best_int8_vela.tflite`
- 标签：`resources/object_detection/samples/coco128.yaml`
- 图片：`20260827_Model/000000058350.jpg`

**第一步：生成独立的 Debug 构建。** 在仓库根目录执行：

```bash
YOLOV8_MODEL_VARIANT=best_int8 \
YOLOV8_BUILD_DIR="$PWD/build-fvp320-yolov8-debug-example" \
BUILD_JOBS=8 \
./scripts/build_yolov8_fvp320.sh

cmake -S . -B build-fvp320-yolov8-debug-example -DCMAKE_BUILD_TYPE=Debug
cmake --build build-fvp320-yolov8-debug-example \
  --target mlek_yolov8_detection --parallel 8
```

第一条命令用已有脚本完成模型、平台和内存配置，并先构建一次；脚本没有
Debug 环境变量接口，所以随后显式切换为 `Debug` 并重新编译。
这里复用刚生成的 CMake 缓存，其他配置会保留。后续修改源码后，只需执行最后一条
`cmake --build` 命令。

检查结果：

```bash
rg '^CMAKE_BUILD_TYPE:' build-fvp320-yolov8-debug-example/CMakeCache.txt
ls -lh build-fvp320-yolov8-debug-example/bin/mlek_yolov8_detection.axf
/usr/local/bin/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi/bin/arm-none-eabi-readelf \
  -S build-fvp320-yolov8-debug-example/bin/mlek_yolov8_detection.axf \
  | rg '\.debug_(info|line)'
```

构建类型应显示 `Debug`，AXF 应含 `.debug_info`、`.debug_line`。
工具链位置不同时调整 `readelf` 路径。仓库 GCC 工具链的 Debug 默认使用 `-Og -g`，
Release 也可能带 `-g`，所以仅有符号不代表关闭了较高等级优化。

**第二步：按 10.3 将新 AXF 路径加入 `inputs.options` 并保存。**

**第三步：检查 FVP 安装位置。** 当前调试脚本默认需要：

```text
/home/xx/FVP_Corstone_SSE-320/scripts/runtime.sh
/home/xx/FVP_Corstone_SSE-320/models/Linux64_GCC-9.3/FVP_Corstone_SSE-320
/home/xx/FastModels_11.32_19/plugins/Linux64_GCC-9.3/GDBServer.so
```

安装位置不同，可以在 `.vscode/tasks.json` 的 FVP 任务对象中增加：

```json
"options": {
    "env": {
        "FVP_ROOT": "/你的路径/FVP_Corstone_SSE-320",
        "FASTMODELS_HOME": "/你的路径/FastModels_11.32_19"
    }
}
```

注意补齐相邻字段之间的逗号。环境变量只改变根目录，脚本中的版本相关子目录
也必须存在。这里不需要 USB、真板或 pyOCD。

**第四步：启动并命中断点。**

1. 打开 `source/app/use_case/yolov8_detection/src/UseCaseHandler.cc`，搜索
   `if (!RunInference(model, profiler))`，点击该行左侧设置断点。
2. `Ctrl+Shift+D`，选择 `FVP | Fast Models GDBServer（源码调试）`。
3. 按 F5，在 AXF 选择框选择 `build-fvp320-yolov8-debug-example/bin/mlek_yolov8_detection.axf`。
4. 任务终端应出现 `GDBServer: Listening address=... port=10000`，随后调试器连接、
   下载 AXF，并在 `main` 暂停。较大的 AXF 下载需要等待。
5. 按 F5 继续，程序执行到推理调用时命中断点。如果应用等待菜单输入，
   先按应用提示选择推理操作；UART 输入输出属于应用终端，不是 Debug Console。
6. 使用“变量”“监视”“调用堆栈”查看当前状态。F10 单步跳过，F11 进入函数，
   Shift+F11 跳出，F5 继续，Shift+F5 停止。

推理断点只观察 Cortex-M 上的调用与返回，不能用 C++ 单步进入 NPU 内部执行的算子。
FVP 的 UART0 输出位于启动它的任务终端。结束调试后，插件配置会请求 FVP 在断开时退出；
如果任务仍存活，通过“任务：终止任务”关闭后再启动，避免端口冲突。

### 10.5 同一个工作流用于 MPS4 真板

1. 使用**适配实际 FI101 硬件、NPU 配置和内存布局**的 AXF，按 10.3 加入列表。
   构建目录叫 `fvp` 或文件扩展名为 `.axf` 本身不能证明兼容真板。
2. 按第一至六节准备板卡、USB 转接和调试访问。若 CPU AP 尚不可访问，先按既有板卡
   部署流程让包含调试使能的应用运行，不能指望 F5 下载来解决连接前的访问失败。
3. 在独立 WSL 终端执行并保持运行：

   ```bash
   ./scripts/debug/mps4/debug.sh server
   ```

4. 等待 `GDB server listening on port 3333`。关闭其他占用该目标的 GDB 会话。
5. 要重新下载新编译的程序，选择 `MPS4 | 选择模块（下载并调试）`，F5 并选中 AXF，
   等待在 `main` 停下，然后按前述方法设置断点。
6. 若只想观察板上已运行的程序，选择 `MPS4 | 选择模块（只连接，不下载）`，并选择
   与板上程序**同一次构建**的 AXF。连接时会暂停 CPU，不会替换程序，也不会重新命中
   已执行过的 `main`。在接下来会执行的位置设断点后继续。

下载调试是通过 GDB 写入目标内存，不等同于更新板卡的持久启动镜像。
修改源码并重新编译后，attach 不会自动把新程序部署到板上；需要重新下载，或先完成
板卡部署再 attach。停止 VS Code 调试后，手动启动的 pyOCD 服务器仍需在其终端退出。

### 10.6 VS Code 调试问题定位

| 现象 | 检查与处理 |
|---|---|
| 下拉列表没有新 AXF | 修改的是当前工作区 `.vscode/launch.json` 的 `inputs.options`，保存后重新 F5 |
| 找不到 executable | 在 WSL 用 `ls` 检查实际路径；相对路径不要重复工作区前缀；F5 不负责构建 |
| 不识别 `cortex-debug` 类型 | 确认 Cortex-Debug 已安装并启用于 WSL 环境 |
| GDB 启动失败 | 先运行包装脚本的 `--version`；检查工具链路径与兼容库 |
| 连接 3333 失败 | 真板需先手动启动 pyOCD；确认 USB 已转接且服务器仍在运行 |
| FVP 任务一直等待 | 查看任务终端是否缺少插件、路径错误或端口占用；就绪匹配器默认只认 10000 |
| 改了 FVP 端口后无法启动 | 同步修改脚本环境变量 `FVP_GDB_PORT`、launch 的 `gdbTarget` 以及 tasks 的 `endsPattern` |
| 灰色断点、源码找不到或行号错位 | 确认 AXF 含调试符号，源码与构建版本一致；优先在当前目录重编译 |
| 从另一台机器复制的 AXF 找不到源码 | 在对应配置增加 `"sourceFileMap": {"/原仓库路径": "${workspaceFolder}"}`，源码版本必须一致 |
| 变量显示 optimized out 或单步跳行 | 用 Debug 重编译，并重新下载匹配 AXF；`-Og` 下仍可能有局部变量被优化 |
| attach 后断点行为异常 | 排查是否选了新 AXF，但板上仍运行旧程序 |
| FVP 启动后 NPU 配置错误 | 当前调试脚本固定 256 MACs；其他模型需核对模型编译配置、应用构建和 FVP 参数 |

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
