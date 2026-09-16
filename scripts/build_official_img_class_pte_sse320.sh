#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/config/official_sse320.sh"
# Keep framework-specific caches and generated sources separate from TFLM.
PTE_BUILD_DIR="${OFFICIAL_PTE_BUILD_DIR:-${OFFICIAL_BUILD_DIR}-img-class-pte}"
MODEL_PATH="${PTE_BUILD_DIR}/models/mv2_arm_delegate_ethos-u85-${NPU_MACS}.pte"
PYTHON="${OFFICIAL_PTE_PYTHON:-${REPO_ROOT}/resources_downloaded/env/bin/python}"
WEIGHTS="${OFFICIAL_PTE_WEIGHTS:-${HOME}/.cache/torch/hub/checkpoints/mobilenet_v2-7ebf99e0.pth}"
MODE_FILE="${PTE_BUILD_DIR}/memory-mode.txt"
if [[ "${PTE_BUILD_DIR}" != /* ]]; then
    printf 'OFFICIAL_PTE_BUILD_DIR must be absolute.\n' >&2
    exit 1
fi
if [[ -f "${PTE_BUILD_DIR}/CMakeCache.txt" ]]; then
    while IFS= read -r line; do
        case "${line}" in
            ML_FRAMEWORK:*=*) expected=ExecuTorch ;;
            ETHOS_U_NPU_MEMORY_MODE:*=*) expected="${NPU_MEMORY_MODE}" ;;
            *) continue ;;
        esac
        if [[ "${line#*=}" != "${expected}" ]]; then
            printf 'Incompatible CMake cache; choose a separate OFFICIAL_PTE_BUILD_DIR.\n' >&2
            exit 1
        fi
    done < "${PTE_BUILD_DIR}/CMakeCache.txt"
fi
if [[ -f "${MODE_FILE}" && "$(cat "${MODE_FILE}")" != "${NPU_MEMORY_MODE}" ]]; then
    printf 'Use a separate OFFICIAL_PTE_BUILD_DIR for each memory mode.\n' >&2
    exit 1
fi
if [[ $# -gt 1 ]]; then
    printf 'Expected at most one argument.\n' >&2
    exit 1
fi
case "${1:-build}" in
    --help|-h)
        printf '%s\n' 'Usage: build_official_img_class_pte_sse320.sh [--prepare-models]' \
            'OFFICIAL_MEMORY_MODE=Dedicated_Sram (default) or Shared_Sram' \
            'Optional: OFFICIAL_PTE_BUILD_DIR, OFFICIAL_PTE_WEIGHTS, OFFICIAL_PTE_PYTHON'
        exit 0 ;;
    --prepare-models|build) ;;
    *) printf 'Unsupported argument: %s\n' "$1" >&2; exit 1 ;;
esac
fingerprint()
{
    printf 'mode=%s\n' "${NPU_MEMORY_MODE}"
    sha256sum "${SCRIPT_DIR}/config/official_sse320.sh" \
        "${SCRIPT_DIR}/export_img_class_pte.py" "${VELA_CONFIG}" "${WEIGHTS}" || return 1
    sha256sum "${REPO_ROOT}"/resources/img_class/samples/*.bmp || return 1
}
FINGERPRINT="$(fingerprint)"
if [[ "${1:-}" == --prepare-models ]]; then
    mkdir -p "${PTE_BUILD_DIR}/models"
    printf '%s\n' "${NPU_MEMORY_MODE}" > "${MODE_FILE}"
    : > "${PTE_BUILD_DIR}/models/profile.sha256"
    "${PYTHON}" "${SCRIPT_DIR}/export_img_class_pte.py" \
        --weights "${WEIGHTS}" --samples "${REPO_ROOT}/resources/img_class/samples" \
        --output "${MODEL_PATH}" --config "${VELA_CONFIG}" \
        --system-config "${VELA_SYSTEM_CONFIG}" --memory-mode "${NPU_MEMORY_MODE}" \
        --macs "${NPU_MACS}" --arena-cache-size "${VELA_ARENA_CACHE_SIZE}" \
        --memory-budget "$((ACTIVATION_BUF_SIZE))"
    printf '%s\n' "${FINGERPRINT}" > "${PTE_BUILD_DIR}/models/profile.sha256"
    exit 0
fi
if [[ ! -f "${MODEL_PATH}" || ! -f "${PTE_BUILD_DIR}/models/profile.sha256" ]] ||
    [[ "$(cat "${PTE_BUILD_DIR}/models/profile.sha256")" != "${FINGERPRINT}" ]]; then
    printf 'PTE missing or configuration changed; run this entry with --prepare-models.\n' >&2
    exit 1
fi
TMP_IN_SRAM=OFF
if [[ "${NPU_MEMORY_MODE}" == Shared_Sram ]]; then
    TMP_IN_SRAM=ON
fi
cmake -S "${REPO_ROOT}" -B "${PTE_BUILD_DIR}" "${OFFICIAL_CMAKE_OPTIONS[@]}" \
    -DML_FRAMEWORK=ExecuTorch -DUSE_CASE_BUILD=img_class \
    "-Dimg_class_MODEL_PATH=${MODEL_PATH}" \
    "-Dimg_class_ACTIVATION_BUF_SZ=${ACTIVATION_BUF_SIZE}" \
    "-DML_FWK_TMP_MEM_SIZE=${ACTIVATION_BUF_SIZE}" \
    "-DMLEK_ET_TMP_IN_SRAM=${TMP_IN_SRAM}"
cmake --build "${PTE_BUILD_DIR}" --target mlek_img_class --parallel "${BUILD_JOBS:-8}"
printf 'PTE application: %s/bin/mlek_img_class.axf\n' "${PTE_BUILD_DIR}"
