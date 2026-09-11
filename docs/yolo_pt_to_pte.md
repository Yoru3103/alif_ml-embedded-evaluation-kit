<!-- SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates <open-source-office@arm.com> -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# YOLO PT → Ethos-U PTE

新入口为 `scripts/export_yolo_pte.py`，模型适配与校验放在
`scripts/yolo_pte_utils.py`。旧脚本保留。仅支持完整 Ultralytics 检测 checkpoint，
不支持任意 state_dict、分割模型或 end-to-end 检测头。
本机验证环境：PyTorch 2.10.0、Ultralytics 8.4.129，以及仓库环境中的 ExecuTorch。
检测头需提供 `_get_decode_boxes` 接口；版本不兼容时直接报错，避免静默导出错误结果。

## 分数异常的排查结论

旧脚本存在以下问题：

1. **单输出路径会先把像素 XYWH（数百）和分类概率（0～1）拼接，再量化。**
   两者共享量化范围，小概率丢失精度；wrapper 在拼接之后除以 image_size，
   无法消除前一个拼接节点的量化误差。
   在当前 `best.pt` 上，用旧脚本排序后的前 32 张训练图校准，前四张图最高概率为
   `0.2691 / 0.8413 / 0.2891 / 0.9839`，单输出量化后变成
   `0 / 0 / 0 / 1.9139`。该路径连框坐标也有误差，因此不是“框一定正常”的证明。
2. **参数组合会产生输出语义错误。**
   `configure_detection_head()` 在 `score_scale == 1 && !split_output` 时提前返回，
   没有考虑 `scores_are_logits`。默认 logits=True 配合关闭拆分时，实际仍输出概率，
   但日志却说是 logits。板端再 sigmoid 会造成另一种分数失真。
3. **不能把当前默认拆分路径误判成上述单输出路径。**
   旧脚本当前默认 `split_output=True`、`scores_are_logits=True`，已经避开框和概率拼接。
   该默认路径在同一批校准数据上的前四张图，sigmoid 后量化概率为
   `0.2349 / 0.9139 / 0.2349 / 0.9619`，没有复现整体趋零。
   若你的 PTE 确实使用当前默认参数生成，仍需检查实际固件的 logits 设置、加载的 PTE、
   校准/实际输入是否一致，以及 NPU 编译后的运行结果。后续 FVP 验证发现输入存储顺序不匹配，见下文。
4. 校准图片原先按文件名取前 N 张，可能集中在某一类别。新脚本采用固定 seed 打乱后取样，
   但仍应由使用者提供覆盖所有类别、背景和光照的代表性数据。

新脚本只保留一种明确输出约定：

- 输入：`float32 [1,3,H,W]`，RGB，像素除以 255。
- 输出 0：`float32 [1,4,N]`，归一化 XYWH。
- 输出 1：`float32 [1,C,N]`，未缩放 logits。
- 分类概率 = `sigmoid(logit)`，不乘 objectness，不额外除以分数缩放系数。
- 框和 logits 在检测头内部就分开，避免先拼接再拆分。

## 使用方法

在仓库根目录激活已有环境后运行：

```sh
source resources_downloaded/env/bin/activate
python scripts/export_yolo_pte.py \
  --model resources_downloaded/gesture_detection/best.pt \
  --calibration-dir /home/xx/gesture-training/data/yolo/gesture10_demo/images/train \
  --calibration-limit 128 \
  --validation-dir resources/gesture_detection/samples \
  --validation-limit 2 \
  --target ethos-u85-512 \
  --vela-config scripts/vela/ensemble_vela.ini \
  --system-config Ethos_U85_SRAM_MRAM \
  --memory-mode Shared_Sram \
  --output resources_downloaded/gesture_detection/best_clean_ethos-u85-512.pte
```

`--calibration-limit 0` 使用所有图片。默认启用逐通道权重量化；用 `--no-per-channel`
可做对照。`--diagnose-only` 只执行浮点和 PT2E 校验，不编译 PTE。
每张验证图会报告浮点最高概率、量化最高概率、浮点最佳位置上的量化概率。
默认任意验证图同位置概率下降超过 0.20 时停止导出，可通过 `--max-score-drop` 调整。
该检查只是排查明显退化，并非带标签的 mAP 评测；默认复用校准目录时尤其不能视作独立验证。

默认 `--preprocessing mlek-crop` 精确沿用当前图片生成工具的缩放和偏右裁剪方式。
`--preprocessing letterbox` 提供居中填充 114 的另一种方式，**固件输入也必须采用相同策略**；
仅改变校准预处理并不会修改固件图片生成。该实现使用 PIL 双线性缩放，不保证与
Ultralytics 的 OpenCV resize 逐像素一致。

每次运行写出同名 `.json`，包含配置、校准图片清单、类别、输出约定和分数诊断。
完整导出还包含 PTE 文件大小和 ExecuTorch 计划内存。
诊断失败不覆盖现有 PTE；因此失败后不要误把目录中旧 PTE 当成本次结果。

## NPU 与内存配置

| 参数 | 用途 |
| --- | --- |
| `--target` | 例如 `ethos-u85-256`、`ethos-u85-512`、`ethos-u85-1024` |
| `--vela-config` | 硬件配置 INI 文件 |
| `--system-config` | INI 的 System_Config 名称，需与实际硬件内存连接一致 |
| `--memory-mode` | INI 的 Memory_Mode 名称，支持自定义名称 |
| `--arena-cache-size` | Vela cache 字节数，覆盖 INI 的 arena_cache_size；用于有 cache 的内存模式 |
| `--extra-flag=...` | 可重复的 Vela 参数，例如 `--extra-flag=--verbose-performance` |
| `--memory-alignment` | ExecuTorch 内存对齐，默认 16 字节 |
| `--max-planned-memory` | ExecuTorch 计划非恒定内存总量上限（字节）；超限停止写 PTE |

例如，若选定的 system config 支持外部可写 arena 与片上 cache，可配置
`--memory-mode Dedicated_Sram --arena-cache-size 393216`。
不能只改模式名称而忽略系统内存连接。`Shared_Sram` 并不通过 cache 参数限制全部 SRAM。

`--max-planned-memory 3145728` 是预算检查，并非强制把任意模型压缩进 3 MiB。
计划内存不是整个系统 RAM 需求；Vela 的 NPU scratch/cache、运行时临时池、栈和其他应用内存
还需结合固件分配方式核对，不能机械相加或当作同一个数字。
应用的 `YOLOV8_ACTIVATION_BUF_SIZE`、`YOLOV8_ET_TMP_MEM_SIZE`、
`YOLOV8_ET_TMP_MEM_BASE`、`YOLOV8_NPU_CACHE_SIZE` 仍由固件构建配置控制，导出器不会改链接布局。

当前构建入口的 `gesture_pte` 已默认设置 logits=1、score scale=1。
选择新 PTE 时可显式运行：

```sh
YOLOV8_MODEL_VARIANT=gesture_pte \
YOLOV8_MODEL_PATH="$PWD/resources_downloaded/gesture_detection/best_clean_ethos-u85-512.pte" \
YOLOV8_SCORE_LOGITS=1 YOLOV8_SCORE_SCALE=1.0 \
./scripts/build_yolov8_fvp320.sh
```

MAC 数量和内存模式改变后，固件也要匹配。

## 本机验证结果

32 张随机校准图、仓库中的 2 张示例图、U85-512 / Shared_Sram：

| 图片 | 浮点最高概率 | PT2E 最高概率 |
| --- | ---: | ---: |
| like | 0.9942 | 0.9879 |
| call | 0.9120 | 0.9428 |

已完成完整 Vela 编译及 PTE 序列化。此次 PTE 大小 3,006,896 字节，
ExecuTorch 计划非恒定内存 1,536,000 字节；Vela 报告 SRAM 804.56 KiB。
这些数值取决于模型、校准、编译器版本和配置，不能作为通用固定容量。
以上概率来自主机 PT2E 图。后续 FVP 验证及修复结果见下文；仍需实板验证。

参考：[ExecuTorch Ethos-U 量化说明](https://docs.pytorch.org/executorch/stable/backends/arm-ethos-u/arm-ethos-u-quantization.html)。

## FVP 输入布局修复与内存统计

已定位漏检和框错位的主要原因：早期导出的输入虽然形状是 `[1,3,320,320]`，
但 PIL 转换得到的张量并不连续，PTE 保存的 `dim_order` 为 `[2,0,3,1]`。
固件按三个颜色平面写入，模型却按 RGB 交错读取，造成输入错乱。

导出器现在显式调用 `.contiguous()`；JSON 中增加编译后的输入输出形状和维度顺序。
固件预处理也改为按实际存储步长写入，因此原有 PTE 无需重新导出即可配合新固件使用。

原 PTE 配合修复后的固件，FVP 结果：

- call：最高分类概率 0.940050，框 `(105,101,73,73)`。
- like：最高分类概率 0.989602，框 `(109,175,69,98)`，不再出现六个错位小框。
- call 图另有 0.179671 的 like 候选，这是 0.10 阈值和按类别 NMS 保留的低分候选。

模型存储在 FVP DDR `0x70096000`，大小 3,006,896 字节。
SRAM 方法池 `0x31000000` 预留 3 MiB，峰值 2,765,677 字节；
DDR 临时池 `0x94000000` 预留 16 MiB，峰值 823,872 字节。
两池预留共 19 MiB，峰值之和约 3.42 MiB；加上 PTE 分别约 21.87 MiB 和 6.29 MiB。
这些是模型与运行时池的统计，不包括完整固件代码、普通堆栈、显示和图片资源。
计划张量、额外输入副本和 delegate scratch 已在池内，不能重复相加。

运行时现在直接输出上述地址、容量、使用量、峰值和合计。
更详细的上板内存说明与无窗口运行命令见
[导出部署文档](deploying_model_executorch_export.md#reading-the-runtime-memory-report)。
