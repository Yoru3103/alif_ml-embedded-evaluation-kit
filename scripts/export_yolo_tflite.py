# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

"""Export a trained Ultralytics YOLO model to TFLite."""

import argparse
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory

from ultralytics import YOLO
from ultralytics.utils import YAML


def make_calibration_yaml(data: Path, split: str, temporary_dir: Path) -> Path:
    """Create a temporary data YAML whose validation split is used for calibration.

    :param data: Original Ultralytics dataset YAML.
    :param split: Dataset split to use for calibration.
    :param temporary_dir: Directory for the temporary YAML when using ``train``.
    :returns: Original YAML for ``val`` or a temporary YAML for ``train``.
    :raises ValueError: If the original YAML does not define a training split.
    """
    if split == "val":
        return data

    configuration = YAML.load(str(data))
    if "train" not in configuration:
        raise ValueError(f"Dataset YAML does not define a train split: {data}")

    configuration["val"] = configuration["train"]
    calibration_data = temporary_dir / data.name
    YAML.save(str(calibration_data), configuration)
    return calibration_data


def export_models(
    weights: Path,
    data: Path,
    imgsz: int,
    calibration_split: str,
    output_dir: Path | None,
) -> tuple[Path, Path]:
    """Export floating-point and INT8 TFLite models.

    :param weights: Trained Ultralytics checkpoint.
    :param data:    Dataset YAML used for quantization calibration.
    :param imgsz:   Input image size matching the ExecuTorch export.
    :param calibration_split: Dataset split used for INT8 calibration.
    :param output_dir: Directory for exported TFLite files; defaults to the
                       checkpoint directory.
    """
    if not weights.is_file():
        raise FileNotFoundError(f"Checkpoint not found: {weights}")

    if not data.is_file():
        raise FileNotFoundError(f"Dataset YAML not found: {data}")

    if imgsz <= 0 or imgsz % 32:
        raise ValueError("imgsz must be a positive multiple of 32")

    common_options = {
        # ``tflite`` is a deprecated alias in recent Ultralytics releases;
        # ``litert`` still produces a .tflite file and is the current API.
        "format": "litert",
        "imgsz": imgsz,
        "batch": 1,
        "device": "cpu",
        "nms": False,
    }

    if output_dir is not None:
        output_dir.mkdir(parents=True, exist_ok=True)

    # Ultralytics derives the output filename from the checkpoint location.
    # Stage the checkpoint when the caller requests a separate output folder.
    with TemporaryDirectory(prefix="yolo_tflite_export-") as export_dir_name:
        export_weights = weights
        if output_dir is not None:
            export_weights = Path(export_dir_name) / weights.name
            shutil.copy2(weights, export_weights)

        print("Exporting floating-point TFLite...")
        float_output = YOLO(str(export_weights)).export(
            **common_options,
            quantize=None,
        )
        print(f"Floating-point export: {float_output}")

        print(f"Exporting int8 TFLite with {calibration_split} calibration...")
        with TemporaryDirectory(prefix="yolo_tflite_calibration-") as temporary_dir_name:
            calibration_data = make_calibration_yaml(
                data, calibration_split, Path(temporary_dir_name)
            )
            int8_output = YOLO(str(export_weights)).export(
                **common_options,
                quantize=8,
                data=str(calibration_data),
                fraction=1.0,
            )

        if output_dir is not None:
            float_destination = output_dir / Path(float_output).name
            int8_destination = output_dir / Path(int8_output).name
            shutil.copy2(float_output, float_destination)
            shutil.copy2(int8_output, int8_destination)
            float_output = float_destination
            int8_output = int8_destination

    print(f"INT8 export: {int8_output}")
    print(f"Output directory: {Path(float_output).parent}")
    print("Inspect the generated files and tensor types before Vela compilation.")
    return Path(float_output), Path(int8_output)


def main():
    """Parse command-line arguments and export the checkpoint."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, required=True,
                        help="Path to the Ultralytics best.pt checkpoint.")
    parser.add_argument("--data", type=Path, required=True,
                        help="Dataset YAML used for INT8 calibration.")
    parser.add_argument("--imgsz", type=int, default=320,
                        help="Square input size in pixels (default: 320).")
    parser.add_argument("--calibration-split", choices=("train", "val"), default="train",
                        help="Dataset split for INT8 calibration (default: train).")
    parser.add_argument("--output-dir", type=Path,
                        help="Directory for TFLite files (default: checkpoint directory).")
    args = parser.parse_args()

    export_models(
        weights=args.weights.resolve(),
        data=args.data.resolve(),
        imgsz=args.imgsz,
        calibration_split=args.calibration_split,
        output_dir=args.output_dir.resolve() if args.output_dir else None,
    )


if __name__ == "__main__":
    main()
