<!-- SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates <open-source-office@arm.com> -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# YOLO PT → PTE：使用原始 MLEK 接口

入口为 `scripts/export_yolo_pte.py`，模型适配、校准图片和精度比较位于
`scripts/yolo_pte_utils.py`。模型格式转换在导出阶段完成，部署层按原始接口工作。

## 固定输入输出

- 输入：连续 NCHW、float32 `[1,3,H,W]`，RGB / 255。
- 输出：一个连续 float32 `[1,4+C,N]`，前四通道是归一化 XYWH，后 C 通道是概率。
- 当前 320×320、10 类模型输出 `[1,14,2100]`。
- 部署端直接阈值过滤和 NMS，不再做 sigmoid、score scale 或张量步长适配。

此前的两个问题都在导出端处理：

1. PIL 得到的 NCHW 形状张量可能实际采用 RGB 交错存储，因此显式使用 `.contiguous()`。
2. 像素框坐标不能先与概率拼接再统一量化；现在先归一化框，再拼接 sigmoid 概率。

最终编译后还强制检查输入输出数量、形状、float32 类型和连续维度顺序。
不兼容的 PTE 不写出，避免再次要求固件适配异常格式。

## 部署代码范围

TensorIface、EtTensor、YOLO 预处理、后处理和 UseCaseHandler 均已恢复原始实现。
拆分输出、logits、score scale 和特殊 stride 分支已移除。
仅保留 PTE 所需的 ExecuTorch 框架选择、算子链接、模型/内存配置，以及通用内存统计。
原始入口只有 TFLite，因此这些框架接入仍然必要。

旧 `best_clean_*` 和 `best_contiguous_*` 是拆分输出 PTE，不能继续配合原始后处理。
现在使用 `best_mlek_ethos-u85-512.pte` 并重新构建。

## 导出、构建和运行

在仓库根目录执行：

```sh
source resources_downloaded/env/bin/activate
python scripts/export_yolo_pte.py \
  --model resources_downloaded/gesture_detection/best.pt \
  --calibration-dir /home/xx/gesture-training/data/yolo/gesture10_demo/images/train \
  --calibration-limit 128 \
  --validation-dir resources/gesture_detection/samples \
  --validation-limit 8 \
  --target ethos-u85-512 \
  --vela-config scripts/vela/ensemble_vela.ini \
  --system-config Ethos_U85_SRAM_MRAM \
  --memory-mode Shared_Sram \
  --output resources_downloaded/gesture_detection/best_mlek_ethos-u85-512.pte

GESTURE_MODEL_VARIANT=pte ./scripts/build_gesture_fvp320.sh
GESTURE_MODEL_VARIANT=pte ./scripts/run_gesture_fvp320.sh
```

`--calibration-limit 0` 使用全部图片。默认逐通道权重量化、固定 seed 打乱取样。
`--diagnose-only` 仅做主机浮点/PT2E 比较；`--max-score-drop` 默认 0.20，
同一最佳位置的概率下降过多则停止导出。实际精度仍应使用独立标注数据评测。

默认 `mlek-crop` 与现有图片生成工具一致。若选择 `--preprocessing letterbox`，
部署输入也必须改成匹配的预处理。参数不会自动改变固件处理流程。

## NPU 与内存

保留 `--target`、`--vela-config`、`--system-config`、`--memory-mode`、
`--arena-cache-size`、可重复 `--extra-flag`、`--memory-alignment` 和
`--max-planned-memory`。所有容量参数使用字节。

内存报告区分模型存储、方法池和临时池的地址、容量、当前使用量及峰值。
计划张量与输入副本已计入方法池，当前配置的 NPU scratch 已计入临时池，不能重复相加。
代码、普通堆栈、显示/图片资源及独立 NPU cache 不在模型池合计中。
实际 SRAM/DDR/MRAM 放置由链接和平台配置决定，并非由 Vela 配置名称决定。

完整参数与上板说明见 [部署文档](deploying_model_executorch_export.md#exporting-the-current-yolo-model)。

## 2026-09-14 单输出 FVP 验证

使用 `best_mlek_ethos-u85-512.pte`、原版 YOLO 前后处理、当前 0.45 阈值，
四张输入各检出一个目标：

| 样例 | 类别概率 | 框 `(x,y,w,h)`，320×320 输入坐标 |
| --- | ---: | --- |
| call | 0.940463 | `(105,99,72,73)` |
| four | 0.982935 | `(78,107,72,103)` |
| like | 0.989003 | `(109,175,68,95)` |
| ok | 0.928328 | `(190,110,66,74)` |

以上是 FVP 冒烟验证，不能代替完整数据集评测或实板验证；完整运行日志保留在本地
`logs/` 目录，不作为仓库提交内容。

| 分配 | 区域/地址 | 容量或模型大小 | 实测池峰值 |
| --- | --- | ---: | ---: |
| PTE | DDR `0x7012c000` | 3,007,008 B | — |
| 方法池 | SRAM `0x31000000` | 3,145,728 B | 2,765,429 B |
| 临时池（含 delegate scratch） | DDR `0x94000000` | 16,777,216 B | 2,048,880 B |

池预留合计 19,922,944 B（19 MiB），峰值之和 4,814,309 B。
加上模型存储，预留合计 22,929,952 B，模型与池峰值之和 7,821,317 B。
这些仍然不包含完整固件代码、普通堆栈、显示和样例资源。

当前单输出模型 NPU TOTAL 约 457 万周期；之前非连续输入、拆分输出模型约 426 万周期。
当前临时峰值约 1.95 MiB，之前约 0.79 MiB。因此恢复统一输入输出接口并非零成本；
该比较同时包含输入连续化和输出合并的变化，不能全部归因于单个操作。
编译器、校准数据和目标配置改变后应重新测量。
