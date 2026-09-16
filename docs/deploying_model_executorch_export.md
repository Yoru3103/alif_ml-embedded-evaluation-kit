# Setting up the MLEK build environment

- Tested in Ubuntu Linux 24.04
- with Arm GNU Toolchain 13.3.Rel1

Clone the repository and update dependencies.
```
git clone https://github.com/alifsemi/alif_ml-embedded-evaluation-kit.git
cd alif_ml-embedded-evaluation-kit
git submodule update --init --recursive
```

Build and install framework and prepare tools and example models
```
python set_up_default_resources.py --ml-framework=executorch
```
This installs ExecuTorch and the ARM tools like the Vela compiler and prepares the example project models
The tools are installed to a python virtual environment under MLEK repo

You can install a separate instance of ExecuTorch, but it is important to use the same version of ExecuTorch when exporting the model and when compiling the runtime.
It is easy to use the correct ExecuTorch version and tools installed by the `set_up_default_resources.py` script by activating the environment from MLEK.
```
source resources_downloaded/env/bin/activate
```

Check the installation:
```
pip list | grep executorch
vela --version
```


# Exporting the model to .pte (lowering and quantization)

In order to run a PyTorch model in Alif target HW the model needs to go through the ExecuTorch export process including
lowering, quantization and finally serialization to .pte format. The process includes setting the model shape specification and using representative data for calibration.

Overall process is well described in [ExecuTorch model export documentation](https://docs.pytorch.org/executorch/1.0/using-executorch-export.html)

In addition to generic export documentation there is [Ethos-U specific backend documentation](https://docs.pytorch.org/executorch/1.0/backends-arm-ethos-u.html).

See also [Ethos-U tutorial](https://docs.pytorch.org/executorch/1.0/tutorial-arm-ethos-u.html).

Reading especially the Ethos-U tutorial [memory modes part](https://docs.pytorch.org/executorch/1.0/backends-arm-ethos-u.html#ethos-u-memory-modes) is highly recommended.

ExecuTorch ARM examples include a [porting guide](https://github.com/pytorch/executorch/blob/main/examples/arm/ethos-u-porting-guide.md) which has similar content as the above links, but a bit more from the code examples point of view.

## Requirements

**NOTE:** you can skip this installation step if you are working from the MLEK environment where `set_up_default_resources.py` script does the installation.

**NOTE:** Use the same version for model export and for target runtime.

**NOTE:** It is a good idea to use python virtual environment or equivalent container solution

Install ExecuTorch from source. Here we have chosen to use version 1.0.

```
git clone git@github.com:pytorch/executorch.git
cd executorch
git checkout release/1.0
git submodule sync && git submodule update --init --recursive
./install_executorch.sh
./examples/arm/setup.sh --i-agree-to-the-contained-eula
```

## Example script

In this example we export a pre trained model form torchvision.models. The important point here is how to configure the compilation for the target system using EthosUCompileSpec.
Before running the script activate the virtual environment you have created or use the one from MLEK repository.

**Note:** Alif specific Vela configuration can be found at https://github.com/alifsemi/alif_ml-embedded-evaluation-kit/blob/main/scripts/vela/ensemble_vela.ini

Choose `EthosUCompileSpec` system_config based on model size and performance based requirements and constraints.
In this example we expect the quantized model .pte fits to SoC internal NVM (MRAM) and the internal SRAM is enough
for the execution of the model graph (input and output tensors and any temporary runtime allocations done by the framework fit to SRAM)

```
source resources_downloaded/env/bin/activate
```

```
import torch

from executorch.exir import (
    EdgeCompileConfig,
    ExecutorchBackendConfig,
    to_edge_transform_and_lower,
)

from torchao.quantization.pt2e.quantize_pt2e import convert_pt2e, prepare_pt2e

from executorch.backends.arm.ethosu import EthosUPartitioner, EthosUCompileSpec
from executorch.backends.arm.quantizer import (
    EthosUQuantizer,
    get_symmetric_quantization_config,
)

# For Cortex M optimization
from executorch.backends.cortex_m.passes.quantized_op_fusion_pass import (
    QuantizedOpFusionPass,
)
from executorch.backends.cortex_m.passes.replace_quant_nodes_pass import (
    ReplaceQuantNodesPass,
)

# Your PyTorch model here
from torchvision.models import mobilenetv2

model = mobilenetv2.mobilenet_v2(
    weights=mobilenetv2.MobileNet_V2_Weights.DEFAULT
)

# Test model eval (sets the model to evaluation mode)
model.eval()

# Note: Use realistic calibration/representative input data in order to get good quantization results
#       Random data for demonstration only
inputs = (torch.randn(1, 3, 224, 224),)

outputs = model(*inputs)
print(f"Model output: {outputs}")

# Export PyTorch model (floating point)
exported_program = torch.export.export(model, inputs, strict=True)
graph_module = exported_program.module(check_guards=False)

# Configure compile spec for Ethos-U85 on Ensemble E8
compile_spec = EthosUCompileSpec(
        target = "ethos-u85-256",
        config_ini="scripts/vela/ensemble_vela.ini",
        system_config="Ethos_U85_SRAM_MRAM",
        memory_mode="Shared_Sram",
        extra_flags=["--output-format=raw --debug-force-regor"]
)

# Do post training quantization
quantizer = EthosUQuantizer(compile_spec)
operator_config = get_symmetric_quantization_config(is_per_channel=False)
quantizer.set_global(operator_config)

graph_module_q = prepare_pt2e(graph_module, quantizer)
graph_module_q(*inputs)
graph_module_q = convert_pt2e(graph_module_q)

exported_program_q = torch.export.export(graph_module_q, inputs, strict=True)

# Lower the exported model to Ethos-U backend using the defined compile spec
edge_prog = to_edge_transform_and_lower(
    exported_program_q,
    partitioner=[EthosUPartitioner(compile_spec)],
    compile_config=EdgeCompileConfig(
        _check_ir_validity=False,
    ),
)

# Use Cortex M optimized backend for quantization and dequantization steps
replace_quant_passes = [ReplaceQuantNodesPass()]
replace_quant_passes.append(QuantizedOpFusionPass())
edge_prog = edge_prog.transform(replace_quant_passes)

et_prog = edge_prog.to_executorch(config=ExecutorchBackendConfig(extract_delegate_segments=False))

with open("model.pte", "wb") as file:
    et_prog.write_to_file(file)

```

Example output:
```
...

Network summary for out
Accelerator configuration               Ethos_U85_256
System configuration              Ethos_U85_SRAM_MRAM
Memory mode                               Shared_Sram
Accelerator clock                                 400 MHz
Design peak SRAM bandwidth                      11.92 GB/s
Design peak Off-chip Flash bandwidth             0.72 GB/s

Total SRAM used                               1474.39 KiB
Total Off-chip Flash used                     2839.62 KiB

CPU operators = 0 (0.0%)
NPU operators = 65 (100.0%)

Average SRAM bandwidth                           2.36 GB/s
Input   SRAM bandwidth                          16.07 MB/batch
Weight  SRAM bandwidth                           9.27 MB/batch
Output  SRAM bandwidth                           7.42 MB/batch
Total   SRAM bandwidth                          33.88 MB/batch
Total   SRAM bandwidth            per input     33.88 MB/inference (batch size 1)

Average Off-chip Flash bandwidth                 0.19 GB/s
Input   Off-chip Flash bandwidth                 0.00 MB/batch
Weight  Off-chip Flash bandwidth                 2.77 MB/batch
Output  Off-chip Flash bandwidth                 0.00 MB/batch
Total   Off-chip Flash bandwidth                 2.77 MB/batch
Total   Off-chip Flash bandwidth  per input      2.77 MB/inference (batch size 1)

Neural network macs                         300987520 MACs/batch

INFO:quant_op_fusion_pass:QuantizedOpFusionPass.call() started
INFO:quant_op_fusion_pass:Total changes: 0

```

Note you can add parameters given to Vela using the compile specification extra_flags. For example --verbose-performance --verbose-cycle-estimate --verbose-weights can be useful.

## Exporting the current YOLO model

Use [scripts/export_yolo_pte.py](../scripts/export_yolo_pte.py) to export a complete
Ultralytics detection checkpoint. It makes the PTE conform to the original MLEK
YOLO interface, so no special tensor strides, split-output branches, logits handling
or score scaling are needed in the deployment code.

The supported model is a non-end-to-end Ultralytics detector whose head exposes
`_get_decode_boxes`. Arbitrary state dictionaries and segmentation models are not
supported. The tested environment uses PyTorch 2.10.0, Ultralytics 8.4.129 and the
repository's ExecuTorch environment. Match the export and runtime versions; the
generic version 1.0 setup above is not a compatibility guarantee for this exporter.

### Input and output contract

| Tensor | Current 10-class model | Meaning |
| --- | --- | --- |
| Input | float32 `[1,3,320,320]` | Contiguous NCHW RGB, pixel values divided by 255 |
| Output | float32 `[1,14,2100]` | Contiguous `[1,4+C,N]`: normalized XYWH followed by class probabilities |

The exporter normalizes box coordinates **before** concatenating them with sigmoid
class probabilities. This avoids sharing the large pixel-coordinate range with
0-to-1 probabilities. Making the input contiguous also avoids the PIL-derived
interleaved layout that caused the earlier FVP input mismatch.

After compilation, the exporter rejects unexpected input/output counts, shapes,
float types or dimension orders. It records the final layout in the JSON report.
The original MLEK preprocessor and single-output postprocessor are used unchanged.
Do not apply sigmoid again or configure score scaling in firmware.

The previous split-output PTE files (`best_clean_*`, `best_contiguous_*`) are not
compatible with the restored single-output path. Use the pre-generated
`best_dedicated_ethos-u85-1024.pte` and rebuild the application. The necessary
ExecuTorch framework selection, portable operator linkage and memory settings remain;
the original entry point only supported TFLite. Runtime memory reporting is
independent of YOLO output adaptation.

### Export and check accuracy

Run from the repository root, substituting your representative calibration dataset:

```sh
source resources_downloaded/env/bin/activate
python scripts/export_yolo_pte.py \
    --model resources_downloaded/gesture_detection/best.pt \
    --calibration-dir /home/xx/gesture-training/data/yolo/gesture10_demo/images/train \
    --calibration-limit 128 \
    --validation-dir resources/gesture_detection/samples \
    --validation-limit 8 \
    --image-size 320 \
    --preprocessing mlek-crop \
    --target ethos-u85-1024 \
    --vela-config scripts/vela/ensemble_vela.ini \
    --system-config Ethos_U85_SRAM_OSPI \
    --memory-mode Dedicated_Sram \
    --arena-cache-size 393216 \
    --output resources_downloaded/gesture_detection/best_dedicated_ethos-u85-1024.pte
```

Calibration images are shuffled reproducibly (`--seed 0` by default).
`--calibration-limit 0` uses all images. Cover all classes, backgrounds and lighting
conditions. Per-channel weight quantization is enabled by default;
`--no-per-channel` enables a per-tensor comparison.

`--preprocessing mlek-crop` matches the original image-generation resize/crop policy.
`--preprocessing letterbox` instead uses PIL bilinear resizing and centered padding
with RGB 114. This option requires matching deployment preprocessing; it does not
change the firmware automatically or guarantee pixel parity with OpenCV resizing.

The exporter verifies the floating-point adapter against the original model and
compares floating-point and PT2E outputs on validation images. It reports maximum
probabilities and the quantized probability at the floating-point best class/anchor.
A same-position probability drop greater than `--max-score-drop` (default 0.20)
stops the export. Add `--diagnose-only` to skip NPU compilation.

Without `--validation-dir`, checks use the calibration directory. The default
validation limit is 8. These checks do not replace labeled mAP evaluation or running
the compiled PTE on FVP/hardware. The same-name JSON records calibration files,
configuration, output contract, comparisons, serialized layouts and planned memory.
A rejected export leaves any existing PTE untouched; check the report before using it.

### NPU and memory options

| Option | Purpose |
| --- | --- |
| `--target` | NPU variant and MAC count, for example `ethos-u85-512` |
| `--vela-config` | Vela hardware configuration INI |
| `--system-config` | System_Config matching actual memory connections |
| `--memory-mode` | Memory_Mode section, including custom modes |
| `--arena-cache-size` | Vela arena cache bytes, overriding the INI setting |
| `--extra-flag` | Repeatable Vela option, e.g. `--extra-flag=--verbose-performance` |
| `--memory-alignment` | ExecuTorch alignment: a power of two >= 16; default 16 |
| `--max-planned-memory` | Byte budget for planned nonconstant buffers; aborts if exceeded |

For example, `--max-planned-memory 3145728` checks a 3 MiB planned-memory budget;
it does not force a larger model to fit. Use
`--memory-mode Dedicated_Sram --arena-cache-size 393216` only with a matching
system configuration that provides the required writable arena and SRAM cache.
The cache option does not limit all SRAM usage in `Shared_Sram` mode.

Changing MAC count or memory mode requires re-exporting and matching the firmware
configuration. Set `YOLOV8_NPU_CONFIG_ID` and `YOLOV8_NPU_MACS` consistently with
`--target`; do not use a U85-512 PTE with a Z256/Z1024 runtime.

### Build and run with the original YOLO processing

```sh
GESTURE_MODEL_VARIANT=pte \
GESTURE_MODEL_PATH="$PWD/resources_downloaded/gesture_detection/best_dedicated_ethos-u85-1024.pte" \
./scripts/build_gesture_fvp320.sh

GESTURE_MODEL_VARIANT=pte ./scripts/run_gesture_fvp320.sh
```

No `YOLOV8_SCORE_LOGITS`, `YOLOV8_SCORE_SCALE` or special output-layout flags are
needed or consumed. The build retains your configured detection threshold and NMS.
Relevant deployment overrides are:

```text
GESTURE_MODEL_PATH
GESTURE_NPU_ID
GESTURE_NPU_CONFIG_ID
GESTURE_NPU_MACS
GESTURE_MEMORY_MODE
GESTURE_NPU_CACHE_SIZE
GESTURE_CPU_PROFILE_ENABLED
GESTURE_ACTIVATION_BUF_SIZE
GESTURE_ET_TMP_MEM_SIZE
GESTURE_ET_TMP_MEM_BASE
GESTURE_IMAGE_SIZE
GESTURE_NUM_CLASSES
```

### Memory report and board deployment

Runtime logs print model storage address/size and each allocator's address,
capacity, current usage, peak usage and `FreeAtPeak`. Totals distinguish reserved
pool capacity from the sum of measured pool peaks. On MPS4, the logs also print
the BRAM, SRAM, DDR and DTCM region capacity, link-time `UsedPeak` and remaining
space. Pool peaks can occur at different times; the pool total is not a whole-
firmware RAM total.

For the current MPS4 gesture configuration (`Dedicated_Sram`, U85-1024), the
method pool is in DDR at `0x70409b30`, with 3 MiB reserved. The temporary pool is
in the dynamic DDR window at `0x76000000`, with 2 MiB reserved.
The PTE is also placed in DDR; its address depends on the linked image resources.
A Vela system name containing MRAM does not place the firmware model in MRAM.
Use the linker map and actual addresses to determine physical placement.

Planned tensors and additional input copies are already in the method pool.
Delegate scratch is included in the temporary pool for this build; do not add
Vela's SRAM figure again. Region `UsedPeak` includes fixed code/data, the reserved
heap/stack, cache and linked buffers; `FreeAtPeak` is the allocator high-water
remainder. Reduce pool reservations only after measuring representative inputs and
checking hardware access, linker layout and headroom. The exporter cannot determine
a universal physical RAM total on its own.

The single-output PTE passed the 2026-09-14 FVP run with the original processing
code: call 0.940463, four 0.982935, like 0.989003 and ok 0.928328, one detection per
sample at the current 0.45 threshold. The model occupies 3,007,008 bytes; method and
temporary pool peaks were 2,765,429 and 2,048,880 bytes respectively. These replace
the earlier split-output model's figures. The current input/output contract costs
more temporary scratch and roughly 7% more NPU cycles than that earlier build;
recheck capacity and performance for the target board.

See [YOLO export notes](yolo_pt_to_pte.md) for boxes and memory addresses. The sample
checks do not replace dataset-wide accuracy or hardware tests.

Regression checks for the export boundary can be run with:

```sh
PYTHONPATH=scripts resources_downloaded/env/bin/python -m unittest discover \
    -s scripts/tests -p test_yolo_pte_contract.py
```

## Visualize exported PTE

You can use the model-explorer to visualize the exported PTE file.

See [PTE Adapter for Model Explorer](https://github.com/arm/pte-adapter-model-explorer)

```
pip install pte-adapter-model-explorer
```

```
model-explorer --extensions=pte_adapter_model_explorer model.pte
```

![Visualize with Model Explorer](media/alif/model_explorer.png)


## Optimizing the input and output tensor type

The default ExecuTorch export behaviour is to keep input and output tensors of the model graph as floats. In some cases you may want to skip the float conversions.
For example converting camera frame from typical 8-bit integer to float input tensor needs 4x memory and consumes CPU resources. Then the first step of the model graph would convert it back from normalized floats to int8 quantized.
Here is an example how to skip the float conversions in such a case. See [Ethos-U porting guide](https://github.com/pytorch/executorch/blob/main/examples/arm/ethos-u-porting-guide.md) for reference.

```
edge_prog = to_edge_transform_and_lower(...)
from executorch.exir.passes.quantize_io_pass import QuantizeInputs

# Apply the QuantizeInputs to input tensor 0
edge_prog.transform(passes=[QuantizeInputs(edge_prog, [0])])

# Convert edge program to executorch
et_prog = edge_prog.to_executorch(config=ExecutorchBackendConfig(extract_delegate_segments=False))
```

If desired, the output tensor conversion can be handled in similar manner.

Now the exported program should look like this.

![Exported model](media/alif/model_integer_input.png)


# Building the ExecuTorch runtime in MLEK

For generic MLEK example use-case build instructions [see](../ML_Embedded_Evaluation_Kit.md)


Here is an example CMAKE configuration for using the `model.pte` exported earlier in this guide (`model.pte` in MLEK root).

**NOTE:** E8 has both Ethos-U55 and Ethos-U85 NPU, choose the one you delegated to in the export script EthosUCompileSpec.

```
    cmake -DTARGET_PLATFORM=alif \
    -DTARGET_SUBSYSTEM=RTSS-HP \
    -DTARGET_BOARD=DevKit-e8 \
    -DCMAKE_TOOLCHAIN_FILE=scripts/cmake/toolchains/bare-metal-gcc.cmake \
    -DCONSOLE_UART=4 \
    -DCMAKE_BUILD_TYPE=Release \
    -DMLEK_LOG_LEVEL=MLEK_LOG_LEVEL_DEBUG \
    -DUSE_CASE_BUILD=alif_img_class \
    -DETHOS_U_NPU_ID=U85 \
    -Dalif_img_class_MODEL_PATH=model.pte \
    -DML_FRAMEWORK=ExecuTorch ..
```

```
make -j8 mlek_alif_img_class
```

- Please see also the [Memory usage and linker files](../ML_Embedded_Evaluation_Kit.md#memoryusage)

If the on chip SRAM is not enough the DevKit-E8 and AppKit-E8 have external OSPI | HEXSPI RAM on board which can be used for model execution.
The external RAM can be enabled in build time using CMAKE variable `-DOSPI_RAM_SUPPORT=ON`.
- In Addition to setting the CMAKE variable some linker file changes are needed.
- To optimize performance when using external RAM the model needs to be exported using corresponding system configuration where Ethos-U has a scratch buffer in internal SRAM.

By default the example use-case puts the serialized model graph and weights to MRAM (NVM)

- For larger models you may want to enable `-DOSPI_FLASH_SUPPORT=ON`. Please check [Running a use-case with ML model data in external flash](../ML_Embedded_Evaluation_Kit.md#externalflash)


# See also

For generic Pre- and Post processing tips [see](custom_model_pre_post_processing.md)
