<!--
SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates <open-source-office@arm.com>
SPDX-License-Identifier: Apache-2.0
-->

# 手势目标检测：CPU 小规模训练与 ExecuTorch／MPS4 转换计划

更新日期：2026-09-10。当前工程基线曾核对为 `40df928b`，ExecuTorch 子模块为
`v1.1.0`；实际执行前重新记录提交及环境版本。本文为工作计划，未执行训练、导出或上板验证。
各步骤按通过条件推进，不规定完成时间。

## 1. 当前目标与优先顺序

任务是对整张图片进行**手势目标检测**，输出每只手的位置、手势类别和置信度。
此前 MobileNetV2／ImageFolder／整图三分类路线由本计划替代，分类训练不再作为必经步骤。

- **当前优先任务：已有训练好的 `.pt` 转为适用于 MPS4／Ethos-U85 的 `.pte`。**
  先识别已有模型，再恢复、导出、校准和验证；不要求先训练新模型。
- **保留学习任务：在本地 CPU 上进行小规模检测训练或微调。**
  以理解训练与产物交付为目标，不下载完整大型数据集，不进行大规模随机初始化训练。
- 部署继续使用当前 Alif MLEK 仓库，固定 `TARGET_PLATFORM=mps4`、SSE-320、Arm GNU 工具链。
  不使用 Alif 专用平台、MRAM 配置或烧录工具链。

## 2. YOLOv8n 还是 YOLO-FastestV2？

**在“仅本地 CPU、小样本练习、关注端侧转换”的约束下，新训练实验优先评估 YOLO-FastestV2。**
YOLOv8n 保留为训练工具完善的备选。这个建议不改变已有 `.pt` 的结构：若现有权重是 YOLOv8，
就先转换 YOLOv8，不为了使用 FastestV2 而重新训练。

| 对比 | YOLO-FastestV2 | YOLOv8n 检测版 |
| --- | --- | --- |
| 来源 | [作者仓库](https://github.com/dog-qiuqiu/Yolo-FastestV2) | [Ultralytics 官方仓库](https://github.com/ultralytics/ultralytics) |
| 模型规模参考 | 作者列出约 0.25M 参数，352 输入约 0.212 GFLOPs | 官方标准模型约 3.2M 参数，640 输入约 8.7 GFLOPs |
| CPU 小规模训练 | 计算规模较小，是首选候选；实际训练耗时仍需测量 | 可显式用 CPU 训练，工具完善，但计算负担通常更高 |
| 使用成本 | 代码短，需处理旧依赖、数据加载及 checkpoint 等细节 | 训练、验证、恢复、日志和设备选择更完整 |
| 检测头 | 需处理 anchors、objectness、类别与框解码 | anchor-free；需处理对应检测头输出与框解码 |
| U85 转换 | 当前尚未验证，不能由模型小推断一定兼容 | 当前尚未验证，普通 ExecuTorch 导出不等于 U85 导出 |

参数与 FLOPs 来自不同输入尺寸、不同仓库统计，不能把比值当作 CPU 训练加速比。
FastestV2 作者报告的手机 NCNN 推理速度也不是本机 PyTorch 训练速度或 MPS4 性能。
来源：[FastestV2 README](https://github.com/dog-qiuqiu/Yolo-FastestV2)、
[YOLOv8 官方模型说明](https://docs.ultralytics.com/models/yolov8/)。

选型的实际通过条件：在相同小型数据集上，跑通加载权重、CPU 前向／反向、保存／恢复，
记录若干 batch 的耗时及内存；同时做固定形状的 Ethos-U 导出预验证。
若 FastestV2 的源码兼容或分区问题比 YOLOv8n 更复杂，可改用 YOLOv8n 微调。
不承诺任何一个模型在当前 ExecuTorch 版本中无需适配即可全图运行于 NPU。

### 2.1 可以直接 fork 哪个仓库

新训练实验 fork **作者的 `dog-qiuqiu/Yolo-FastestV2`**，保留上游结构与许可证，记录基线提交；
它是模型作者提供的实现，不是 PyTorch 官方仓库。
如采用 YOLOv8n，则 fork **`ultralytics/ultralytics`**，固定兼容版本。
原计划 fork `pytorch/vision` 分类脚本不再作为检测主线。

两种路线都复用原有训练代码，自己修改类别、数据、输入尺寸和设备配置；不用重新写训练框架。
[PyTorch 基础教程](https://docs.pytorch.org/tutorials/beginner/basics/intro.html)
可用于理解梯度、优化器和恢复训练，但不必先训练另一个分类模型。

FastestV2 当前上游训练源码有 CPU 自动选择路径，但仍需逐项验证：

- `workers=0` 时关闭 `persistent_workers`，否则 DataLoader 配置不合法。
- 变化的分类头不能直接加载尺寸不匹配的权重；`strict=False` 不会忽略所有 shape mismatch。
  只加载名称与尺寸兼容的参数，记录加载与跳过的参数，重新初始化手势检测头。
- 核对所用 torchsummary 的设备选择，确保没有在 CPU 环境发起 CUDA 操作。
- 调整原脚本较稀疏的保存／评估频率，为短实验增加每轮 last、按验证指标保存 best 和恢复状态。
- 在加入纯背景图前，验证损失函数能处理无框样本及整个 batch 无目标的情况。

这些是执行时的检查和适配任务，目前尚未修改源码。
依据：[作者 train.py](https://github.com/dog-qiuqiu/Yolo-FastestV2/blob/main/train.py)、
[作者 loss.py](https://github.com/dog-qiuqiu/Yolo-FastestV2/blob/main/utils/loss.py)。

## 3. 小数据集：可以抽样，不必用完整 HaGRID

这里的“裁剪一部分”优先理解为**筛选图片子集**，而不是把所有图片只裁成手部小图。
检测学习需要保留目标在背景中的位置和大小；如实际裁切图像，必须同步变换、截断和检查所有框。

### 3.1 第一轮规模建议

选择 `fist`（握拳）、`stop`（张掌）、`peace`（V 手势）三类；以实际标注定义为准，
HaGRID 的 `rock` 不应当作猜拳中的握拳。统计单位同时包括图片数和每类框数，多手图片只计一次。

| 阶段 | 建议数据量 | 任务与目标 |
| --- | --- | --- |
| 流程冒烟 | 30～60 张训练图片，另留少量验证图片 | 跑通标注、训练、保存、预测，不以此衡量泛化 |
| 小规模微调 | 总计约 300～600 张不同图片，尽量平衡三类目标框 | 比较 loss、检测框和验证指标，获得可导出的学习模型 |
| 可选扩展 | 总计约 900～1500 张 | 仅在 CPU 耗时可接受且需要更多场景时增加 |

建议按人物／采集场次分组，约 70%／15%／15% 划为训练／验证／测试。
比例服从组隔离和每类覆盖，不为凑数拆开同一人物的相邻帧。
校准集先取训练集内 50～100 张多样化图片，后续根据量化误差增加；测试集不参与训练和校准。
这些数量是练习规模，不保证生产级精度或可靠的小目标识别。

### 3.2 控制下载规模

[HaGRID 作者仓库](https://github.com/hukenovs/hagrid) 提供框、类别和 `user_id`。
官方大类压缩包即便只选三类也可能很大；“训练只用 300 张”不意味着“下载只需 300 张”。

数据获取按以下顺序执行：

1. 优先使用已有且带框标注的数据。若已有 `.pt` 来自其它任务，转换验证和校准先匹配它的实际输入分布。
2. 若有可按样本获取、来源与标注可核对的 HaGRID 子集，只取固定样本清单；
   未验证下载渠道前，不承诺可以从官方大压缩包直接按图片抽取。
3. 若无法小规模获取，直接自采约 300～600 张图并标框，覆盖多位参与者、背景、距离和光照。
   可以用视频抽帧，但相邻帧先去重，按人物／场次划分，再做增强。
4. 原 RPS 分类图片没有本计划所需的现成检测框，不能直接当作检测数据使用；需要额外标注。

**验收**：逐图可视化框与类别；查重、排除损坏图片，保存来源、标注版本、划分和摘要。
HaGRID 框为归一化左上角 `x,y,w,h`，转换成 YOLO 中心点 `cx,cy,w,h` 时不要重复归一化。
同一图片中的所有目标类别实例都要标注。未选中的其它手势如何处理需固定策略，
不能把未标注的目标类别实例无意作为背景。

## 4. CPU 小规模训练步骤（可选支线）

### T1：固定源码、环境与模型

**任务**：fork 选定作者仓库、记录提交；建立独立训练环境，安装兼容依赖。
FastestV2 先检查预训练参数可用性、CPU 运行及前述源码细节；已有 `.pt` 另行保留。

**产物／目标**：环境清单、模型配置、CPU 单次推理与反向传播成功。

### T2：建立少量完整检测样本

**任务**：按第 3 节筛选或采集图片，保存框、类别与固定划分；先可视化再训练。
FastestV2 按作者数据格式生成路径列表、`.names`、`.data` 与训练集 anchors。
YOLOv8n 使用自己的 dataset YAML。两种训练器都读取相同划分，不要求配置文件格式相同。

**产物／目标**：可重复使用的三类小数据集，框正确且划分无泄漏。

### T3：用最低成本验证训练流程

**任务**：先用 30～60 张图片、1～2 个 epoch 检查全部流程。
建议先采用固定 320×320 输入、batch 2～4、workers 0，按本机内存和 CPU 测量调整。
FastestV2 调整输入时核查 stride、anchors 和预处理；关闭多尺度与昂贵增强。
CPU 不默认开启 CUDA AMP；线程数量通过实测选择，避免加载线程与算子线程过度竞争。

**产物／目标**：batch 耗时、内存、loss、保存与重载、检测框预览均正常。
少量样本过拟合用于检查训练代码，不当作泛化能力证明。

### T4：微调小数据集

**任务**：优先加载兼容预训练权重，先冻结骨干训练手势检测头，再视验证结果解冻部分层。
冻结时核对 BatchNorm 状态及优化器参数组。
首轮可设置 5～10 个 epoch 观察趋势，保存每轮结果，按验证集变化决定继续或早停。
这是训练轮数建议，不是时间承诺；若可用权重不兼容，先解决加载问题，不默认在 CPU 上全网从零训练。

**产物／目标**：best、last、可恢复状态和检测指标报告。评价 mAP50、mAP50-95、precision、recall，
同时展示误检、漏检与各类框；小测试集报告样本数，不沿用分类 accuracy／top-1 作为主指标。

### T5：固化模型与转换交付

**任务**：保存权重对应的网络定义、类别、输入和解码配置，再走第 5 节转换流程。
随机初始化训练仅作为可选小样本对照，不是完成部署前置条件。

**产物／目标**：checkpoint 可独立恢复，同一输入重载后输出一致，转换侧可重建模型。

YOLOv8n 的 CPU 备选训练入口示意（数据和环境准备好后使用，本计划未执行）：

```bash
yolo detect train model=yolov8n.pt data=gesture.yaml device=cpu \
  imgsz=320 batch=4 workers=0 epochs=10 amp=False mosaic=0.0 mixup=0.0
```

[Ultralytics 训练参数说明](https://docs.ultralytics.com/modes/train/)。
FastestV2 使用其 `.data` 配置控制训练，不把上述 Ultralytics 参数直接用于 FastestV2。

## 5. 已有 `.pt` → U85 `.pte`：当前优先主线

训练支线未完成也可以执行本节。目前模型路径、具体结构、输入协议和校准样本尚待提供。
已有 `.pt` 的结构可能不是本计划候选，必须先识别文件，再决定实际适配。

```text
已有 .pt + 对应模型源码／配置
  → 主机恢复与参考输出
  → 固定 shape 的 torch.export
  → PT2E 真实样本校准与量化
  → Ethos-U 分区 → TOSA → Vela（导出过程内调用）
  → 目标 .pte + 输出协议 + 校验样本
  → MLEK 检测接入 → MPS4 正确性及性能验证
```

### C1：识别 checkpoint 与固定版本

**任务**：获取模型路径、来源仓库及版本、模型配置、样本目录。判断 state_dict、完整对象或
TorchScript；不能通过 `.pt` 后缀判断格式，也不能直接改名成为 `.pte`。
记录 torch、torchvision、模型库、torchao、ExecuTorch 和 Vela 的兼容版本。

**产物／目标**：能重建正确网络，加载权重并解释输入和输出。

### C2：在主机生成参考结果

**任务**：先以 CPU 恢复 eval 模型，检查实际 RGB／BGR、缩放或 letterbox、像素范围、布局。
对代表性图片保存输入张量、原始输出和最终检测框；明确框坐标、类别激活、objectness、
阈值、NMS、anchors／stride（如适用）。不沿用原 MobileNet 的 ImageNet mean／std。

**产物／目标**：模型可运行，参考框合理，预处理和解码协议完整。

### C3：导出预验证与后处理边界

**任务**：锁定 batch=1 与模型兼容的固定分辨率，使用 `torch.export` 比较原图输出。
NMS 优先留给 Cortex-M85，网络输出解码按实际算子与分区结果决定位置。
FastestV2 和 YOLOv8 的输出结构不同，不强制套用统一 shape，也不遗漏 sigmoid／softmax 等变换。

复用 [本地官方 Arm 导出脚本](../dependencies/executorch/examples/arm/aot_arm_compiler.py)。
本地版本支持 `.py` 模型适配中的 `ModelUnderTest` 和 `ModelInputs`，可以在适配层加载权重。
checkpoint 字典不能直接假定为完整模型；真实校准数据也需单独接入，不能只提供随机示例输入。

**产物／目标**：固定计算图、输出协议、FP32 差异报告。预验证失败先解决图和算子，再扩大训练。

### C4：PT2E 校准与量化

**任务**：以实际输入分布的样本校准 EthosUQuantizer，再 convert 和 export。
已有模型若与三类手势不同，使用与该模型任务匹配的数据，不机械套用手势校准集。
外部 FP32 I/O 可作为第一轮接口，内部 NPU 子图仍需量化。

**产物／目标**：量化模型及误差报告。用一致后处理比较 FP32／量化检测 mAP，
可先设 mAP 下降不超过 2 个百分点作为试验目标；小数据集波动较大，必须结合逐图框检查。
若没有标注，只能做数值与视觉一致性检查，不能声称精度验证已完成。

### C5：生成 MPS4 目标 `.pte`

**任务**：核实 FI101 镜像、U85 MAC 数、Vela ini、system_config、memory_mode 和内存预算；
这些参数以 MPS4 平台资料和运行日志确定，不照抄 Alif E8 配置。
执行 EthosUPartitioner、Vela 和 ExecuTorch 序列化，记录 CPU 回退及内核需求。

**Vela 在 Ethos-U 导出内部调用，不再对 `.pte` 单独运行 Vela。**
Ultralytics 的通用 ExecuTorch 集成目前描述的是 FP32／XNNPACK 路线，不能直接作为 U85 模型交付。
来源：[Ultralytics ExecuTorch 文档](https://docs.ultralytics.com/integrations/executorch/)。

**产物／目标**：目标 `.pte`、分区／Vela 报告、所需 CPU 算子列表及摘要。
关键计算有合理 NPU 分区，内存预算可用；Vela 子图 100% NPU 不代表整个程序没有 CPU 工作。

### C6：接入 MLEK 检测应用

**任务**：在当前 MLEK 中增加或适配 ExecuTorch 检测用例、模型与标签生成、算子注册、
输入处理、多输出读取、模型专用解码、NMS 及原图坐标还原。

本地 [object_detection 配置](../source/app/use_case/object_detection/usecase.cmake)
当前只声明 TFLM 支持，不能通过传入 `.pte` 就获得 ExecuTorch 检测应用。
现有 YOLO-Fastest 人脸模型也不等于 YOLO-FastestV2；anchors、输出头与解码都需核对，不能直接复用假设。
新用例的确切 CMake 参数在实现后确定，因此本文不提供尚不存在的可运行检测构建命令。

保持 `source/lib/` 平台无关，硬件访问位于应用／HAL 层。
使用 Arm GNU、`TARGET_PLATFORM=mps4`、`TARGET_SUBSYSTEM=sse-320`，独立构建目录保存 map。

**产物／目标**：可加载 PTE 的 MPS4 检测固件，标签、解码和坐标处理正确。

### C7：固定样本上板与性能验证

**任务**：先单图再小批量逐图对照，按相同类别及 IoU 匹配框，比较位置与置信度。
不要依赖 NMS 后检测框列表顺序一一相等。记录预处理、网络、后处理耗时和完整应用内存。
普通 PC 不能直接执行 U85 delegate；使用实际硬件或匹配 FVP，性能结论以硬件测量为准。

**产物／目标**：板端检测报告、NPU 活动证据、内存表及重复运行稳定性。
摄像头仅为后续扩展，当前离线图片即可完成转换与推理闭环。

## 6. 两个仓库与交付接口

训练／模型适配代码与 MLEK 分仓管理；本次仅写计划，不创建 fork 或下载数据。
训练仓库可选 FastestV2 或 Ultralytics；已有模型转换时优先保留其原始结构和来源。

```text
gesture-model/                   # 作者仓库的个人 fork 或已有模型工程
  <上游模型与训练代码>
  gesture/configs/               # CPU 训练、类别、数据划分
  gesture/prepare_subset.py      # 待实现：筛选、标注转换及查重
  export/                        # 待实现：模型加载、校准及官方流程适配
  data/                          # 小规模图片与标注，不提交大文件
  runs/                          # 权重、日志与检测指标
  releases/<实验标识>/            # 完整转换交付包

alif_ml-embedded-evaluation-kit/
  docs/executorch_gesture_learning_plan_zh.md
  resources_downloaded/env/     # 与运行时匹配的导出环境
  artifacts/gesture/            # 接收的交付包
  build-gesture-mps4/           # 固件、map 和构建配置
```

交付包包含：PTE、类别映射、输入预处理、输出／解码协议、anchors（如适用）、MPS4 编译配置、
golden 图片与参考输出、量化／分区报告。manifest 记录模型来源、代码提交、checkpoint 摘要、
工具版本和所有交付文件摘要；不要混用不同实验的标签、anchors 或模型。

训练环境独立；导出环境固定为与 MLEK 匹配的版本，避免随意升级 ExecuTorch。
已有 MLEK 安装入口及 `pte-ops-dump` 可用于准备环境和检查产物，但不负责训练模型。

## 7. 完成清单

- [ ] 识别已有 `.pt`、恢复原模型并跑通参考图片（当前优先）。
- [ ] 确认 MPS4 目标参数，完成 export／量化／Vela 预验证。
- [ ] 导出 `.pte`，检查 CPU 回退、内存和检测输出协议。
- [ ] 适配 MLEK 的 ExecuTorch 检测应用，完成固定样本上板比较。
- [ ] 可选：fork FastestV2，完成 CPU 小样本训练、恢复和检测评估。
- [ ] 可选：有测量依据后扩充数据，或切换 YOLOv8n 训练。
- [ ] 保存可复现的交付包、版本及板端报告。

## 8. 参考入口

- [YOLO-FastestV2 作者仓库](https://github.com/dog-qiuqiu/Yolo-FastestV2)
- [Ultralytics 官方仓库](https://github.com/ultralytics/ultralytics)
- [HaGRID 数据与标注](https://github.com/hukenovs/hagrid)
- [ExecuTorch v1.1.0 Arm 示例](https://github.com/pytorch/executorch/tree/v1.1.0/examples/arm)
- [工程导出示例](deploying_model_executorch_export.md)（仅参考通用逻辑，不采用 Alif 平台参数）
- [自定义前后处理](custom_model_pre_post_processing.md)
- [MPS4 WSL 调试](mps4_wsl_debug_guide_zh.md)
- [构建](sections/building.md)、[部署](sections/deployment.md)、[测试](sections/testing_benchmarking.md)
