#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0
"""Export official MobileNetV2 weights with local calibration images to Ethos-U PTE."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

import torch
from PIL import Image
from torchvision.models import mobilenet_v2
from torchvision.transforms import Compose, Normalize, Resize, ToTensor
from executorch.backends.arm.ethosu import EthosUCompileSpec, EthosUPartitioner
from executorch.backends.arm.quantizer import EthosUQuantizer, get_symmetric_quantization_config
from executorch.backends.cortex_m.passes.quantized_op_fusion_pass import QuantizedOpFusionPass
from executorch.backends.cortex_m.passes.replace_quant_nodes_pass import ReplaceQuantNodesPass
from executorch.exir import EdgeCompileConfig, ExecutorchBackendConfig, to_edge_transform_and_lower
from executorch.exir.passes.memory_planning_pass import MemoryPlanningPass
from executorch.exir.schema import ExecutionPlan, ScalarType
from torchao.quantization.pt2e.quantize_pt2e import convert_pt2e, prepare_pt2e


def parse_args() -> argparse.Namespace:
    """Parse explicit model, hardware and memory configuration."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--weights', type=Path, required=True)
    parser.add_argument('--samples', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--system-config', required=True)
    parser.add_argument('--memory-mode', choices=['Shared_Sram', 'Dedicated_Sram'], required=True)
    parser.add_argument('--macs', type=int, required=True)
    parser.add_argument('--arena-cache-size', type=int, required=True)
    parser.add_argument('--memory-budget', type=int, required=True)
    return parser.parse_args()


def quantize_and_lower(model: torch.nn.Module, inputs: list[torch.Tensor],
                       paths: list[Path], args: argparse.Namespace) -> tuple[object, list[dict]]:
    """Calibrate and lower MobileNetV2 using the selected Ethos-U memory profile.

    :param model:   Official model with loaded weights.
    :param inputs:  Normalized calibration tensors.
    :param paths:   Corresponding sample paths.
    :param args:    Export configuration.
    :returns:       Compiled program and host prediction checks.
    """
    spec = EthosUCompileSpec(
        target=f'ethos-u85-{args.macs}', config_ini=str(args.config),
        system_config=args.system_config, memory_mode=args.memory_mode,
        extra_flags=[f'--arena-cache-size={args.arena_cache_size}'])
    exported = torch.export.export(model, (inputs[0],), strict=True)
    quantizer = EthosUQuantizer(spec).set_global(
        get_symmetric_quantization_config(is_per_channel=True))
    prepared = prepare_pt2e(exported.module(check_guards=False), quantizer)
    with torch.no_grad():
        for tensor in inputs:
            prepared(tensor)
    quantized = convert_pt2e(prepared)
    with torch.no_grad():
        predictions = [{'image': path.name, 'float_top1': model(tensor).argmax().item(),
                        'quantized_top1': quantized(tensor).argmax().item()}
                       for path, tensor in zip(paths, inputs)]
    exported = torch.export.export(quantized, (inputs[0],), strict=True)
    edge = to_edge_transform_and_lower(
        exported, partitioner=[EthosUPartitioner(spec)],
        compile_config=EdgeCompileConfig(_check_ir_validity=False))
    edge = edge.transform([ReplaceQuantNodesPass(), QuantizedOpFusionPass()])
    program = edge.to_executorch(config=ExecutorchBackendConfig(
        extract_delegate_segments=False,
        memory_planning_pass=MemoryPlanningPass(alignment=16)))
    return program, predictions


def check_plan(plan: ExecutionPlan, memory_budget: int) -> list[int]:
    """Verify tensor contracts, delegation and planned memory with allocator headroom.

    :param plan:            Serialized execution plan.
    :param memory_budget:   Firmware arena budget in bytes.
    :returns:               Planned buffer sizes in bytes.
    :raises ValueError:     The plan violates the firmware contract.
    """
    if len(plan.inputs) != 1 or len(plan.outputs) != 1:
        raise ValueError('Expected one input and output')
    for index, shape in [(plan.inputs[0], [1, 3, 224, 224]), (plan.outputs[0], [1, 1000])]:
        tensor = plan.values[index].val
        if (tensor.sizes != shape or tensor.scalar_type != ScalarType.FLOAT
                or tensor.dim_order != list(range(len(shape)))):
            raise ValueError('Expected contiguous float32 NCHW input and [1,1000] output')
    buffers = list(plan.non_const_buffer_sizes)
    if sum(buffers) > memory_budget - 131072:
        raise ValueError(f'Planned buffers {buffers} exceed budget with 128 KiB headroom')
    if not any(delegate.id == 'EthosUBackend' for delegate in plan.delegates):
        raise ValueError('No Ethos-U delegate found')
    return buffers


def main():
    """Calibrate, compile and verify the firmware tensor and memory contracts."""
    args = parse_args()
    os.environ['PATH'] = str(Path(sys.executable).absolute().parent) + ':' + os.environ['PATH']
    torch.set_num_threads(4)
    torch.manual_seed(0)
    model = mobilenet_v2(weights=None).eval()
    model.load_state_dict(torch.load(args.weights, map_location='cpu', weights_only=True))
    transform = Compose([Resize((224, 224)), ToTensor(),
                         Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225])])
    paths = sorted(args.samples.glob('*.bmp'))
    if not paths:
        raise ValueError('Calibration requires local BMP samples')
    inputs = []
    for path in paths:
        with Image.open(path) as image:
            inputs.append(transform(image.convert('RGB')).unsqueeze(0).contiguous())
    program, predictions = quantize_and_lower(model, inputs, paths, args)
    plan = program.executorch_program.execution_plan[0]
    buffers = check_plan(plan, args.memory_budget)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix('.pte.tmp')
    with temporary.open('wb') as stream:
        program.write_to_file(stream)
    temporary.replace(args.output)
    report = {
        'configuration': {key: str(value) for key, value in vars(args).items()},
        'weights_sha256': hashlib.sha256(args.weights.read_bytes()).hexdigest(),
        'pte_sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(),
        'planned_buffer_bytes': buffers, 'host_predictions': predictions,
        'validation_scope': 'Local calibration samples only; NPU execution not validated',
    }
    args.output.with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PTE: {args.output}; planned buffers: {buffers}', flush=True)


if __name__ == '__main__':
    main()
