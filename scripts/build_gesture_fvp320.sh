#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Select the Gesture model with GESTURE_MODEL_VARIANT:
#   tflite - TensorFlow Lite Micro model, Vela-compiled for Ethos-U85/Z1024
#   pte    - ExecuTorch PTE model, Vela-compiled for Ethos-U85/Z1024
MODEL_VARIANT="${GESTURE_MODEL_VARIANT:-tflite}"
case "${MODEL_VARIANT}" in
tflite)
    BUILD_DIR="${REPO_ROOT}/build-mps4-gesture-tflite"
    MODEL_PATH="${REPO_ROOT}/resources_downloaded/gesture_detection/best_int8_ethos-u85-1024.tflite"
    ML_FRAMEWORK=TensorFlowLiteMicro
    NPU_MEMORY_MODE="${GESTURE_MEMORY_MODE:-Shared_Sram}"
    ET_TMP_MEM_SIZE=""
    ET_TMP_MEM_BASE=""
    ;;
pte)
    BUILD_DIR="${REPO_ROOT}/build-mps4-gesture-pte"
    MODEL_PATH="${REPO_ROOT}/resources_downloaded/gesture_detection/best_dedicated_ethos-u85-1024.pte"
    ML_FRAMEWORK=ExecuTorch
    NPU_MEMORY_MODE="${GESTURE_MEMORY_MODE:-Dedicated_Sram}"
    ET_TMP_MEM_SIZE=0x00200000
    ET_TMP_MEM_BASE=""
    ;;
*)
    printf 'Unsupported Gesture model variant: %s (use tflite or pte)\n' \
        "${MODEL_VARIANT}" >&2
    exit 1
    ;;
esac

# The defaults above can be overridden for either model variant.
BUILD_DIR="${GESTURE_BUILD_DIR:-${BUILDv_DIR}}"
MODEL_PATH="${GESTURE_MODEL_PATH:-${MODEL_PATH}}"
INPUT_PATH="${GESTURE_INPUT_PATH:-${REPO_ROOT}/resources/gesture_detection/samples}"
LABELS_FILE="${GESTURE_LABELS_FILE:-${REPO_ROOT}/resources/gesture_detection/labels.txt}"
ET_TMP_MEM_SIZE="${GESTURE_ET_TMP_MEM_SIZE:-${ET_TMP_MEM_SIZE}}"
ET_TMP_MEM_BASE="${GESTURE_ET_TMP_MEM_BASE:-${ET_TMP_MEM_BASE}}"

IMAGE_SIZE="${GESTURE_IMAGE_SIZE:-320}"
NUM_CLASSES="${GESTURE_NUM_CLASSES:-10}"
DISPLAY_DOWNSCALE="${GESTURE_DISPLAY_DOWNSCALE:-2}"
ACTIVATION_BUF_SIZE="${GESTURE_ACTIVATION_BUF_SIZE:-0x00300000}"
MAX_DETECTIONS="${GESTURE_MAX_DETECTIONS:-20}"
SCORE_THRESHOLD="${GESTURE_SCORE_THRESHOLD:-0.45}"
NMS_THRESHOLD="${GESTURE_NMS_THRESHOLD:-0.45}"

# Corstone-320 FVP: Ethos-U85, 1024 MACs.
# ExecuTorch/PTE models use Dedicated_Sram on the target board.
NPU_ID="${GESTURE_NPU_ID:-U85}"
NPU_CONFIG_ID="${GESTURE_NPU_CONFIG_ID:-Z1024}"
NPU_MACS="${GESTURE_NPU_MACS:-1024}"
NPU_CACHE_SIZE="${GESTURE_NPU_CACHE_SIZE:-}"
TIMING_ADAPTER_ENABLED="${GESTURE_TIMING_ADAPTER_ENABLED:-OFF}"
CPU_PROFILE_ENABLED="${GESTURE_CPU_PROFILE_ENABLED:-ON}"
BUILD_JOBS="${BUILD_JOBS:-8}"

if [[ "${ML_FRAMEWORK}" == "ExecuTorch" ]]; then
    if [[ "${NPU_MEMORY_MODE}" == "Dedicated_Sram" ]]; then
        NPU_CACHE_SIZE="${GESTURE_NPU_CACHE_SIZE:-393216}"
    elif [[ "${NPU_MEMORY_MODE}" == "Shared_Sram" && "${GESTURE_ET_TMP_IN_SRAM:-OFF}" == "ON" ]]; then
        NPU_CACHE_SIZE=0
        MODEL_PATH="${GESTURE_MODEL_PATH:-${REPO_ROOT}/resources_downloaded/gesture_detection/best_shared_ethos-u85-1024.pte}"
    else
        printf 'PTE requires Dedicated_Sram or Shared_Sram with GESTURE_ET_TMP_IN_SRAM=ON.\n' >&2
        exit 1
    fi
fi

if [[ ! -f "${MODEL_PATH}" ]]; then
    printf 'Gesture %s model not found: %s\n' "${MODEL_VARIANT}" "${MODEL_PATH}" >&2
    if [[ "${MODEL_VARIANT}" == "pte" ]]; then
        printf 'Set GESTURE_MODEL_PATH to the ExecuTorch PTE model.\n' >&2
    else
        printf 'Set GESTURE_MODEL_PATH to the Vela-compiled TFLite model.\n' >&2
    fi
    exit 1
fi

if [[ ! -e "${INPUT_PATH}" ]]; then
    printf 'Gesture input path not found: %s\n' "${INPUT_PATH}" >&2
    exit 1
fi

if [[ ! -f "${LABELS_FILE}" ]]; then
    printf 'Gesture labels file not found: %s\n' "${LABELS_FILE}" >&2
    exit 1
fi

NPU_CACHE_OPTIONS=()
if [[ -n "${NPU_CACHE_SIZE}" ]]; then
    NPU_CACHE_OPTIONS+=("-DETHOS_U_NPU_CACHE_SIZE=${NPU_CACHE_SIZE}")
elif [[ "${NPU_MEMORY_MODE}" == "Dedicated_Sram" ]]; then
    NPU_CACHE_OPTIONS+=("-DETHOS_U_NPU_CACHE_SIZE=393216")
fi

FRAMEWORK_MEMORY_OPTIONS=()
if [[ "${ML_FRAMEWORK}" == "ExecuTorch" ]]; then
    if [[ -z "${ET_TMP_MEM_SIZE}" ]]; then
        printf 'ExecuTorch temporary memory size is empty. '
        printf 'Set GESTURE_ET_TMP_MEM_SIZE.\n' >&2
        exit 1
    fi
    FRAMEWORK_MEMORY_OPTIONS+=("-DML_FWK_TMP_MEM_SIZE=${ET_TMP_MEM_SIZE}")
    if [[ -n "${ET_TMP_MEM_BASE}" ]]; then
        FRAMEWORK_MEMORY_OPTIONS+=("-DML_FWK_TMP_MEM_BASE=${ET_TMP_MEM_BASE}")
    fi
fi

printf 'Configuring Gesture %s FVP build\n' "${ML_FRAMEWORK}"
printf '  Variant:         %s\n' "${MODEL_VARIANT}"
printf '  Build directory: %s\n' "${BUILD_DIR}"
printf '  Model:           %s\n' "${MODEL_PATH}"
printf '  Labels:          %s\n' "${LABELS_FILE}"
printf '  Input:           %s\n' "${INPUT_PATH}"
printf '  Image size:      %s\n' "${IMAGE_SIZE}"
printf '  Classes:         %s\n' "${NUM_CLASSES}"
printf '  NPU:             Ethos-%s %s (%s MACs)\n' "${NPU_ID}" "${NPU_CONFIG_ID}" "${NPU_MACS}"
printf '  Memory mode:     %s\n' "${NPU_MEMORY_MODE}"
printf '  CPU profiling:   %s\n' "${CPU_PROFILE_ENABLED}"
printf '  Activation buf:  %s\n' "${ACTIVATION_BUF_SIZE}"
if [[ "${ML_FRAMEWORK}" == "ExecuTorch" ]]; then
    printf '  ET temp memory:  %s\n' "${ET_TMP_MEM_SIZE}"
fi

cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" \
    -DTARGET_PLATFORM=mps4 \
    -DTARGET_SUBSYSTEM=sse-320 \
    -DML_FRAMEWORK="${ML_FRAMEWORK}" \
    -DMLEK_ET_TMP_IN_SRAM="${GESTURE_ET_TMP_IN_SRAM:-OFF}" \
    -DUSE_CASE_BUILD=yolov8_detection \
    -DUSE_SINGLE_INPUT=OFF \
    -DCPU_PROFILE_ENABLED="${CPU_PROFILE_ENABLED}" \
    -DETHOS_U_NPU_ENABLED=ON \
    -DETHOS_U_NPU_ID="${NPU_ID}" \
    -DETHOSU_TARGET_NPU_CONFIG="ethos-${NPU_ID}-${NPU_MACS}" \
    -DETHOS_U_NPU_CONFIG_ID="${NPU_CONFIG_ID}" \
    -DETHOS_U_NPU_MEMORY_MODE="${NPU_MEMORY_MODE}" \
    -DETHOS_U_NPU_TIMING_ADAPTER_ENABLED="${TIMING_ADAPTER_ENABLED}" \
    "${NPU_CACHE_OPTIONS[@]}" \
    "${FRAMEWORK_MEMORY_OPTIONS[@]}" \
    -Dyolov8_detection_MODEL_PATH="${MODEL_PATH}" \
    -Dyolov8_detection_FILE_PATH="${INPUT_PATH}" \
    -Dyolov8_detection_LABELS_YAML_FILE="${LABELS_FILE}" \
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
