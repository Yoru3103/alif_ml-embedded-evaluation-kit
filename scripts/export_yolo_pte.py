#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

"""Export Ultralytics PT to Ethos-U PTE with an explicit, checked output contract."""

import argparse
import json
import os
from pathlib import Path
import sys

import torch
from executorch.backends.arm.ethosu import EthosUPartitioner, EthosUCompileSpec
from executorch.backends.arm.quantizer import EthosUQuantizer, get_symmetric_quantization_config
from executorch.backends.cortex_m.passes.quantized_op_fusion_pass import QuantizedOpFusionPass
from executorch.backends.cortex_m.passes.replace_quant_nodes_pass import ReplaceQuantNodesPass
from executorch.exir import EdgeCompileConfig, ExecutorchBackendConfig, to_edge_transform_and_lower
from executorch.exir.passes.memory_planning_pass import MemoryPlanningPass
from executorch.exir.schema import ExecutionPlan, ScalarType
from torchao.quantization.pt2e.quantize_pt2e import convert_pt2e, prepare_pt2e

from yolo_pte_utils import compare_outputs, find_images, load_image, load_model

ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    """Parse model, calibration, NPU and memory options."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--calibration-dir", type=Path, required=True)
    parser.add_argument("--validation-dir", type=Path,
                        help="Independent images for quantization checks; defaults to calibration")
    parser.add_argument("--calibration-limit", type=int, default=128, help="0 uses all images")
    parser.add_argument("--validation-limit", type=int, default=8)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--image-size", type=int, default=320)
    parser.add_argument("--preprocessing", choices=("mlek-crop", "letterbox"), default="mlek-crop")
    parser.add_argument("--per-channel", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--max-score-drop", type=float, default=0.20,
                        help="Abort if probability at an FP32 best anchor drops more than this")
    parser.add_argument("--diagnose-only", action="store_true",
                        help="Check float and PT2E results without compiling a PTE")
    npu = parser.add_argument_group("NPU / Vela")
    npu.add_argument("--target", default="ethos-u85-512")
    npu.add_argument("--vela-config", type=Path, default=ROOT / "scripts/vela/ensemble_vela.ini")
    npu.add_argument("--system-config", default="Ethos_U85_SRAM_MRAM")
    npu.add_argument("--memory-mode", default="Shared_Sram",
                     help="Memory_Mode section in the Vela INI, including custom modes")
    npu.add_argument("--arena-cache-size", type=int,
                     help="Vela arena cache bytes; meaningful for cache-based memory modes")
    npu.add_argument("--extra-flag", action="append", default=[],
                     help="Repeat as --extra-flag=--verbose-performance")
    memory = parser.add_argument_group("ExecuTorch memory")
    memory.add_argument("--memory-alignment", type=int, default=16)
    memory.add_argument("--max-planned-memory", type=int,
                        help="Abort if total planned nonconstant memory exceeds this byte budget")
    args = parser.parse_args()
    if not args.model.is_file() or not args.vela_config.is_file():
        parser.error("--model and --vela-config must name existing files")
    if args.output.suffix != ".pte":
        parser.error("--output must have a .pte suffix")
    if args.image_size <= 0 or args.image_size % 32:
        parser.error("--image-size must be a positive multiple of 32")
    if args.calibration_limit < 0 or args.validation_limit <= 0 or args.threads <= 0:
        parser.error("Invalid image limit or thread count")
    if not 0 <= args.max_score_drop <= 1:
        parser.error("--max-score-drop must be in [0, 1]")
    if args.memory_alignment < 16 or args.memory_alignment & (args.memory_alignment - 1):
        parser.error("--memory-alignment must be a power of two >= 16")
    if any(value is not None and value <= 0 for value in
           (args.arena_cache_size, args.max_planned_memory)):
        parser.error("Memory sizes must be positive byte counts")
    return args


def make_compile_spec(args: argparse.Namespace) -> EthosUCompileSpec:
    """Build the NPU compile specification without mutating argument lists."""
    flags = list(args.extra_flag)
    if args.arena_cache_size is not None:
        flags.append(f"--arena-cache-size={args.arena_cache_size}")
    return EthosUCompileSpec(target=args.target, config_ini=str(args.vela_config.resolve()),
                            system_config=args.system_config, memory_mode=args.memory_mode,
                            extra_flags=flags)


def quantize(model: torch.nn.Module, paths: list[Path], args: argparse.Namespace,
             spec: EthosUCompileSpec) -> torch.fx.GraphModule:
    """Export and calibrate using representative images without tracking gradients."""
    example = load_image(paths[0], args.image_size, args.preprocessing)
    exported = torch.export.export(model, (example,), strict=True)
    quantizer = EthosUQuantizer(spec).set_global(
        get_symmetric_quantization_config(is_per_channel=args.per_channel))
    prepared = prepare_pt2e(exported.module(check_guards=False), quantizer)
    with torch.no_grad():
        for index, path in enumerate(paths, 1):
            prepared(load_image(path, args.image_size, args.preprocessing))
            if index % 16 == 0 or index == len(paths):
                print(f"Calibrated {index}/{len(paths)}", flush=True)
    return convert_pt2e(prepared)


def validate(model: torch.nn.Module, quantized: torch.fx.GraphModule,
             paths: list[Path], args: argparse.Namespace) -> list[dict]:
    """Check the exported FP32 graph and quantized outputs on the same input tensors."""
    example = load_image(paths[0], args.image_size, args.preprocessing)
    exported = torch.export.export(model, (example,), strict=True).module(check_guards=False)
    results = []
    with torch.no_grad():
        for path in paths:
            inputs = load_image(path, args.image_size, args.preprocessing)
            reference = model(inputs)
            torch.testing.assert_close(actual=exported(inputs), expected=reference)
            result = {"image": str(path), **compare_outputs(reference, quantized(inputs))}
            results.append(result)
            print(f"{path.name}: FP32={result['float_max_probability']:.4f}, "
                  f"PT2E={result['quantized_max_probability']:.4f}, "
                  f"same-anchor={result['quantized_probability_at_float_best']:.4f}", flush=True)
    return results


def lower(quantized: torch.fx.GraphModule, example: torch.Tensor,
          spec: EthosUCompileSpec, args: argparse.Namespace) -> object:
    """Lower to Ethos-U and plan memory while retaining float input/output tensors."""
    exported = torch.export.export(quantized, (example,), strict=True)
    edge = to_edge_transform_and_lower(exported, partitioner=[EthosUPartitioner(spec)],
                                      compile_config=EdgeCompileConfig(_check_ir_validity=False))
    edge = edge.transform([ReplaceQuantNodesPass(), QuantizedOpFusionPass()])
    return edge.to_executorch(config=ExecutorchBackendConfig(
        extract_delegate_segments=False,
        memory_planning_pass=MemoryPlanningPass(alignment=args.memory_alignment)))


def check_io_contract(plan: ExecutionPlan, image_size: int, num_classes: int) -> dict:
    """Reject PTE layouts or types that the original MLEK pipeline cannot consume."""
    if len(plan.inputs) != 1 or len(plan.outputs) != 1:
        raise ValueError("MLEK requires exactly one input and one output")
    input_tensor = plan.values[plan.inputs[0]].val
    output_tensor = plan.values[plan.outputs[0]].val
    if input_tensor.sizes != [1, 3, image_size, image_size]:
        raise ValueError("Unexpected input shape")
    if (len(output_tensor.sizes) != 3 or output_tensor.sizes[:2] != [1, 4 + num_classes]
            or output_tensor.sizes[2] <= 0):
        raise ValueError("Expected output [1, 4 + classes, N]")
    for tensor in (input_tensor, output_tensor):
        if tensor.scalar_type != ScalarType.FLOAT:
            raise ValueError("MLEK input/output must be float32")
        if tensor.dim_order != list(range(len(tensor.sizes))):
            raise ValueError("MLEK input/output must use contiguous dimension order")
    return {label: [{"shape": tensor.sizes, "dim_order": tensor.dim_order}]
            for label, tensor in (("inputs", input_tensor), ("outputs", output_tensor))}


def save_report(output: Path, report: dict):
    """Write a human-readable sidecar with the contract, configuration and diagnostics."""
    path = output.with_suffix(".json")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Report: {path}", flush=True)


def main():
    """Run the export stages, rejecting excessive measured score degradation."""
    args = parse_args()
    # Do not resolve python symlinks: flatc lives in the virtualenv bin directory.
    os.environ["PATH"] = os.pathsep.join(
        (str(Path(sys.executable).absolute().parent), os.environ.get("PATH", "")))
    torch.set_num_threads(args.threads)
    paths = find_images(args.calibration_dir, args.calibration_limit, args.seed)
    checks = find_images(args.validation_dir or args.calibration_dir,
                         args.validation_limit, args.seed + 1)
    example = load_image(paths[0], args.image_size, args.preprocessing)
    model, names = load_model(args.model, args.image_size, example)
    spec = make_compile_spec(args)
    quantized = quantize(model, paths, args, spec)
    results = validate(model, quantized, checks, args)
    report = {
        "status": "quantization_checked",
        "configuration": {key: str(value) if isinstance(value, Path) else value
                          for key, value in vars(args).items()},
        "classes": names,
        "contract": {"input": "float32 contiguous RGB NCHW /255",
                     "output": "float32 contiguous [1,4+C,N]: normalized XYWH + probabilities",
                     "postprocessing": "original MLEK YOLO; no sigmoid or score scaling"},
        "calibration_images": [str(path) for path in paths],
        "validation": results,
        "validation_scope": "FP32 versus host PT2E; compiled NPU execution is not tested here",
    }
    if max(item["best_probability_drop"] for item in results) > args.max_score_drop:
        report["status"] = "score_drop_exceeded"
        save_report(args.output, report)
        raise RuntimeError("Quantization score drop exceeds --max-score-drop; inspect the report")
    save_report(args.output, report)
    if args.diagnose_only:
        return
    program = lower(quantized, example, spec, args)
    plan = program.executorch_program.execution_plan[0]
    report["serialized_tensor_layouts"] = check_io_contract(plan, args.image_size, len(names))
    buffers = list(plan.non_const_buffer_sizes)
    report["planned_buffer_bytes"] = buffers
    report["planned_total_bytes"] = sum(buffers)
    if args.max_planned_memory is not None and sum(buffers) > args.max_planned_memory:
        report["status"] = "memory_budget_exceeded"
        save_report(args.output, report)
        raise RuntimeError(
            f"Planned memory {sum(buffers)} exceeds budget {args.max_planned_memory}")
    temporary = args.output.with_suffix(".pte.tmp")
    try:
        with temporary.open("wb") as stream:
            program.write_to_file(stream)
        temporary.replace(args.output)
    finally:
        temporary.unlink(missing_ok=True)
    report["status"] = "pte_written"
    report["pte_bytes"] = args.output.stat().st_size
    save_report(args.output, report)
    print(f"PTE: {args.output}; planned memory: {sum(buffers)} bytes", flush=True)


if __name__ == "__main__":
    main()
