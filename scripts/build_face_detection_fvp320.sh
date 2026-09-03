#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${REPO_ROOT}/build-fvp320-face-detection"
MODEL_PATH="${FACE_DETECTION_MODEL_PATH:-${REPO_ROOT}/resources_downloaded/object_detection/yolo-fastest_192_face_v4_vela_Z256.tflite}"
INPUT_PATH="${FACE_DETECTION_INPUT_PATH:-${REPO_ROOT}/resources/object_detection/samples}"

# Corstone-320 FVP: Ethos-U85, 256 MACs, Shared SRAM.
IMAGE_SIZE=192
NPU_MEMORY_MODE=Shared_Sram
ACTIVATION_BUF_SIZE=0x00082000
BUILD_JOBS="${BUILD_JOBS:-8}"

if [[ ! -f "${MODEL_PATH}" ]]; then
    printf 'Face detection model not found: %s\n' "${MODEL_PATH}" >&2
    printf 'Prepare the U85/Z256 Shared_Sram Vela model first.\n' >&2
    exit 1
fi

if [[ ! -e "${INPUT_PATH}" ]]; then
    printf 'Face detection input path not found: %s\n' "${INPUT_PATH}" >&2
    exit 1
fi

printf 'Configuring face detection FVP build\n'
printf '  Build directory: %s\n' "${BUILD_DIR}"
printf '  Model:           %s\n' "${MODEL_PATH}"
printf '  Input:           %s\n' "${INPUT_PATH}"
printf '  Image size:      %s\n' "${IMAGE_SIZE}"
printf '  Memory mode:     %s\n' "${NPU_MEMORY_MODE}"

cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" \
    -DTARGET_PLATFORM=mps4 \
    -DTARGET_SUBSYSTEM=sse-320 \
    -DML_FRAMEWORK=TensorFlowLiteMicro \
    -DUSE_CASE_BUILD=object_detection \
    -DUSE_SINGLE_INPUT=OFF \
    -DETHOS_U_NPU_ENABLED=ON \
    -DETHOS_U_NPU_ID=U85 \
    -DETHOS_U_NPU_CONFIG_ID=Z256 \
    -DETHOS_U_NPU_MEMORY_MODE="${NPU_MEMORY_MODE}" \
    -DETHOS_U_NPU_TIMING_ADAPTER_ENABLED=ON \
    -Dobject_detection_MODEL_PATH="${MODEL_PATH}" \
    -Dobject_detection_FILE_PATH="${INPUT_PATH}" \
    -Dobject_detection_IMAGE_SIZE="${IMAGE_SIZE}" \
    -Dobject_detection_ACTIVATION_BUF_SZ="${ACTIVATION_BUF_SIZE}"

cmake --build "${BUILD_DIR}" \
    --target mlek_object_detection \
    --parallel "${BUILD_JOBS}"

printf 'Build complete: %s\n' "${BUILD_DIR}/bin/mlek_object_detection.axf"
