# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

"""Model adaptation, image preparation and accuracy checks for YOLO PTE export."""

import random
from pathlib import Path
import types

import torch
from PIL import Image, ImageOps
from torchvision.transforms.functional import pil_to_tensor
from ultralytics import YOLO


def split_inference(head: torch.nn.Module, predictions: dict) -> tuple:
    """Decode boxes without combining their quantization range with class logits."""
    return getattr(head, "_get_decode_boxes")(predictions), predictions["scores"]


class ExportYolo(torch.nn.Module):
    """Return one contiguous tensor of normalized XYWH and class probabilities."""

    def __init__(self, model: torch.nn.Module, image_size: int):
        """Store the detection model and its fixed square input size."""
        super().__init__()
        self.model = model
        self.image_size = image_size

    def forward(self, inputs: torch.Tensor) -> torch.Tensor:
        """Normalize boxes before concatenating them with probabilities."""
        boxes, logits = self.model(inputs)
        return torch.cat((boxes / self.image_size, logits.sigmoid()), dim=1).contiguous()


def load_model(path: Path, image_size: int, example: torch.Tensor) -> tuple:
    """Adapt a supported Detect head and verify parity with its original output."""
    yolo = YOLO(str(path))
    model = yolo.model.cpu().float().eval()
    head = model.model[-1]
    if yolo.task != "detect" or getattr(head, "end2end", False):
        raise ValueError("Only non-end-to-end Ultralytics detection checkpoints are supported")
    if not callable(getattr(head, "_get_decode_boxes", None)):
        raise ValueError("This Ultralytics Detect version lacks _get_decode_boxes")
    head.export = True
    with torch.no_grad():
        original = model(example)
    setattr(head, "_inference", types.MethodType(split_inference, head))
    wrapper = ExportYolo(model, image_size).eval()
    with torch.no_grad():
        output = wrapper(example)
        boxes, probabilities = output[:, :4], output[:, 4:]
        if boxes.shape[1] != 4 or probabilities.shape[1] != head.nc:
            raise ValueError("Unexpected detection output layout")
        torch.testing.assert_close(boxes * image_size, original[:, :4])
        torch.testing.assert_close(probabilities, original[:, 4:])
    return wrapper, model.names


def find_images(directory: Path, limit: int, seed: int) -> list[Path]:
    """Select a reproducible shuffled sample instead of a class-sorted prefix."""
    if not directory.is_dir():
        raise NotADirectoryError(directory)
    paths = sorted(path for path in directory.rglob("*")
                   if path.is_file() and path.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"})
    if not paths:
        raise ValueError(f"No calibration images found in {directory}")
    random.Random(seed).shuffle(paths)
    return paths[:limit] if limit else paths


def load_image(path: Path, image_size: int, preprocessing: str) -> torch.Tensor:
    """Load RGB / 255 NCHW data using the selected deployment resize policy."""
    with Image.open(path) as source:
        image = source.convert("RGB")
    if preprocessing == "mlek-crop":
        ratio = image_size / min(image.size)
        image = image.resize((int(image.width * ratio), int(image.height * ratio)),
                             Image.Resampling.BILINEAR)
        left = (image.width - image_size) * 0.9
        top = (image.height - image_size) / 2
        image = image.crop((left, top, left + image_size, top + image_size))
    elif preprocessing == "letterbox":
        ratio = image_size / max(image.size)
        image = image.resize((round(image.width * ratio), round(image.height * ratio)),
                             Image.Resampling.BILINEAR)
        width, height = image_size - image.width, image_size - image.height
        image = ImageOps.expand(image, (width // 2, height // 2,
                                      width - width // 2, height - height // 2),
                                fill=(114, 114, 114))
    else:
        raise ValueError(f"Unknown preprocessing: {preprocessing}")
    return (pil_to_tensor(image).float().unsqueeze(0) / 255.0).contiguous()


def compare_outputs(reference: torch.Tensor, actual: torch.Tensor) -> dict:
    """Compare probabilities at identical anchors, including the strongest detection."""
    if reference.shape != actual.shape or not torch.isfinite(actual).all():
        raise ValueError("Output shape mismatch or non-finite inference result")
    boxes, probabilities = reference[:, :4], reference[:, 4:]
    quant_boxes, quant_probabilities = actual[:, :4], actual[:, 4:]
    if quant_probabilities.min() < 0 or quant_probabilities.max() > 1:
        raise ValueError("Quantized probabilities are outside [0, 1]")
    best = int(probabilities.flatten().argmax())
    return {
        "float_max_probability": float(probabilities.max()),
        "quantized_max_probability": float(quant_probabilities.max()),
        "quantized_probability_at_float_best": float(quant_probabilities.flatten()[best]),
        "best_probability_drop": float(probabilities.flatten()[best]
                                       - quant_probabilities.flatten()[best]),
        "probability_mae": float((probabilities - quant_probabilities).abs().mean()),
        "box_mae_normalized": float((boxes - quant_boxes).abs().mean()),
        "float_probability_range": [float(probabilities.min()), float(probabilities.max())],
        "quantized_probability_range": [float(quant_probabilities.min()),
                                        float(quant_probabilities.max())],
    }
