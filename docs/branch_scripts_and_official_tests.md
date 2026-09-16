<!-- SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
     <open-source-office@arm.com> -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# 分支脚本与官方 usecase 统一测试

## 两个分支共存两套入口

`feature/yolov8-fvp` 和 `feature/yolov8-real-board` 都应保留以下文件。
按目标选择脚本，不根据当前 Git 分支自动改变脚本行为。

| 用途 | 构建入口 | FVP 运行入口 |
| --- | --- | --- |
| FVP gesture | `scripts/build_gesture_fvp320.sh` | `scripts/run_gesture_fvp320.sh` |
| MPS4 gesture | `scripts/build_gesture_mps4.sh` | `scripts/run_gesture_mps4_on_fvp.sh` |
| FVP YOLOv8 | `scripts/build_yolov8_fvp320.sh` | `scripts/run_yolov8_fvp320.sh` |
| MPS4 YOLOv8 | `scripts/build_yolov8_mps4.sh` | `scripts/run_yolov8_mps4_on_fvp.sh` |

FVP 四个入口恢复为拆分时 `feature/yolov8-fvp` 的版本（`65695e12`）。
实板入口保留原实板分支的模型和内存策略；修复 gesture 的 `BUILDv_DIR` 拼写。
YOLOv8 实板构建目录统一改为 `build-mps4-yolov8-*`，避免覆盖 FVP 产物。
已有的 `GESTURE_*`、`YOLOV8_*` 环境变量仍可使用。
`run_*_mps4_on_fvp.sh` 仅在 FVP 中模拟实板构建产物，不烧录实板。
实板调试继续使用 `scripts/debug/mps4/debug.sh`。

例如：

```bash
# 实板模型
GESTURE_MODEL_VARIANT=pte ./scripts/build_gesture_mps4.sh
# FVP 模型
GESTURE_MODEL_VARIANT=pte ./scripts/build_gesture_fvp320.sh
```

专用脚本保留各模型已有的参数，并非官方统一性能测试入口。
原先在实板分支运行 `*_fvp320.sh` 的命令、IDE task 和个人快捷方式，
应改用 `*_mps4.sh`。已有历史文档里的 FVP 命令仍表示 FVP 用途。

## 官方统一构建

唯一配置源是 `scripts/config/official_sse320.sh`，两个分支保持相同内容。
`scripts/build_official_sse320.sh` 支持 Dedicated_Sram（默认）和 Shared_Sram。
每种内存模式分别在自己的 CMake 构建目录配置所有应用，
只改变要构建的 usecase target，不为不同 usecase 切换平台参数。

| 项目 | 统一值 |
| --- | --- |
| 平台 | MPS4 / SSE-320 |
| 框架、构建类型 | TensorFlowLiteMicro / Release |
| NPU | Ethos-U85 / Z1024 / 1024 MAC |
| 内存模式、NPU cache | Dedicated_Sram / 393216 字节；Shared_Sram / 0（无独立 cache） |
| Vela system config | Ethos_U85_SYS_DRAM_Mid_1024 |
| Timing adapter / CPU profiling | OFF / ON |
| 每个 usecase 的 activation arena | 0x00200000（2 MiB） |
| 输入、交互 | USE_SINGLE_INPUT=ON / INTERACTIVE_MODE=OFF |
| ASR、KWS_ASR、inference_runner 外部 flash 选项 | OFF |

各模型、输入、标签和算法参数仍采用对应官方 usecase 的定义；这些内容本来就不同。
2 MiB 是统一预留预算，不是实测内存用量。默认每个应用使用一个官方输入，适合冒烟测试。
Shared_Sram 模式统一向 Vela 传入 `--arena-cache-size 1966080`，
限制共享 arena 调度预算为 1.875 MiB，为 TFLM 元数据及 CPU 分配预留 128 KiB。
这里的 Vela 参数名不表示另建独立 NPU cache；固件的 NPU cache 仍为 0。
Dedicated_Sram 模式的 Vela cache 预算为 393216 字节。
两种模式都保持 2 MiB activation arena；Shared 的 arena 由现有链接配置放入 SRAM，
Dedicated 的 arena 放入 DDR。其余公共参数相同。
不同代码分支的算法、驱动或链接脚本仍可能不同；严格性能比较时应使用同一个提交。

包含 Arm 的全部 9 个标准 ML usecase：

```text
ad asr img_class inference_runner kws kws_asr noise_reduction object_detection vww
```

排除自定义 gesture / `yolov8_detection`。保留官方 `object_detection`
（其默认模型本身是 YOLO Fastest 人脸检测）。
`alif_*` 是依赖 Alif 平台的移植应用，不能按同一 MPS4 配置测试；
`mps4_clock_calibration` 是时钟校准工具，不属于 ML 测试集。

先确保仓库原有资源准备流程已完成（原始 TFLite、样本、Python 环境和交叉工具链可用）。
在仓库根目录执行：

```bash
# 使用相同 Vela 配置重新编译全部原始模型，保留原 resources_downloaded 不变
./scripts/build_official_sse320.sh --prepare-models

# 构建全部 9 个应用
./scripts/build_official_sse320.sh

# Shared SRAM：使用独立模型和构建目录，保留 Dedicated 产物
OFFICIAL_MEMORY_MODE=Shared_Sram ./scripts/build_official_sse320.sh --prepare-models
OFFICIAL_MEMORY_MODE=Shared_Sram ./scripts/build_official_sse320.sh

# 或者只编译其中几个 target，配置仍是同一套
./scripts/build_official_sse320.sh kws asr

# 列出 usecase / 只打印命令
./scripts/build_official_sse320.sh --list
./scripts/build_official_sse320.sh --dry-run
```

Dedicated 产物：`build-official-sse320/bin/mlek_<use_case>.axf`。
Shared 产物：`build-official-sse320-shared/bin/mlek_<use_case>.axf`。
两种模式也各自生成对应的分区 `.bin`；模型分别在各自构建目录下的 `models/`。
编译记录包含 Vela 版本与输入/配置 SHA-256；配置或原模型变化后，构建会要求重新准备模型。
Vela 版本升级后也应重新运行 `--prepare-models`。

可以使用 `BUILD_JOBS=8`、`VELA=/absolute/path/to/vela`（准备模型时）和
`OFFICIAL_BUILD_DIR=/absolute/path/to/build`。自定义构建目录需在准备与构建时一致。
`OFFICIAL_MEMORY_MODE` 在准备与构建时也必须一致；两种模式不可共用一个目录，
脚本会检查已有 CMake cache 和模型模式标记并拒绝混用。
修改统一硬件配置时，在配置文件中同时维护 MAC、Vela system config、内存模式及 cache。
不要在各 usecase 入口分别调这些值。不要在此专用构建目录中手工改变 CMake cache；
如需其他实验配置，请使用另一个目录。

在 FVP 上运行时必须匹配 1024 MAC。例如：

```bash
FVP_ROOT=/home/xx/FVP_Corstone_SSE-320
source "$FVP_ROOT/scripts/runtime.sh"
"$FVP_ROOT/models/Linux64_GCC-9.3/FVP_Corstone_SSE-320" \
    -a build-official-sse320/bin/mlek_kws.axf \
    -C mps4_board.subsystem.ethosu.num_macs=1024 \
    -C mps4_board.telnetterminal0.start_telnet=0 \
    -C mps4_board.uart0.out_file=- \
    -C mps4_board.uart0.shutdown_on_eot=1 \
    -C mps4_board.visualisation.disable-visualisation=1 \
    -C vis_hdlcd.disable_visualisation=1 --stat
```

更换 `mlek_kws.axf` 可运行其他应用。上述流程构建的是应用，不等于运行了 native 单元测试。

### 本次验证（2026-09-16）

- 10 个模型文件（KWS_ASR 包含两个模型）全部通过统一 Vela 编译。
- 9 个应用全部构建成功，生成对应 AXF 和分区 BIN。
- Shell 语法、非法 usecase 拒绝、单目标与全量构建配置一致性检查通过；
  实际 CMake cache 与统一硬件配置一致。
- FVP/实板自定义入口经过模拟 CMake 的参数回归检查；未重新构建全部自定义模型。
- AD 的额外 FVP 冒烟运行在 45 秒内未产生应用串口输出，超时后终止；
  因此未宣称 FVP 运行通过。实板运行和 native 单元测试尚未执行。

## 首次同步和后续合并

本次文件修改在 `feature/yolov8-real-board` 工作区中，尚未提交或移动其他分支。
先检查、提交这次拆分（DCO sign-off 必须保留）：

```bash
git diff
git add scripts/build_gesture_fvp320.sh scripts/run_gesture_fvp320.sh \
    scripts/build_yolov8_fvp320.sh scripts/run_yolov8_fvp320.sh \
    scripts/build_gesture_mps4.sh scripts/run_gesture_mps4_on_fvp.sh \
    scripts/build_yolov8_mps4.sh scripts/run_yolov8_mps4_on_fvp.sh \
    scripts/build_official_sse320.sh scripts/config/official_sse320.sh \
    docs/branch_scripts_and_official_tests.md
git commit -s -m "Separate FVP and board scripts and add uniform official builds"
```

如果希望同步整个实板分支（包括脚本以外的驱动和链接脚本修改）：

```bash
git switch feature/yolov8-fvp
git merge feature/yolov8-real-board
```

检查时 FVP 分支是实板分支的祖先，因此首次全量同步可快进。
如果只想引入本次脚本拆分，不引入其余实板代码，记录刚才的提交号后：

```bash
git switch feature/yolov8-fvp
git cherry-pick <脚本拆分提交号>
```

拆分提交包含把 FVP 脚本恢复到 FVP 分支原有内容的修改；首次 cherry-pick 若出现这些文件的冲突，
保留 FVP 分支已有的四个 `*_fvp320.sh`，同时保留新增的实板和公共文件，再继续 cherry-pick。
脚本同步不代表其他实板功能、模型文件已经同步；模型仍需按各入口要求准备。

以后正常双向合并即可，例如：

```bash
git switch feature/yolov8-real-board
git merge feature/yolov8-fvp
# 完成开发并提交后，在需要同步时：
git switch feature/yolov8-fvp
git merge feature/yolov8-real-board
```

维护约定：FVP 参数修改只进入 FVP 专用入口，实板参数修改只进入实板专用入口，
公共测试配置作为同一份配置随合并同步。无需合并后再把 MAC 数或模型路径改回去。
共享业务代码仍可能正常发生冲突，需要逐项处理；不要设置 `merge=ours` 或用
`git merge -X ours` 全局掩盖冲突，也不要在两个分支反复反向修改同一个配置文件。
