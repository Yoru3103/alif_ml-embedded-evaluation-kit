#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${REPO_ROOT}/build-fvp320-kws"
MODEL_PATH="${KWS_MODEL_PATH:-${REPO_ROOT}/resources_downloaded/kws/kws_micronet_m_vela_Z256.tflite}"
INPUT_PATH="${KWS_INPUT_PATH:-${REPO_ROOT}/resources/kws/samples}"
LABELS_TXT="${KWS_LABELS_TXT:-${REPO_ROOT}/resources/kws/labels/micronet_kws_labels.txt}"

# Corstone-320 FVP: Ethos-U85, 256 MACs, Dedicated SRAM.
NPU_MEMORY_MODE=Dedicated_Sram
ACTIVATION_BUF_SIZE=0x00100000
BUILD_JOBS="${BUILD_JOBS:-8}"

if [[ ! -f "${MODEL_PATH}" ]]; then
    printf 'KWS model not found: %s\n' "${MODEL_PATH}" >&2
    printf 'Prepare the U85/Z256 Vela model first; see docs/quick_start.md.\n' >&2
    exit 1
fi

if [[ ! -e "${INPUT_PATH}" ]]; then
    printf 'KWS input path not found: %s\n' "${INPUT_PATH}" >&2
    exit 1
fi

if [[ ! -f "${LABELS_TXT}" ]]; then
    printf 'KWS labels file not found: %s\n' "${LABELS_TXT}" >&2
    exit 1
fi

printf 'Configuring KWS FVP build\n'
printf '  Build directory: %s\n' "${BUILD_DIR}"
printf '  Model:           %s\n' "${MODEL_PATH}"
printf '  Input:           %s\n' "${INPUT_PATH}"
printf '  Memory mode:     %s\n' "${NPU_MEMORY_MODE}"

cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" \
    -DTARGET_PLATFORM=mps4 \
    -DTARGET_SUBSYSTEM=sse-320 \
    -DML_FRAMEWORK=TensorFlowLiteMicro \
    -DUSE_CASE_BUILD=kws \
    -DUSE_SINGLE_INPUT=OFF \
    -DETHOS_U_NPU_ENABLED=ON \
    -DETHOS_U_NPU_ID=U85 \
    -DETHOS_U_NPU_CONFIG_ID=Z256 \
    -DETHOS_U_NPU_MEMORY_MODE="${NPU_MEMORY_MODE}" \
    -DETHOS_U_NPU_CACHE_SIZE=393216 \
    -DETHOS_U_NPU_TIMING_ADAPTER_ENABLED=ON \
    -Dkws_MODEL_PATH="${MODEL_PATH}" \
    -Dkws_FILE_PATH="${INPUT_PATH}" \
    -Dkws_LABELS_TXT_FILE="${LABELS_TXT}" \
    -Dkws_ACTIVATION_BUF_SZ="${ACTIVATION_BUF_SIZE}"

cmake --build "${BUILD_DIR}" \
    --target mlek_kws \
    --parallel "${BUILD_JOBS}"

printf 'Build complete: %s\n' "${BUILD_DIR}/bin/mlek_kws.axf"
