#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# -----------------------------------------------------------------------------
# User configuration: best_int8, 256x256, Shared_Sram (enabled by default).
# -----------------------------------------------------------------------------
BUILD_DIR="${REPO_ROOT}/build-fvp320-yolov8-best"
MODEL_PATH="${REPO_ROOT}/vela_output/best_int8_z256/best_int8_vela.tflite"
IMAGE_SIZE=256
DISPLAY_DOWNSCALE=2
ACTIVATION_BUF_SIZE=0x00200000
NPU_MEMORY_MODE=Shared_Sram

# -----------------------------------------------------------------------------
# Alternative: yolov8n_int8, 640x640, Dedicated_Sram.
# Comment the block above and uncomment this block to use it.
# -----------------------------------------------------------------------------
# BUILD_DIR="${REPO_ROOT}/build-fvp320-yolov8n"
# MODEL_PATH="${REPO_ROOT}/vela_output/yolov8n_int8_z256_dedicated/yolov8n_int8_vela.tflite"
# IMAGE_SIZE=640
# DISPLAY_DOWNSCALE=4
# ACTIVATION_BUF_SIZE=0x01000000
# NPU_MEMORY_MODE=Dedicated_Sram

# A directory is scanned recursively. Unsupported files such as YAML and Markdown
# are skipped by the image generator.
INPUT_PATH="${REPO_ROOT}/20260827_Model"
LABELS_YAML="${REPO_ROOT}/resources/object_detection/samples/coco128.yaml"

NUM_CLASSES=80
MAX_DETECTIONS=20
SCORE_THRESHOLD=0.25
NMS_THRESHOLD=0.45
BUILD_JOBS="${BUILD_JOBS:-8}"

if [[ ! -f "${MODEL_PATH}" ]]; then
    printf 'Model not found: %s\n' "${MODEL_PATH}" >&2
    exit 1
fi

if [[ ! -e "${INPUT_PATH}" ]]; then
    printf 'Input path not found: %s\n' "${INPUT_PATH}" >&2
    exit 1
fi

if [[ ! -f "${LABELS_YAML}" ]]; then
    printf 'Labels YAML not found: %s\n' "${LABELS_YAML}" >&2
    exit 1
fi

NPU_CACHE_OPTIONS=()
if [[ "${NPU_MEMORY_MODE}" == "Dedicated_Sram" ]]; then
    NPU_CACHE_OPTIONS+=("-DETHOS_U_NPU_CACHE_SIZE=393216")
fi

printf 'Configuring YOLOv8 FVP build\n'
printf '  Build directory: %s\n' "${BUILD_DIR}"
printf '  Model:           %s\n' "${MODEL_PATH}"
printf '  Input:           %s\n' "${INPUT_PATH}"
printf '  Memory mode:     %s\n' "${NPU_MEMORY_MODE}"

cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" \
    -DTARGET_PLATFORM=mps4 \
    -DTARGET_SUBSYSTEM=sse-320 \
    -DML_FRAMEWORK=TensorFlowLiteMicro \
    -DUSE_CASE_BUILD=yolov8_detection \
    -DUSE_SINGLE_INPUT=OFF \
    -DETHOS_U_NPU_ENABLED=ON \
    -DETHOS_U_NPU_ID=U85 \
    -DETHOS_U_NPU_CONFIG_ID=Z256 \
    -DETHOS_U_NPU_MEMORY_MODE="${NPU_MEMORY_MODE}" \
    -DETHOS_U_NPU_TIMING_ADAPTER_ENABLED=ON \
    "${NPU_CACHE_OPTIONS[@]}" \
    -Dyolov8_detection_MODEL_PATH="${MODEL_PATH}" \
    -Dyolov8_detection_FILE_PATH="${INPUT_PATH}" \
    -Dyolov8_detection_LABELS_YAML_FILE="${LABELS_YAML}" \
    -Dyolov8_detection_IMAGE_SIZE="${IMAGE_SIZE}" \
    -Dyolov8_detection_DISPLAY_DOWNSCALE="${DISPLAY_DOWNSCALE}" \
    -Dyolov8_detection_ACTIVATION_BUF_SZ="${ACTIVATION_BUF_SIZE}" \
    -Dyolov8_detection_NUM_CLASSES="${NUM_CLASSES}" \
    -Dyolov8_detection_MAX_DETECTIONS="${MAX_DETECTIONS}" \
    -Dyolov8_detection_SCORE_THRESHOLD="${SCORE_THRESHOLD}" \
    -Dyolov8_detection_NMS_THRESHOLD="${NMS_THRESHOLD}"

cmake --build "${BUILD_DIR}" \
    --target mlek_yolov8_detection \
    --parallel "${BUILD_JOBS}"

printf 'Build complete: %s\n' "${BUILD_DIR}/bin/mlek_yolov8_detection.axf"
