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
Ultralytics detection checkpoint. Model adaptation and accuracy checks are in
[scripts/yolo_pte_utils.py](../scripts/yolo_pte_utils.py). Specify the model,
calibration directory and output path explicitly; the exporter does not search
for checkpoints automatically.

This exporter supports non-end-to-end detection models whose Detect head exposes
`_get_decode_boxes`. It does not accept arbitrary state dictionaries or segmentation
models. The tested environment uses PyTorch 2.10.0, Ultralytics 8.4.129 and the
ExecuTorch installation in the repository virtual environment. Use the matching
ExecuTorch runtime when building the application; the generic version 1.0 setup
above is not a compatibility guarantee for this YOLO exporter.

### Input and output contract

The default input size is 320, with the following float32 tensors:

| Tensor | Shape for the current 10-class model | Meaning |
| --- | --- | --- |
| Input | `[1, 3, 320, 320]` | RGB, NCHW, pixel values divided by 255 |
| Output 0 | `[1, 4, 2100]` | Normalized XYWH box coordinates |
| Output 1 | `[1, 10, 2100]` | Unscaled class logits |

Apply sigmoid to class logits exactly once in postprocessing. Set
`YOLOV8_SCORE_LOGITS=1` and `YOLOV8_SCORE_SCALE=1.0` in the MLEK build.
Do not treat the raw logits as probabilities or multiply them by an objectness score.

Boxes and logits are separated inside the detection head, before quantization.
Combining pixel-scale boxes with probabilities in one quantized tensor can destroy
class-score precision; normalizing boxes after that concatenation does not undo
its quantization error. The new exporter uses a fixed two-output contract without
score scaling or single-output switches. The legacy `export_my_model.py` is retained;
its current default already splits outputs, so this single-output failure does not
explain every low-score result. See the [YOLO export notes](yolo_pt_to_pte.md) for
reproduced results and the legacy logits-option issue.

### Export and check accuracy

Run from the repository root. Replace the calibration directory with your own
representative images when using a different dataset:

```sh
source resources_downloaded/env/bin/activate
python scripts/export_yolo_pte.py \
    --model resources_downloaded/gesture_detection/best.pt \
    --calibration-dir /home/xx/gesture-training/data/yolo/gesture10_demo/images/train \
    --calibration-limit 128 \
    --validation-dir resources/gesture_detection/samples \
    --validation-limit 2 \
    --image-size 320 \
    --preprocessing mlek-crop \
    --target ethos-u85-512 \
    --vela-config scripts/vela/ensemble_vela.ini \
    --system-config Ethos_U85_SRAM_MRAM \
    --memory-mode Shared_Sram \
    --output resources_downloaded/gesture_detection/best_clean_ethos-u85-512.pte
```

Calibration uses a reproducible shuffled sample (`--seed 0` by default).
`--calibration-limit 0` uses all images. Provide images covering all classes,
backgrounds and lighting conditions. Per-channel weight quantization is enabled
by default; `--no-per-channel` allows a comparison with per-tensor weights.

`--preprocessing mlek-crop` matches the current MLEK image-generation resize and
crop policy. `--preprocessing letterbox` uses centered padding with RGB value 114
and PIL bilinear resizing. The deployment input pipeline must use the same policy;
changing the export option does not change firmware preprocessing. The PIL
letterbox implementation is not guaranteed to match OpenCV resizing pixel for pixel.

The exporter verifies the adapted floating-point model against the original model,
then compares floating-point and host PT2E outputs on validation images. Each image
reports the maximum probability before and after quantization and the quantized
probability at the floating-point model's best class/anchor position. By default,
a drop greater than 0.20 at that position stops the export. Adjust this threshold
with `--max-score-drop`. Add `--diagnose-only` to the command above to run these
checks without compiling a PTE.

If `--validation-dir` is omitted, validation uses the calibration directory; the
default validation limit is 8 images. These checks detect obvious degradation and
are not a labeled mAP evaluation or a test of the compiled PTE on the NPU.

A same-name `.json` report records configuration, classes, the output contract,
calibration image paths and score comparisons. Successful compilation also records
PTE size and planned memory. A failed accuracy or memory-budget check leaves any
existing PTE untouched; inspect the report status before using an older output file.

### FVP input-layout diagnosis

The first exported PTE had logical input shape `[1, 3, 320, 320]` but serialized
`dim_order=[2, 0, 3, 1]`: its RGB channels were interleaved in storage. Writing
planar NCHW data based only on the shape scrambled the input, causing a missed
`call` and several misplaced `like` boxes. This was an input-layout mismatch,
not an XYWH decoding error.

The exporter now makes inputs contiguous and records `serialized_tensor_layouts`
in its JSON report. Firmware preprocessing uses the tensor's actual storage
strides, so it also handles the previously exported PTE. Rebuild the firmware;
rerunning an old AXF does not apply the fix.

FVP verification with the existing `best_clean_ethos-u85-512.pte` produced:

| Sample | Best detection | Score | Box `(x, y, width, height)` in the 320x320 input |
| --- | --- | ---: | --- |
| call | call | 0.940050 | `(105, 101, 73, 73)` |
| like | like | 0.989602 | `(109, 175, 69, 98)` |

The call sample also has a low-score like candidate (0.179671), retained by the
0.10 threshold and class-aware NMS. These coordinates refer to the cropped model
input, not the original uncropped image. Physical-board validation is still required.

### NPU and memory configuration

| Option | Purpose |
| --- | --- |
| `--target` | NPU variant and MAC count, for example `ethos-u85-512` |
| `--vela-config` | Vela hardware configuration INI file |
| `--system-config` | System_Config section matching the hardware memory connections |
| `--memory-mode` | Memory_Mode section, including custom names from the INI |
| `--arena-cache-size` | Vela arena cache size in bytes, overriding the INI setting |
| `--extra-flag` | Repeatable Vela option, such as `--extra-flag=--verbose-performance` |
| `--memory-alignment` | ExecuTorch memory alignment, a power of two >= 16; default 16 |
| `--max-planned-memory` | Byte budget for total planned nonconstant memory; aborts if exceeded |

For example, add `--max-planned-memory 3145728` to enforce a 3 MiB planned-memory
budget. This checks the result; it does not force a larger model to fit the budget.
For a system configuration with a writable external arena and an internal SRAM
cache, use `--memory-mode Dedicated_Sram --arena-cache-size 393216` as appropriate
for the hardware. An arena cache size is not a limit on all SRAM in `Shared_Sram` mode.

Additional Vela flags may be repeated, for example:

```text
--extra-flag=--verbose-performance --extra-flag=--verbose-cycle-estimate
```

Each different MAC configuration or memory mode requires a separately exported
PTE. Do not use a PTE exported for `ethos-u85-512` with a `Z256` or `Z1024` runtime.
The MAC configuration is controlled by `--target` during export and
`YOLOV8_NPU_CONFIG_ID` during the MLEK build. Set `YOLOV8_NPU_MACS` consistently;
it supplies build target metadata and selects the MAC count in the FVP run script.

Planned ExecuTorch memory is not the complete application RAM requirement. Check
Vela scratch/cache requirements, runtime temporary allocations, stack and other
application memory against the firmware allocation and linker layout. Exporting
does not change those firmware settings.

### Build with the exported PTE

Select `gesture_pte` and explicitly point the build at the new output:

```sh
YOLOV8_MODEL_VARIANT=gesture_pte \
YOLOV8_MODEL_PATH="$PWD/resources_downloaded/gesture_detection/best_clean_ethos-u85-512.pte" \
YOLOV8_SCORE_LOGITS=1 \
YOLOV8_SCORE_SCALE=1.0 \
./scripts/build_yolov8_fvp320.sh
```

The build script accepts these environment overrides when a different generated
PTE or platform layout is needed:

```text
YOLOV8_MODEL_PATH
YOLOV8_NPU_ID
YOLOV8_NPU_CONFIG_ID
YOLOV8_NPU_MACS
YOLOV8_MEMORY_MODE
YOLOV8_NPU_CACHE_SIZE
YOLOV8_ACTIVATION_BUF_SIZE
YOLOV8_ET_TMP_MEM_SIZE
YOLOV8_ET_TMP_MEM_BASE
YOLOV8_IMAGE_SIZE
YOLOV8_NUM_CLASSES
YOLOV8_SCORE_LOGITS
YOLOV8_SCORE_SCALE
```

`YOLOV8_ACTIVATION_BUF_SIZE` is the application activation buffer.
`YOLOV8_ET_TMP_MEM_SIZE` and optional `YOLOV8_ET_TMP_MEM_BASE` configure the
ExecuTorch runtime temporary allocation pool. These settings and
`YOLOV8_NPU_CACHE_SIZE` must be checked separately from the planned memory in the
JSON report and the Ethos-U SRAM requirement reported by Vela.

### Reading the runtime memory report

The runtime prints model storage address/size and each allocator's address,
capacity, current usage and peak usage. It also prints total reserved pool bytes,
the sum of pool peaks, and both totals with PTE storage included. The FVP run script
saves console output to `logs/yolov8_gesture_pte_fvp320.log` for `gesture_pte`.

For the verified build above:

| Allocation | Actual FVP region / address | Reserved or stored bytes | Measured pool peak bytes |
| --- | --- | ---: | ---: |
| PTE weights and command stream | DDR, `0x70096000` | 3,006,896 | N/A |
| Method pool | SRAM, `0x31000000` | 3,145,728 | 2,765,677 |
| Temporary pool including delegate scratch | DDR, `0x94000000` | 16,777,216 | 823,872 |

Runtime pools reserve **19 MiB** (19,922,944 bytes). Their peak sum is
3,589,549 bytes (about 3.42 MiB); individual peaks need not occur simultaneously.
PTE plus reserved pools is 22,929,840 bytes (about 21.87 MiB); PTE plus pool peaks
is 6,596,445 bytes (about 6.29 MiB). These are model-storage/runtime-pool totals,
not whole-firmware memory requirements.

The 1,536,000-byte planned buffer and the 1,228,800-byte additional input buffer
are already inside the method pool. Delegate scratch is included in the temporary
pool for this build. Do not add those sizes or Vela's SRAM figure a second time.
Code, general heap, stack, display/sample data and any separate NPU cache are
outside these totals. The PTE is currently in FVP DDR, even though the Vela system
configuration is named `Ethos_U85_SRAM_MRAM`; actual placement comes from the
firmware linker/platform configuration, not that name.

Before moving to hardware, check the actual linker map, NPU access to each region,
cache mode and measured peaks across representative inputs. The current 16 MiB
temporary capacity is a reservation, not evidence of a 16 MiB runtime requirement.
Changing `YOLOV8_ET_TMP_MEM_SIZE` requires rebuilding and checking the resulting
platform layout and inference again; retain headroom rather than setting capacity
to exactly one observed peak.

To run without display windows and exit after completion:

```sh
YOLOV8_MODEL_VARIANT=gesture_pte \
YOLOV8_BOARD_VISUALISATION_DISABLED=1 \
YOLOV8_HDLCD_VISUALISATION_DISABLED=1 \
YOLOV8_SHUTDOWN_ON_EOT=1 \
./scripts/run_yolov8_fvp320.sh
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
