#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/config/official_sse320.sh"

usage()
{
    cat <<'EOF'
Usage: scripts/build_official_sse320.sh [--dry-run] [all | USE_CASE ...]
       scripts/build_official_sse320.sh --prepare-models [--dry-run]
       scripts/build_official_sse320.sh --list

Default: build all nine Arm ML use cases with the shared SSE-320 profile.
First run --prepare-models to compile the downloaded original TFLite models.
Environment: BUILD_JOBS (default 8), OFFICIAL_BUILD_DIR (absolute path),
             OFFICIAL_MEMORY_MODE (Dedicated_Sram by default, or Shared_Sram),
             VELA (default resources_downloaded/env/bin/vela).
Each memory mode has its own default build and model directory.
See docs/branch_scripts_and_official_tests.md for usage and merge instructions.
EOF
}

DRY_RUN=OFF
PREPARE_MODELS=OFF
SELECTED=()
for arg in "$@"; do
    case "${arg}" in
        --help|-h) usage; exit 0 ;;
        --list) printf '%s\n' "${OFFICIAL_USE_CASES[@]}"; exit 0 ;;
        --dry-run) DRY_RUN=ON ;;
        --prepare-models) PREPARE_MODELS=ON ;;
        *) SELECTED+=("${arg}") ;;
    esac
done
if [[ "${OFFICIAL_BUILD_DIR}" != /* ]]; then
    printf 'OFFICIAL_BUILD_DIR must be an absolute path.\n' >&2
    exit 1
fi
# Protect existing firmware and models when a custom directory is reused across modes.
if [[ -f "${OFFICIAL_BUILD_DIR}/CMakeCache.txt" ]]; then
    while IFS= read -r cache_line; do
        if [[ "${cache_line}" == ETHOS_U_NPU_MEMORY_MODE:*=* ]] &&
            [[ "${cache_line#*=}" != "${NPU_MEMORY_MODE}" ]]; then
            printf 'Build directory contains %s; choose a separate OFFICIAL_BUILD_DIR for %s.\n' \
                "${cache_line#*=}" "${NPU_MEMORY_MODE}" >&2
            exit 1
        fi
    done < "${OFFICIAL_BUILD_DIR}/CMakeCache.txt"
fi
if [[ -f "${OFFICIAL_MODEL_DIR}/memory-mode.txt" ]] &&
    [[ "$(cat "${OFFICIAL_MODEL_DIR}/memory-mode.txt")" != "${NPU_MEMORY_MODE}" ]]; then
    printf '%s\n' \
        'Model directory belongs to another memory mode; choose a separate OFFICIAL_BUILD_DIR.' >&2
    exit 1
fi
if [[ ${#SELECTED[@]} == 0 || "${SELECTED[*]}" == all ]]; then
    SELECTED=("${OFFICIAL_USE_CASES[@]}")
fi
for use_case in "${SELECTED[@]}"; do
    if [[ " ${OFFICIAL_USE_CASES[*]} " != *" ${use_case} "* ]]; then
        printf 'Unsupported official use case: %s (see --list)\n' "${use_case}" >&2
        exit 1
    fi
done

run_command()
{
    printf '%q ' "$@"
    printf '\n'
    if [[ "${DRY_RUN}" != ON ]]; then
        "$@"
    fi
}

# Fingerprint original models and compilation configuration. Refuse stale/mixed models.
model_fingerprint()
{
    printf 'memory_mode=%s\ncache_size=%s\n' "${NPU_MEMORY_MODE}" "${NPU_CACHE_SIZE}"
    sha256sum "${SCRIPT_DIR}/config/official_sse320.sh" "${VELA_CONFIG}" || return 1
    for model in "${OFFICIAL_MODELS[@]}"; do
        sha256sum "${REPO_ROOT}/resources_downloaded/${model}.tflite" || return 1
    done
}

if [[ "${PREPARE_MODELS}" == ON ]]; then
    VELA="${VELA:-${REPO_ROOT}/resources_downloaded/env/bin/vela}"
    if [[ "${DRY_RUN}" != ON ]]; then
        # Preflight every input before invoking Vela or changing the model manifest.
        FINGERPRINT="$(model_fingerprint)"
        command -v "${VELA}" >/dev/null
        mkdir -p "${OFFICIAL_MODEL_DIR}"
        printf '%s\n' "${NPU_MEMORY_MODE}" > "${OFFICIAL_MODEL_DIR}/memory-mode.txt"
        # Invalidate the manifest before compilation, so partial failures cannot look successful.
        : > "${OFFICIAL_MODEL_DIR}/profile.sha256"
    fi
    for model in "${OFFICIAL_MODELS[@]}"; do
        output_dir="${OFFICIAL_MODEL_DIR}/${model%/*}"
        run_command mkdir -p "${output_dir}"
        run_command "${VELA}" \
            --config "${VELA_CONFIG}" \
            --accelerator-config "ethos-u85-${NPU_MACS}" \
            --system-config "${VELA_SYSTEM_CONFIG}" \
            --memory-mode "${NPU_MEMORY_MODE}" \
            --arena-cache-size "${VELA_ARENA_CACHE_SIZE}" \
            --output-dir "${output_dir}" \
            "${REPO_ROOT}/resources_downloaded/${model}.tflite"
        run_command mv "${output_dir}/${model##*/}_vela.tflite" \
            "${OFFICIAL_MODEL_DIR}/${model}_vela_Z${NPU_MACS}.tflite"
    done
    if [[ "${DRY_RUN}" != ON ]]; then
        printf '%s\n' "${FINGERPRINT}" > "${OFFICIAL_MODEL_DIR}/profile.sha256"
        "${VELA}" --version > "${OFFICIAL_MODEL_DIR}/vela-version.txt"
    fi
    exit 0
fi

if [[ "${DRY_RUN}" != ON ]]; then
    FINGERPRINT="$(model_fingerprint)"
    if [[ ! -f "${OFFICIAL_MODEL_DIR}/profile.sha256" ]] ||
        [[ "$(cat "${OFFICIAL_MODEL_DIR}/profile.sha256")" != "${FINGERPRINT}" ]]; then
        printf 'Models missing or profile changed. Run:\n' >&2
        printf 'OFFICIAL_MEMORY_MODE=%q OFFICIAL_BUILD_DIR=%q %q --prepare-models\n' \
            "${NPU_MEMORY_MODE}" "${OFFICIAL_BUILD_DIR}" "$0" >&2
        exit 1
    fi
fi

TARGETS=()
for model in "${OFFICIAL_MODELS[@]}"; do
    use_case="${model%/*}"
    model_option="${use_case}_MODEL_PATH"
    if [[ "${use_case}" == kws_asr ]]; then
        case "${model##*/}" in
            kws_*) model_option+=_KWS ;;
            wav2letter_*) model_option+=_ASR ;;
        esac
    fi
    OFFICIAL_CMAKE_OPTIONS+=(
        "-D${model_option}=${OFFICIAL_MODEL_DIR}/${model}_vela_Z${NPU_MACS}.tflite"
    )
done
for use_case in "${OFFICIAL_USE_CASES[@]}"; do
    # Equal arena budgets and model placement, including combined KWS/ASR.
    OFFICIAL_CMAKE_OPTIONS+=("-D${use_case}_ACTIVATION_BUF_SZ=${ACTIVATION_BUF_SIZE}")
done
OFFICIAL_CMAKE_OPTIONS+=(
    -Dasr_MODEL_IN_EXT_FLASH=OFF
    -Dkws_asr_MODEL_IN_EXT_FLASH=OFF
    -Dinference_runner_MODEL_IN_EXT_FLASH=OFF
    -Dinference_runner_DYNAMIC_MEM_LOAD_ENABLED=OFF
)
for use_case in "${SELECTED[@]}"; do
    TARGETS+=("mlek_${use_case}")
done
# Always configure the same suite. Selection only changes which targets are built.
USE_CASE_LIST="$(IFS=';'; printf '%s' "${OFFICIAL_USE_CASES[*]}")"
run_command cmake -S "${REPO_ROOT}" -B "${OFFICIAL_BUILD_DIR}" \
    "${OFFICIAL_CMAKE_OPTIONS[@]}" "-DUSE_CASE_BUILD=${USE_CASE_LIST}"
run_command cmake --build "${OFFICIAL_BUILD_DIR}" --target "${TARGETS[@]}" \
    --parallel "${BUILD_JOBS:-8}"
printf 'Official applications: %s/bin/mlek_<use_case>.axf\n' "${OFFICIAL_BUILD_DIR}"
