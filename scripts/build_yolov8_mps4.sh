#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# -----------------------------------------------------------------------------
# User configuration. Select the model with YOLOV8_MODEL_VARIANT:
#   best_int8      - original FP32/NCHW single-output model
#   best_int8_new  - INT8/NHWC four-output model with 15 classes
#   gesture_pte    - ExecuTorch PTE model with 10 gesture classes
# Example: YOLOV8_MODEL_VARIANT=best_int8_new ./scripts/build_yolov8_mps4.sh
# -----------------------------------------------------------------------------
MODEL_VARIANT="${YOLOV8_MODEL_VARIANT:-best_int8}"
case "${MODEL_VARIANT}" in
best_int8)
    BUILD_DIR="${REPO_ROOT}/build-mps4-yolov8-best"
    MODEL_PATH="${REPO_ROOT}/vela_output/best_int8_z256/best_int8_vela.tflite"
    LABELS_FILE="${REPO_ROOT}/resources/object_detection/samples/coco128.yaml"
    INPUT_PATH="${REPO_ROOT}/20260827_Model/000000058350.jpg"
    NUM_CLASSES=80
    NPU_CONFIG_ID=Z256
    NPU_MACS=256
    SCORE_THRESHOLD=0.1
    IMAGE_SIZE=256
    ACTIVATION_BUF_SIZE=0x00200000
    ML_FRAMEWORK=TensorFlowLiteMicro
    ET_TMP_MEM_SIZE=""
    ET_TMP_MEM_BASE=""
    TIMING_ADAPTER_ENABLED=ON
    ;;
best_int8_new)
    BUILD_DIR="${REPO_ROOT}/build-mps4-yolov8-best-new"
    MODEL_PATH="${REPO_ROOT}/vela_output/best_int8_new_z1024/best_int8_new_vela.tflite"
    LABELS_FILE="${REPO_ROOT}/resources/object_detection/samples/labels_yolo15.txt"
    INPUT_PATH="${REPO_ROOT}/resources/object_detection/samples_best_new"
    NUM_CLASSES=15
    NPU_CONFIG_ID=Z512
    NPU_MACS=512
    SCORE_THRESHOLD=0.10
    IMAGE_SIZE=256
    ACTIVATION_BUF_SIZE=0x00200000
    ML_FRAMEWORK=TensorFlowLiteMicro
    ET_TMP_MEM_SIZE=""
    ET_TMP_MEM_BASE=""
    TIMING_ADAPTER_ENABLED=ON
    ;;
gesture_pte)
    BUILD_DIR="${REPO_ROOT}/build-mps4-yolov8-gesture-pte"
    MODEL_PATH="${REPO_ROOT}/resources_downloaded/gesture_detection/best_dedicated_ethos-u85-1024.pte"
    LABELS_FILE="${REPO_ROOT}/resources/gesture_detection/labels.txt"
    INPUT_PATH="${REPO_ROOT}/resources/gesture_detection/samples/"
    NUM_CLASSES=10
    NPU_CONFIG_ID=Z1024
    NPU_MACS=1024
    SCORE_THRESHOLD=0.45
    IMAGE_SIZE=320
    ACTIVATION_BUF_SIZE=0x00300000
    ML_FRAMEWORK=ExecuTorch
    NPU_MEMORY_MODE=Dedicated_Sram
    ET_TMP_MEM_SIZE=0x01000000
    ET_TMP_MEM_BASE=""
    TIMING_ADAPTER_ENABLED=ON
    ;;
*)
    printf 'Unsupported YOLOv8 model variant: %s\n' "${MODEL_VARIANT}" >&2
    exit 1
    ;;
esac

MODEL_PATH="${YOLOV8_MODEL_PATH:-${MODEL_PATH}}"
LABELS_FILE="${YOLOV8_LABELS_FILE:-${YOLOV8_LABELS_YAML:-${LABELS_FILE}}}"
INPUT_PATH="${YOLOV8_INPUT_PATH:-${INPUT_PATH}}"
NUM_CLASSES="${YOLOV8_NUM_CLASSES:-${NUM_CLASSES}}"
BUILD_DIR="${YOLOV8_BUILD_DIR:-${BUILD_DIR}}"
IMAGE_SIZE="${YOLOV8_IMAGE_SIZE:-${IMAGE_SIZE}}"
DISPLAY_DOWNSCALE=2
ACTIVATION_BUF_SIZE="${YOLOV8_ACTIVATION_BUF_SIZE:-${ACTIVATION_BUF_SIZE}}"
NPU_ID="${YOLOV8_NPU_ID:-U85}"
NPU_CONFIG_ID="${YOLOV8_NPU_CONFIG_ID:-${NPU_CONFIG_ID}}"
NPU_MACS="${YOLOV8_NPU_MACS:-${NPU_MACS}}"
NPU_CACHE_SIZE="${YOLOV8_NPU_CACHE_SIZE:-${NPU_CACHE_SIZE:-}}"
NPU_MEMORY_MODE="${YOLOV8_MEMORY_MODE:-${NPU_MEMORY_MODE:-Shared_Sram}}"
ML_FRAMEWORK="${YOLOV8_ML_FRAMEWORK:-${ML_FRAMEWORK}}"
ET_TMP_MEM_SIZE="${YOLOV8_ET_TMP_MEM_SIZE:-${ET_TMP_MEM_SIZE}}"
ET_TMP_MEM_BASE="${YOLOV8_ET_TMP_MEM_BASE:-${ET_TMP_MEM_BASE}}"

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
MAX_DETECTIONS=20
NMS_THRESHOLD=0.45
CPU_PROFILE_ENABLED="${YOLOV8_CPU_PROFILE_ENABLED:-ON}"
BUILD_JOBS="${BUILD_JOBS:-8}"

if [[ "${ML_FRAMEWORK}" == "ExecuTorch" && "${NPU_MEMORY_MODE}" != "Dedicated_Sram" ]]; then
    printf 'ExecuTorch/PTE builds require Dedicated_Sram on this target.\n' >&2
    exit 1
fi

if [[ "${ML_FRAMEWORK}" == "ExecuTorch" ]]; then
    NPU_CACHE_SIZE="${NPU_CACHE_SIZE:-393216}"
fi

if [[ ! -f "${MODEL_PATH}" ]]; then
    printf 'Model not found: %s\n' "${MODEL_PATH}" >&2
    exit 1
fi

if [[ ! -e "${INPUT_PATH}" ]]; then
    printf 'Input path not found: %s\n' "${INPUT_PATH}" >&2
    exit 1
fi

if [[ ! -f "${LABELS_FILE}" ]]; then
    printf 'Labels file not found: %s\n' "${LABELS_FILE}" >&2
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
        printf 'ExecuTorch temporary memory size is empty. Set YOLOV8_ET_TMP_MEM_SIZE.\n' >&2
        exit 1
    fi
    FRAMEWORK_MEMORY_OPTIONS+=("-DML_FWK_TMP_MEM_SIZE=${ET_TMP_MEM_SIZE}")
    if [[ -n "${ET_TMP_MEM_BASE}" ]]; then
        FRAMEWORK_MEMORY_OPTIONS+=("-DML_FWK_TMP_MEM_BASE=${ET_TMP_MEM_BASE}")
    fi
fi

printf 'Configuring YOLOv8 MPS4 board build\n'
printf '  Build directory: %s\n' "${BUILD_DIR}"
printf '  Model:           %s\n' "${MODEL_PATH}"
printf '  Labels:          %s\n' "${LABELS_FILE}"
printf '  Input:           %s\n' "${INPUT_PATH}"
printf '  NPU:             Ethos-%s %s (%s MACs)\n' "${NPU_ID}" "${NPU_CONFIG_ID}" "${NPU_MACS}"
printf '  Memory mode:     %s\n' "${NPU_MEMORY_MODE}"
printf '  CPU profiling:   %s\n' "${CPU_PROFILE_ENABLED}"
printf '  Activation buf:  %s\n' "${ACTIVATION_BUF_SIZE}"
if [[ "${ML_FRAMEWORK}" == "ExecuTorch" ]]; then
    printf '  ET temp memory:  %s\n' "${ET_TMP_MEM_SIZE}"
    if [[ -n "${ET_TMP_MEM_BASE}" ]]; then
        printf '  ET temp base:    %s\n' "${ET_TMP_MEM_BASE}"
    fi
fi

cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" \
    -DTARGET_PLATFORM=mps4 \
    -DTARGET_SUBSYSTEM=sse-320 \
    -DML_FRAMEWORK="${ML_FRAMEWORK}" \
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
