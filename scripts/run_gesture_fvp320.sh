#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Select the Gesture build with GESTURE_MODEL_VARIANT:
#   tflite - TensorFlow Lite Micro build
#   pte    - ExecuTorch PTE build
MODEL_VARIANT="${GESTURE_MODEL_VARIANT:-tflite}"
case "${MODEL_VARIANT}" in
tflite)
    BUILD_DIR="${REPO_ROOT}/build-mps4-gesture-tflite"
    RUN_NAME=gesture_tflite
    ML_FRAMEWORK=TensorFlowLiteMicro
    ;;
pte)
    BUILD_DIR="${REPO_ROOT}/build-mps4-gesture-pte"
    RUN_NAME=gesture_pte
    ML_FRAMEWORK=ExecuTorch
    ;;
*)
    printf 'Unsupported Gesture model variant: %s (use tflite or pte)\n' \
        "${MODEL_VARIANT}" >&2
    exit 1
    ;;
esac

BUILD_DIR="${GESTURE_BUILD_DIR:-${BUILD_DIR}}"
NPU_MACS="${GESTURE_NPU_MACS:-1024}"

FVP_ROOT="${FVP_ROOT:-/home/xx/FVP_Corstone_SSE-320}"
FVP_RUNTIME="${FVP_ROOT}/scripts/runtime.sh"
FVP_BINARY="${FVP_ROOT}/models/Linux64_GCC-9.3/FVP_Corstone_SSE-320"
APPLICATION="${BUILD_DIR}/bin/mlek_yolov8_detection.axf"
LOG_FILE="${REPO_ROOT}/logs/${RUN_NAME}_fvp320.log"

# Headless mode (enabled by default). Override these for GUI runs.
BOARD_VISUALISATION_DISABLED="${GESTURE_BOARD_VISUALISATION_DISABLED:-0}"
HDLCD_VISUALISATION_DISABLED="${GESTURE_HDLCD_VISUALISATION_DISABLED:-0}"
SHUTDOWN_ON_EOT="${GESTURE_SHUTDOWN_ON_EOT:-1}"

# Optional FVP diagnostics. Add pairs of "-C" and "component.option=value".
EXTRA_FVP_OPTIONS=()

if [[ ! -f "${FVP_RUNTIME}" ]]; then
    printf 'FVP runtime script not found: %s\n' "${FVP_RUNTIME}" >&2
    exit 1
fi

if [[ ! -x "${FVP_BINARY}" ]]; then
    printf 'FVP executable not found: %s\n' "${FVP_BINARY}" >&2
    exit 1
fi

if [[ ! -f "${APPLICATION}" ]]; then
    printf 'Gesture %s application not found: %s\n' "${MODEL_VARIANT}" \
        "${APPLICATION}" >&2
    printf 'Run GESTURE_MODEL_VARIANT=%s ./scripts/build_gesture_fvp320.sh first.\n' \
        "${MODEL_VARIANT}" >&2
    exit 1
fi

mkdir -p "${REPO_ROOT}/logs"

# The Arm FVP runtime expects errexit to be disabled while sourced.
# shellcheck source=/dev/null
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
set +e
source "${FVP_RUNTIME}"
set -e

printf 'Running Corstone-320 FVP Gesture demo\n'
printf '  Variant:     %s\n' "${MODEL_VARIANT}"
printf '  Framework:   %s\n' "${ML_FRAMEWORK}"
printf '  Application: %s\n' "${APPLICATION}"
printf '  NPU MACs:    %s\n' "${NPU_MACS}"
printf '  Log:         %s\n' "${LOG_FILE}"

"${FVP_BINARY}" \
    -a "${APPLICATION}" \
    -C mps4_board.subsystem.ethosu.num_macs="${NPU_MACS}" \
    -C mps4_board.telnetterminal0.start_telnet=0 \
    -C mps4_board.uart0.out_file=- \
    -C mps4_board.uart0.shutdown_on_eot="${SHUTDOWN_ON_EOT}" \
    -C mps4_board.visualisation.disable-visualisation="${BOARD_VISUALISATION_DISABLED}" \
    -C vis_hdlcd.disable_visualisation="${HDLCD_VISUALISATION_DISABLED}" \
    "${EXTRA_FVP_OPTIONS[@]}" \
    --stat \
    2>&1 | tee "${LOG_FILE}"
