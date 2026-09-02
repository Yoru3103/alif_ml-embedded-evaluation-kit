#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${REPO_ROOT}/build-fvp320-asr"
MODEL_PATH="${REPO_ROOT}/resources_downloaded/asr/wav2letter_pruned_int8_vela_Z256.tflite"
INPUT_PATH="${REPO_ROOT}/resources/asr/samples"
LABELS_TXT="${REPO_ROOT}/resources/asr/labels/labels_wav2letter.txt"

NPU_MEMORY_MODE=Shared_Sram
ACTIVATION_BUF_SIZE=0x00200000
BUILD_JOBS="${BUILD_JOBS:-8}"

if [[ ! -f "${MODEL_PATH}" ]]; then
    printf 'Model not found: %s\n' "${MODEL_PATH}" >&2
    exit 1
fi

if [[ ! -e "${INPUT_PATH}" ]]; then
    printf 'Input path not found: %s\n' "${INPUT_PATH}" >&2
    exit 1
fi

if [[ ! -f "${LABELS_TXT}" ]]; then
    printf 'Labels file not found: %s\n' "${LABELS_TXT}" >&2
    exit 1
fi

printf 'Configuring ASR FVP build\n'
printf '  Build directory: %s\n' "${BUILD_DIR}"
printf '  Model:           %s\n' "${MODEL_PATH}"
printf '  Input:           %s\n' "${INPUT_PATH}"
printf '  Memory mode:     %s\n' "${NPU_MEMORY_MODE}"

cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" \
    -DTARGET_PLATFORM=mps4 \
    -DTARGET_SUBSYSTEM=sse-320 \
    -DML_FRAMEWORK=TensorFlowLiteMicro \
    -DUSE_CASE_BUILD=asr \
    -DUSE_SINGLE_INPUT=OFF \
    -DETHOS_U_NPU_ENABLED=ON \
    -DETHOS_U_NPU_ID=U85 \
    -DETHOS_U_NPU_CONFIG_ID=Z256 \
    -DETHOS_U_NPU_MEMORY_MODE="${NPU_MEMORY_MODE}" \
    -DETHOS_U_NPU_TIMING_ADAPTER_ENABLED=ON \
    -Dasr_MODEL_IN_EXT_FLASH=OFF \
    -Dasr_MODEL_PATH="${MODEL_PATH}" \
    -Dasr_FILE_PATH="${INPUT_PATH}" \
    -Dasr_LABELS_TXT_FILE="${LABELS_TXT}" \
    -Dasr_ACTIVATION_BUF_SZ="${ACTIVATION_BUF_SIZE}"

cmake --build "${BUILD_DIR}" \
    --target mlek_asr \
    --parallel "${BUILD_JOBS}"

printf 'Build complete: %s\n' "${BUILD_DIR}/bin/mlek_asr.axf"
